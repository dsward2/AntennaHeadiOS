import AntennaHeadAPI
import Foundation
import os

/// Talks to one AntennaHead server's JSON API, directly when the Watch can
/// reach it and through the iPhone app (`PhoneLink`) when it can't.
///
/// Direct comes first: at home, or whenever the Watch's traffic is routed
/// through a nearby iPhone that's on the VPN, it's faster and doesn't need
/// the iPhone app. When a direct request fails for lack of a network path,
/// the same request is relayed, and relaying stays preferred for a minute so
/// the Now Playing poll doesn't wait out a direct timeout every time.
@MainActor
final class WatchAPIClient {
    enum Route: String {
        case direct = "Direct"
        case iPhone = "via iPhone"
    }

    enum ClientError: LocalizedError {
        case invalidAddress
        case loginFailed
        case badResponse(Int)
        case server(String)
        case decoding(Error)

        var errorDescription: String? {
            switch self {
            case .invalidAddress: "The server's address isn't valid."
            case .loginFailed: "The server rejected the web login."
            case .badResponse(let code): "The server returned HTTP \(code)."
            case .server(let message): message
            case .decoding(let error): "Couldn't understand the server's response: \(error.localizedDescription)"
            }
        }
    }

    private static let log = Logger(subsystem: "com.dsward.AntennaHeadiOS.watchkitapp", category: "API")

    let server: WatchLink.Server
    private let link: PhoneLink
    private(set) var lastRoute: Route?
    private var preferRelayUntil: Date?

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    init(server: WatchLink.Server, link: PhoneLink) {
        self.server = server
        self.link = link
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

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await send("GET", path, body: nil)
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, _ body: Body) async throws -> T {
        try await send("POST", path, body: try JSONEncoder().encode(body))
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: Data?) async throws -> T {
        let (status, data) = try await perform(method, path, body: body)
        guard (200...299).contains(status) else {
            if status == 401 { throw ClientError.loginFailed }
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

    private func perform(_ method: String, _ path: String, body: Data?) async throws -> (Int, Data) {
        #if DEBUG
        // `-forceRelay YES` launch argument: always go through the iPhone,
        // to test the relay without taking the server off the network.
        if UserDefaults.standard.bool(forKey: "forceRelay") {
            return try await relayed(method, path, body: body)
        }
        #endif
        if let preferRelayUntil, preferRelayUntil > Date(), link.canRelay {
            do {
                return try await relayed(method, path, body: body)
            } catch {
                // The relay broke (the iPhone app went away, say); try direct.
                self.preferRelayUntil = nil
            }
        }
        do {
            let result = try await direct(method, path, body: body)
            preferRelayUntil = nil
            return result
        } catch let error as URLError where Self.meansNoPath(error) && link.canRelay {
            Self.log.info("Direct \(path, privacy: .public) failed (\(error.code.rawValue)); relaying through the iPhone")
            let result = try await relayed(method, path, body: body)
            preferRelayUntil = Date().addingTimeInterval(60)
            return result
        }
    }

    private func direct(_ method: String, _ path: String, body: Data?) async throws -> (Int, Data) {
        guard let base = server.baseURL, let url = URL(string: path, relativeTo: base) else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let authorization = server.basicAuthorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        lastRoute = .direct
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    private func relayed(_ method: String, _ path: String, body: Data?) async throws -> (Int, Data) {
        let response = try await link.relay(WatchLink.RelayRequest(serverID: server.id, method: method, path: path, body: body))
        if let error = response.error {
            throw PhoneLink.RelayError.failed("iPhone: \(error)")
        }
        lastRoute = .iPhone
        return (response.status ?? -1, response.body ?? Data())
    }

    /// Errors that mean "no way to reach the server from here", as opposed to
    /// the server answering badly. Only these are worth relaying.
    private static func meansNoPath(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost,
             .networkConnectionLost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            true
        default:
            false
        }
    }
}
