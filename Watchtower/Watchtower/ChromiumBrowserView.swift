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

    // MARK: - First Responder (minimal)

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            browser?.isFocused = true
            if let host = cefBrowser?.pointee.get_host?(cefBrowser!) {
                host.pointee.set_focus?(host, 1)
                _ = host.pointee.base.release?(&host.pointee.base)
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

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags == [.command, .shift],
           let chars = event.charactersIgnoringModifiers,
           chars == "[" || chars == "]" {
            return false
        }

        if flags == [.command],
           let chars = event.charactersIgnoringModifiers,
           chars == "l" {
            return false
        }

        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Close

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

    func closeCEFBrowser() {
        guard let browser = cefBrowser else { return }
        guard let host = browser.pointee.get_host?(browser) else { return }
        host.pointee.close_browser?(host, 1)
        _ = host.pointee.base.release?(&host.pointee.base)
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
