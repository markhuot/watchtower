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
class WatchtowerWebView: WKWebView {
    weak var browser: BrowserPaneModel?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            browser?.isFocused = true
            scrollToVisibleInEnclosingScrollView()
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

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Let Cmd+Shift+[ and Cmd+Shift+] pass through to the menu system
        // for pane navigation instead of being consumed by WebKit.
        if flags == [.command, .shift],
           let chars = event.charactersIgnoringModifiers,
           chars == "[" || chars == "]" {
            return false
        }

        // Let Cmd+L pass through to the menu system for the command palette
        // instead of being consumed by WebKit's "focus address bar" handler.
        if flags == [.command],
           let chars = event.charactersIgnoringModifiers,
           chars == "l" {
            return false
        }

        return super.performKeyEquivalent(with: event)
    }

    /// Intercept the "Close" menu item (Cmd+W). When multiple panes exist,
    /// close just this browser pane via a notification. When this is the only
    /// pane, fall through to the default window close.
    @objc func performClose(_ sender: Any?) {
        guard let browser = browser else {
            window?.performClose(sender)
            return
        }

        // Count all panes (terminals + browsers) via the view model.
        let totalPanes = browser.viewModel?.panes.count ?? 0

        if totalPanes > 1 {
            // Multiple panes — close just this one.
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
        } else {
            // Single pane — let the window close normally.
            guard let window = self.window else { return }
            window.performClose(sender)
        }
    }
}

// MARK: - BrowserWebView

struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var browser: BrowserPaneModel

    func makeCoordinator() -> Coordinator {
        Coordinator(browser: browser)
    }

    func makeNSView(context: Context) -> WatchtowerWebView {
        let config = BrowserConfiguration.makeConfiguration()
        let webView = WatchtowerWebView(frame: .zero, configuration: config)
        webView.browser = browser
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView

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

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
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
                      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url?.absoluteString ?? "<nil>"
            let isTargetNil = navigationAction.targetFrame == nil
            logger.info("[decidePolicyFor action] url=\(url, privacy: .public) targetFrame=\(isTargetNil ? "nil" : "present", privacy: .public) navigationType=\(navigationAction.navigationType.rawValue)")
            // Allow all navigations. Target=_blank opens in same web view.
            if navigationAction.targetFrame == nil {
                // New window request — load in the same view
                if let url = navigationAction.request.url {
                    webView.load(URLRequest(url: url))
                }
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
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
            } else {
                logger.info("[decidePolicyFor response] url=\(url, privacy: .public) (not HTTP response)")
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
                    // Skip about:blank and deduplicate consecutive visits to the same URL.
                    let urlString = url.absoluteString
                    if urlString != "about:blank" && urlString != self.browser.lastRecordedURL {
                        self.browser.lastRecordedURL = urlString
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
    }
}
