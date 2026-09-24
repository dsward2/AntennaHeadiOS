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
/// It also plays **recordings** (`Source.recording`): AntennaHead's
/// Range-capable `/recordings-download/…` files, which seek. A recording
/// resumes where it was paused, retries from the same position after a
/// network failure, skips back and forward, and stops at its end instead of
/// reconnecting.
///
/// Audio always comes straight from the server: the iPhone relay carries API
/// calls, not audio.
@MainActor
@Observable
final class WatchAudioPlayer {
    enum State: String {
        case idle, activating, buffering, playing, reconnecting, paused, failed
    }

    enum Source: Equatable {
        /// The live HLS stream.
        case live(URL)
        /// A recording file, with its name for display.
        case recording(URL, name: String)

        var url: URL {
            switch self {
            case .live(let url), .recording(let url, _): url
            }
        }

        var isLive: Bool {
            if case .live = self { return true }
            return false
        }

        var recordingName: String? {
            if case .recording(_, let name) = self { return name }
            return nil
        }
    }

    /// Skip intervals for recordings (the Now Playing screen's buttons too).
    static let skipBack: Double = 15
    static let skipForward: Double = 30

    private(set) var state: State = .idle
    private(set) var statusText = "Not listening"

    /// True from a Listen tap (or Now Playing play) until Stop Listening,
    /// Now Playing pause, or losing the output.
    private(set) var wantsToPlay = false

    private(set) var source: Source?
    /// A recording's playback position and length, in seconds, updated
    /// every half second while one is loaded; `nil` for the live stream.
    private(set) var position: Double?
    private(set) var duration: Double?

    var nowPlayingTitle: String? { didSet { updateNowPlayingInfo() } }
    var nowPlayingSubtitle: String? { didSet { updateNowPlayingInfo() } }

    private static let log = Logger(subsystem: "com.dsward.AntennaHeadiOS.watchkitapp", category: "Player")

