import AntennaHeadAPI
import CarPlay
import Observation
import os
import UIKit

/// AntennaHead in the car: tabs for Favorites, Categories, Sources, and
/// Servers, built from CarPlay's audio-app templates (CarPlay allows no
/// custom views, so the server's web page can't be shown here).
///
/// Choosing anything tells the server to start it, then plays the live
/// stream from its live edge so the change is heard right away, and shows
/// the system Now Playing screen. That screen gets its title and controls
/// from `NativeAudioPlayer`, the same player the phone uses, plus a Stop
/// button that stops the server's tuning; as in every AntennaHead client,
/// the stream keeps playing into the filler.
///
/// The server is the phone's current one (`ServerStore.current`); servers
/// and logins are added on the phone, since CarPlay has no text entry.
@MainActor
final class CarPlayController: NSObject {
    private static let log = Logger(subsystem: "com.dsward.AntennaHeadiOS", category: "CarPlay")

    private let interfaceController: CPInterfaceController
    private let store: ServerStore
    private let player: NativeAudioPlayer
    private let monitor: NowPlayingMonitor

    private var client: ServerAPIClient?
    /// What `client` was made from, so a change that doesn't touch the
    /// current server (another server edited, say) doesn't reconnect.
    private var connectionKey: String?
    private var isRunning = false

    private let favoritesTemplate = CPListTemplate(title: "Favorites", sections: [])
    private let categoriesTemplate = CPListTemplate(title: "Categories", sections: [])
    private let sourcesTemplate = CPListTemplate(title: "Sources", sections: [])
    private let serversTemplate = CPListTemplate(title: "Servers", sections: [])
    private var tabBar: CPTabBarTemplate?

    // What's on the air, for the lists' playing indicators.
    private var nowPlaying: NowPlayingStatus?
    private var favoriteItems: [(FrequencySummary, CPListItem)] = []
    private var categoryItems: [(CategorySummary, CPListItem)] = []
    /// The category last scanned from here; the server's status doesn't say
    /// which category a scan is in.
    private var scanningCategoryID: Int64?

    /// 1 or 2 channels for Gqrx, as chosen on the Watch or TV; CarPlay has
    /// no room for the toggle, so it's stereo unless set otherwise.
    private var gqrxChannels: Int {
        UserDefaults.standard.object(forKey: "gqrxChannels") as? Int ?? 2
    }

    init(interfaceController: CPInterfaceController, services: AppServices) {
        self.interfaceController = interfaceController
        store = services.store
        player = services.player
        monitor = NowPlayingMonitor(player: services.player)
        super.init()
    }

    func start() {
        isRunning = true
        favoritesTemplate.tabImage = UIImage(systemName: "star.fill")
        categoriesTemplate.tabImage = UIImage(systemName: "list.bullet")
        sourcesTemplate.tabImage = UIImage(systemName: "antenna.radiowaves.left.and.right")
        serversTemplate.tabImage = UIImage(systemName: "server.rack")
        for template in [favoritesTemplate, categoriesTemplate, sourcesTemplate, serversTemplate] {
            template.emptyViewTitleVariants = ["Loading…"]
        }

        let tabBar = CPTabBarTemplate(templates: [favoritesTemplate, categoriesTemplate, sourcesTemplate, serversTemplate])
        tabBar.delegate = self
        self.tabBar = tabBar
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)

