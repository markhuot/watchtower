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

    /// Open this engine's web inspector / developer tools UI.
    func openWebInspector()
}

// MARK: - App Shortcut Detection

/// Returns true if the given key event matches a Watchtower app-level
/// keyboard shortcut that should always be handled by the menu system
/// rather than consumed by a browser engine.
///
/// Both WatchtowerWebView and ChromiumBrowserView call this from
/// `performKeyEquivalent(with:)` to return `false` for matching events,
/// letting them propagate up the responder chain to the menu system.
func isWatchtowerAppShortcut(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }

    switch (flags, chars) {
    // Pane management
    case ([.command], "t"):                return true  // New Pane
    case ([.command, .shift], "t"):        return true  // New Terminal
    case ([.command, .shift], "b"):        return true  // New Browser

    // Command palette
    case ([.command, .shift], "p"):        return true  // Toggle Command Palette
    case ([.command], "l"):                return true  // Focus Command Palette

    // Pane navigation
    case ([.command, .shift], "["):        return true  // Focus Previous Pane
    case ([.command, .shift], "]"):        return true  // Focus Next Pane
    case ([.command, .option], "["):       return true  // Move Pane Left
    case ([.command, .option], "]"):       return true  // Move Pane Right

    // Focus mode
    case ([.command, .shift], "\r"):       return true  // Toggle Focus Mode

    // Pane sizing
    case ([.command, .shift], "-"):        return true  // Collapse Pane
    case ([.command, .shift], "+"),
         ([.command, .shift], "="):        return true  // Expand Pane

    // Browser navigation (handled by our menu items, not the engine)
    case ([.command], "["):                return true  // Go Back
    case ([.command], "]"):                return true  // Go Forward
    case ([.command], "r"):                return true  // Reload Page
    case ([.command, .option], "i"):       return true  // Open Web Inspector

    default: return false
    }
}
