import Foundation
import Observation
import Security

/// One AntennaHead Mac the app knows how to reach.
///
/// `address` is a plain "host:port" — a LAN IP from Bonjour, or whatever
/// reaches the Mac over a VPN (its WireGuard/OpenVPN tunnel address, or a
/// hostname). Bonjour doesn't cross a VPN tunnel, so remote use always means
/// a manually entered address.
struct SavedServer: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var address: String
    var usesHTTPS = false
    /// Web-login username; the password lives in the Keychain (see
    /// `ServerStore.password(for:)`). Empty when the web login is off.
    var username = ""

    var baseURL: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: "\(usesHTTPS ? "https" : "http")://\(trimmed)/")
    }
}

/// The saved server list and which one is open, persisted in
/// `UserDefaults`, with passwords in the Keychain.
@MainActor
@Observable
final class ServerStore {
    private(set) var servers: [SavedServer] = []
    private(set) var currentServerID: UUID?

    private let defaults = UserDefaults.standard
    private static let serversKey = "savedServers"
    private static let currentKey = "currentServerID"

    init() {
        if let data = defaults.data(forKey: Self.serversKey),
           let decoded = try? JSONDecoder().decode([SavedServer].self, from: data) {
            servers = decoded
        }
        currentServerID = defaults.string(forKey: Self.currentKey).flatMap(UUID.init)
        if current == nil { currentServerID = nil }
    }

    var current: SavedServer? {
        servers.first { $0.id == currentServerID }
    }

    func connect(to server: SavedServer) {
        currentServerID = server.id
        defaults.set(server.id.uuidString, forKey: Self.currentKey)
    }

    /// Back to the server list.
    func disconnect() {
        currentServerID = nil
        defaults.removeObject(forKey: Self.currentKey)
    }

    /// Adds `server`, or replaces the saved one with the same `id`.
    func save(_ server: SavedServer, password: String?) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        if let password {
            setPassword(password, for: server)
        }
        persist()
    }

    func delete(_ server: SavedServer) {
        servers.removeAll { $0.id == server.id }
        Keychain.delete(account: server.id.uuidString)
        if currentServerID == server.id { disconnect() }
        persist()
    }

    func password(for server: SavedServer) -> String? {
        Keychain.read(account: server.id.uuidString)
    }

    func setPassword(_ password: String, for server: SavedServer) {
        if password.isEmpty {
            Keychain.delete(account: server.id.uuidString)
        } else {
            Keychain.write(password, account: server.id.uuidString)
        }
    }

    /// The server's web login as a credential, or `nil` if none is saved.
    func credential(for server: SavedServer) -> URLCredential? {
        guard !server.username.isEmpty, let password = password(for: server) else { return nil }
        return URLCredential(user: server.username, password: password, persistence: .forSession)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: Self.serversKey)
        }
    }
}

/// Minimal generic-password Keychain wrapper for the web-login passwords.
enum Keychain {
    private static let service = "com.dsward.AntennaHeadiOS.weblogin"

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let data = Data(value.utf8)
        let base = query(account: account)
        let update = [kSecValueData as String: data]
        if SecItemUpdate(base as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}
