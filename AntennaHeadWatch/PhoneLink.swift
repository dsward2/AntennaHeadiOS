import Foundation
import WatchConnectivity

/// The Watch side of the iPhone link (see `WatchLink`): receives the
/// iPhone's server list, and relays API calls through the iPhone app.
@MainActor
final class PhoneLink: NSObject {
    enum RelayError: LocalizedError {
        case unreachable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unreachable: "The iPhone isn't reachable."
            case .failed(let message): message
            }
        }
    }

    private let store: WatchServerStore

    init(store: WatchServerStore) {
        self.store = store
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Whether the iPhone app can be messaged right now (the iPhone is
    /// nearby and connected; the app is woken in the background if needed).
    var isReachable: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    func relay(_ request: WatchLink.RelayRequest) async throws -> WatchLink.RelayResponse {
        guard isReachable else { throw RelayError.unreachable }
        let payload = [WatchLink.relayRequestKey: try JSONEncoder().encode(request)]
        return try await withCheckedThrowingContinuation { continuation in
            WCSession.default.sendMessage(payload, replyHandler: { reply in
                guard let data = reply[WatchLink.relayResponseKey] as? Data,
                      let response = try? JSONDecoder().decode(WatchLink.RelayResponse.self, from: data) else {
                    continuation.resume(throwing: RelayError.failed("The iPhone app sent an unreadable reply."))
                    return
                }
                continuation.resume(returning: response)
            }, errorHandler: { error in
                continuation.resume(throwing: RelayError.failed(error.localizedDescription))
            })
        }
    }

    private func apply(context: [String: Any]) {
        guard let data = context[WatchLink.serverListKey] as? Data,
              let list = try? JSONDecoder().decode(WatchLink.ServerList.self, from: data) else { return }
        store.applyPhoneList(list)
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // Pick up a context that arrived while the app wasn't running.
        let context = session.receivedApplicationContext
        Task { @MainActor in
            Diagnostics.note("WCSession activated (\(activationState.rawValue)), reachable \(session.isReachable)")
            if !context.isEmpty { self.apply(context: context) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        nonisolated(unsafe) let context = applicationContext
        Task { @MainActor in self.apply(context: context) }
    }
}
