import AVFoundation
import MediaPlayer
import Observation
import os

/// Plays AntennaHead's audio natively instead of through the web page's
/// `<audio>` element — the reason this app exists.
///
/// In Safari (and in a `WKWebView` still playing through `<audio>`), WebKit
/// won't restart media after an interruption — a notification sound, a
/// call, Siri — without a fresh user gesture, so the stream stays silent
/// until someone unlocks the phone and taps Play. A native app owns its
/// `AVAudioSession`, is told when an interruption ends, and may resume by
/// itself. This class does that, plus the things a long-running live radio
/// stream needs that a podcast player doesn't:
///
/// - **Live edge on resume.** Resuming the live HLS stream always loads a
///   fresh `AVPlayerItem` rather than un-pausing the old one, so the
///   listener hears what's on air now, not buffered audio from before the
///   interruption (the same reason the web page's `emptyBufferDataForAudioPlayer()`
///   exists).
/// - **Self-healing.** Failures, stalls that don't clear, the stream ending
///   (AntennaHead or LiveAudioServer restarting), and pauses nobody asked for
///   all trigger a reconnect with backoff, for as long as the listener still
///   wants audio (`wantsToPlay`).
/// - **Lock Screen / Control Center** controls and Now Playing details.
///
/// Recording playback ("fast download" in the web UI) is a `.file` source:
/// it's seekable and may loop, and it doesn't jump to a live edge.
@MainActor
@Observable
final class NativeAudioPlayer {
    enum Source: Equatable {
        case live(URL)
        case file(URL, loop: Bool)

        var url: URL {
            switch self {
            case .live(let url), .file(let url, _): url
            }
        }

        var isLive: Bool {
            if case .live = self { return true }
            return false
        }
    }

    /// Mirrors the strings the web page's `antennaheadNativeAudioState()`
    /// understands.
    enum State: String {
        case idle, buffering, playing, paused, reconnecting, failed
    }

    private(set) var state: State = .idle
    private(set) var statusText = "Not playing"
    private(set) var source: Source?

    /// The page's live HLS URL, reported on page load so the Lock Screen
    /// Play button and the page's own ▶︎ button can start the stream before
    /// any Listen button has been pressed.
    var defaultLiveURL: URL?

    /// Station name and detail line for the Lock Screen, from
    /// `NowPlayingMonitor`.
    var nowPlayingTitle: String? { didSet { updateNowPlayingInfo() } }
    var nowPlayingSubtitle: String? { didSet { updateNowPlayingInfo() } }

    /// Resume after *every* interruption, not only the ones iOS marks
    /// `.shouldResume`. iOS leaves that flag off after some interruptions
    /// (e.g. another app's audio that ended), and for a radio you left
    /// playing, coming back is almost always what you want.
    var resumesAfterAllInterruptions: Bool {
        get { UserDefaults.standard.object(forKey: Self.resumeAllKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.resumeAllKey) }
    }
    private static let resumeAllKey = "resumesAfterAllInterruptions"

    /// Called on every state or status change; the web view forwards it to
    /// the page's native-controls row.
    var onStateChange: ((State, String) -> Void)?

    /// The listener's intent. Everything that recovers playback checks this
    /// first, so a Pause is never undone by a reconnect.
    private var wantsToPlay = false
    private var isInterrupted = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var stallWatchdog: Task<Void, Never>?

    private var player = AVPlayer()
    private var playerObservations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private var itemNotificationTokens: [NSObjectProtocol] = []
    private let authDelegate = BasicAuthResourceLoaderDelegate()

    init() {
        observePlayer()
        observeAudioSession()
        setUpRemoteCommands()
    }

    /// HTTP Basic credentials for the stream, when AntennaHead's web login is
    /// on. The stream is proxied through the same server as the page, so
    /// it's the same login.
    func setCredential(_ credential: URLCredential?) {
        authDelegate.credential = credential
    }

    // MARK: Commands (from the page, the Lock Screen, and the app)

    func play(_ newSource: Source) {
        source = newSource
        wantsToPlay = true
        reconnectAttempt = 0
        loadFreshItem()
    }

