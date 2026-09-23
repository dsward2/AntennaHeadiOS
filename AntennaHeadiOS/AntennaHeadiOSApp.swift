import SwiftUI

@main
struct AntennaHeadiOSApp: App {
    @State private var store = ServerStore()
    @State private var player = NativeAudioPlayer()

    var body: some Scene {
        WindowGroup {
            RootView(store: store, player: player)
        }
    }
}

/// The server list until a server is chosen, then that server's web UI.
struct RootView: View {
    let store: ServerStore
    let player: NativeAudioPlayer
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let server = store.current {
                ServerScreen(server: server, store: store, player: player)
                    .id(server.id)   // a fresh web view per server
            } else {
                ConnectView(store: store)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { player.appBecameActive() }
        }
    }
}

/// One server's web UI, with an error screen when it can't be reached and a
/// way back to the server list when its page predates the app.
struct ServerScreen: View {
    let server: SavedServer
    let store: ServerStore
    let player: NativeAudioPlayer

    @State private var loadError: String?
    @State private var isLegacyPage = false
    @State private var reloadToken = 0
    @State private var monitor: NowPlayingMonitor?

    var body: some View {
        ZStack {
            AntennaHeadWebView(server: server, store: store, player: player,
                               onLoadError: { loadError = $0 },
                               onLegacyPage: { isLegacyPage = $0 },
                               reloadToken: reloadToken)
                .ignoresSafeArea(edges: .bottom)

            if let loadError {
                errorView(loadError)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isLegacyPage && loadError == nil {
                // This server's page still plays through <audio> and has no
                // ⋯ button of its own.
                Button("Servers", systemImage: "server.rack") { showServers() }
                    .labelStyle(.iconOnly)
                    .padding(10)
                    .background(.regularMaterial, in: Circle())
                    .padding(.trailing, 8)
                    .padding(.top, 2)
            }
        }
        .onAppear {
            let credential = store.credential(for: server)
            player.setCredential(credential)
            let monitor = NowPlayingMonitor(player: player)
            monitor.start(server: server, credential: credential)
            self.monitor = monitor
        }
        .onDisappear {
            monitor?.stop()
        }
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Can't Reach \(server.name)", systemImage: "antenna.radiowaves.left.and.right.slash")
        } description: {
            Text(message)
            Text(verbatim: server.baseURL?.absoluteString ?? server.address)
                .font(.caption)
            Text("If you're away from home, check that your VPN is connected.")
                .font(.caption)
        } actions: {
            Button("Try Again") {
                loadError = nil
                reloadToken += 1
            }
            .buttonStyle(.borderedProminent)
            Button("Choose Server") { showServers() }
        }
        .background(Color(.systemBackground))
    }

    private func showServers() {
        player.stop()
        store.disconnect()
    }
}
