import AntennaHeadAPI
import SwiftUI

/// The sources beyond favorites and categories. Each one starts on the Mac
/// with a tap ("Play"), then goes back to Now Playing. "Listen" stays the
/// Watch's own audio, as on the main screen.
struct SourcesView: View {
    let model: WatchModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        sourceList
            // Dismissing this screen also pops the source screen above it,
            // which lands back on Now Playing.
            .environment(\.returnToNowPlaying, ReturnAction { dismiss() })
    }

    private var sourceList: some View {
        List {
            NavigationLink { ControlBoothView(model: model) } label: {
                Label("ControlBooth", systemImage: "slider.horizontal.3")
            }
            NavigationLink { AirPlayView(model: model) } label: {
                Label("AirPlay Receiver", systemImage: "airplayaudio")
            }
            NavigationLink { GqrxView(model: model) } label: {
                Label("Gqrx", systemImage: "dot.radiowaves.left.and.right")
            }
            NavigationLink { DevicesView(model: model) } label: {
                Label("Devices", systemImage: "mic")
            }
            NavigationLink { FolderSourceView(model: model, kind: .audioFiles) } label: {
                Label("Audio Files", systemImage: "music.note.list")
            }
            NavigationLink { FolderSourceView(model: model, kind: .textToSpeech) } label: {
                Label("Text to Speech", systemImage: "text.bubble")
            }
            NavigationLink { RSSHeadlinesView(model: model) } label: {
                Label("RSS Headlines", systemImage: "newspaper")
            }
        }
        .navigationTitle("Sources")
    }
}

/// Goes back to Now Playing from a source screen (two levels down).
struct ReturnAction {
    let action: @MainActor () -> Void
    @MainActor func callAsFunction() { action() }
}

extension EnvironmentValues {
    @Entry var returnToNowPlaying = ReturnAction {}
}

extension View {
    /// Clears an old error (say, from the main screen) when a source screen
    /// opens, so the screen shows only its own failures.
    fileprivate func freshErrors(_ model: WatchModel) -> some View {
        onAppear { model.errorMessage = nil }
    }
}

/// Runs a start action, then goes back to Now Playing if it worked.
private struct StartButton<Label: View>: View {
    let model: WatchModel
    let action: () async -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.returnToNowPlaying) private var returnToNowPlaying

    var body: some View {
        Button {
            Task {
                await action()
                if model.errorMessage == nil { returnToNowPlaying() }
            }
        } label: {
            label()
        }
    }
}

/// The model's error, shown on the source's own screen (the main screen is
/// out of sight while a source screen is open).
private struct ErrorSection: View {
    let model: WatchModel

