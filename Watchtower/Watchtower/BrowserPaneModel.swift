import Foundation
import SwiftUI
import WebKit

class BrowserPaneModel: PaneModel {
    @Published var url: URL
    @Published var pageTitle: String = "New Tab"
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var estimatedProgress: Double = 0.0
    @Published var httpStatusCode: Int? = nil
    @Published var hasInteractedForms: Bool = false

    /// The rendering engine used by this browser pane.
    @Published var engine: BrowserEngine

    /// Weak reference to the underlying engine NSView (WatchtowerWebView or
    /// ChromiumBrowserView), set by the NSViewRepresentable's makeNSView.
    /// Used by the header back/forward buttons to trigger navigation directly.
    weak var engineView: (any BrowserEngineView)?

    /// How the current navigation was initiated. Set before navigating,
    /// consumed and reset to "navigation" after the visit is recorded.
    /// Values: "navigation" (default), "palette", "address".
    var navigationSource: String = "navigation"

    /// The last URL that was recorded to history for this pane.
    /// Used to deduplicate consecutive visits to the same URL.
    var lastRecordedURL: String?

    /// Incremented each time user code requests navigation (via `navigate(to:)`).
    /// The web view coordinator tracks the last generation it loaded so that
    /// KVO writeback (which updates `url` but NOT `navigationGeneration`) does
    /// not trigger redundant loads in `updateNSView`.
    @Published var navigationGeneration: UInt = 0

    /// True once the CEF close sequence has been initiated for this browser.
    /// Prevents double-close and tells `removePane` that the close is already
    /// in flight (the pane will be removed when `on_before_close` fires).
    var isClosingCEF: Bool = false

    override var title: String { pageTitle }
    override var subtitle: String? {
        guard let host = url.host else { return nil }
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }
    override var directory: String? { nil }

    override var status: PaneStatus {
        if isLoading { return .active }
        if let code = httpStatusCode, !(200..<300).contains(code) { return .failed }
        return .idle
    }

    override var progress: PaneProgress? {
        isLoading ? PaneProgress(state: .normal, value: estimatedProgress) : nil
    }

    /// Browsers use 80% of the window width in focus mode instead of
    /// the terminal column-based width, since they benefit from wider layout.
    override func focusModeMinWidth(windowWidth: CGFloat) -> CGFloat {
        return windowWidth * 0.8
    }

    init(url: URL = URL(string: "about:blank")!, paneWidth: CGFloat = PaneModel.defaultPaneWidth, engine: BrowserEngine = WatchtowerConfig.shared.browserEngine) {
        self.url = url
        self.engine = engine
        super.init(id: UUID(), paneWidth: paneWidth)
        // If the initial URL is not about:blank, mark generation 1 so
        // makeNSView's initial load is recognized.
        if url.absoluteString != "about:blank" {
            navigationGeneration = 1
        }
    }

    /// Request navigation to a new URL. This increments `navigationGeneration`
    /// so the web view knows to load it, even if the URL is the same as the
    /// current one (e.g. explicit refresh).
    func navigate(to newURL: URL) {
        url = newURL
        navigationGeneration += 1
    }

    /// Navigate back in the web view's history.
    func goBack() {
        engineView?.goBack()
    }

    /// Navigate forward in the web view's history.
    func goForward() {
        engineView?.goForward()
    }

    /// Reload the current page, or stop loading if a load is in progress.
    func reloadOrStop() {
        if isLoading {
            engineView?.stopLoading()
        } else {
            engineView?.reload()
        }
    }

    /// Switch this pane to a different rendering engine. Clears the current
    /// engine view reference so the SwiftUI view layer re-creates it with
    /// the new engine.
    func switchEngine(to newEngine: BrowserEngine) {
        guard newEngine != engine else { return }
        engineView = nil
        engine = newEngine
    }
}
