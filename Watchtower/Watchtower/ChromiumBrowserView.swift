import AppKit
import os

private let logger = Logger(subsystem: "com.watchtower", category: "ChromiumBrowserView")

/// Minimal NSView subclass for the Chromium/CEF browser engine.
/// Stripped to bare minimum: load a URL, that's it.
class ChromiumBrowserView: NSView, BrowserEngineView {
    weak var browser: BrowserPaneModel?
    var isInspectable: Bool = true

    /// The CEF browser object. Set in on_after_created.
    var cefBrowser: UnsafeMutablePointer<cef_browser_t>?

    deinit {
        NSLog("[CEF] ChromiumBrowserView.deinit: paneId=%@, hasCefBrowser=%d",
              browser?.id.uuidString ?? "nil", cefBrowser != nil ? 1 : 0)
    }

    // MARK: - BrowserEngineView

    func loadRequest(_ request: URLRequest) {
        guard let urlString = request.url?.absoluteString else { return }
        NSLog("[CEF] ChromiumBrowserView.loadRequest: %@", urlString)
        guard let browser = cefBrowser else {
            NSLog("[CEF] loadRequest deferred (no cefBrowser yet)")
            pendingURL = urlString
            return
        }

        guard let frame = browser.pointee.get_main_frame?(browser) else {
            NSLog("[CEF] loadRequest: could not get main frame")
            return
        }

        withCEFString(urlString) { cefUrl in
            frame.pointee.load_url?(frame, &cefUrl)
        }

        _ = frame.pointee.base.release?(&frame.pointee.base)
    }

    func goBack() {
        cefBrowser?.pointee.go_back?(cefBrowser!)
    }

    func goForward() {
        cefBrowser?.pointee.go_forward?(cefBrowser!)
    }

    func reload() {
        cefBrowser?.pointee.reload?(cefBrowser!)
    }

    func stopLoading() {
        cefBrowser?.pointee.stop_load?(cefBrowser!)
    }

    func evaluateJavaScript(_ script: String) async throws -> Any? {
        // Not needed for minimal test
        return nil
    }

    // MARK: - Pending URL

    var pendingURL: String?

