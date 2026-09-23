import AVFoundation
import MediaPlayer
import Observation
import os

/// Plays AntennaHead's live HLS stream on the Watch, following the iPhone
/// app's `NativeAudioPlayer` where watchOS allows:
///
/// - **Long-form audio session.** watchOS only streams through one, and only
///   to Bluetooth headphones or speakers. `activate()` shows the system's
///   output picker when none is connected, so it's called only for a Listen
///   tap, never for an automatic reconnect.
/// - **Live edge.** Every (re)start loads a fresh `AVPlayerItem`, so what's
///   heard is what's on the air now.
/// - **Self-healing.** Failures, stalls that don't clear, and the stream
///   ending (the server restarting) reconnect after 1, 2, 4, 8, then every
///   15 s, while the listener still wants audio. The backoff resets only
///   after 15 s of steady playback.
/// - **Interruptions** resume by themselves; losing the headphones stops.
/// - **Now Playing** details and play/pause for the system's Now Playing
///   screen.
///
/// The stream (`/hls/index.m3u8`) always comes straight from the server:
/// the iPhone relay carries API calls, not audio.
@MainActor
@Observable
final class WatchAudioPlayer {
    enum State: String {
        case idle, activating, buffering, playing, reconnecting, paused, failed
    }

    private(set) var state: State = .idle
    private(set) var statusText = "Not listening"

    /// True from a Listen tap (or Now Playing play) until Stop Listening,
    /// Now Playing pause, or losing the output.
    private(set) var wantsToPlay = false

    var nowPlayingTitle: String? { didSet { updateNowPlayingInfo() } }
    var nowPlayingSubtitle: String? { didSet { updateNowPlayingInfo() } }

    private static let log = Logger(subsystem: "com.dsward.AntennaHeadiOS.watchkitapp", category: "Player")

    private var url: URL?
    private var isInterrupted = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var stallWatchdog: Task<Void, Never>?
    private var steadyPlaybackTask: Task<Void, Never>?

    private let player = AVPlayer()
    private var playerObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var itemNotificationTokens: [NSObjectProtocol] = []
    /// `Authorization` header for the stream, when the web login is on.
    private var authorization: String?

    init() {
        observePlayer()
        observeAudioSession()
        setUpRemoteCommands()
    }

    // MARK: Commands

