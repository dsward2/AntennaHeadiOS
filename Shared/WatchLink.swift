import Foundation

/// The WatchConnectivity contract between the iPhone app and the Watch app.
/// This folder is compiled into both targets, so a change here is a compile
/// error on both sides instead of a silent mismatch.
///
/// Two things cross the link:
///
/// - **Servers** (iPhone → Watch, `updateApplicationContext`): the iPhone's
///   saved servers with their web-login passwords, and which one is open.
///   The application context is delivered even when the Watch app isn't
///   running, and only the latest one is kept.
/// - **Relayed API calls** (Watch → iPhone, `sendMessage`): when the Watch
///   can't reach the server itself, it asks the iPhone app to make the
///   request over the iPhone's connection (a VPN, typically). The iPhone only
///   relays `/api/v1/` paths, and only to a server it has saved.
nonisolated enum WatchLink {
    /// One server as the Watch needs it. The iPhone's `SavedServer` plus its
    /// password, since the Watch has no access to the iPhone's Keychain.
    struct Server: Codable, Identifiable, Hashable, Sendable {
        var id: UUID
        var name: String
        var address: String
        var usesHTTPS: Bool
        var username: String
        var password: String

        var baseURL: URL? {
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return URL(string: "\(usesHTTPS ? "https" : "http")://\(trimmed)")
        }

        /// The `Authorization` header value, or `nil` when the web login is off.
        var basicAuthorization: String? {
            guard !username.isEmpty, !password.isEmpty else { return nil }
            return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        }
    }

    struct ServerList: Codable, Sendable {
        var servers: [Server]
        /// The server open on the iPhone, if any.
        var currentID: UUID?
    }

    /// A Watch → iPhone request to relay.
    struct RelayRequest: Codable, Sendable {
        var serverID: UUID
        var method: String
        /// Must start with `/api/v1/`.
        var path: String
        var body: Data?
    }

    /// The iPhone's answer: the server's HTTP status and body, or why the
    /// request couldn't be made at all.
    struct RelayResponse: Codable, Sendable {
        var status: Int?
        var body: Data?
        var error: String?
    }

    static let apiPathPrefix = "/api/v1/"

    /// Keys in the WatchConnectivity dictionaries. Each value is the
    /// JSON-encoded struct above.
    static let serverListKey = "serverList"
    static let relayRequestKey = "relayRequest"
    static let relayResponseKey = "relayResponse"
}
