import Foundation
import Observation
import Security

/// The servers the Watch knows: the iPhone's saved servers (sent over
/// WatchConnectivity, see `WatchLink`), plus any added on the Watch itself
/// for standalone use. Both lists, passwords included, live in the Watch's
/// Keychain, so the Watch still works when the iPhone is out of reach.
@MainActor
@Observable
final class WatchServerStore {
    private(set) var phoneServers: [WatchLink.Server] = []
    private(set) var watchServers: [WatchLink.Server] = []
    /// The server the iPhone has open, used until one is picked on the Watch.
    private(set) var phoneCurrentID: UUID?
    private(set) var selectedID: UUID?

    private static let selectedKey = "selectedServerID"

    init() {
        if let list: WatchLink.ServerList = WatchKeychain.read(account: "phoneServers") {
            phoneServers = list.servers
            phoneCurrentID = list.currentID
        }
        watchServers = WatchKeychain.read(account: "watchServers") ?? []
        selectedID = UserDefaults.standard.string(forKey: Self.selectedKey).flatMap(UUID.init)
    }

    var allServers: [WatchLink.Server] { phoneServers + watchServers }

    /// The picked server if it still exists, otherwise the iPhone's open one,
    /// otherwise the first known.
    var current: WatchLink.Server? {
        let all = allServers
        return all.first { $0.id == selectedID }
            ?? all.first { $0.id == phoneCurrentID }
            ?? all.first
    }

    func isFromPhone(_ server: WatchLink.Server) -> Bool {
        phoneServers.contains { $0.id == server.id }
    }

    func select(_ server: WatchLink.Server) {
        selectedID = server.id
        UserDefaults.standard.set(server.id.uuidString, forKey: Self.selectedKey)
    }

    func applyPhoneList(_ list: WatchLink.ServerList) {
        phoneServers = list.servers
        phoneCurrentID = list.currentID
        WatchKeychain.write(list, account: "phoneServers")
        Diagnostics.note("received \(list.servers.count) server(s) from iPhone")
    }

    /// Adds `server`, or replaces the Watch-added one with the same `id`.
    func saveWatchServer(_ server: WatchLink.Server) {
        if let index = watchServers.firstIndex(where: { $0.id == server.id }) {
            watchServers[index] = server
        } else {
            watchServers.append(server)
        }
        WatchKeychain.write(watchServers, account: "watchServers")
    }

    func deleteWatchServer(_ server: WatchLink.Server) {
        watchServers.removeAll { $0.id == server.id }
        WatchKeychain.write(watchServers, account: "watchServers")
    }
}

/// Codable values as generic passwords in the Watch's Keychain.
enum WatchKeychain {
    private static let service = "com.dsward.AntennaHeadiOS.watchkitapp.servers"

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read<T: Decodable>(account: String) -> T? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ value: T, account: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let base = query(account: account)
        let update = [kSecValueData as String: data]
        if SecItemUpdate(base as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
