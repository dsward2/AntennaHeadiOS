import SwiftUI

/// AntennaHead for Apple Watch: Now Playing, favorites, categories, Stop,
/// and listening on Bluetooth headphones.
///
/// watchOS has no VPN, so the Watch reaches AntennaHead directly when it can
/// (at home, or through a nearby iPhone's connection) and otherwise relays
/// API calls through the iPhone app (see `WatchAPIClient`). Servers and web
/// logins come from the iPhone app (`WatchLink`).
@main
struct AntennaHeadWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: DiagnosticsAppDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: WatchModel

    init() {
        Diagnostics.start()
        let store = WatchServerStore()
        let link = PhoneLink(store: store)
        _model = State(initialValue: WatchModel(store: store, link: link, player: WatchAudioPlayer()))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in
            Diagnostics.note("scenePhase → \(phase)")
            model.isForeground = phase == .active
            if phase == .active {
                model.player.appBecameActive()
                Task { await model.refreshNowPlaying() }
            }
        }
    }
}