    private var isInterrupted = false
    /// Where a recording picks up after a failure or a reload.
    private var resumePosition: Double = 0
    private var timeObserver: Any?
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
        observePosition()
    }

    // MARK: Commands

    /// Starts `source`: picks an output (the system may ask), then loads it.
    func play(_ source: Source, authorization: String?) async {
        self.source = source
        self.authorization = authorization
        resumePosition = 0
        position = source.isLive ? nil : 0
        duration = nil
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
        source = nil
        position = nil
        duration = nil
        setState(.idle, status)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Pause, from the app or the system Now Playing screen. Unlike
    /// `stopListening()`, keeps the audio session and the Now Playing entry,
    /// so watchOS keeps sending this app the play command. (Clearing them
    /// made play do nothing.) The live item is dropped so play starts at the
    /// live edge; a recording keeps its item and position.
    func pause() {
        wantsToPlay = false
        cancelRecovery()
        player.pause()
        if source?.isLive != false {
            player.replaceCurrentItem(with: nil)
        } else {
            resumePosition = player.currentTime().seconds.finiteOrZero
        }
        setState(.paused, "Paused")
    }

    /// Resume after `pause()`: a recording continues where it was, the live
    /// stream restarts at the live edge. No output picker, since the session
    /// is still active.
    func resume() {
        guard source != nil, !wantsToPlay else { return }
        wantsToPlay = true
        reconnectAttempt = 0
        if source?.isLive == false, let item = player.currentItem, item.status != .failed {
            player.play()
            setState(.buffering, "Resuming…")
        } else {
            loadFreshItem()
        }
    }

    /// The server changed (tune, scan, Stop): a fresh item jumps to the live
    /// edge so the change is heard now, not after the buffer drains. If a
    /// recording was playing, switch back to the live stream, as the Apple TV
    /// app does, since the listener just chose something live.
    func jumpToLiveEdge(liveURL: URL?) {
        guard wantsToPlay, !isInterrupted, state != .activating else { return }
        if source?.isLive == false {
            guard let liveURL else { return }
            source = .live(liveURL)
            position = nil
            duration = nil
        }
        reconnectAttempt = 0
        loadFreshItem()
    }

    /// Switch from a recording back to the live stream.
    func returnToLive(_ liveURL: URL) {
        source = .live(liveURL)
        position = nil
        duration = nil
        wantsToPlay = true
        reconnectAttempt = 0
        loadFreshItem()
    }

    /// Moves a recording's position by `seconds` (negative skips back).
    func skip(by seconds: Double) {
        guard let current = position else { return }
        seek(to: current + seconds)
    }

    func seek(to seconds: Double) {
        guard source?.isLive == false else { return }
        let upper = (duration ?? .infinity) - 0.5
        let target = max(0, min(seconds, upper))
        resumePosition = target
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.updateNowPlayingInfo() }
        }
    }

    /// The app came back to the foreground. If audio is wanted but isn't
    /// playing (an interruption whose end never arrived, say), restart it.
    func appBecameActive() {
        guard wantsToPlay, !isInterrupted, reconnectTask == nil, state != .activating,
              player.timeControlStatus != .playing else { return }
        reconnectAttempt = 0
        if source?.isLive == false, let item = player.currentItem, item.status == .readyToPlay {
            player.play()
        } else {
            loadFreshItem()
        }
    }

    // MARK: Loading

    private func loadFreshItem() {
        guard let source else { return }
        cancelRecovery()
        // watchOS has no AVAssetResourceLoader to answer a 401 the way the
        // iPhone app does, so the login is sent up front with every playlist
        // and segment request. ("AVURLAssetHTTPHeaderFieldsKey" is
        // undocumented but long-standing.)
        var options: [String: Any] = [:]
        if let authorization {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": authorization]
        }
        let asset = AVURLAsset(url: source.url, options: options)
        let item = AVPlayerItem(asset: asset)
        observe(item)
        player.replaceCurrentItem(with: item)
        if !source.isLive, resumePosition > 0 {
            // Pick up where the recording was (after a failure or reload).
            player.seek(to: CMTime(seconds: resumePosition, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        setState(.buffering, source.isLive ? "Connecting…"
                 : "Loading recording… The Mac may take a minute to prepare a long one the first time.")
    }


    // MARK: Recovery

    private func scheduleRecovery(_ reason: String) {
        guard wantsToPlay, !isInterrupted, reconnectTask == nil else { return }
        stallWatchdog?.cancel()
        stallWatchdog = nil
        reconnectAttempt += 1
        if source?.isLive == false {
            // Retry from where the recording got to.
            resumePosition = position ?? resumePosition
        }
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
            let what = source?.isLive == false ? "Playing recording" : "Listening"
            setState(.playing, route.map { "\(what) on \($0)" } ?? what)
        case .waitingToPlayAtSpecifiedRate:
            guard wantsToPlay else { return }
            // Keep a more specific message ("Connecting…", "Loading
            // recording…", "Resuming…") while one's showing.
            if state != .reconnecting && state != .buffering {
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

    /// A live stream that stays "buffering" this long isn't coming back on
    /// its own. A recording is a finite download that may just be slow.
    private func startStallWatchdog() {
        guard stallWatchdog == nil, source?.isLive != false else { return }
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
                MainActor.assumeIsolated { self?.itemReachedEnd() }
            },
        ]
    }

    private func itemReachedEnd() {
        guard let source else { return }
        if source.isLive {
            // A live stream doesn't end: the server went away or restarted.
            scheduleRecovery("Stream ended")
        } else {
            // Stay loaded at the start, so play goes again from the top.
            wantsToPlay = false
            cancelRecovery()
            player.pause()
            seek(to: 0)
            setState(.paused, "Finished")
        }
    }

    /// Keeps `position` and `duration` current for a recording (the app's
    /// progress bar and the Now Playing screen's elapsed time).
    private func observePosition() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.source?.isLive == false else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.position = seconds }
                if let length = self.player.currentItem?.duration.seconds, length.isFinite, length > 0,
                   self.duration != length {
                    self.duration = length
                    self.updateNowPlayingInfo()
                }
            }
        }
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
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.wantsToPlay { self.pause() } else { self.resume() }
            }
            return .success
        }
        commands.nextTrackCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false

        // Recordings only (enabled in `updateNowPlayingInfo()`).
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBack)]
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForward)]
        commands.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: -Self.skipBack) }
            return .success
        }
        commands.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: Self.skipForward) }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = event.positionTime
            MainActor.assumeIsolated { self?.seek(to: target) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        // Paused stays listed (at rate 0) so the play button still reaches
        // this app; only Stop Listening and failures remove the entry.
        guard wantsToPlay || state == .paused else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let isRecording = source?.isLive == false
        let commands = MPRemoteCommandCenter.shared()
        commands.skipBackwardCommand.isEnabled = isRecording
        commands.skipForwardCommand.isEnabled = isRecording
        commands.changePlaybackPositionCommand.isEnabled = isRecording

        var info: [String: Any] = [
            MPMediaItemPropertyAlbumTitle: "AntennaHead",
            MPNowPlayingInfoPropertyIsLiveStream: !isRecording,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
        ]
        if let name = source?.recordingName {
            info[MPMediaItemPropertyTitle] = name
            info[MPMediaItemPropertyArtist] = "Recording"
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position ?? 0
            if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        } else {
            info[MPMediaItemPropertyTitle] = nowPlayingTitle ?? "AntennaHead"
            if let nowPlayingSubtitle, !nowPlayingSubtitle.isEmpty {
                info[MPMediaItemPropertyArtist] = nowPlayingSubtitle
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setState(_ newState: State, _ text: String) {
        Self.log.info("\(newState.rawValue, privacy: .public): \(text, privacy: .public)")
        state = newState
        statusText = text
        updateNowPlayingInfo()
    }
}

private extension Double {
    /// `self`, or 0 for NaN/infinity (e.g. `CMTime.invalid.seconds`).
    var finiteOrZero: Double { isFinite ? self : 0 }
}
