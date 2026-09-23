import Foundation
import WatchConnectivity
import WatchKit

/// The Watch side of the iPhone link (see `WatchLink`): receives the
/// iPhone's server list, and relays API calls through the iPhone app.
///
/// Relaying follows WatchConnectivity's rules:
///
/// - The iPhone is only reachable while this app is in the foreground. In
///   the background (where the app only runs while audio plays, which needs
///   a direct path to the server anyway) the relay isn't attempted at all.
/// - Right after launch or a return to the foreground, the session may still
///   be activating, or `isReachable` may not have caught up yet, so a relay
///   waits up to 8 s for reachability instead of failing at once. (Measured:
///   about 4.5 s after a launch with the screen off.)
/// - Delivery can fail transiently ("not reachable", "transfer timed out"),
///   so a failed send is retried once.
@MainActor
final class PhoneLink: NSObject {
    enum RelayError: LocalizedError {
        case unavailable(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): reason
            case .failed(let message): message
            }
        }
    }

    private let store: WatchServerStore
    /// Relays waiting for the iPhone to become reachable.
    private var reachabilityWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(store: WatchServerStore) {
        self.store = store
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Whether the iPhone app can be messaged right now.
    var isReachable: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    /// Whether a relay is worth attempting: the app is in the foreground
    /// (WatchConnectivity never reaches the iPhone otherwise) and the iPhone
    /// app is installed. Reachability itself is waited for in `relay`.
    var canRelay: Bool {
        guard WCSession.isSupported(), WKApplication.shared().applicationState == .active else { return false }
        let session = WCSession.default
        return session.activationState != .activated || session.isCompanionAppInstalled
    }

    func relay(_ request: WatchLink.RelayRequest) async throws -> WatchLink.RelayResponse {
        let started = Date()
        do {
            let response = try await sendOnce(request)
            Diagnostics.note(String(format: "relay %@ ok in %.0f ms", request.path, Date().timeIntervalSince(started) * 1000))
            return response
        } catch let error as RelayError {
            guard case .failed(let message) = error else { throw error }
            Diagnostics.note("relay \(request.path) failed (\(message)); retrying")
            try? await Task.sleep(for: .milliseconds(500))
            let response = try await sendOnce(request)
            Diagnostics.note(String(format: "relay %@ ok on retry in %.0f ms", request.path, Date().timeIntervalSince(started) * 1000))
            return response
        }
    }

    private func sendOnce(_ request: WatchLink.RelayRequest) async throws -> WatchLink.RelayResponse {
        guard canRelay else {
            throw RelayError.unavailable(WCSession.isSupported() && WCSession.default.activationState == .activated
                                         && !WCSession.default.isCompanionAppInstalled
                                         ? "AntennaHead isn't installed on the iPhone."
                                         : "The iPhone can only be reached while this app is open.")
        }
        guard await waitUntilReachable(timeout: .seconds(8)) else {
            throw RelayError.unavailable("The iPhone isn't reachable.")
        }
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

    /// True as soon as the iPhone is reachable, false after `timeout`.
    private func waitUntilReachable(timeout: Duration) async -> Bool {
        if isReachable { return true }
        let id = UUID()
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resumeWaiter(id, reachable: false)
        }
        let reachable = await withCheckedContinuation { continuation in
            reachabilityWaiters[id] = continuation
        }
        timeoutTask.cancel()
        return reachable
    }

    private func resumeWaiter(_ id: UUID, reachable: Bool) {
        reachabilityWaiters.removeValue(forKey: id)?.resume(returning: reachable)
    }

    private func reachabilityChanged() {
        guard isReachable else { return }
        for id in Array(reachabilityWaiters.keys) {
            resumeWaiter(id, reachable: true)
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
            self.reachabilityChanged()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            Diagnostics.note("iPhone reachable: \(session.isReachable)")
            self.reachabilityChanged()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        nonisolated(unsafe) let context = applicationContext
        Task { @MainActor in self.apply(context: context) }
    }
}
