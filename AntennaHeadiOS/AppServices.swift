import Foundation

/// The objects every scene shares: the saved servers and the one audio
/// player. The phone's window and the CarPlay screen are separate scenes,
/// and iOS may launch the app for CarPlay alone (phone locked, no window at
/// all), so these can't belong to either one.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let store = ServerStore()
    let player = NativeAudioPlayer()

    private init() {
        WatchSync.shared.start(store: store)
    }
}
