import AntennaHeadAPI
import Foundation

/// Talks to one AntennaHead server's JSON API for the CarPlay screen. The
/// phone's own UI is the server's web page, so until CarPlay nothing here
/// needed the API beyond Now Playing (`NowPlayingMonitor`) and the Watch
/// relay (`WatchSync`). The Watch's `WatchAPIClient` is the fuller cousin;
/// this one only ever goes direct, since the iPhone has the VPN.
@MainActor
final class ServerAPIClient {
    enum ClientError: LocalizedError {
        case invalidAddress
        case loginNeeded
        case loginRejected
        case badResponse(Int)
        case server(String)
        case decoding(Error)

        var errorDescription: String? {
            switch self {
            case .invalidAddress: "The server's address isn't valid."
            case .loginNeeded: "This server needs a web login. Add it in AntennaHead on your iPhone."
            case .loginRejected: "The server rejected the web login. Check it in AntennaHead on your iPhone."
            case .badResponse(let code): "The server returned HTTP \(code)."
            case .server(let message): message
            case .decoding(let error): "Couldn't understand the server's response: \(error.localizedDescription)"
            }
        }
    }

    let server: SavedServer
    private let authorization: String?

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    init(server: SavedServer, credential: URLCredential?) {
        self.server = server
        if let user = credential?.user, let password = credential?.password {
            authorization = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        } else {
            authorization = nil
        }
    }

    /// The live HLS stream, the same one the Watch plays.
    var liveURL: URL? {
        server.baseURL.flatMap { URL(string: "hls/index.m3u8", relativeTo: $0) }
    }

    func nowPlaying() async throws -> NowPlayingStatus { try await get(APIEndpoint.nowPlaying) }
    func favorites() async throws -> [FrequencySummary] { try await get(APIEndpoint.favorites) }
    func categories() async throws -> [CategorySummary] { try await get(APIEndpoint.categories) }

    func tune(frequencyID: Int64) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.tune, TuneFrequencyRequest(frequencyID: frequencyID))
    }

    func startScan(categoryID: Int64) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.startScan, StartCategoryScanRequest(categoryID: categoryID))
    }

    func stop() async throws -> NowPlayingStatus { try await send("POST", APIEndpoint.stop, body: nil) }

    // MARK: Other sources

    func devices() async throws -> [DeviceSummary] { try await get(APIEndpoint.devices) }

    func startDevice(name: String) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.startDevice, StartDeviceRequest(deviceName: name))
    }

    func controlBoothStatus() async throws -> ControlBoothStatus { try await get(APIEndpoint.controlBoothStatus) }
    func launchControlBooth() async throws -> ControlBoothStatus { try await send("POST", APIEndpoint.controlBoothLaunch, body: nil) }

    func startControlBoothPipeline(named name: String) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.controlBoothStart, StartControlBoothPipelineRequest(pipelineName: name))
    }

    func stopControlBooth() async throws -> NowPlayingStatus { try await send("POST", APIEndpoint.controlBoothStop, body: nil) }
    func startAirPlay() async throws -> NowPlayingStatus { try await send("POST", APIEndpoint.controlBoothAirPlayStart, body: nil) }
    func stopAirPlay() async throws -> NowPlayingStatus { try await send("POST", APIEndpoint.controlBoothAirPlayStop, body: nil) }

    func gqrxStatus() async throws -> GqrxStatus { try await get(APIEndpoint.gqrxStatus) }
    func launchGqrx() async throws -> GqrxStatus { try await send("POST", APIEndpoint.gqrxLaunch, body: nil) }

    func startGqrx(channels: Int) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.gqrxStart, StartGqrxRequest(channels: channels))
    }

    func gqrxBookmarks() async throws -> [GqrxBookmarkSummary] { try await get(APIEndpoint.gqrxBookmarks) }

    func playGqrxBookmark(frequencyHz: Int64, channels: Int) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.gqrxBookmarkPlay, PlayGqrxBookmarkRequest(frequencyHz: frequencyHz, channels: channels))
    }

    func audioFiles() async throws -> FolderListing { try await get(APIEndpoint.audioFiles) }

    func startAudioFiles(_ request: StartAudioFilesRequest) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.audioFilesStart, request)
    }

    func textToSpeechFiles() async throws -> FolderListing { try await get(APIEndpoint.textToSpeech) }

    func startTextToSpeech(_ request: StartTextToSpeechRequest) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.textToSpeechStart, request)
    }

    func rssFeeds() async throws -> [RSSFeedSummary] { try await get(APIEndpoint.rssFeeds) }

    func startRSSHeadlines(_ request: StartRSSHeadlinesRequest) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.rssHeadlinesStart, request)
    }

    // MARK: Requests

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await send("GET", path, body: nil)
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, _ body: Body) async throws -> T {
        try await send("POST", path, body: try JSONEncoder().encode(body))
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: Data?) async throws -> T {
        guard let base = server.baseURL, let url = URL(string: String(path.dropFirst()), relativeTo: base) else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            if status == 401 {
                throw authorization == nil ? ClientError.loginNeeded : ClientError.loginRejected
            }
            if let apiError = try? JSONDecoder().decode(APIError.self, from: data) {
                throw ClientError.server(apiError.error)
            }
            throw ClientError.badResponse(status)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ClientError.decoding(error)
        }
    }
}
