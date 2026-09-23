import SwiftUI
import WebKit
import os

/// Shows AntennaHead's own web UI and routes its audio to `NativeAudioPlayer`.
///
/// The contract with the page (`Web/index.html` in the AntennaHead repo):
///
/// - The app registers a script message handler named `antennaheadAudio`.
///   The page checks for it; when it's present, the page hides its `<audio>`
///   element behind a small native-controls row and sends the app messages
///   instead of playing anything itself:
///   - `{command: "pageLoaded", url}` — the live HLS URL, on every page load
///   - `{command: "playLive", url}` — a Listen/Tuner/Devices/... action
///   - `{command: "playFile", url, loop}` — play a recording ("fast download")
///   - `{command: "toggle", url}` — the ▶︎/❚❚ button
///   - `{command: "showServers"}` — the ⋯ button, back to the server list
/// - The app reports player state by calling the page's
///   `antennaheadNativeAudioState(state, status)`.
/// - The page defines `antennaheadNativeAudioSupported`. An older server
///   whose page doesn't know about the app lacks it; the page then still
///   plays through `<audio>` as before, and `onLegacyPage` lets the app show
///   its own way back to the server list.
struct AntennaHeadWebView: UIViewRepresentable {
    let server: SavedServer
    let store: ServerStore
    let player: NativeAudioPlayer
    /// Set when the page can't be loaded at all; `nil` once it loads.
    let onLoadError: (String?) -> Void
    /// `true` when the loaded page predates the native-audio bridge.
    let onLegacyPage: (Bool) -> Void
    /// Bumped by the parent to force a reload (the error screen's Retry).
    let reloadToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakScriptMessageHandler(context.coordinator),
                                                name: Coordinator.handlerName)
        // Only matters for an older server's page that still plays through
        // <audio>.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        #if DEBUG
        webView.isInspectable = true   // Safari ▸ Develop, for debugging the page
        #endif

        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.pullToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        context.coordinator.webView = webView
        context.coordinator.attachPlayer()
        context.coordinator.load()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.lastReloadToken != reloadToken {
            coordinator.lastReloadToken = reloadToken
            coordinator.load()
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.handlerName)
        coordinator.parent.player.onStateChange = nil
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        static let handlerName = "antennaheadAudio"
        private static let log = Logger(subsystem: "com.dsward.AntennaHeadiOS", category: "WebBridge")

        var parent: AntennaHeadWebView
        weak var webView: WKWebView?
        var lastReloadToken: Int

        init(parent: AntennaHeadWebView) {
            self.parent = parent
            self.lastReloadToken = parent.reloadToken
        }

        func load() {
            guard let url = parent.server.baseURL else {
                parent.onLoadError("“\(parent.server.address)” isn't a valid address.")
                return
            }
            webView?.load(URLRequest(url: url))
        }

        func attachPlayer() {
            parent.player.onStateChange = { [weak self] state, status in
                self?.pushPlayerState(state, status)
            }
        }

        @objc func pullToRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
        }

        private func pushPlayerState(_ state: NativeAudioPlayer.State, _ status: String) {
            guard let webView,
                  let args = try? JSONEncoder().encode([state.rawValue, status]),
                  let argsJSON = String(data: args, encoding: .utf8) else { return }
            // argsJSON is a two-element JSON array; spread it into the call.
            let script = "typeof antennaheadNativeAudioState === 'function' && antennaheadNativeAudioState.apply(null, \(argsJSON));"
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        // MARK: Messages from the page

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let command = body["command"] as? String else { return }
            let player = parent.player
            let url = (body["url"] as? String).flatMap(URL.init(string:))
            Self.log.info("page → \(command, privacy: .public) \(url?.absoluteString ?? "-", privacy: .public)")

            switch command {
            case "pageLoaded":
                if let url { player.defaultLiveURL = url }
                pushPlayerState(player.state, player.statusText)
                #if DEBUG
                // `-autoplayLive YES` launch argument: start the live stream
                // without a tap, for testing on a device from the Mac.
                // `-liveURLOverride <url>`: play that instead (e.g. to bypass
                // AntennaHead's HLS proxy while diagnosing).
                if UserDefaults.standard.bool(forKey: "autoplayLive"), player.source == nil, let url {
                    let override = UserDefaults.standard.string(forKey: "liveURLOverride").flatMap(URL.init(string:))
                    player.play(.live(override ?? url))
                }
                #endif
            case "playLive":
                guard let url = url ?? player.defaultLiveURL else { return }
                // The page sends this on every Listen press. If the live
                // stream is already playing, carry on, as the web page does
                // (the server switched what's on it, not the URL).
                if player.source == .live(url), player.state == .playing { return }
                player.play(.live(url))
            case "playFile":
                guard let url else { return }
                player.play(.file(url, loop: body["loop"] as? Bool ?? false))
            case "toggle":
                if player.source == nil, let url { player.defaultLiveURL = url }
                player.togglePlayPause()
            case "showServers":
                player.stop()
                parent.store.disconnect()
            default:
                break
            }
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoadError(nil)
            webView.evaluateJavaScript("typeof antennaheadNativeAudioSupported !== 'undefined'") { [weak self] result, _ in
                self?.parent.onLegacyPage((result as? Bool) != true)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportFailure(error)
        }

        private func reportFailure(_ error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
            parent.onLoadError(error.localizedDescription)
        }

        /// iOS may kill the web content process while the app is in the
        /// background (audio keeps playing — it isn't in that process).
        /// Reload so the page is there when the user comes back.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        // MARK: Web login (HTTP Basic Auth)

        func webView(_ webView: WKWebView,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let server = parent.server
            if challenge.previousFailureCount == 0, let credential = parent.store.credential(for: server) {
                use(credential, for: challenge, completionHandler)
                return
            }
            promptForLogin(server: server, failed: challenge.previousFailureCount > 0) { [weak self] username, password in
                guard let self, let username, let password else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                var updated = server
                updated.username = username
                self.parent.store.save(updated, password: password)
                let credential = URLCredential(user: username, password: password, persistence: .forSession)
                self.use(credential, for: challenge, completionHandler)
            }
        }

        private func use(_ credential: URLCredential,
                         for challenge: URLAuthenticationChallenge,
                         _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Share it with the native player and the Now Playing poller,
            // which make their own requests to the same server.
            URLCredentialStorage.shared.setDefaultCredential(credential, for: challenge.protectionSpace)
            parent.player.setCredential(credential)
            completionHandler(.useCredential, credential)
        }

        private func promptForLogin(server: SavedServer, failed: Bool,
                                    completion: @escaping (String?, String?) -> Void) {
            let alert = UIAlertController(
                title: failed ? "Login Failed" : "Log In to \(server.name)",
                message: "AntennaHead's web login is on. Enter the username and password from its Configuration.",
                preferredStyle: .alert)
            alert.addTextField { field in
                field.placeholder = "Username"
                field.text = server.username
                field.textContentType = .username
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
            }
            alert.addTextField { field in
                field.placeholder = "Password"
                field.isSecureTextEntry = true
                field.textContentType = .password
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil, nil) })
            alert.addAction(UIAlertAction(title: "Log In", style: .default) { [weak alert] _ in
                completion(alert?.textFields?[0].text ?? "", alert?.textFields?[1].text ?? "")
            })
            present(alert)
        }

        // MARK: JavaScript alert() / confirm() / prompt()
        //
        // The page uses these (e.g. "Select a recording first."); WKWebView
        // silently drops them unless the app shows them itself.

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            present(alert, orElse: completionHandler)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            present(alert) { completionHandler(false) }
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                completionHandler(alert?.textFields?.first?.text)
            })
            present(alert) { completionHandler(nil) }
        }

        /// Presents from the top-most view controller; runs `fallback` if
        /// there's nowhere to present (so WebKit's completion handler is
        /// always called).
        private func present(_ alert: UIAlertController, orElse fallback: (() -> Void)? = nil) {
            guard var top = webView?.window?.rootViewController else {
                fallback?()
                return
            }
            while let presented = top.presentedViewController { top = presented }
            top.present(alert, animated: true)
        }
    }
}

/// `WKUserContentController` retains its message handlers strongly, which
/// would keep the coordinator (and through it the web view) alive forever.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
