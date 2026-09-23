import AntennaHeadAPI
import Foundation
import Network

/// Finds AntennaHead Macs on the LAN via Bonjour, for `ConnectView`'s
/// server list. (Adapted from AntennaHeadTV's copy; unlike the TV app, this
/// one supports the web login, so auth-enabled servers aren't disabled.) Browses the dedicated `_antennahead._tcp` type (see
/// `BonjourAdvertisement` for why not `_http._tcp`), which AntennaHead
/// publishes under the Mac's own computer name on its plain-HTTP port.
///
/// Browsing needs `NSBonjourServices` (listing that type) and
/// `NSLocalNetworkUsageDescription` in Info.plist; iOS shows its Local
/// Network permission prompt the first time `start()` runs. Manual entry
/// stays alongside the list for when discovery can't work — over a VPN
/// (Bonjour doesn't cross the tunnel), multicast filtered, the Mac on
/// another subnet, or permission declined.
///
/// Everything runs on `.main`: results are few and infrequent, and it keeps
/// the handlers on the same actor as the `@Observable` state they update.
@MainActor
@Observable
final class ServerBrowser {
    struct Server: Identifiable, Equatable {
        /// The Bonjour instance name — the Mac's computer name.
        let name: String
        let endpoint: NWEndpoint
        let advertisement: BonjourAdvertisement

        var id: String { name }

        /// Why this client can't connect to this server, or `nil` if it can.
        /// Such servers are still listed (so the user can see their Mac was
        /// found) but disabled.
        var unsupportedReason: String? {
            if advertisement.apiVersion > BonjourAdvertisement.currentAPIVersion {
                return "Needs a newer version of this app"
            }
            return nil
        }
    }

    enum ResolveError: LocalizedError {
        case timedOut
        case failed(NWError)
        case noAddress

        var errorDescription: String? {
            switch self {
            case .timedOut: "Couldn't reach that server. Try entering its address below."
            case .failed(let error): "Couldn't reach that server: \(error.localizedDescription)"
            case .noAddress: "That server didn't report an address. Try entering it below."
            }
        }
    }

    private(set) var servers: [Server] = []
    /// Set when the browser itself fails — most often because Local Network
    /// access was declined in Settings.
    private(set) var browseError: String?

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        browseError = nil
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: BonjourAdvertisement.serviceType, domain: nil),
            using: .tcp)
        // Network's handlers are `@Sendable`, but they're delivered on the
        // `.main` queue passed to `start(queue:)`, so they're on the main
        // actor in fact — `assumeIsolated` states that (and traps if not).
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed(let error), .waiting(let error):
                    self?.browseError = "Can't search the network (\(error.localizedDescription)). Check Settings › Privacy › Local Network."
                case .ready:
                    self?.browseError = nil
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        servers = results.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata {
                txt = record.dictionary
            }
            return Server(name: name,
                          endpoint: result.endpoint,
                          advertisement: BonjourAdvertisement(txtRecord: txt))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Turns a discovered service into the "host:port" string the rest of
    /// the app (and the manual-entry field) already works in. A Bonjour
    /// endpoint can't go in a URL directly, so this opens a throwaway TCP
    /// connection and reads back the address it landed on. IPv4 is required
    /// so the result is a plain `192.168.x.y:port` — an IPv6 link-local
    /// address would need a `%interface` scope that URLs handle badly.
    func resolve(_ server: Server) async throws -> String {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: server.endpoint, using: parameters)
        defer { connection.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            // Only touched on `.main` (the connection's queue and the
            // timeout's), so the flag needs no lock.
            nonisolated(unsafe) var finished = false
            @Sendable func finish(_ result: Result<String, Error>) {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Formatted from the raw bytes rather than the address's
                    // description, which appends the interface scope
                    // ("192.168.1.23%en0") and makes `URL(string:)` fail.
                    if case .hostPort(.ipv4(let address), let port) = connection.currentPath?.remoteEndpoint {
                        let dotted = address.rawValue.map(String.init).joined(separator: ".")
                        finish(.success("\(dotted):\(port.rawValue)"))
                    } else {
                        finish(.failure(ResolveError.noAddress))
                    }
                case .failed(let error):
                    finish(.failure(ResolveError.failed(error)))
                default:
                    break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                finish(.failure(ResolveError.timedOut))
            }
        }
    }
}
