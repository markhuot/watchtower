import SwiftUI
import WebKit
import os

private let logger = Logger(subsystem: "com.watchtower", category: "BrowserWebView")

// MARK: - Shared Configuration

/// Shared process pool so all browser panes share cookies, localStorage,
/// and session state. Each pane gets its own WKWebViewConfiguration (and
/// therefore its own WKUserContentController) to avoid the crash that
/// occurs when two message handlers with the same name are registered on
/// a single content controller.
enum BrowserConfiguration {
    static let processPool = WKProcessPool()

    /// User script injected into every browser pane for form interaction detection.
    ///
    /// Tracks whether the user has interacted with form elements (input, textarea,
    /// select) and notifies Swift via a message handler. The local `changed`
    /// gate variable is reset on `beforeunload` so it re-arms for each new
    /// document. The Swift-side `hasInteractedForms` flag is reset separately
    /// in `didStartProvisionalNavigation` and `didCommit`.
    static let formScript = WKUserScript(
        source: """
        (function() {
            var changed = false;
            document.addEventListener('input', function(e) {
                if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.tagName === 'SELECT') {
                    if (!changed) {
                        changed = true;
                        window.webkit.messageHandlers.formInteraction.postMessage(true);
                    }
                }
            }, true);
            window.addEventListener('beforeunload', function() { changed = false; });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    /// Creates a new configuration for each browser pane, sharing only the
    /// process pool (for cookies/session state).
    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        // Enable "Inspect Element" in the WKWebView context menu.
        // isInspectable (set on the view) allows Safari's Develop menu to
        // connect, but the context menu item requires developerExtrasEnabled.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let contentController = WKUserContentController()
        contentController.addUserScript(formScript)
        config.userContentController = contentController
        return config
    }
}

// MARK: - WatchtowerWebView (WKWebView subclass)

/// Custom WKWebView subclass that participates in the app's focus tracking
/// and lets app-level keyboard shortcuts (like Cmd+Shift+[/]) pass through
/// to the menu system instead of being consumed by WebKit.
class WatchtowerWebView: WKWebView, BrowserEngineView {
    weak var browser: BrowserPaneModel?

    /// Load the given URL request (BrowserEngineView conformance).
    func loadRequest(_ request: URLRequest) {
        load(request)
    }

    /// BrowserEngineView conformance — WKWebView's goBack() returns
    /// WKNavigation? which doesn't match the Void protocol signature.
    func goBack() {
        _ = super.goBack()
    }

    /// BrowserEngineView conformance — wraps WKWebView's goForward().
    func goForward() {
        _ = super.goForward()
    }

    /// BrowserEngineView conformance — wraps WKWebView's reload().
    func reload() {
        _ = super.reload()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            browser?.isFocused = true

            // Notify the view model so focusModePaneId is updated (which
            // drives the focus-mode width expansion). Without this, direct
            // clicks on the WKWebView bypass focusPane() entirely and the
            // pane never expands.
            if let browser = browser, let vm = browser.viewModel {
                // Only call focusPane when the view model doesn't already
                // consider this pane focused, to avoid re-entrant loops
                // (focusPane → makeFirstResponder → becomeFirstResponder).
                if vm.focusModePaneId != browser.id || vm.contextualPane?.id != browser.id {
                    vm.focusPane(id: browser.id)
                }
            }

            scrollToVisibleInEnclosingScrollView()

            // In focus mode the pane width changes after focusModePaneId is
            // updated, but SwiftUI lays out asynchronously. The immediate
            // scroll above uses the pre-expansion frame. Schedule a
            // second scroll after the layout pass so the fully-expanded
            // pane is brought into view.
            DispatchQueue.main.async { [weak self] in
                self?.scrollToVisibleInEnclosingScrollView()
            }
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            browser?.isFocused = false
        }
        return result
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard self.window != nil else { return }

        // Claim focus if this view was pending.
        // Defer to the next run-loop iteration because viewDidMoveToWindow
        // fires during the SwiftUI view-update pass that is inserting this
        // NSView. Calling makeFirstResponder here triggers
        // becomeFirstResponder which sets @Published isFocused, causing
        // "Publishing changes from within view updates" warnings and a
        // frozen/black WebView.
        if let pending = browser?.viewModel?.pendingFocus,
           pending.paneId == browser?.id,
           pending.fulfill() {
            browser?.viewModel?.pendingFocus = nil
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }

        // When collapsed, block key equivalents from reaching WebKit.
        // Return false so menu shortcuts (Cmd+Shift+P, Cmd+L, etc.) still
        // propagate through the responder chain to the menu system.
        if let browser = browser, browser.isCollapsed { return false }

        // Let all Watchtower app shortcuts pass through to the menu system
        // instead of being consumed by WebKit (e.g. Cmd+R for reload,
        // Cmd+Shift+P for command palette, Cmd+L, pane navigation, etc.).
        if isWatchtowerAppShortcut(event) { return false }

        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // When collapsed, swallow all key events. Enter/Return/Space expands the pane.
        if let browser = browser, browser.isCollapsed {
            if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 { // Return, Enter, or Space
                browser.viewModel?.toggleCollapsePane()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if let browser = browser, browser.isCollapsed { return }
        super.keyUp(with: event)
    }

    /// Intercept the "Close" menu item (Cmd+W). Close just this browser pane,
    /// with a confirmation dialog if unsaved form data exists.
    /// When this is the last pane, the empty state is shown instead of closing the window.
    @objc func performClose(_ sender: Any?) {
        guard let browser = browser else {
            window?.performClose(sender)
            return
        }

        if browser.hasInteractedForms {
            guard let window = self.window else { return }
            let alert = NSAlert()
            alert.messageText = "Close Browser Pane?"
            alert.informativeText = "There are unsaved changes on this page that will be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    NotificationCenter.default.post(
                        name: .browserPaneClosed,
                        object: nil,
                        userInfo: ["paneId": browser.id]
                    )
                }
            }
        } else {
            NotificationCenter.default.post(
                name: .browserPaneClosed,
                object: nil,
                userInfo: ["paneId": browser.id]
            )
        }
    }
}

// MARK: - WebKitBrowserView

struct WebKitBrowserView: NSViewRepresentable {
    @ObservedObject var browser: BrowserPaneModel
    @ObservedObject private var appManager = GhosttyAppManager.shared

    func makeCoordinator() -> Coordinator {
        Coordinator(browser: browser)
    }

    func makeNSView(context: Context) -> WatchtowerWebView {
        let config = BrowserConfiguration.makeConfiguration()
        let webView = WatchtowerWebView(frame: .zero, configuration: config)
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        // Set a Safari-like user agent so websites don't misidentify
        // the embedded browser (WKWebView defaults to the host app's
        // bundle name, which sites report as "Apple Mail").
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString = "\(osVersion.majorVersion)_\(osVersion.minorVersion)_\(osVersion.patchVersion)"
        let safariMajor = osVersion.majorVersion + 3 // macOS 15 → Safari 18, etc.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X \(osVersionString)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariMajor).0 Safari/605.1.15"
        webView.browser = browser
        browser.engineView = webView
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView

        // Set the web view appearance based on the terminal theme so that
        // CSS `prefers-color-scheme` matches the surrounding UI.
        let appManager = GhosttyAppManager.shared
        webView.appearance = NSAppearance(named: appManager.isDarkTheme ? .darkAqua : .aqua)

        // Register the form interaction message handler on this web view's
        // own content controller (each pane gets a fresh configuration).
        webView.configuration.userContentController.add(
            context.coordinator,
            name: "formInteraction"
        )

        // Defer KVO setup and initial load to the next run-loop iteration so
        // that @Published mutations triggered by KVO don't land inside the
        // SwiftUI view-update pass that is creating this NSView.
        DispatchQueue.main.async {
            context.coordinator.setupKVO(for: webView)

            // Always load the URL — even about:blank — so WKWebView's
            // rendering pipeline initialises. Without at least one
            // navigation the web content process never composits a
            // frame and the view stays black.
            context.coordinator.loadedGeneration = self.browser.navigationGeneration
            logger.info("[makeNSView] Loading initial URL: \(self.browser.url.absoluteString, privacy: .public) (generation=\(self.browser.navigationGeneration))")
            webView.load(URLRequest(url: self.browser.url))
        }

        return webView
    }

    func updateNSView(_ webView: WatchtowerWebView, context: Context) {
        // Keep the web view appearance in sync with the terminal theme so
        // that CSS `prefers-color-scheme` reflects light/dark changes.
        let desired = NSAppearance(named: appManager.isDarkTheme ? .darkAqua : .aqua)
        if webView.appearance?.name != desired?.name {
            webView.appearance = desired
        }

        // Only navigate when the model's navigation generation has advanced
        // past what the coordinator last loaded. This prevents KVO writeback
        // (which updates browser.url but not navigationGeneration) from
        // triggering redundant loads.
        guard browser.navigationGeneration > context.coordinator.loadedGeneration else { return }
        context.coordinator.loadedGeneration = browser.navigationGeneration
        logger.info("[updateNSView] Navigating to: \(self.browser.url.absoluteString, privacy: .public) (generation=\(self.browser.navigationGeneration))")
        webView.load(URLRequest(url: browser.url))
    }

    static func dismantleNSView(_ nsView: WatchtowerWebView, coordinator: Coordinator) {
        coordinator.teardownKVO()
        nsView.configuration.userContentController.removeScriptMessageHandler(
            forName: "formInteraction"
        )
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
        var browser: BrowserPaneModel
        weak var webView: WKWebView?

        /// Tracks the last `BrowserPaneModel.navigationGeneration` that was
        /// loaded so that `updateNSView` only triggers a load when the model
        /// has advanced past this value.
        var loadedGeneration: UInt = 0

        private var titleObservation: NSKeyValueObservation?
        private var isLoadingObservation: NSKeyValueObservation?
        private var canGoBackObservation: NSKeyValueObservation?
        private var canGoForwardObservation: NSKeyValueObservation?
        private var estimatedProgressObservation: NSKeyValueObservation?
        private var urlObservation: NSKeyValueObservation?

        init(browser: BrowserPaneModel) {
            self.browser = browser
        }

        func setupKVO(for webView: WKWebView) {
            // No `options:` argument — default is [] which means the observer
            // only fires on *changes* after registration, not for the initial
            // value. This avoids publishing @Published mutations during the
            // SwiftUI view-update pass that is creating the NSView.
            titleObservation = webView.observe(\.title) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.browser.pageTitle = wv.title ?? "New Tab"
                }
            }
            isLoadingObservation = webView.observe(\.isLoading) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.browser.isLoading = wv.isLoading
                }
            }
            canGoBackObservation = webView.observe(\.canGoBack) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.browser.canGoBack = wv.canGoBack
                }
            }
            canGoForwardObservation = webView.observe(\.canGoForward) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.browser.canGoForward = wv.canGoForward
                }
            }
            estimatedProgressObservation = webView.observe(\.estimatedProgress) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.browser.estimatedProgress = wv.estimatedProgress
                }
            }
            urlObservation = webView.observe(\.url) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    if let newURL = wv.url {
                        self?.browser.url = newURL
                    }
                }
            }
        }

        func teardownKVO() {
            titleObservation?.invalidate()
            isLoadingObservation?.invalidate()
            canGoBackObservation?.invalidate()
            canGoForwardObservation?.invalidate()
            estimatedProgressObservation?.invalidate()
            urlObservation?.invalidate()
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView,
                      decidePolicyFor navigationAction: WKNavigationAction,
                      preferences: WKWebpagePreferences,
                      decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            let url = navigationAction.request.url?.absoluteString ?? "<nil>"
            let isTargetNil = navigationAction.targetFrame == nil
            logger.info("[decidePolicyFor action] url=\(url, privacy: .public) targetFrame=\(isTargetNil ? "nil" : "present", privacy: .public) navigationType=\(navigationAction.navigationType.rawValue)")

            // If the navigation action itself indicates a download (e.g. the
            // link has a `download` attribute), convert it to a download.
            if navigationAction.shouldPerformDownload {
                logger.info("[decidePolicyFor action] shouldPerformDownload=true — converting to download")
                decisionHandler(.download, preferences)
                return
            }

            // Cmd+click on a link opens it in a new browser pane, leaving
            // the current pane untouched.
            let isCmdHeld = navigationAction.modifierFlags.contains(.command)
            if isCmdHeld,
               navigationAction.navigationType == .linkActivated,
               let targetURL = navigationAction.request.url {
                logger.info("[decidePolicyFor action] Cmd+click — opening in new pane: \(targetURL.absoluteString, privacy: .public)")
                DispatchQueue.main.async { [weak self] in
                    guard let vm = self?.browser.viewModel else { return }
                    let newBrowser = vm.addBrowser(url: targetURL)
                    vm.focusPane(newBrowser)
                }
                decisionHandler(.cancel, preferences)
                return
            }

            // Allow all navigations. Target=_blank opens in same web view.
            if navigationAction.targetFrame == nil {
                // New window request — load in the same view
                if let url = navigationAction.request.url {
                    webView.load(URLRequest(url: url))
                }
                decisionHandler(.cancel, preferences)
            } else {
                decisionHandler(.allow, preferences)
            }
        }

        func webView(_ webView: WKWebView,
                      decidePolicyFor navigationResponse: WKNavigationResponse,
                      decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let url = navigationResponse.response.url?.absoluteString ?? "<nil>"
            // Capture HTTP status code
            if let httpResponse = navigationResponse.response as? HTTPURLResponse {
                logger.info("[decidePolicyFor response] url=\(url, privacy: .public) status=\(httpResponse.statusCode)")
                DispatchQueue.main.async { [weak self] in
                    self?.browser.httpStatusCode = httpResponse.statusCode
                }

                // Check for Content-Disposition: attachment header
                let contentDisposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition") ?? ""
                if contentDisposition.lowercased().hasPrefix("attachment") {
                    logger.info("[decidePolicyFor response] Content-Disposition: attachment — converting to download")
                    decisionHandler(.download)
                    return
                }
            } else {
                logger.info("[decidePolicyFor response] url=\(url, privacy: .public) (not HTTP response)")
            }

            // If WebKit cannot display the MIME type, convert to download
            if !navigationResponse.canShowMIMEType {
                logger.info("[decidePolicyFor response] canShowMIMEType=false — converting to download")
                decisionHandler(.download)
                return
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            logger.info("[didStartProvisionalNavigation] url=\(webView.url?.absoluteString ?? "<nil>", privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                self?.browser.isLoading = true
                self?.browser.hasInteractedForms = false
                self?.browser.httpStatusCode = nil
            }
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            logger.info("[didReceiveServerRedirect] redirected to url=\(webView.url?.absoluteString ?? "<nil>", privacy: .public)")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            logger.info("[didCommit] url=\(webView.url?.absoluteString ?? "<nil>", privacy: .public)")
            // Reset the form interaction flag here as well as in
            // didStartProvisionalNavigation. By the time didCommit fires the
            // old document is fully replaced, so any stale formInteraction
            // messages queued by the previous page's scripts have already been
            // delivered. This eliminates a race where a late-arriving message
            // re-sets the flag after the provisional-navigation reset.
            DispatchQueue.main.async { [weak self] in
                self?.browser.hasInteractedForms = false
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            logger.info("[didFinish] url=\(webView.url?.absoluteString ?? "<nil>", privacy: .public) title=\(webView.title ?? "<nil>", privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.browser.isLoading = false
                if let title = webView.title, !title.isEmpty {
                    self.browser.pageTitle = title
                }
                if let url = webView.url {
                    self.browser.url = url

                    // Record the visit to history.
                    // Skip about:blank and deduplicate consecutive visits to the same path
                    // (query strings are stripped before storage).
                    let cleanURL = HistoryStore.stripQueryString(from: url).absoluteString
                    if cleanURL != "about:blank" && cleanURL != self.browser.lastRecordedURL {
                        self.browser.lastRecordedURL = cleanURL
                        let source = self.browser.navigationSource
                        self.browser.navigationSource = "navigation"  // reset after consuming
                        let pageTitle = webView.title
                        HistoryStore.shared.recordVisit(
                            url: url,
                            title: (pageTitle?.isEmpty ?? true) ? nil : pageTitle,
                            source: source
                        )
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            logger.error("[didFail] url=\(webView.url?.absoluteString ?? "<nil>", privacy: .public) error=\(error.localizedDescription, privacy: .public) (code=\((error as NSError).code), domain=\((error as NSError).domain, privacy: .public))")
            DispatchQueue.main.async { [weak self] in
                self?.browser.isLoading = false
                // Mark as failed by setting a non-2xx status code
                if self?.browser.httpStatusCode == nil {
                    self?.browser.httpStatusCode = 0
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            logger.error("[didFailProvisionalNavigation] url=\(webView.url?.absoluteString ?? "<nil>", privacy: .public) error=\(error.localizedDescription, privacy: .public) (code=\((error as NSError).code), domain=\((error as NSError).domain, privacy: .public))")
            if let underlyingError = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError {
                logger.error("[didFailProvisionalNavigation] underlying: \(underlyingError.localizedDescription, privacy: .public) (code=\(underlyingError.code), domain=\(underlyingError.domain, privacy: .public))")
            }
            DispatchQueue.main.async { [weak self] in
                self?.browser.isLoading = false
                // Mark as failed
                self?.browser.httpStatusCode = 0
            }
        }

        // MARK: - WKUIDelegate

        func webView(_ webView: WKWebView,
                      createWebViewWith configuration: WKWebViewConfiguration,
                      for navigationAction: WKNavigationAction,
                      windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Cmd+click opens the link in a new browser pane.
            if navigationAction.modifierFlags.contains(.command),
               let targetURL = navigationAction.request.url {
                logger.info("[createWebViewWith] Cmd+click — opening in new pane: \(targetURL.absoluteString, privacy: .public)")
                DispatchQueue.main.async { [weak self] in
                    guard let vm = self?.browser.viewModel else { return }
                    let newBrowser = vm.addBrowser(url: targetURL)
                    vm.focusPane(newBrowser)
                }
                return nil
            }

            // Open target=_blank links in the same view
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController,
                                    didReceive message: WKScriptMessage) {
            if message.name == "formInteraction" {
                DispatchQueue.main.async { [weak self] in
                    self?.browser.hasInteractedForms = true
                }
            }
        }

        // MARK: - Download initiation (WKNavigationDelegate)

        /// Called when `decidePolicyFor navigationAction` returns `.download`.
        func webView(_ webView: WKWebView,
                      navigationAction: WKNavigationAction,
                      didBecome download: WKDownload) {
            logger.info("[navigationAction didBecome download] url=\(download.originalRequest?.url?.absoluteString ?? "<nil>", privacy: .public)")
            download.delegate = self
        }

        /// Called when `decidePolicyFor navigationResponse` returns `.download`.
        func webView(_ webView: WKWebView,
                      navigationResponse: WKNavigationResponse,
                      didBecome download: WKDownload) {
            logger.info("[navigationResponse didBecome download] url=\(download.originalRequest?.url?.absoluteString ?? "<nil>", privacy: .public)")
            download.delegate = self
        }

        // MARK: - WKDownloadDelegate

        func download(_ download: WKDownload,
                      decideDestinationUsing response: URLResponse,
                      suggestedFilename: String,
                      completionHandler: @escaping (URL?) -> Void) {
            logger.info("[download decideDestination] suggestedFilename=\(suggestedFilename, privacy: .public)")

            DispatchQueue.main.async {
                let savePanel = NSSavePanel()
                savePanel.nameFieldStringValue = suggestedFilename
                savePanel.canCreateDirectories = true

                savePanel.begin { result in
                    if result == .OK, let url = savePanel.url {
                        logger.info("[download] User chose: \(url.path, privacy: .public)")
                        // WKDownload requires that the destination file does NOT
                        // already exist. NSSavePanel may prompt the user to
                        // replace an existing file; in that case, remove it first.
                        try? FileManager.default.removeItem(at: url)
                        completionHandler(url)
                    } else {
                        logger.info("[download] User cancelled save panel")
                        completionHandler(nil)
                    }
                }
            }
        }

        func downloadDidFinish(_ download: WKDownload) {
            logger.info("[download] Finished successfully: \(download.originalRequest?.url?.absoluteString ?? "<nil>", privacy: .public)")
        }

        func download(_ download: WKDownload,
                      didFailWithError error: Error,
                      resumeData: Data?) {
            logger.error("[download] Failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
