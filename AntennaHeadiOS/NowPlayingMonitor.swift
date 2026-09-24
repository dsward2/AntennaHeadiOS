import AntennaHeadAPI
import Foundation

/// Polls the server's Now Playing API (`APIEndpoint.nowPlaying`) so the Lock Screen and Control
/// Center show the station that's actually on the air. The web page has its
/// own Now Playing display; this exists because the page's JavaScript stops
/// running when the app is in the background, while audio (and this task)
/// keep going.
@MainActor
final class NowPlayingMonitor {
    private let player: NativeAudioPlayer
    private var task: Task<Void, Never>?

    /// Called with every status the poll gets, after the player's Lock
    /// Screen details are updated (CarPlay marks what's on the air with it).
    var onStatus: ((NowPlayingStatus) -> Void)?

    init(player: NativeAudioPlayer) {
        self.player = player
    }

    func start(server: SavedServer, credential: URLCredential?) {
        stop()
        guard let url = server.baseURL.flatMap({ URL(string: String(APIEndpoint.nowPlaying.dropFirst()), relativeTo: $0) }) else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        if let credential, let user = credential.user, let password = credential.password {
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        task = Task { [weak self] in
            while !Task.isCancelled {
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   let status = try? decoder.decode(NowPlayingStatus.self, from: data) {
                    self?.apply(status)
                }
                // Every 5 s while audio is wanted, otherwise just enough to
                // stay roughly current.
                let playing = self?.player.state == .playing || self?.player.state == .buffering
                try? await Task.sleep(for: .seconds(playing ? 5 : 20))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func apply(_ status: NowPlayingStatus) {
        defer { onStatus?(status) }
        if status.taskMode == .stopped {
            // Stop keeps the stream running into the filler audio (see the
            // server's Stop behavior), so this still describes what's heard.
            player.nowPlayingTitle = "AntennaHead"
            player.nowPlayingSubtitle = status.statusText
            return
        }
        let name = status.stationName.isEmpty ? status.statusText : status.stationName
        player.nowPlayingTitle = name
        player.nowPlayingSubtitle = [status.formattedFrequency, status.statusText == name ? nil : status.statusText]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }
}