        setUpNowPlayingTemplate()
        monitor.onStatus = { [weak self] status in self?.apply(status) }
        buildSources()
        observeStore()
        connectToCurrentServer()
    }

    func stop() {
        isRunning = false
        monitor.stop()
        monitor.onStatus = nil
    }

    // MARK: Server

    /// Follows the phone's server list: another server chosen (on the phone
    /// or in the Servers tab), a login changed, or a server added.
    private func observeStore() {
        withObservationTracking {
            _ = store.revision
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.connectToCurrentServer()
                self.observeStore()
            }
        }
    }

    private func connectToCurrentServer() {
        buildServers()
        guard let server = store.current else {
            connectionKey = nil
            client = nil
            monitor.stop()
            let message = store.servers.isEmpty
                ? "Add your AntennaHead Mac in the AntennaHead app on your iPhone."
                : "Choose a server in the Servers tab."
            for template in [favoritesTemplate, categoriesTemplate] {
                showMessage(in: template, "No Server", message)
            }
            return
        }
        let credential = store.credential(for: server)
        let key = "\(server.id)|\(server.address)|\(server.usesHTTPS)|\(server.username)|\(credential?.password ?? "")"
        guard key != connectionKey else { return }

        if let previous = client, previous.server.id != server.id {
            // The old server's stream shouldn't keep playing under the new
            // server's name.
            player.stop()
        }
        connectionKey = key
        let client = ServerAPIClient(server: server, credential: credential)
        self.client = client
        player.setCredential(credential)
        if player.source == nil {
            // Lets the Now Playing screen's Play button start the stream.
            player.defaultLiveURL = client.liveURL
        }
        monitor.start(server: server, credential: credential)
        Self.log.info("CarPlay using server \(server.name, privacy: .public)")
        Task {
            await loadFavorites()
            await loadCategories()
        }
    }

    private func buildServers() {
        guard !store.servers.isEmpty else {
            serversTemplate.updateSections([])
            serversTemplate.emptyViewTitleVariants = ["No Servers"]
            serversTemplate.emptyViewSubtitleVariants = ["Add your AntennaHead Mac in the AntennaHead app on your iPhone."]
            return
        }
        let items = store.servers.map { server in
            let isCurrent = server.id == store.currentServerID
            let item = CPListItem(text: server.name,
                                  detailText: isCurrent ? "Connected · \(server.address)" : server.address,
                                  image: UIImage(systemName: isCurrent ? "checkmark.circle.fill" : "desktopcomputer"))
            item.handler = { [weak self] _, completion in
                if let self, server.id != self.store.currentServerID {
                    self.store.connect(to: server)
                }
                completion()
            }
            return item
        }
        serversTemplate.updateSections(Self.limited([CPListSection(items: items)]))
    }

    // MARK: Favorites and categories

    private func loadFavorites() async {
        guard let client else { return }
        do {
            let favorites = try await client.favorites()
            guard client === self.client else { return }
            favoriteItems = favorites.map { favorite in
                let detail = [favorite.formattedFrequency, favorite.modulation]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                let item = startItem(favorite.stationName.isEmpty ? favorite.formattedFrequency : favorite.stationName,
                                     detail: detail) { try await $0.tune(frequencyID: favorite.id) }
                return (favorite, item)
            }
            if favoriteItems.isEmpty {
                showMessage(in: favoritesTemplate, "No Favorites", "Mark frequencies as favorites in AntennaHead on the Mac.")
            } else {
                favoritesTemplate.updateSections(Self.limited([CPListSection(items: favoriteItems.map(\.1))]))
            }
            markPlaying()
        } catch {
            showMessage(in: favoritesTemplate, "Can't Reach \(client.server.name)", Self.describe(error))
        }
    }

    private func loadCategories() async {
        guard let client else { return }
        do {
            let categories = try await client.categories()
            guard client === self.client else { return }
            categoryItems = categories.map { category in
                let count = "\(category.frequencyCount) frequenc\(category.frequencyCount == 1 ? "y" : "ies")"
                let item = startItem(category.categoryName,
                                     detail: category.scanningEnabled ? "Scan · \(count)" : "\(count) · scanning off",
                                     image: "dot.radiowaves.left.and.right") { [weak self] client in
                    let status = try await client.startScan(categoryID: category.id)
                    self?.scanningCategoryID = category.id
                    return status
                }
                return (category, item)
            }
            if categoryItems.isEmpty {
                showMessage(in: categoriesTemplate, "No Categories", "Add categories in AntennaHead on the Mac.")
            } else {
                categoriesTemplate.updateSections(Self.limited([CPListSection(items: categoryItems.map(\.1))]))
            }
            markPlaying()
        } catch {
            showMessage(in: categoriesTemplate, "Can't Reach \(client.server.name)", Self.describe(error))
        }
    }

    // MARK: Other sources

    private func buildSources() {
        let items = [
            sourceItem("Gqrx", image: "dot.radiowaves.left.and.right", build: buildGqrx),
            sourceItem("ControlBooth", image: "slider.horizontal.3", build: buildControlBooth),
            sourceItem("AirPlay Receiver", image: "airplayaudio", build: buildAirPlay),
            sourceItem("Devices", image: "mic", build: buildDevices),
            sourceItem("Audio Files", image: "music.note.list") { try await self.buildFolder($0, textToSpeech: false) },
            sourceItem("Text to Speech", image: "text.bubble") { try await self.buildFolder($0, textToSpeech: true) },
            sourceItem("RSS Headlines", image: "newspaper", build: buildRSS),
        ]
        sourcesTemplate.updateSections([CPListSection(items: items)])
    }

    /// A Sources row that loads its list, then opens it. The list is built
    /// before it's pushed, so the row shows CarPlay's spinner meanwhile and a
    /// failure is an alert rather than an empty screen.
    private func sourceItem(_ title: String, image: String,
                            build: @escaping (ServerAPIClient) async throws -> [CPListSection]) -> CPListItem {
        let item = CPListItem(text: title, detailText: nil, image: UIImage(systemName: image))
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            Task {
                defer { completion() }
                guard let self, let client = self.client else {
                    self?.showAlert("Choose a server in the Servers tab first.")
                    return
                }
                do {
                    let template = CPListTemplate(title: title, sections: Self.limited(try await build(client)))
                    self.interfaceController.pushTemplate(template, animated: true, completion: nil)
                } catch {
                    self.showAlert(Self.describe(error))
                }
            }
        }
        return item
    }

    private func buildGqrx(_ client: ServerAPIClient) async throws -> [CPListSection] {
        let status = try await client.gqrxStatus()
        let channels = gqrxChannels
        guard status.isRunning else {
            return [CPListSection(items: [
                startItem("Launch Gqrx", detail: "Starts Gqrx on the Mac and listens to it", image: "power") { client in
                    _ = try await client.launchGqrx()
                    return try await client.nowPlaying()
                },
            ])]
        }
        var sections = [CPListSection(items: [
            startItem("Play Gqrx", detail: channels == 2 ? "Stereo" : "Mono", image: "play.fill") {
                try await $0.startGqrx(channels: channels)
            },
        ])]
        do {
            let bookmarks = try await client.gqrxBookmarks()
            let items = bookmarks.isEmpty
                ? [infoItem("No bookmarks")]
                : bookmarks.map { bookmark in
                    let megahertz = String(format: "%.4f MHz", Double(bookmark.frequencyHz) / 1_000_000)
                    return startItem(bookmark.name.isEmpty ? megahertz : bookmark.name,
                                     detail: "\(megahertz) · \(bookmark.modulation)") {
                        try await $0.playGqrxBookmark(frequencyHz: bookmark.frequencyHz, channels: channels)
                    }
                }
            sections.append(CPListSection(items: items, header: "Bookmarks", sectionIndexTitle: nil))
        } catch {
            // Gqrx's remote control is off, say: a state, not a failure.
            sections.append(CPListSection(items: [infoItem(Self.describe(error))], header: "Bookmarks", sectionIndexTitle: nil))
        }
        return sections
    }

    private func buildControlBooth(_ client: ServerAPIClient) async throws -> [CPListSection] {
        let status = try await client.controlBoothStatus()
        guard status.isRunning else { return [launchControlBoothSection()] }
        let pipelines = status.pipelineNames.isEmpty
            ? [infoItem("No pipelines configured in ControlBooth.")]
            : status.pipelineNames.map { name in
                let item = startItem(name) { try await $0.startControlBoothPipeline(named: name) }
                item.isPlaying = name == status.activePipelineName
                item.playingIndicatorLocation = .trailing
                return item
            }
        return [
            CPListSection(items: pipelines, header: "Pipelines", sectionIndexTitle: nil),
            CPListSection(items: [
                startItem("Stop ControlBooth", detail: "AntennaHead goes back to its filler", image: "stop.fill") {
                    try await $0.stopControlBooth()
                },
            ]),
        ]
    }

    private func buildAirPlay(_ client: ServerAPIClient) async throws -> [CPListSection] {
        let status = try await client.controlBoothStatus()
        guard status.isRunning else { return [launchControlBoothSection()] }
        let item = status.isListeningToAirPlay
            ? startItem("Stop", detail: "Stop listening to AirPlay", image: "stop.fill") { try await $0.stopAirPlay() }
            : startItem("Play", detail: "AirPlay to ControlBooth, and it comes through AntennaHead", image: "airplayaudio") {
                try await $0.startAirPlay()
            }
        return [CPListSection(items: [item])]
    }

    /// ControlBooth isn't running: offer to launch it, then refresh the
    /// list that asked.
    private func launchControlBoothSection() -> CPListSection {
        let item = CPListItem(text: "Launch ControlBooth", detailText: "ControlBooth isn't running.", image: UIImage(systemName: "power"))
        item.handler = { [weak self] _, completion in
            Task {
                defer { completion() }
                guard let self, let client = self.client else { return }
                do {
                    _ = try await client.launchControlBooth()
                    self.interfaceController.popTemplate(animated: true, completion: nil)
                } catch {
                    self.showAlert(Self.describe(error))
                }
            }
        }
        return CPListSection(items: [item])
    }

    private func buildDevices(_ client: ServerAPIClient) async throws -> [CPListSection] {
        let devices = try await client.devices()
        guard !devices.isEmpty else { return [CPListSection(items: [infoItem("No input devices")])] }
        return [CPListSection(items: devices.map { device in
            startItem(device.name, image: "mic") { try await $0.startDevice(name: device.name) }
        })]
    }

    private func buildFolder(_ client: ServerAPIClient, textToSpeech: Bool) async throws -> [CPListSection] {
        let listing = textToSpeech ? try await client.textToSpeechFiles() : try await client.audioFiles()
        guard listing.folderConfigured else {
            let kind = textToSpeech ? "Text to Speech" : "Audio Files"
            return [CPListSection(items: [infoItem("Choose a folder for \(kind) in AntennaHead's Configuration tab on the Mac.")])]
        }
        func start(_ fileNames: [String]?) -> (ServerAPIClient) async throws -> NowPlayingStatus {
            { client in
                textToSpeech
                    ? try await client.startTextToSpeech(StartTextToSpeechRequest(fileNames: fileNames))
                    : try await client.startAudioFiles(StartAudioFilesRequest(fileNames: fileNames))
            }
        }
        var sections = [CPListSection(items: [startItem("Play All", image: "play.fill", start: start(nil))])]
        if !textToSpeech, !listing.playlists.isEmpty {
            sections.append(CPListSection(items: listing.playlists.map { name in
                startItem(name, image: "music.note.list") {
                    try await $0.startAudioFiles(StartAudioFilesRequest(playlistName: name))
                }
            }, header: "Playlists", sectionIndexTitle: nil))
        }
        let files = listing.files.isEmpty
            ? [infoItem("The folder is empty.")]
            : listing.files.map { startItem($0.name, start: start([$0.name])) }
        sections.append(CPListSection(items: files, header: "Files", sectionIndexTitle: nil))
        return sections
    }

    private func buildRSS(_ client: ServerAPIClient) async throws -> [CPListSection] {
        let feeds = try await client.rssFeeds()
        guard !feeds.isEmpty else { return [CPListSection(items: [infoItem("No RSS feeds. Add them in AntennaHead on the Mac.")])] }
        let all = startItem("Play All Feeds", detail: "5 headlines from each feed", image: "play.fill") {
            try await $0.startRSSHeadlines(StartRSSHeadlinesRequest(feedIDs: feeds.map(\.id)))
        }
        return [
            CPListSection(items: [all]),
            CPListSection(items: feeds.map { feed in
                startItem(feed.name, image: "newspaper") {
                    try await $0.startRSSHeadlines(StartRSSHeadlinesRequest(feedIDs: [feed.id]))
                }
            }, header: "Feeds", sectionIndexTitle: nil),
        ]
    }

    // MARK: Starting things

    /// A row that starts something on the server when chosen.
    private func startItem(_ text: String, detail: String? = nil, image: String? = nil,
                           start: @escaping (ServerAPIClient) async throws -> NowPlayingStatus) -> CPListItem {
        let item = CPListItem(text: text, detailText: detail, image: image.flatMap { UIImage(systemName: $0) })
        item.playingIndicatorLocation = .trailing
        item.handler = { [weak self] _, completion in
            Task {
                await self?.perform(start)
                completion()
            }
        }
        return item
    }

    /// A row that only says something, e.g. why a list is empty.
    private func infoItem(_ text: String) -> CPListItem {
        CPListItem(text: text, detailText: nil)
    }

    private func perform(_ start: (ServerAPIClient) async throws -> NowPlayingStatus) async {
        guard let client else {
            showAlert("Choose a server in the Servers tab first.")
            return
        }
        do {
            apply(try await start(client))
            listen()
            showNowPlaying()
        } catch {
            showAlert(Self.describe(error))
        }
    }

    /// Plays the live stream from its live edge: a fresh item even if it's
    /// already playing, so what was just chosen is heard now rather than
    /// after the buffer drains.
    private func listen() {
        guard let url = client?.liveURL else { return }
        player.play(.live(url))
    }

    // MARK: Now Playing

    private func setUpNowPlayingTemplate() {
        let template = CPNowPlayingTemplate.shared
        template.isUpNextButtonEnabled = false
        template.isAlbumArtistButtonEnabled = false
        guard let image = UIImage(systemName: "stop.fill") else { return }
        let stop = CPNowPlayingImageButton(image: image) { [weak self] _ in
            // Stops the tuning on the server; the stream keeps playing into
            // the filler, as Stop does in every AntennaHead client.
            Task { await self?.perform { try await $0.stop() } }
        }
        template.updateNowPlayingButtons([stop])
    }

    private func showNowPlaying() {
        let template = CPNowPlayingTemplate.shared
        guard interfaceController.topTemplate !== template else { return }
        if interfaceController.templates.contains(where: { $0 === template }) {
            interfaceController.pop(to: template, animated: true, completion: nil)
        } else {
            interfaceController.pushTemplate(template, animated: true, completion: nil)
        }
    }

    private func apply(_ status: NowPlayingStatus) {
        nowPlaying = status
        if status.taskMode != .scan { scanningCategoryID = nil }
        markPlaying()
    }

    /// The speaker icon beside whatever is on the air.
    private func markPlaying() {
        let status = nowPlaying
        for (favorite, item) in favoriteItems {
            item.isPlaying = status?.taskMode == .frequency
                && status?.stationName == favorite.stationName
                && status?.formattedFrequency == favorite.formattedFrequency
        }
        for (category, item) in categoryItems {
            item.isPlaying = status?.taskMode == .scan && category.id == scanningCategoryID
        }
    }

    // MARK: Messages

    private func showMessage(in template: CPListTemplate, _ title: String, _ subtitle: String) {
        template.updateSections([])
        template.emptyViewTitleVariants = [title]
        template.emptyViewSubtitleVariants = [subtitle]
        if template === favoritesTemplate { favoriteItems = [] }
        if template === categoriesTemplate { categoryItems = [] }
    }

    private func showAlert(_ message: String) {
        Self.log.error("\(message, privacy: .public)")
        let alert = CPAlertTemplate(titleVariants: [message], actions: [
            CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
                self?.interfaceController.dismissTemplate(animated: true, completion: nil)
            },
        ])
        if interfaceController.presentedTemplate != nil {
            interfaceController.dismissTemplate(animated: false, completion: nil)
        }
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .networkConnectionLost:
                return "\(urlError.localizedDescription) If you're away from home, check that your VPN is connected."
            default: break
            }
        }
        return error.localizedDescription
    }

    /// Trims to what this car allows; CarPlay limits list length so a
    /// driver isn't scrolling.
    private static func limited(_ sections: [CPListSection]) -> [CPListSection] {
        var remaining = Int(CPListTemplate.maximumItemCount)
        var result: [CPListSection] = []
        for section in sections.prefix(Int(CPListTemplate.maximumSectionCount)) where remaining > 0 {
            let items = Array(section.items.prefix(remaining))
            remaining -= items.count
            result.append(CPListSection(items: items, header: section.header, sectionIndexTitle: section.sectionIndexTitle))
        }
        return result
    }
}

extension CarPlayController: CPTabBarTemplateDelegate {
    /// Refreshes a tab's list whenever it's opened, so a favorite added on
    /// the Mac shows up without reconnecting.
    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        Task {
            if selectedTemplate === favoritesTemplate {
                await loadFavorites()
            } else if selectedTemplate === categoriesTemplate {
                await loadCategories()
            }
        }
    }
}