    func pause() {
        wantsToPlay = false
        cancelRecovery()
        player.pause()
        if source?.isLive == true {
            // Drop the live item so the next Play starts at the live edge
            // instead of resuming buffered audio.
            player.replaceCurrentItem(with: nil)
        }
        setState(.paused, "Paused")
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func resume() {
        if let source {
            play(source)
        } else if let defaultLiveURL {
            play(.live(defaultLiveURL))
        }
    }

    func togglePlayPause() {
        if wantsToPlay {
            pause()
        } else {
            resume()
        }
    }

    /// Stops everything, e.g. when switching servers.
    func stop() {
        wantsToPlay = false
        cancelRecovery()
        player.pause()
        player.replaceCurrentItem(with: nil)
        source = nil
        defaultLiveURL = nil
        nowPlayingTitle = nil
        nowPlayingSubtitle = nil
        setState(.idle, "Not playing")
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The app came to the foreground. If audio was wanted but isn't
    /// playing — an interruption whose end we never heard about, say — get
    /// it going again.
    func appBecameActive() {
        guard wantsToPlay, !isInterrupted, reconnectTask == nil,
              player.timeControlStatus != .playing else { return }
        reconnectAttempt = 0
        loadFreshItem()
    }

    // MARK: Loading

    private func loadFreshItem() {
        guard let source else { return }
        cancelRecovery()
        activateSession()

        let asset = AVURLAsset(url: source.url)
        asset.resourceLoader.setDelegate(authDelegate, queue: .main)
        let item = AVPlayerItem(asset: asset)
        observe(item)
        player.replaceCurrentItem(with: item)
        player.play()
        setState(.buffering, source.isLive ? "Connecting…" : "Loading recording…")
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            setState(.failed, "Audio session error: \(error.localizedDescription)")
        }
    }

    // MARK: Recovery

    /// Reconnects after 1, 2, 4, 8, then every 15 seconds, for as long as
    /// the listener wants audio and nothing else (an interruption) owns the
    /// audio session.
    private func scheduleRecovery(_ reason: String) {
        guard wantsToPlay, !isInterrupted, reconnectTask == nil else { return }
        stallWatchdog?.cancel()
        stallWatchdog = nil
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 15)
        setState(.reconnecting, "\(reason) — reconnecting in \(Int(delay)) s")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            guard self.wantsToPlay, !self.isInterrupted else { return }
            self.loadFreshItem()
        }
    }

    private func cancelRecovery() {
        reconnectTask?.cancel()
        reconnectTask = nil
        stallWatchdog?.cancel()
        stallWatchdog = nil
    }

    // MARK: Player and item observation

    private func observePlayer() {
        playerObservations = [
            // KVO may fire off the main thread; hop over. (The class is
            // main-actor isolated, so a strong `self` is fine to send.)
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                guard let self else { return }
                Task { @MainActor in self.timeControlStatusChanged() }
            },
        ]
    }

    private func timeControlStatusChanged() {
        switch player.timeControlStatus {
        case .playing:
            reconnectAttempt = 0
            stallWatchdog?.cancel()
            stallWatchdog = nil
            setState(.playing, playingStatusText())
        case .waitingToPlayAtSpecifiedRate:
            guard wantsToPlay else { return }
            if state != .reconnecting {
                setState(.buffering, "Buffering…")
            }
            startStallWatchdog()
        case .paused:
            // A pause nobody asked for — not the listener (wantsToPlay is
            // still true) and not an interruption. Give an interruption
            // notification a moment to arrive first, since it can land after
            // this KVO change.
            guard wantsToPlay else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.wantsToPlay, !self.isInterrupted,
                      self.player.timeControlStatus == .paused else { return }
                self.scheduleRecovery("Playback stopped")
            }
        @unknown default:
            break
        }
    }

    /// A live stream that stays "buffering" this long isn't coming back on
    /// its own — reconnect. A recording is given the benefit of the doubt:
    /// it's a finite download that may just be slow.
    private func startStallWatchdog() {
        guard stallWatchdog == nil, source?.isLive == true else { return }
        stallWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled else { return }
            self.stallWatchdog = nil
            if self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                self.scheduleRecovery("Stream stalled")
            }
        }
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                // Re-read the current item rather than sending the observed
                // one across; a replaced item's failure no longer matters.
                guard let current = self.player.currentItem, current.status == .failed else { return }
                self.scheduleRecovery(Self.describe(current.error, fallback: "Stream error"))
            }
        }

        let center = NotificationCenter.default
        itemNotificationTokens.forEach(center.removeObserver)
        itemNotificationTokens = [
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated {
                    self?.scheduleRecovery(Self.describe(error, fallback: "Stream interrupted"))
                }
            },
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.itemReachedEnd() }
            },
        ]
    }

    private func itemReachedEnd() {
        switch source {
        case .live:
            // A live stream doesn't end — the server went away or restarted.
            scheduleRecovery("Stream ended")
        case .file(_, let loop) where loop:
            player.seek(to: .zero)
            player.play()
        case .file:
            wantsToPlay = false
            setState(.idle, "Recording finished")
        case nil:
            break
        }
    }

    private static func describe(_ error: Error?, fallback: String) -> String {
        guard let error else { return fallback }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorUserAuthenticationRequired {
            return "Login needed"
        }
        return error.localizedDescription
    }

    // MARK: Audio session notifications

    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        _ = center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                self?.handleInterruption(type: type, options: options)
            }
        }

        _ = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                // Headphones unplugged / Bluetooth gone: pause rather than
                // suddenly play out loud — the standard iOS behavior.
                if reason == .oldDeviceUnavailable, self?.wantsToPlay == true {
                    self?.pause()
                }
            }
        }

        _ = center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildAfterMediaServicesReset() }
        }
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType?,
                                    options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            isInterrupted = true
            cancelRecovery()
            if wantsToPlay {
                setState(.paused, "Interrupted — will resume")
            }
        case .ended:
            isInterrupted = false
            guard wantsToPlay else { return }
            if options.contains(.shouldResume) || resumesAfterAllInterruptions {
                reconnectAttempt = 0
                // A short pause lets the interrupting audio (a notification
                // sound, say) finish releasing the hardware first.
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, self.wantsToPlay, !self.isInterrupted else { return }
                    self.resume()
                }
            } else {
                wantsToPlay = false
                setState(.paused, "Paused by an interruption")
            }
        default:
            break
        }
    }

    /// Apple's guidance for `mediaServicesWereReset`: every AVFoundation
    /// object is now orphaned and must be recreated.
    private func rebuildAfterMediaServicesReset() {
        cancelRecovery()
        playerObservations = []
        itemObservation = nil
        player = AVPlayer()
        observePlayer()
        if wantsToPlay {
            reconnectAttempt = 0
            loadFreshItem()
        } else {
            setState(.idle, "Not playing")
        }
    }

    // MARK: Lock Screen / Control Center

    private func setUpRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        // Radio has no tracks to skip.
        commands.nextTrackCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false
    }

    private func updateNowPlayingInfo() {
        guard source != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle ?? "AntennaHead",
            MPNowPlayingInfoPropertyIsLiveStream: source?.isLive ?? true,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
        ]
        if let nowPlayingSubtitle {
            info[MPMediaItemPropertyArtist] = nowPlayingSubtitle
        }
        info[MPMediaItemPropertyAlbumTitle] = "AntennaHead"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: State

    private func playingStatusText() -> String {
        switch source {
        case .file: "Playing recording"
        default: nowPlayingTitle.map { "Playing — \($0)" } ?? "Playing live"
        }
    }

    private static let log = Logger(subsystem: "com.dsward.AntennaHeadiOS", category: "Player")

    private func setState(_ newState: State, _ text: String) {
        Self.log.info("\(newState.rawValue, privacy: .public): \(text, privacy: .public)")
        state = newState
        statusText = text
        updateNowPlayingInfo()
        onStateChange?(newState, text)
    }
}

/// Answers the HTTP Basic Auth challenge for the stream's playlist and
/// segment requests. AVFoundation asks here when the server replies 401;
/// without it, a server with the web login turned on would just fail.
final class BasicAuthResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    /// Only read and written on the main queue (the delegate queue passed to
    /// `setDelegate(_:queue:)`), hence `@unchecked Sendable`.
    nonisolated(unsafe) var credential: URLCredential?

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                                    shouldWaitForResponseTo authenticationChallenge: URLAuthenticationChallenge) -> Bool {
        let method = authenticationChallenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic,
              authenticationChallenge.previousFailureCount == 0,
              let credential else { return false }
        authenticationChallenge.sender?.use(credential, for: authenticationChallenge)
        return true
    }
}
