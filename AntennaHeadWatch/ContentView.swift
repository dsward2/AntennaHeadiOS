import AntennaHeadAPI
import SwiftUI

/// The server's screen, or how to get one when the Watch doesn't know any.
struct ContentView: View {
    let model: WatchModel

    var body: some View {
        NavigationStack {
            if model.store.current != nil {
                MainView(model: model)
            } else {
                NoServerView(store: model.store)
            }
        }
        // Changing the ID rebuilds the stack at its root: how a source screen
        // (two levels down) gets back to Now Playing. (`dismiss()` on the
        // Sources screen from the screen above it didn't pop on watchOS.)
        // The tasks sit outside it, so going back doesn't reload everything.
        .id(model.navigationRootID)
        .task(id: model.store.current) { await model.connect() }
        .task(id: model.store.current?.id) { await model.pollNowPlaying() }
    }
}

private struct MainView: View {
    let model: WatchModel

    var body: some View {
        List {
            Section {
                NowPlayingSummary(model: model)
            }

            if model.player.source?.recordingName != nil {
                RecordingSection(model: model)
            }

            Section {
                // A paused recording counts as listening: Listen would
                // replace it with the live stream.
                if model.player.wantsToPlay || model.player.source?.recordingName != nil {
                    Button("Stop Listening", systemImage: "headphones.slash") {
                        model.player.stopListening()
                    }
                } else {
                    Button("Listen", systemImage: "headphones") {
                        Task { await model.listen() }
                    }
                }
                Button("Stop", systemImage: "stop.fill") {
                    Task { await model.stop() }
                }
                .disabled(model.nowPlaying == nil || model.nowPlaying?.taskMode == .stopped)
            } footer: {
                Text(model.player.statusText)
            }

            Section {
                NavigationLink {
                    FavoritesView(model: model)
                } label: {
                    LabeledContent {
                        Text(model.favorites.map { "\($0.count)" } ?? "")
                    } label: {
                        Label("Favorites", systemImage: "star")
                    }
                }
                NavigationLink {
                    CategoriesView(model: model)
                } label: {
                    LabeledContent {
                        Text(model.categories.map { "\($0.count)" } ?? "")
                    } label: {
                        Label("Categories", systemImage: "square.grid.2x2")
                    }
                }
                NavigationLink {
                    SourcesView(model: model)
                } label: {
                    Label("More Sources", systemImage: "ellipsis.circle")
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Button("Try Again") {
                        Task { await model.connect() }
                    }
                }
            }

            Section {
                NavigationLink {
                    ServersView(model: model)
                } label: {
                    Label(model.store.current?.name ?? "Server", systemImage: "server.rack")
                }
            }
        }
        .navigationTitle("AntennaHead")
    }
}

/// The recording playing on the Watch: progress, back / play-pause /
/// forward, and a way back to the live stream.
private struct RecordingSection: View {
    let model: WatchModel

    private var player: WatchAudioPlayer { model.player }

    var body: some View {
        Section("Recording") {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.source?.recordingName ?? "")
                    .font(.headline)
                    .lineLimit(2)
                if let duration = player.duration, duration > 0 {
                    ProgressView(value: min(player.position ?? 0, duration), total: duration)
                }
                Text(timeLine)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                if player.state != .playing && player.state != .paused {
                    // Loading, reconnecting, or failed: say which.
                    Text(player.statusText)
                        .font(.footnote)
                        .foregroundStyle(player.state == .failed ? .red : .secondary)
                }
            }
            HStack {
                Button {
                    player.skip(by: -WatchAudioPlayer.skipBack)
                } label: {
                    Image(systemName: "gobackward.15")
                }
                .accessibilityLabel("Back 15 seconds")
                Spacer()
                Button {
                    if player.wantsToPlay { player.pause() } else { player.resume() }
                } label: {
                    Image(systemName: player.wantsToPlay ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .accessibilityLabel(player.wantsToPlay ? "Pause" : "Play")
                Spacer()
                Button {
                    player.skip(by: WatchAudioPlayer.skipForward)
                } label: {
                    Image(systemName: "goforward.30")
                }
                .accessibilityLabel("Forward 30 seconds")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            Button("Back to Live", systemImage: "dot.radiowaves.left.and.right") {
                model.returnToLive()
            }
        }
    }

    /// "1:23 / 45:06", or just the position until the length is known.
    private var timeLine: String {
        let position = Self.format(player.position ?? 0)
        guard let duration = player.duration else { return position }
        return "\(position) / \(Self.format(duration))"
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

private struct NowPlayingSummary: View {
    let model: WatchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let status = model.nowPlaying {
                Text(status.stationName.isEmpty ? status.statusText : status.stationName)
                    .font(.headline)
                    .lineLimit(2)
                if let frequency = status.formattedFrequency, !frequency.isEmpty {
                    Text(frequency)
                        .font(.footnote)
                }
                if status.statusText != status.stationName {
                    Text(status.statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else if model.isLoading {
                ProgressView()
            } else {
                Text("Not connected")
                    .foregroundStyle(.secondary)
            }
            if let route = model.route {
                Text(route.rawValue)
                    .font(.caption2)
                    .foregroundStyle(route == .iPhone ? .orange : .secondary)
            }
        }
    }
}

/// Tap a favorite to tune it, then go back to Now Playing.
private struct FavoritesView: View {
    let model: WatchModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let favorites = model.favorites {
                if favorites.isEmpty {
                    Text("No favorites")
                        .foregroundStyle(.secondary)
                } else {
                    List(favorites) { frequency in
                        Button {
                            Task {
                                await model.tune(frequency)
                                if model.errorMessage == nil { dismiss() }
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(frequency.stationName)
                                Text(frequency.formattedFrequency)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Favorites")
        .task { await model.refreshLists() }
    }
}

/// Tap a category to scan it, then go back to Now Playing.
private struct CategoriesView: View {
    let model: WatchModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let categories = model.categories {
                if categories.isEmpty {
                    Text("No categories")
                        .foregroundStyle(.secondary)
                } else {
                    List(categories) { category in
                        Button {
                            Task {
                                await model.startScan(category)
                                if model.errorMessage == nil { dismiss() }
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(category.categoryName)
                                Text(category.scanningEnabled
                                     ? "\(category.frequencyCount) frequencies"
                                     : "Scanning off")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Categories")
        .task { await model.refreshLists() }
    }
}

private struct NoServerView: View {
    let store: WatchServerStore

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                Text("Open AntennaHead on your iPhone and add your Mac. It will appear here.")
                    .multilineTextAlignment(.center)
                    .font(.footnote)
                NavigationLink("Add on Watch") {
                    ServerEditView(store: store, server: nil)
                }
            }
        }
        .navigationTitle("AntennaHead")
    }
}
