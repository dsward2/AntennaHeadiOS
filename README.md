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

Not yet verified (needs a real iPhone):

- automatic resume after real interruptions (notification sounds, calls, Siri)
- Lock Screen controls
- reconnects after the server restarts
- web login against a server with Basic Auth turned on
- recording playback

## Not yet done

- Trust AntennaHead's self-signed HTTPS certificate on first use (pinning).
- A setting to turn off `resumesAfterAllInterruptions`.
- The Apple Watch companion described in the feasibility study.
