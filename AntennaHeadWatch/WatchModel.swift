import AntennaHeadAPI
import Foundation
import Observation
import os

/// The state the Watch screens render for the current server: Now Playing,
/// favorites, and categories, plus the actions (tune, scan, Stop, listen).
/// The Watch's slice of AntennaHeadTV's `AntennaHeadViewModel`.
@MainActor
@Observable
final class WatchModel {
    private static let log = Logger(subsystem: "com.dsward.AntennaHeadiOS.watchkitapp", category: "Model")

    let store: WatchServerStore
    let link: PhoneLink
    let player: WatchAudioPlayer

    private(set) var nowPlaying: NowPlayingStatus?
    private(set) var favorites: [FrequencySummary]?
    private(set) var categories: [CategorySummary]?

    // Other sources, each loaded when its screen opens (WatchModel+Sources).
    var devices: [DeviceSummary]?
    var controlBoothStatus: ControlBoothStatus?
    var gqrxStatus: GqrxStatus?
    var gqrxBookmarks: [GqrxBookmarkSummary]?
    /// Why the bookmarks couldn't be loaded (Gqrx's remote control off, say).
    /// Shown in place of the list, since it's a state, not a failed action.
    var gqrxBookmarksMessage: String?
    var audioFiles: FolderListing?
    var textToSpeechFiles: FolderListing?
    var rssFeeds: [RSSFeedSummary]?
    /// How the last API call reached the server.
    private(set) var route: WatchAPIClient.Route?
    private(set) var isLoading = false
    var errorMessage: String?
    /// Set by the app from its scene phase; polls less often in the
    /// background (where the app only runs while audio plays).
    var isForeground = true

    private(set) var client: WatchAPIClient?
    /// The message the poll last put in `errorMessage`, so a later successful
    /// poll clears only its own error, never a failed action's.
    private var pollErrorMessage: String?

    init(store: WatchServerStore, link: PhoneLink, player: WatchAudioPlayer) {
        self.store = store
        self.link = link
        self.player = player
    }

    /// Loads everything for the current server. Runs whenever the server
    /// changes, including when its details arrive from the iPhone.
    func connect() async {
        guard let server = store.current else {
            client = nil
            return
        }
        if client?.server != server {
            if player.wantsToPlay, client != nil { player.stopListening() }
            client = WatchAPIClient(server: server, link: link)
            nowPlaying = nil
            favorites = nil
            categories = nil
            devices = nil
            controlBoothStatus = nil
            gqrxStatus = nil
            gqrxBookmarks = nil
            gqrxBookmarksMessage = nil
            audioFiles = nil
            textToSpeechFiles = nil
            rssFeeds = nil
        }
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        await refreshNowPlaying()
        await refreshLists()
    }

    func refreshLists() async {
        guard let client else { return }
        do {
            favorites = try await client.favorites()
            categories = try await client.categories()
            route = client.lastRoute
        } catch {
            report(error)
        }
    }

    func refreshNowPlaying() async {
        guard let client else { return }
        do {
            apply(try await client.nowPlaying())
            if route != client.lastRoute {
                Self.log.info("API route: \(client.lastRoute?.rawValue ?? "-", privacy: .public)")
            }
            route = client.lastRoute
            if let pollErrorMessage, errorMessage == pollErrorMessage {
                errorMessage = nil
            }
            pollErrorMessage = nil
        } catch {
            report(error)
            pollErrorMessage = errorMessage
        }
    }

    /// Polls Now Playing for as long as the calling `.task` lives: every 3 s
    /// on screen, every 10 s in the background while audio plays (to keep the
    /// system Now Playing screen current), otherwise not at all.
    func pollNowPlaying() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(isForeground ? 3 : 10))
            guard !Task.isCancelled else { return }
            if isForeground || player.wantsToPlay {
                await refreshNowPlaying()
            }
        }
    }

    func tune(_ frequency: FrequencySummary) async {
        await perform { try await $0.tune(frequencyID: frequency.id) }
    }

    func startScan(_ category: CategorySummary) async {
        await perform { try await $0.startScan(categoryID: category.id) }
    }

    /// Stops the tuning pipeline on the server. The stream keeps running
    /// into the server's filler audio, so listening continues, as in every
    /// other AntennaHead client.
    func stop() async {
        await perform { try await $0.stop() }
    }

    func listen() async {
        guard let server = store.current, let base = server.baseURL,
              let url = URL(string: "/hls/index.m3u8", relativeTo: base) else {
            errorMessage = "The server's address isn't valid."
            return
        }
        await player.listen(to: url, authorization: server.basicAuthorization)
    }

    /// Runs a "start listening to X" call: shows the server's new Now
    /// Playing, and jumps the Watch's stream (if listening) to the live edge
    /// so the change is heard now.
    func perform(_ action: (WatchAPIClient) async throws -> NowPlayingStatus) async {
        guard let client else { return }
        do {
            apply(try await action(client))
            route = client.lastRoute
            errorMessage = nil
            player.jumpToLiveEdge()
        } catch {
            report(error)
        }
    }

    private func apply(_ status: NowPlayingStatus) {
        nowPlaying = status
        if status.taskMode == .stopped {
            player.nowPlayingTitle = "AntennaHead"
            player.nowPlayingSubtitle = status.statusText
        } else {
            let name = status.stationName.isEmpty ? status.statusText : status.stationName
            player.nowPlayingTitle = name
            player.nowPlayingSubtitle = [status.formattedFrequency, status.statusText == name ? nil : status.statusText]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " · ")
        }
    }

    /// Shows `error`, unless it's only the cancellation of a request whose
    /// `.task` went away.
    func report(_ error: Error) {
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        errorMessage = error.localizedDescription
        Self.log.error("\(error.localizedDescription, privacy: .public)")
    }
}