    /// Starts listening to `url`: picks an output (the system may ask), then
    /// loads the stream.
    func listen(to url: URL, authorization: String?) async {
        self.url = url
        self.authorization = authorization
        wantsToPlay = true
        reconnectAttempt = 0
        cancelRecovery()
        setState(.activating, "Choosing audio output…")

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            guard try await session.activate() else {
                wantsToPlay = false
                setState(.failed, "No audio output chosen")
                return
            }
        } catch {
            wantsToPlay = false
            setState(.failed, "Audio output: \(error.localizedDescription)")
            return
        }
        // The listener may have tapped Stop Listening while the picker was up.
        guard wantsToPlay else { return }
        loadFreshItem()
    }

    func stopListening(_ status: String = "Not listening") {
        wantsToPlay = false
        cancelRecovery()
        player.pause()
        player.replaceCurrentItem(with: nil)
        setState(.idle, status)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Pause from the system Now Playing screen. Unlike `stopListening()`,
    /// keeps the audio session and the Now Playing entry, so watchOS keeps
    /// sending this app the play command. (Clearing them made play do
    /// nothing.) The live item is dropped so play starts at the live edge.
    func pause() {
        wantsToPlay = false
        cancelRecovery()
        player.pause()
        player.replaceCurrentItem(with: nil)
        setState(.paused, "Paused")
    }

    /// The server changed (tune, scan, Stop): a fresh item jumps to the live
    /// edge so the change is heard now, not after the buffer drains.
    func jumpToLiveEdge() {
        guard wantsToPlay, !isInterrupted, state != .activating else { return }
        reconnectAttempt = 0
        loadFreshItem()
    }

    /// The app came back to the foreground. If audio is wanted but isn't
    /// playing (an interruption whose end never arrived, say), restart it.
    func appBecameActive() {
        guard wantsToPlay, !isInterrupted, reconnectTask == nil, state != .activating,
              player.timeControlStatus != .playing else { return }
        reconnectAttempt = 0
        loadFreshItem()
    }

    // MARK: Loading

    private func loadFreshItem() {
        guard let url else { return }
        cancelRecovery()
        // watchOS has no AVAssetResourceLoader to answer a 401 the way the
        // iPhone app does, so the login is sent up front with every playlist
        // and segment request. ("AVURLAssetHTTPHeaderFieldsKey" is
        // undocumented but long-standing.)
        var options: [String: Any] = [:]
        if let authorization {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": authorization]
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        observe(item)
        player.replaceCurrentItem(with: item)
        player.play()
        setState(.buffering, "Connecting…")
    }

    /// Restarts after a Now Playing screen play command. The session is
    /// still active from the last Listen (`pause()` keeps it), so no output
    /// picker.
    private func resumeFromRemote() {
        guard url != nil, !wantsToPlay else { return }
        wantsToPlay = true
        reconnectAttempt = 0
        loadFreshItem()
    }

    // MARK: Recovery

    private func scheduleRecovery(_ reason: String) {
        guard wantsToPlay, !isInterrupted, reconnectTask == nil else { return }
        stallWatchdog?.cancel()
        stallWatchdog = nil
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 15)
        setState(.reconnecting, "\(reason) — retrying in \(Int(delay)) s")
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

    // MARK: Observation

    private func observePlayer() {
        // KVO may fire off the main thread; hop over. (The class is
        // main-actor isolated, so a strong `self` is fine to send.)
        playerObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.timeControlStatusChanged() }
        }
    }

    private func timeControlStatusChanged() {
        switch player.timeControlStatus {
        case .playing:
            resetBackoffAfterSteadyPlayback()
            stallWatchdog?.cancel()
            stallWatchdog = nil
            let route = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName
            setState(.playing, route.map { "Listening on \($0)" } ?? "Listening")
        case .waitingToPlayAtSpecifiedRate:
            guard wantsToPlay else { return }
            if state != .reconnecting {
                setState(.buffering, "Buffering…")
            }
            startStallWatchdog()
        case .paused:
            // A pause nobody asked for. Give an interruption notification a
            // moment to arrive first, since it can land after this change.
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

    private func resetBackoffAfterSteadyPlayback() {
        steadyPlaybackTask?.cancel()
        steadyPlaybackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, self.player.timeControlStatus == .playing else { return }
            self.reconnectAttempt = 0
        }
    }

    private func startStallWatchdog() {
        guard stallWatchdog == nil else { return }
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
                // Re-read the current item; a replaced item's failure no
                // longer matters.
                guard let current = self.player.currentItem, current.status == .failed else { return }
                self.scheduleRecovery(Self.describe(current.error, item: current))
            }
        }
        let center = NotificationCenter.default
        itemNotificationTokens.forEach(center.removeObserver)
        itemNotificationTokens = [
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scheduleRecovery(Self.describe(error, item: self.player.currentItem))
                }
            },
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                // A live stream doesn't end: the server went away or restarted.
                MainActor.assumeIsolated { self?.scheduleRecovery("Stream ended") }
            },
        ]
    }

    private static func describe(_ error: Error?, item: AVPlayerItem?) -> String {
        if let nsError = error as NSError?,
           nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorUserAuthenticationRequired {
            return "Login needed"
        }
        var text = "Stream error"
        if let nsError = error as NSError? {
            text = "\(nsError.localizedFailureReason ?? nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
        }
        if let entry = item?.errorLog()?.events.last {
            text += " · HLS \(entry.errorStatusCode)"
        }
        log.error("Playback error: \(text, privacy: .public)")
        return text
    }

    // MARK: Audio session

    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        _ = center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            MainActor.assumeIsolated { self?.handleInterruption(type) }
        }
        _ = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                // Headphones gone: stop rather than reconnect to nothing.
                // Listening again brings up the output picker.
                guard let self, reason == .oldDeviceUnavailable, self.wantsToPlay else { return }
                self.stopListening("Audio output disconnected")
            }
        }
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .began:
            isInterrupted = true
            cancelRecovery()
            if wantsToPlay { setState(.buffering, "Interrupted — will resume") }
        case .ended:
            isInterrupted = false
            guard wantsToPlay else { return }
            // A radio left playing should come back, whatever the
            // `.shouldResume` flag says (as on the iPhone).
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.wantsToPlay, !self.isInterrupted else { return }
                self.reconnectAttempt = 0
                self.loadFreshItem()
            }
        default:
            break
        }
    }

    // MARK: Now Playing

    private func setUpRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeFromRemote() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.wantsToPlay { self.pause() } else { self.resumeFromRemote() }
            }
            return .success
        }
        commands.nextTrackCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false
    }

    private func updateNowPlayingInfo() {
        // Paused stays listed (at rate 0) so the play button still reaches
        // this app; only Stop Listening and failures remove the entry.
        guard wantsToPlay || state == .paused else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle ?? "AntennaHead",
            MPMediaItemPropertyAlbumTitle: "AntennaHead",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
        ]
        if let nowPlayingSubtitle, !nowPlayingSubtitle.isEmpty {
            info[MPMediaItemPropertyArtist] = nowPlayingSubtitle
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setState(_ newState: State, _ text: String) {
        Self.log.info("\(newState.rawValue, privacy: .public): \(text, privacy: .public)")
        Diagnostics.note("player \(newState.rawValue): \(text)")
        state = newState
        statusText = text
        updateNowPlayingInfo()
    }
}
