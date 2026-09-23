import AntennaHeadAPI
import SwiftUI

/// The server's screen, or how to get one when the Watch doesn't know any.
struct ContentView: View {
    let model: WatchModel

    var body: some View {
        NavigationStack {
            if let server = model.store.current {
                MainView(model: model)
                    .task(id: server) { await model.connect() }
                    .task(id: server.id) { await model.pollNowPlaying() }
            } else {
                NoServerView(store: model.store)
            }
        }
    }
}

private struct MainView: View {
    let model: WatchModel

    var body: some View {
        List {
            Section {
                NowPlayingSummary(model: model)
            }

            Section {
                if model.player.wantsToPlay {
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
