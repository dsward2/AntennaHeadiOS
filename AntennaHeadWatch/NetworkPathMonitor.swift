import Network
import Observation

/// Describes the Watch's current network path, so a test result can be
/// matched to how the Watch was connected: its own Wi-Fi, its own cellular,
/// or relayed through the paired iPhone over Bluetooth (which Network.framework
/// reports as an "other" interface).
@MainActor
@Observable
final class NetworkPathMonitor {
    private(set) var summary = "Checking…"

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let text = Self.describe(path)
            Task { @MainActor in self.summary = text }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkPathMonitor"))
    }

    deinit {
        monitor.cancel()
    }

    nonisolated private static func describe(_ path: NWPath) -> String {
        guard path.status == .satisfied else {
            return path.status == .requiresConnection ? "Needs connection" : "No network"
        }
        let names = path.availableInterfaces.map { interface -> String in
            switch interface.type {
            case .wifi: "Wi-Fi"
            case .cellular: "Cellular"
            case .wiredEthernet: "Ethernet"
            case .loopback: "Loopback"
            case .other: "iPhone/other"
            @unknown default: "Unknown"
            }
        }
        var text = names.isEmpty ? "Connected" : names.joined(separator: ", ")
        if path.isExpensive { text += " (expensive)" }
        if path.isConstrained { text += " (constrained)" }
        return text
    }
}
