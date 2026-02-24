import Foundation
import SwiftUI

class BrowserPaneModel: PaneModel {
    @Published var url: URL
    @Published var pageTitle: String = "New Tab"
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var estimatedProgress: Double = 0.0
    @Published var httpStatusCode: Int? = nil
    @Published var hasInteractedForms: Bool = false

    /// Incremented each time user code requests navigation (via `navigate(to:)`).
    /// The web view coordinator tracks the last generation it loaded so that
    /// KVO writeback (which updates `url` but NOT `navigationGeneration`) does
    /// not trigger redundant loads in `updateNSView`.
    @Published var navigationGeneration: UInt = 0

    override var title: String { pageTitle }
    override var subtitle: String? { url.host }
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

    init(url: URL = URL(string: "about:blank")!, paneWidth: CGFloat = PaneModel.defaultPaneWidth) {
        self.url = url
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
}
