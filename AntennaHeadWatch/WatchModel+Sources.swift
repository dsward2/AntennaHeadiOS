import AntennaHeadAPI
import Foundation

/// The sources beyond favorites and categories: ControlBooth (and its
/// AirPlay Receiver), Gqrx, the Mac's input devices, Play Audio Files, Text
/// to Speech, and Speak RSS Headlines. Each list is loaded when its screen
/// opens, as in AntennaHead TV, rather than all at connect time.
extension WatchModel {
    // MARK: Loading

    /// Runs `load` and stores its result, reporting failures.
    private func load<T>(_ load: (WatchAPIClient) async throws -> T, into keyPath: ReferenceWritableKeyPath<WatchModel, T?>) async {
        guard let client else { return }
        do {
            self[keyPath: keyPath] = try await load(client)
        } catch {
            report(error)
        }
    }

    func loadDevices() async { await load({ try await $0.devices() }, into: \.devices) }
    func loadControlBoothStatus() async { await load({ try await $0.controlBoothStatus() }, into: \.controlBoothStatus) }
    func loadGqrxStatus() async { await load({ try await $0.gqrxStatus() }, into: \.gqrxStatus) }
    func loadAudioFiles() async { await load({ try await $0.audioFiles() }, into: \.audioFiles) }
    func loadTextToSpeechFiles() async { await load({ try await $0.textToSpeechFiles() }, into: \.textToSpeechFiles) }
    func loadRSSFeeds() async { await load({ try await $0.rssFeeds() }, into: \.rssFeeds) }

    /// Newest first.
    func loadRecordings() async {
        await load({ try await $0.recordings().sorted { $0.modifiedAt > $1.modifiedAt } }, into: \.recordings)
    }

    func loadGqrxBookmarks() async {
        guard let client else { return }
        do {
            gqrxBookmarks = try await client.gqrxBookmarks()
            gqrxBookmarksMessage = nil
        } catch {
            if error is CancellationError { return }
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
            gqrxBookmarks = nil
            gqrxBookmarksMessage = error.localizedDescription
        }
    }

    // MARK: Devices

    func startDevice(_ device: DeviceSummary) async {
        await perform { try await $0.startDevice(name: device.name) }
    }

    // MARK: ControlBooth and AirPlay

    func launchControlBooth() async {
        await load({ try await $0.launchControlBooth() }, into: \.controlBoothStatus)
    }

    func startControlBoothPipeline(named name: String) async {
        await perform { try await $0.startControlBoothPipeline(named: name) }
        await loadControlBoothStatus()
    }

    /// Like Stop: the server falls back to the filler, and listening
    /// continues into it.
    func stopControlBooth() async {
        await perform { try await $0.stopControlBooth() }
        await loadControlBoothStatus()
    }

    func startAirPlay() async {
        await perform { try await $0.startAirPlay() }
        await loadControlBoothStatus()
    }

    func stopAirPlay() async {
        await perform { try await $0.stopAirPlay() }
        await loadControlBoothStatus()
    }

    // MARK: Gqrx

    /// Launches Gqrx and starts listening to it (the server does both).
    func launchGqrx() async {
        guard let client else { return }
        do {
            gqrxStatus = try await client.launchGqrx()
            errorMessage = nil
            await refreshNowPlaying()
            player.jumpToLiveEdge(liveURL: liveURL)
        } catch {
            report(error)
        }
    }

    func startGqrx(channels: Int) async {
        await perform { try await $0.startGqrx(channels: channels) }
    }

    func playGqrxBookmark(_ bookmark: GqrxBookmarkSummary, channels: Int) async {
        await perform { try await $0.playGqrxBookmark(frequencyHz: bookmark.frequencyHz, channels: channels) }
    }

    // MARK: Files, Text to Speech, RSS

    func startAudioFiles(_ request: StartAudioFilesRequest) async {
        await perform { try await $0.startAudioFiles(request) }
    }

    func startTextToSpeech(_ request: StartTextToSpeechRequest) async {
        await perform { try await $0.startTextToSpeech(request) }
    }

    func startRSSHeadlines(_ request: StartRSSHeadlinesRequest) async {
        await perform { try await $0.startRSSHeadlines(request) }
    }
}
