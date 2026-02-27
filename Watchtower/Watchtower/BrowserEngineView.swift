import AppKit

/// Protocol that both WebKit and Chromium browser NSViews conform to.
/// Provides a uniform interface for navigation, JavaScript execution,
/// and model binding so BrowserPaneModel and the view routing layer
/// don't need to know which engine is active.
protocol BrowserEngineView: NSView {
    /// The browser pane model this view is bound to.
    var browser: BrowserPaneModel? { get set }

    /// Load the given URL request.
    func loadRequest(_ request: URLRequest)

    /// Navigate back in history.
    func goBack()

    /// Navigate forward in history.
    func goForward()

    /// Reload the current page.
    func reload()

    /// Stop loading the current page.
    func stopLoading()

    /// Execute JavaScript in the main frame and return the result.
    func evaluateJavaScript(_ script: String) async throws -> Any?
}