    func loadPendingURLIfNeeded() {
        NSLog("[CEF] loadPendingURLIfNeeded: pendingURL=%@, cefBrowser=%@",
              String(describing: pendingURL), String(describing: cefBrowser))

        // Sync appearance now that the browser is ready
        let isDark = GhosttyAppManager.shared.isDarkTheme
        syncAppearance(isDark: isDark)

        guard let url = pendingURL else { return }
        pendingURL = nil
        loadRequest(URLRequest(url: URL(string: url)!))
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let host = cefBrowser?.pointee.get_host?(cefBrowser!) {
            host.pointee.was_resized?(host)
            _ = host.pointee.base.release?(&host.pointee.base)
        }
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    /// Tracks whether we intentionally gave CEF focus. Used by the CEF
    /// focus handler callbacks to distinguish intentional focus from CEF
    /// trying to reclaim focus on its own.
    var cefHasFocus: Bool = false

    /// KVO observation of window.firstResponder. When first responder moves
    /// outside our view hierarchy we blur CEF; this single observer replaces
    /// procedural blurCEF() calls at every site that might take focus.
    private var firstResponderObservation: NSKeyValueObservation?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()

        if result {
            cefHasFocus = true
            browser?.isFocused = true

            // Notify the view model so focusModePaneId is updated (which
            // drives the focus-mode width expansion). Without this, direct
            // clicks on the Chromium view bypass focusPane() entirely and the
            // pane never expands / receives focus state.
            if let browser = browser, let vm = browser.viewModel {
                if vm.focusModePaneId != browser.id || vm.contextualPane?.id != browser.id {
                    vm.focusPane(id: browser.id)
                }
            }

            if let host = cefBrowser?.pointee.get_host?(cefBrowser!) {
                host.pointee.set_focus?(host, 1)
                _ = host.pointee.base.release?(&host.pointee.base)
            }
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Tear down old observation when moving between windows
        firstResponderObservation?.invalidate()
        firstResponderObservation = nil

        guard let window = self.window else { return }

        // Observe window.firstResponder. When it moves outside our
        // subtree, tell CEF to release focus. This is reactive — it
        // covers command palette, other panes, accessibility controls,
        // or anything else that becomes first responder.
        firstResponderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            guard let self = self else { return }
            let responder = window.firstResponder
            let isOurs = (responder as? NSView)?.isDescendant(of: self) == true
                || responder === self

            if isOurs && !self.cefHasFocus {
                // CEF child view took focus (e.g. after set_focus(1))
                self.cefHasFocus = true
                self.browser?.isFocused = true
            } else if !isOurs && self.cefHasFocus {
                // Focus moved outside — blur CEF
                self.cefHasFocus = false
                self.browser?.isFocused = false
                if let host = self.cefBrowser?.pointee.get_host?(self.cefBrowser!) {
                    host.pointee.set_focus?(host, 0)
                    _ = host.pointee.base.release?(&host.pointee.base)
                }
            }
        }

        // Handle pending focus for newly-created panes
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

    // MARK: - Key Event Passthrough (keep for pane navigation)

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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        if let browser = browser, browser.isCollapsed { return false }

        // Let all Watchtower app shortcuts pass through to the menu system
        // instead of being consumed by CEF (e.g. Cmd+R for reload,
        // Cmd+Shift+P for command palette, Cmd+L, pane navigation, etc.).
        if isWatchtowerAppShortcut(event) { return false }

        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Close

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

    func closeCEFBrowser() {
        let backtrace = Thread.callStackSymbols.joined(separator: "\n")
        NSLog("[CEF] closeCEFBrowser: cefBrowser=%@, paneId=%@\n  backtrace:\n%@",
              String(describing: cefBrowser), browser?.id.uuidString ?? "nil", backtrace)
        guard let browser = cefBrowser else {
            NSLog("[CEF] closeCEFBrowser: no cefBrowser, returning early")
            return
        }
        guard let host = browser.pointee.get_host?(browser) else {
            NSLog("[CEF] closeCEFBrowser: could not get host, returning early")
            return
        }
        // Use force=0 for a graceful close. do_close will fire and return true,
        // meaning we take responsibility for the close. We will call
        // close_browser(force=1) from dismantleNSView once SwiftUI has torn
        // down the view hierarchy.
        NSLog("[CEF] closeCEFBrowser: calling close_browser(force=0)")
        host.pointee.close_browser?(host, 0)
        _ = host.pointee.base.release?(&host.pointee.base)
        NSLog("[CEF] closeCEFBrowser: close_browser returned")
    }

    /// Called from dismantleNSView after SwiftUI has removed the view from
    /// the hierarchy. With force=1 CEF will destroy the browser immediately
    /// and fire on_before_close.
    func closeCEFBrowserForce() {
        NSLog("[CEF] closeCEFBrowserForce: cefBrowser=%@, paneId=%@",
              String(describing: cefBrowser), browser?.id.uuidString ?? "nil")
        guard let cefBrowser = cefBrowser else {
            NSLog("[CEF] closeCEFBrowserForce: no cefBrowser, returning early")
            return
        }
        guard let host = cefBrowser.pointee.get_host?(cefBrowser) else {
            NSLog("[CEF] closeCEFBrowserForce: could not get host, returning early")
            return
        }
        NSLog("[CEF] closeCEFBrowserForce: calling close_browser(force=1)")
        host.pointee.close_browser?(host, 1)
        _ = host.pointee.base.release?(&host.pointee.base)
        NSLog("[CEF] closeCEFBrowserForce: close_browser(force=1) returned")
    }

    // MARK: - Appearance Syncing

    /// Syncs the macOS dark/light theme to CEF via the DevTools Protocol
    /// so that CSS `prefers-color-scheme` reflects the surrounding UI.
    /// Uses `Emulation.setEmulatedMedia` with features: [{name: "prefers-color-scheme", value: "dark"|"light"}].
    func syncAppearance(isDark: Bool) {
        guard let browser = cefBrowser else {
            NSLog("[CEF] syncAppearance: no cefBrowser yet, skipping")
            return
        }
        guard let host = browser.pointee.get_host?(browser) else {
            NSLog("[CEF] syncAppearance: could not get host")
            return
        }
        defer { _ = host.pointee.base.release?(&host.pointee.base) }

        // Use send_dev_tools_message with raw JSON — simpler than building
        // nested cef_dictionary_value_t / cef_list_value_t objects.
        let value = isDark ? "dark" : "light"
        let json = """
        {"id":1,"method":"Emulation.setEmulatedMedia","params":{"features":[{"name":"prefers-color-scheme","value":"\(value)"}]}}
        """

        let jsonData = Array(json.utf8)
        let result = jsonData.withUnsafeBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            return host.pointee.send_dev_tools_message?(host, base, jsonData.count) ?? 0
        }
        NSLog("[CEF] syncAppearance: send_dev_tools_message returned \(result) (isDark=\(isDark))")
    }
}
