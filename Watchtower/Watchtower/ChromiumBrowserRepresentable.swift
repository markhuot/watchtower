import SwiftUI
import os

private let logger = Logger(subsystem: "com.watchtower", category: "ChromiumBrowserRepresentable")

/// Minimal NSViewRepresentable wrapper for ChromiumBrowserView.
/// Creates a CEF browser with the URL directly — no deferred loading.
struct ChromiumBrowserRepresentable: NSViewRepresentable {
    @ObservedObject var browser: BrowserPaneModel
    @ObservedObject private var appManager = GhosttyAppManager.shared

    func makeCoordinator() -> Coordinator {
        Coordinator(browser: browser)
    }

    func makeNSView(context: Context) -> ChromiumBrowserView {
        ChromiumManager.shared.ensureInitialized()
        let view = ChromiumBrowserView(frame: .zero)
        view.browser = browser
        browser.engineView = view
        context.coordinator.view = view

        let clientContext = CEFClientContext(browserModel: browser, browserView: view)
        context.coordinator.clientContext = clientContext
        let client = cefMakeClient(context: clientContext)

        // Also store the URL as pending in case on_after_created fires before
        // CEF actually loads it (belt and suspenders)
        view.pendingURL = browser.url.absoluteString

        // Create the browser with the actual URL directly
        DispatchQueue.main.async {
            context.coordinator.loadedGeneration = self.browser.navigationGeneration
            let url = self.browser.url.absoluteString
            NSLog("[CEF] makeNSView: Creating CEF browser with URL: %@", url)
            self.createCEFBrowser(in: view, client: client, url: url)
        }

        return view
    }

    func updateNSView(_ view: ChromiumBrowserView, context: Context) {
        // Sync appearance (dark/light theme) for CSS prefers-color-scheme.
        let isDark = appManager.isDarkTheme
        if context.coordinator.lastSyncedIsDark != isDark {
            context.coordinator.lastSyncedIsDark = isDark
            view.syncAppearance(isDark: isDark)
        }

        guard browser.navigationGeneration > context.coordinator.loadedGeneration else { return }
        context.coordinator.loadedGeneration = browser.navigationGeneration
        view.loadRequest(URLRequest(url: browser.url))
    }

    static func dismantleNSView(_ nsView: ChromiumBrowserView, coordinator: Coordinator) {
        let backtrace = Thread.callStackSymbols.joined(separator: "\n")
        let paneId = nsView.browser?.id.uuidString ?? "nil"
        let isClosingCEF = nsView.browser?.isClosingCEF ?? false
        let hasCefBrowser = nsView.cefBrowser != nil
        NSLog("[CEF] dismantleNSView: paneId=%@, isClosingCEF=%d, hasCefBrowser=%d\n  backtrace:\n%@",
              paneId, isClosingCEF ? 1 : 0, hasCefBrowser ? 1 : 0, backtrace)

        if nsView.cefBrowser != nil {
            if isClosingCEF {
                // do_close already called close_browser(force=1) and dispatched
                // finishRemovingCEFPane. We're now inside the resulting SwiftUI
                // teardown. CEF will fire on_before_close once it detects the
                // view removal. Nothing to do here.
                NSLog("[CEF] dismantleNSView: isClosingCEF=true, skipping force-close (already in progress)")
            } else {
                // Unexpected teardown (e.g. window closed externally). Force-close
                // so CEF can clean up.
                NSLog("[CEF] dismantleNSView: unexpected teardown, calling close_browser(force=1)")
                nsView.closeCEFBrowserForce()
            }
        } else {
            NSLog("[CEF] dismantleNSView: no cefBrowser, nothing to do")
        }
        // Do NOT call cefCleanupClientContext here — CEF's close sequence is
        // asynchronous. The handlers must remain registered until CEF fires
        // on_before_close, which now handles the cleanup. Cleaning up eagerly
        // here caused EXC_BREAKPOINT on CrBrowserMain.
        NSLog("[CEF] dismantleNSView: setting coordinator.view = nil, clientContext.browserView is %@",
              String(describing: coordinator.clientContext?.browserView))
        coordinator.view = nil
        NSLog("[CEF] dismantleNSView: after niling, clientContext.browserView is %@",
              String(describing: coordinator.clientContext?.browserView))
    }

    // MARK: - CEF Browser Creation

    private func createCEFBrowser(in view: ChromiumBrowserView, client: UnsafeMutablePointer<cef_client_t>, url: String) {
        var windowInfo = cef_window_info_t()
        windowInfo.size = MemoryLayout<cef_window_info_t>.size
        windowInfo.parent_view = Unmanaged.passUnretained(view).toOpaque()

        let frame = view.bounds
        let scale = view.window?.backingScaleFactor ?? 2.0
        let boundsWidth = max(Int32(frame.size.width * scale), 1)
        let boundsHeight = max(Int32(frame.size.height * scale), 1)
        windowInfo.bounds = cef_rect_t(
            x: Int32(frame.origin.x),
            y: Int32(frame.origin.y),
            width: boundsWidth,
            height: boundsHeight
        )
        NSLog("[CEF] createCEFBrowser: bounds=%dx%d, url=%@", boundsWidth, boundsHeight, url)

        var browserSettings = cef_browser_settings_t()
        browserSettings.size = MemoryLayout<cef_browser_settings_t>.size

        var cefUrl = cef_string_t()
        cefStringSet(url, cefStr: &cefUrl)

        client.pointee.base.add_ref?(&client.pointee.base)

        NSLog("[CEF] Calling cef_browser_host_create_browser_sync")
        let browser = cef_browser_host_create_browser_sync(
            &windowInfo,
            client,
            &cefUrl,
            &browserSettings,
            nil,
            nil
        )

        if let browser = browser {
            NSLog("[CEF] cef_browser_host_create_browser_sync returned browser %@", String(describing: browser))
        } else {
            NSLog("[CEF] cef_browser_host_create_browser_sync returned nil!")
        }

        cef_string_utf16_clear(&cefUrl)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject {
        var browser: BrowserPaneModel
        weak var view: ChromiumBrowserView?
        var loadedGeneration: UInt = 0
        var clientContext: CEFClientContext?
        var lastSyncedIsDark: Bool?

        init(browser: BrowserPaneModel) {
            self.browser = browser
        }
    }
}
