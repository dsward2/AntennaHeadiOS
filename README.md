# AntennaHeadiOS

iPhone and iPad app for [AntennaHead](https://github.com/dsward2/AntennaHead).
It shows AntennaHead's own web UI in a `WKWebView`, but plays the audio
natively with `AVPlayer` instead of the page's `<audio>` element.

## Why native audio

In Safari, when something interrupts AntennaHead's stream (a notification
sound, a call, Siri), WebKit won't restart the audio without a new tap, so
the radio goes silent until you unlock the phone. A native app owns its
`AVAudioSession`, gets told when an interruption ends, and can resume by
itself. `NativeAudioPlayer` does that and also:

- resumes the live stream at the **live edge**, not from stale buffered audio
- **reconnects** with backoff after errors, stalls, or the stream ending
  (for example when AntennaHead or LiveAudioServer restarts), for as long as
  you still want audio; a Pause is never undone
- keeps playing **in the background**, with **Lock Screen / Control Center**
  controls and the station name (polled from the server's `/api/v1` Now Playing API)
- pauses when headphones are unplugged, as iOS apps normally do

By default it resumes after *every* interruption, not only the ones iOS marks
"should resume" (`resumesAfterAllInterruptions`).

## How the page and the app talk

The server's `Web/index.html` checks for a `antennaheadAudio` script message
handler. When the page is running in this app, it hides its `<audio>` element
behind a small row of controls (▶︎/❚❚, status, ⋯ for the server list) and sends
the app `pageLoaded`, `playLive`, `playFile`, `toggle` and `showServers`
messages. The app reports its state back through the page's
`antennaheadNativeAudioState()`. `WebBridge.swift` documents the whole
contract.

An older AntennaHead whose page predates the bridge still works: the page
plays through `<audio>` as before, and the app adds a floating Servers button.

## Servers, VPN, and login

- **At home:** the server list finds AntennaHead Macs with Bonjour
  (`_antennahead._tcp`, the same service AntennaHeadTV uses).
- **Away from home:** connect the iPhone's VPN (WireGuard, OpenVPN, …) first,
  then use **Add Server Manually** with the Mac's address on the VPN, such as
  `10.0.0.2:8090`. Bonjour doesn't cross a VPN tunnel. iOS apps use the
  system VPN automatically, so nothing else is needed.
- **Web login:** if AntennaHead's web login is on, enter the username and
  password in the server editor, or when the app asks. The password is stored in
  the Keychain. The same login is used for the page, the audio stream, and the
  Now Playing API.
- App Transport Security allows plain HTTP (`NSAllowsArbitraryLoads`),
  because AntennaHead serves plain HTTP on the LAN and VPN addresses can be
  anything. Over WireGuard or OpenVPN the traffic is already encrypted.
  HTTPS works when the iPhone trusts the Mac's certificate. AntennaHead's
  default self-signed certificate isn't trusted yet (see Not yet done).

## Building

This is a sibling repo in the `antennahead-umbrella` workspace (see
`antennahead-workspace/README.md`). It references `../AntennaHeadAPI` as a
local Swift package, so clone it with the workspace's `bootstrap.sh`.

Open `AntennaHeadiOS.xcodeproj`, choose the `AntennaHeadiOS` scheme, and run.
It needs iOS 17 or later. The project uses a synchronized folder group, so
new files in `AntennaHeadiOS/` are picked up automatically.

## Status

Verified in the iOS Simulator against a live AntennaHead:

- Bonjour discovery and address resolution
- the page switching to native controls
- native HLS playback, with the Now Playing title from the API
- background playback
- Pause, including that reconnects don't undo it
- the fallback for an older server's page

Verified on an iPhone 15 Pro Max:

- live HLS playback of an AntennaHead source (iMic USB audio input)
- the diagnostics that found a failure caused by a dead AirPlay route (see
  Troubleshooting)

Not yet verified:

- automatic resume after real interruptions (notification sounds, calls, Siri)
- Lock Screen controls
- reconnects after the server restarts
- web login against a server with Basic Auth turned on
- recording playback

## Troubleshooting

**Plays for a second, then "reconnecting" over and over.** The iPhone's audio
output is probably set to an AirPlay speaker that isn't responding, such as
ControlBooth's AirPlay Receiver after it has been turned off. CoreMedia reports
this only as `CoreMediaErrorDomain 1852797029` (`'nope'`). The app names the
AirPlay speaker in its status line and shows an output picker. Choose iPhone
there, or in Control Center.

**Debugging on a device.** Debug builds print player state, the full error,
and an access-log summary to stdout, and accept two launch arguments:

```bash
xcrun devicectl device process launch --device <UDID> --console com.dsward.AntennaHeadiOS -- -autoplayLive YES -liveURLOverride http://<mac>:8080/hls/index.m3u8
```

`-autoplayLive YES` starts the live stream without a tap, and
`-liveURLOverride` plays a different URL (for example, LiveAudioServer
directly, bypassing AntennaHead's proxy).

## Apple Watch

The `AntennaHeadWatch` target is a watchOS 10 companion app, embedded in the
iPhone app (`com.dsward.AntennaHeadiOS.watchkitapp`). It has AntennaHead TV's
core features: Now Playing, Favorites (tap to tune), Categories (tap to
scan), Stop, and listening on Bluetooth headphones.

**More Sources** starts the other AntennaHead sources on the Mac, each with
one tap: ControlBooth pipelines, the AirPlay Receiver, Gqrx (launch, or play
a bookmark, in stereo or mono), the Mac's input devices, Play Audio Files
(everything, a playlist, or one file), Text to Speech (everything or one
file), and Speak RSS Headlines (all feeds or one). Order and Repeat are
remembered. Selecting several files at once, Spatial Audio, and Captions
are left to the other clients.

**Recordings** (also under More Sources) plays AntennaHead's recordings on
the Watch itself, newest first, from the Range-capable
`/recordings-download/` route, so they seek. Tapping one goes back to Now
Playing with a Recording section: progress, back 15 s, pause/resume, forward
30 s, and **Back to Live**. The system Now Playing screen gets the same skip
buttons and a scrubber. Tuning, scanning, or Stop switch back to the live
stream. The first play of a long `.aac` recording can take a minute or two:
the Mac remuxes it to `.m4a` once and caches the result.

**Reaching the server.** watchOS has no VPN. The Watch calls the API
directly first. That works at home, and also away from home when its traffic
goes through a nearby iPhone that's on the VPN (tested: iPhone on cellular
with WireGuard, Watch Wi-Fi off, and the stream played on the Watch). When a
direct call fails for lack of a network path, the Watch asks the iPhone app
to make it instead (`WatchSync`, over WatchConnectivity), and keeps using the
iPhone for a minute. Now Playing shows "via iPhone" when that happens. The
relay carries `/api/v1/` calls only. Audio always comes straight from the
server, so listening needs a direct path.

WatchConnectivity only reaches the iPhone while the Watch app is in the
foreground, so the relay is used only then. It wakes the iPhone app in the
background if needed. In the background the Watch uses the direct path,
which it needs for audio anyway. Measured with the iPhone app closed: 60
relayed requests in a row with no failures, 100–300 ms each, up to about
1 s right after the iPhone app was woken.

**Servers.** The iPhone app sends its saved servers and web logins to the
Watch (`Shared/WatchLink.swift` is compiled into both apps). The Watch keeps
them in its Keychain. You can also add a server on the Watch, for use
without the iPhone app. Watch → Servers also shows how the Watch is
connected.

Stop stops the tuning on the Mac, and listening continues into the filler
audio, as in the other clients.

Debug builds accept `-forceRelay YES` (always use the iPhone relay), e.g.
`xcrun devicectl device process launch --device <watch> com.dsward.AntennaHeadiOS.watchkitapp -- -forceRelay YES`.
The Watch app logs to the unified log under the subsystem
`com.dsward.AntennaHeadiOS.watchkitapp` (categories Player, API,
PhoneLink, Model, Servers).

Installing directly on the Watch with devicectl needs the iPhone connected
to the Mac by USB. The first build for a new Watch needs
`-allowProvisioningDeviceRegistration`.

## Not yet done

- Trust AntennaHead's self-signed HTTPS certificate on first use (pinning).
- A setting to turn off `resumesAfterAllInterruptions`.
- HTTPS with AntennaHead's self-signed certificate. The Watch can't
  support it at all (watchOS has no `AVAssetResourceLoader`, so its player
  only trusts certificates the system trusts). HTTPS with a trusted
  certificate works: give the server the certificate's name and HTTPS
  port, e.g. `mac.example.com:8094`, with HTTPS on. Verified in the watchOS
  simulator with the web login on, for both the API and the stream.
