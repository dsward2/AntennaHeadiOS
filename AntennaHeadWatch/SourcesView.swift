import AntennaHeadAPI
import SwiftUI

/// The sources beyond favorites and categories. Each one starts on the Mac
/// with a tap ("Play"), then goes back to Now Playing. "Listen" stays the
/// Watch's own audio, as on the main screen.
struct SourcesView: View {
    let model: WatchModel

    var body: some View {
        List {
            NavigationLink { ControlBoothView(model: model) } label: {
                Label { Text("ControlBooth") } icon: { ControlBoothGlyph() }
            }
            NavigationLink { AirPlayView(model: model) } label: {
                Label("AirPlay Receiver", systemImage: "airplayaudio")
            }
            NavigationLink { RadioView(model: model) } label: {
                Label("AntennaHead Radio", systemImage: "radio")
            }
            NavigationLink { GqrxView(model: model) } label: {
                Label("Gqrx", systemImage: "dot.radiowaves.left.and.right")
            }
            NavigationLink { DsdNeoView(model: model) } label: {
                Label("dsd-neo", systemImage: "antenna.radiowaves.left.and.right")
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
            NavigationLink { RecordingsView(model: model) } label: {
                // Not "recordingtape": that symbol is wide enough to run into
                // the label on the Watch.
                Label("Recordings", systemImage: "waveform.circle")
            }
        }
        .navigationTitle("Sources")
    }
}

extension View {
    /// Clears an old error (say, from the main screen) when a source screen
    /// opens, so the screen shows only its own failures.
    fileprivate func freshErrors(_ model: WatchModel) -> some View {
        onAppear { model.errorMessage = nil }
    }
}

/// Runs a start action, then goes back to Now Playing if it worked.
/// (Through the model: a pushed screen gets its environment from the
/// navigation stack, not from the Sources screen, so an environment action
/// set there never arrived.)
private struct StartButton<Label: View>: View {
    let model: WatchModel
    let action: () async -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button {
            Task {
                await action()
                if model.errorMessage == nil { model.returnToNowPlaying() }
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

// MARK: AntennaHead Radio

/// ControlBooth's AntennaHead Radio station: Go On Air / Stop, like the web
/// page's ControlBooth section. Refreshes while open, since the station takes
/// a few seconds to start and changes segments on its own.
private struct RadioView: View {
    let model: WatchModel

    var body: some View {
        List {
            if let status = model.controlBoothStatus {
                if !status.isRunning {
                    LaunchControlBoothSection(model: model,
                                              message: "AntennaHead Radio is part of ControlBooth, which isn't running.")
                } else if status.radioPhase == nil {
                    Text("This ControlBooth doesn't have AntennaHead Radio. Update ControlBooth on the Mac.")
                        .font(.footnote)
                } else {
                    Section {
                        Text(status.radioStatusText ?? "")
                            .font(.headline)
                        if let song = status.radioNowPlaying {
                            Text(song)
                                .font(.footnote)
                        }
                        if let error = status.radioLastError {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        if status.isRadioOnAir {
                            if status.radioCanSkip != nil {
                                Button("Skip Song", systemImage: "forward.end.fill") {
                                    Task { await model.skipRadioSong() }
                                }
                                .disabled(status.radioCanSkip != true)
                            }
                            Button("Stop", systemImage: "stop.fill") {
                                Task { await model.stopRadio() }
                            }
                            .disabled(status.radioPhase == "stopping")
                        } else {
                            StartButton(model: model) {
                                await model.startRadio()
                            } label: {
                                Label("Go On Air", systemImage: "play.fill")
                            }
                        }
                    } footer: {
                        Text("Music, announcements, news and weather, set up in ControlBooth's AntennaHead Radio tab.")
                    }
                }
            } else {
                ProgressView()
            }
            ErrorSection(model: model)
        }
        .navigationTitle("Radio")
        .freshErrors(model)
        .task {
            while !Task.isCancelled {
                await model.loadControlBoothStatus()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

// MARK: Gqrx

private struct GqrxView: View {
    let model: WatchModel
    /// 1 or 2, remembered between visits.
    @AppStorage("gqrxChannels") private var channels = 2
    /// True from tapping Launch until the bookmarks have loaded (or given up).
    @State private var isLaunching = false

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
                        // Not a StartButton: stay here, so the bookmarks appear
                        // on this screen as soon as Gqrx is ready.
                        Button {
                            Task { await launch() }
                        } label: {
                            Label("Launch Gqrx", systemImage: "power")
                        }
                        .disabled(isLaunching)
                    }
                    Toggle("Stereo", isOn: Binding(get: { channels == 2 }, set: { channels = $0 ? 2 : 1 }))
                }

                if status.isRunning {
                    Section("Bookmarks") {
                        if isLaunching, model.gqrxBookmarks?.isEmpty != false {
                            ProgressView()
                        } else if let bookmarks = model.gqrxBookmarks {
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

    /// Launches Gqrx (which also starts listening), then loads the bookmarks
    /// into this screen. Gqrx's remote control takes a few seconds to come up,
    /// so a failed load is retried before its message is shown.
    private func launch() async {
        isLaunching = true
        defer { isLaunching = false }
        await model.launchGqrx()
        guard model.errorMessage == nil else { return }
        for attempt in 0..<10 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            if Task.isCancelled { return }
            await model.loadGqrxBookmarks()
            // Right after launch Gqrx can answer with an empty list before it
            // has loaded its bookmarks, so empty counts as not ready yet.
            if model.gqrxBookmarks?.isEmpty == false { return }
        }
    }

    private static func megahertz(_ hertz: Int64) -> String {
        String(format: "%.4f MHz", Double(hertz) / 1_000_000)
    }
}

// MARK: dsd-neo

/// ControlBooth's dsd-neo Scanner: Listen/Stop/Skip, and which saved system
/// (AWIN, CWIN, …) and control channel it follows. Choosing a system or
/// channel stays on this screen — a running scanner restarts on it within a
/// few seconds — while Listen goes back to Now Playing like the other sources.
private struct DsdNeoView: View {
    let model: WatchModel
    @State private var isSwitching = false

    var body: some View {
        List {
            if let status = model.dsdNeoStatus {
                if !status.isRunning {
                    LaunchControlBoothSection(model: model, message: "The dsd-neo Scanner is part of ControlBooth, which isn't running.")
                } else if status.pipelineName == nil {
                    Text("ControlBooth has no dsd-neo Scanner pipeline. Set it up in ControlBooth's dsd-neo Scanner tab.")
                        .font(.footnote)
                } else if !status.installed {
                    Text("dsd-neo isn't installed on the Mac.")
                        .font(.footnote)
                } else {
                    controls(status)
                    if status.configurations.isEmpty {
                        Text("Update ControlBooth on the Mac to choose a system here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Section("System") {
                            ForEach(status.configurations) { configuration in
                                Button {
                                    switchTo(configuration.id, controlChannelHz: nil)
                                } label: {
                                    HStack {
                                        Text(configuration.name)
                                        Spacer()
                                        if configuration.id == status.activeConfigurationID {
                                            Image(systemName: "checkmark").foregroundStyle(.tint)
                                        }
                                    }
                                }
                                .disabled(isSwitching)
                            }
                        }
                        if let active = status.activeConfiguration, !active.controlChannels.isEmpty {
                            Section("Control Channel") {
                                ForEach(active.controlChannels, id: \.hz) { channel in
                                    Button {
                                        switchTo(active.id, controlChannelHz: channel.hz)
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading) {
                                                Text(Self.megahertz(channel.hz))
                                                if !channel.label.isEmpty {
                                                    Text(channel.label)
                                                        .font(.footnote)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer()
                                            if channel.hz == status.controlChannelHz {
                                                Image(systemName: "checkmark").foregroundStyle(.tint)
                                            }
                                        }
                                    }
                                    .disabled(isSwitching)
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
            ErrorSection(model: model)
        }
        .navigationTitle("dsd-neo")
        .freshErrors(model)
        .task {
            // Refreshes while open: the scanner restarts and hears calls on
            // its own, and the system can be changed on the Mac.
            while !Task.isCancelled {
                if !isSwitching { await model.loadDsdNeoStatus() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    @ViewBuilder
    private func controls(_ status: DsdNeoStatus) -> some View {
        Section {
            Text(Self.statusText(status))
                .font(.footnote)
            if status.isListening {
                if status.isActive {
                    Button("Skip Call", systemImage: "forward.end.fill") {
                        Task { await model.skipDsdNeoCall() }
                    }
                }
                Button("Stop", systemImage: "stop.fill") {
                    Task { await model.stopDsdNeo() }
                }
            } else if status.configured {
                StartButton(model: model) {
                    await model.startDsdNeo()
                } label: {
                    Label("Listen", systemImage: "play.fill")
                }
            } else {
                Text("Choose a system below, or set up the scanner in ControlBooth.")
                    .font(.footnote)
            }
        }
    }

    /// Changes the system or channel, then waits for the scanner's restart to
    /// show up in the status before polling resumes.
    private func switchTo(_ id: String, controlChannelHz: Int?) {
        isSwitching = true
        Task {
            await model.setDsdNeoConfiguration(id: id, controlChannelHz: controlChannelHz)
            try? await Task.sleep(for: .seconds(1))
            isSwitching = false
        }
    }

    private static func statusText(_ status: DsdNeoStatus) -> String {
        switch status.state {
        case "running": return status.talkgroupText.map { "Running — last heard \($0)" } ?? "Running — waiting for a clear call"
        case "restarting": return "Restarting dsd-neo"
        case "failed": return status.message ?? "Stopped after an error"
        default: return "Not running"
        }
    }

    private static func megahertz(_ hertz: Int) -> String {
        DsdNeoStatus.ControlChannel(hz: hertz, label: "").title
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

// MARK: Recordings

/// AntennaHead's recordings, newest first. Unlike the other sources, a
/// recording plays on the Watch itself (it's downloaded as it plays, so it
/// can pause and skip), and the Mac carries on with whatever it's doing.
private struct RecordingsView: View {
    let model: WatchModel

    var body: some View {
        List {
            if let recordings = model.recordings {
                if recordings.isEmpty {
                    Text("No recordings")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(recordings) { recording in
                            StartButton(model: model) {
                                await model.playRecording(recording)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(WatchModel.displayName(recording.fileName))
                                        .lineLimit(3)
                                    Text(recording.modifiedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } footer: {
                        Text("Plays on this Watch. Needs headphones and a direct connection to the Mac. The first play of a long recording can take a minute or two while the Mac prepares it.")
                    }
                }
            } else {
                ProgressView()
            }
            ErrorSection(model: model)
        }
        .navigationTitle("Recordings")
        .freshErrors(model)
        .task { await model.loadRecordings() }
    }
}

/// ControlBooth's mixing-board glyph (the `ControlBoothGlyph` template image),
/// sized like an SF Symbol. An asset image draws at its SVG's own 100 pt, so
/// it takes its frame from a hidden SF Symbol instead, which follows the
/// surrounding font the way the neighbouring symbols do.
struct ControlBoothGlyph: View {
    var body: some View {
        Image(systemName: "square")
            .hidden()
            .overlay { Image("ControlBoothGlyph").resizable().scaledToFit() }
    }
}