    var body: some View {
        if let errorMessage = model.errorMessage {
            Section {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: ControlBooth

private struct ControlBoothView: View {
    let model: WatchModel

    var body: some View {
        List {
            if let status = model.controlBoothStatus {
                if !status.isRunning {
                    LaunchControlBoothSection(model: model, message: "ControlBooth isn't running.")
                } else if status.pipelineNames.isEmpty {
                    Text("No pipelines configured in ControlBooth.")
                        .foregroundStyle(.secondary)
                } else {
                    Section("Pipelines") {
                        ForEach(status.pipelineNames, id: \.self) { name in
                            StartButton(model: model) {
                                await model.startControlBoothPipeline(named: name)
                            } label: {
                                HStack {
                                    Text(name)
                                    Spacer()
                                    if name == status.activePipelineName {
                                        Image(systemName: "waveform")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                    if status.activePipelineName != nil {
                        Button("Stop ControlBooth", systemImage: "stop.fill") {
                            Task { await model.stopControlBooth() }
                        }
                    }
                }
            } else {
                ProgressView()
            }
            ErrorSection(model: model)
        }
        .navigationTitle("ControlBooth")
        .freshErrors(model)
        .task { await model.loadControlBoothStatus() }
    }
}

private struct LaunchControlBoothSection: View {
    let model: WatchModel
    let message: String

    var body: some View {
        Section {
            Text(message)
                .foregroundStyle(.secondary)
            Button("Launch ControlBooth") {
                Task {
                    await model.launchControlBooth()
                    // It takes a moment to come up and report its pipelines.
                    try? await Task.sleep(for: .seconds(3))
                    await model.loadControlBoothStatus()
                }
            }
        }
    }
}

// MARK: AirPlay Receiver

private struct AirPlayView: View {
    let model: WatchModel

    var body: some View {
        List {
            if let status = model.controlBoothStatus {
                if !status.isRunning {
                    LaunchControlBoothSection(model: model,
                                              message: "The AirPlay Receiver is part of ControlBooth, which isn't running.")
                } else {
                    Section {
                        Text(Self.statusText(status))
                            .font(.footnote)
                        if status.isListeningToAirPlay {
                            Button("Stop", systemImage: "stop.fill") {
                                Task { await model.stopAirPlay() }
                            }
                        } else {
                            StartButton(model: model) {
                                await model.startAirPlay()
                            } label: {
                                Label("Play", systemImage: "airplayaudio")
                            }
                        }
                    } footer: {
                        Text("AirPlay to ControlBooth from an iPhone, iPad, or Mac, and the audio comes through AntennaHead's stream.")
                    }
                }
            } else {
                ProgressView()
            }
            ErrorSection(model: model)
        }
        .navigationTitle("AirPlay")
        .freshErrors(model)
        .task { await model.loadControlBoothStatus() }
    }

    /// Same wording as the web page and AntennaHead TV.
    private static func statusText(_ status: ControlBoothStatus) -> String {
        guard let enabled = status.airPlayEnabled else { return "AirPlay: Unknown" }
        if !enabled { return "AirPlay: Not in use" }
        if status.airPlayReceivingAudio == true { return "Receiving AirPlay audio" }
        return "Idle — no AirPlay client connected"
    }
}

// MARK: Gqrx

private struct GqrxView: View {
    let model: WatchModel
    /// 1 or 2, remembered between visits.
    @AppStorage("gqrxChannels") private var channels = 2

    var body: some View {
        List {
            if let status = model.gqrxStatus {
                Section {
                    if status.isRunning {
                        StartButton(model: model) {
                            await model.startGqrx(channels: channels)
                        } label: {
                            Label("Play Gqrx", systemImage: "play.fill")
                        }
                    } else {
                        StartButton(model: model) {
                            await model.launchGqrx()
                        } label: {
                            Label("Launch Gqrx", systemImage: "power")
                        }
                    }
                    Toggle("Stereo", isOn: Binding(get: { channels == 2 }, set: { channels = $0 ? 2 : 1 }))
                }

                if status.isRunning {
                    Section("Bookmarks") {
                        if let bookmarks = model.gqrxBookmarks {
                            if bookmarks.isEmpty {
                                Text("No bookmarks")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(bookmarks) { bookmark in
                                StartButton(model: model) {
                                    await model.playGqrxBookmark(bookmark, channels: channels)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(bookmark.name.isEmpty ? Self.megahertz(bookmark.frequencyHz) : bookmark.name)
                                        Text("\(Self.megahertz(bookmark.frequencyHz)) · \(bookmark.modulation)")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else if let message = model.gqrxBookmarksMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
                }
            } else {
                ProgressView()
            }
            ErrorSection(model: model)
        }
        .navigationTitle("Gqrx")
        .freshErrors(model)
        .task {
            await model.loadGqrxStatus()
            if model.gqrxStatus?.isRunning == true {
                await model.loadGqrxBookmarks()
            }
        }
    }

    private static func megahertz(_ hertz: Int64) -> String {
        String(format: "%.4f MHz", Double(hertz) / 1_000_000)
    }
}

// MARK: Devices

private struct DevicesView: View {
    let model: WatchModel

    var body: some View {
        List {
            if let devices = model.devices {
                if devices.isEmpty {
                    Text("No input devices")
                        .foregroundStyle(.secondary)
                }
                ForEach(devices) { device in
                    StartButton(model: model) {
                        await model.startDevice(device)
                    } label: {
                        Text(device.name)
                    }
                }
            } else {
                ProgressView()
            }
            ErrorSection(model: model)
        }
        .navigationTitle("Devices")
        .freshErrors(model)
        .task { await model.loadDevices() }
    }
}

// MARK: Audio Files and Text to Speech

private struct FolderSourceView: View {
    enum Kind {
        case audioFiles, textToSpeech

        var title: String {
            switch self {
            case .audioFiles: "Audio Files"
            case .textToSpeech: "Text to Speech"
            }
        }
    }

    let model: WatchModel
    let kind: Kind
    @AppStorage("folderSequence") private var sequence = FileSequence.chronological
    @AppStorage("folderRepeat") private var repeatForever = false

    private var listing: FolderListing? {
        kind == .audioFiles ? model.audioFiles : model.textToSpeechFiles
    }

    var body: some View {
        List {
            if let listing {
                if !listing.folderConfigured {
                    Text("Choose a folder for \(kind.title) in AntennaHead's Configuration tab on the Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        StartButton(model: model) {
                            await start(fileNames: nil)
                        } label: {
                            Label("Play All", systemImage: "play.fill")
                        }
                        .disabled(listing.files.isEmpty)
                        Picker("Order", selection: $sequence) {
                            ForEach(FileSequence.allCases, id: \.self) { sequence in
                                Text(sequence.label).tag(sequence)
                            }
                        }
                        Toggle("Repeat", isOn: $repeatForever)
                    }

                    if kind == .audioFiles, !listing.playlists.isEmpty {
                        Section("Playlists") {
                            ForEach(listing.playlists, id: \.self) { playlist in
                                StartButton(model: model) {
                                    await model.startAudioFiles(StartAudioFilesRequest(
                                        sequence: sequence, repeatForever: repeatForever, playlistName: playlist))
                                } label: {
                                    Text(playlist)
                                }
                            }
                        }
                    }

                    Section("Files") {
                        if listing.files.isEmpty {
                            Text("The folder is empty.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(listing.files) { file in
                            StartButton(model: model) {
                                await start(fileNames: [file.name])
                            } label: {
                                Text(file.name)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
            ErrorSection(model: model)
        }
        .navigationTitle(kind.title)
        .freshErrors(model)
        .task {
            switch kind {
            case .audioFiles: await model.loadAudioFiles()
            case .textToSpeech: await model.loadTextToSpeechFiles()
            }
        }
    }

    /// `nil` plays every file in the folder.
    private func start(fileNames: [String]?) async {
        switch kind {
        case .audioFiles:
            await model.startAudioFiles(StartAudioFilesRequest(
                fileNames: fileNames, sequence: sequence, repeatForever: repeatForever))
        case .textToSpeech:
            await model.startTextToSpeech(StartTextToSpeechRequest(
                fileNames: fileNames, sequence: sequence, repeatForever: repeatForever))
        }
    }
}

private extension FileSequence {
    /// Same labels as AntennaHead TV.
    var label: String {
        switch self {
        case .chronological: "Oldest First"
        case .alphabetical: "Alphabetical"
        case .random: "Random"
        }
    }
}

// MARK: RSS Headlines

private struct RSSHeadlinesView: View {
    let model: WatchModel
    @AppStorage("rssRepeat") private var repeatForever = false

    var body: some View {
        List {
            if let feeds = model.rssFeeds {
                if feeds.isEmpty {
                    Text("No RSS feeds. Add them in AntennaHead on the Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        StartButton(model: model) {
                            await model.startRSSHeadlines(StartRSSHeadlinesRequest(
                                feedIDs: feeds.map(\.id), repeatForever: repeatForever))
                        } label: {
                            Label("Play All Feeds", systemImage: "play.fill")
                        }
                        Toggle("Repeat", isOn: $repeatForever)
                    } footer: {
                        Text("Reads 5 headlines from each feed.")
                    }
                    Section("Feeds") {
                        ForEach(feeds) { feed in
                            StartButton(model: model) {
                                await model.startRSSHeadlines(StartRSSHeadlinesRequest(
                                    feedIDs: [feed.id], repeatForever: repeatForever))
                            } label: {
                                Text(feed.name)
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
            ErrorSection(model: model)
        }
        .navigationTitle("RSS Headlines")
        .freshErrors(model)
        .task { await model.loadRSSFeeds() }
    }
}
