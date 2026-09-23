import Foundation
import os
import UIKit
import WatchConnectivity

/// The iPhone side of the Watch link (see `WatchLink`): keeps the Watch's
/// copy of the saved servers current, and relays the Watch's API calls over
/// this iPhone's connection when the Watch can't reach the server itself.
///
/// watchOS has no VPN, so away from home this relay is the Watch's only
/// dependable way to reach AntennaHead for control and status. (Audio is
/// different: the Watch streams HLS itself, which works whenever its traffic
/// is routed through a nearby iPhone.)
@MainActor
final class WatchSync: NSObject {
    static let shared = WatchSync()

    private static let log = Logger(subsystem: "com.dsward.AntennaHeadiOS", category: "WatchSync")

    private weak var store: ServerStore?

    /// Starts the session. Call once at launch, so a relay request that wakes
    /// the app in the background finds a delegate waiting.
    func start(store: ServerStore) {
        self.store = store
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Sends the current server list to the Watch. Cheap to call often: the
    /// system keeps only the latest context and skips unchanged ones.
    func pushServers() {
        guard WCSession.isSupported(), let store else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let list = WatchLink.ServerList(
            servers: store.servers.map { server in
                WatchLink.Server(id: server.id, name: server.name, address: server.address,
                                 usesHTTPS: server.usesHTTPS, username: server.username,
                                 password: store.password(for: server) ?? "")
            },
            currentID: store.currentServerID
        )
        do {
            let data = try JSONEncoder().encode(list)
            try session.updateApplicationContext([WatchLink.serverListKey: data])
            Self.log.info("Sent \(list.servers.count) server(s) to the Watch")
        } catch {
            Self.log.error("Couldn't send servers to the Watch: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func relay(_ request: WatchLink.RelayRequest) async -> WatchLink.RelayResponse {
        guard request.path.hasPrefix(WatchLink.apiPathPrefix) else {
            return WatchLink.RelayResponse(error: "Only AntennaHead API requests can be relayed.")
        }
        guard let store, let server = store.servers.first(where: { $0.id == request.serverID }) else {
            return WatchLink.RelayResponse(error: "That server isn't saved on the iPhone.")
        }
        guard let base = server.baseURL,
              let url = URL(string: String(request.path.dropFirst()), relativeTo: base) else {
            return WatchLink.RelayResponse(error: "The server's address isn't valid.")
        }
        // Short enough that the reply reaches the Watch before its message
        // times out.
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        urlRequest.httpMethod = request.method
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let credential = store.credential(for: server), let user = credential.user, let password = credential.password {
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            urlRequest.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            return WatchLink.RelayResponse(status: (response as? HTTPURLResponse)?.statusCode, body: data)
        } catch {
            return WatchLink.RelayResponse(error: error.localizedDescription)
        }
    }
}

extension WatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.pushServers() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        // The Watch app was just installed, for example.
        Task { @MainActor in self.pushServers() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Switching to another paired Watch: activate again for the new one.
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard let data = message[WatchLink.relayRequestKey] as? Data,
              let request = try? JSONDecoder().decode(WatchLink.RelayRequest.self, from: data) else {
            replyHandler([:])
            return
        }
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in
            // WatchConnectivity may have launched or woken this app in the
            // background just for this message; keep it running until the
            // server answers and the reply is sent.
            let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Watch relay")
            defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
            let started = Date()
            let response = await self.relay(request)
            Self.log.info("Relayed \(request.method, privacy: .public) \(request.path, privacy: .public) → \(response.status.map(String.init) ?? response.error ?? "-", privacy: .public) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            let encoded = (try? JSONEncoder().encode(response)) ?? Data()
            reply([WatchLink.relayResponseKey: encoded])
        }
    }
}
