import SwiftUI
import os

private let shortcutLogger = Logger(subsystem: "com.watchtower", category: "ShortcutRouting")

struct WatchtowerApp: App {
    // Initialize Ghostty at app launch
    @StateObject private var ghosttyManager = GhosttyAppManager.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @FocusedValue(\.paneViewModel) var activeViewModel

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ghosttyManager)
        }
        .defaultSize(width: 1960, height: 1000)
        .commands {
            // Override the default Quit command so we can set
            // WatchtowerRequestQuit() before calling terminate:.
            // This is necessary because CefApplication.m swizzles terminate:
            // to block CEF-initiated quits — we must signal that this quit
            // is user-initiated.
            CommandGroup(replacing: .appTermination) {
                Button("Quit Watchtower") {
                    WatchtowerRequestQuit()
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }

            CommandGroup(after: .newItem) {
                // Context-aware: duplicates the type of the currently focused pane
                Button("New Pane") {
                    activeViewModel?.addContextualPane()
                }
                .keyboardShortcut("t", modifiers: [.command])

                Button("New Terminal") {
                    if let vm = activeViewModel {
                        let terminal = vm.addTerminal()
                        vm.focusPane(terminal)
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("New Browser") {
                    if let vm = activeViewModel {
                        vm.openNewBrowser()
                    }
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }

            CommandGroup(after: .toolbar) {
                Button("Command Palette") {
                    activeViewModel?.toggleCommandPalette()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                // Alternative shortcut: Cmd+L (matches browser "focus URL bar")
                Button("Focus Command Palette") {
                    activeViewModel?.focusCommandPalette()
                }
                .keyboardShortcut("l", modifiers: [.command])

                Divider()

                Button("Focus Previous Pane") {
                    activeViewModel?.focusPreviousPane()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Button("Focus Next Pane") {
                    activeViewModel?.focusNextPane()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Divider()

                Button("Move Pane Left") {
                    activeViewModel?.movePaneLeft()
                }
                .keyboardShortcut("[", modifiers: [.command, .option])

                Button("Move Pane Right") {
                    activeViewModel?.movePaneRight()
                }
                .keyboardShortcut("]", modifiers: [.command, .option])

                Divider()

                Button(activeViewModel?.isFocusMode == true ? "Exit Focus Mode" : "Enter Focus Mode") {
                    activeViewModel?.toggleFocusMode()
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])

                Button("Fit Panes to Window") {
                    activeViewModel?.fitPanesToWindow()
                }

                Button("Center Pane") {
                    activeViewModel?.centerPane()
                }

                Button("Collapse Pane") {
                    activeViewModel?.collapsePane()
                }
                .keyboardShortcut("-", modifiers: [.command, .shift])

                Button("Expand Pane") {
                    activeViewModel?.expandPane()
                }
                .keyboardShortcut("+", modifiers: [.command, .shift])

                Divider()

                // Browser navigation commands — disabled when focused pane is not a browser
                let isBrowserFocused = activeViewModel?.contextualPane is BrowserPaneModel

                Button("Go Back") {
                    if let browser = activeViewModel?.contextualPane as? BrowserPaneModel {
                        browser.goBack()
                    }
                }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(!isBrowserFocused)

                Button("Go Forward") {
                    if let browser = activeViewModel?.contextualPane as? BrowserPaneModel {
                        browser.goForward()
                    }
                }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(!isBrowserFocused)

                Button("Reload Page") {
                    if let browser = activeViewModel?.contextualPane as? BrowserPaneModel {
                        browser.reloadOrStop()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!isBrowserFocused)

                Button("Open Web Inspector") {
                    activeViewModel?.openWebInspector()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(!isBrowserFocused)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

import WebKit

/// Walk the view hierarchy to find a BrowserEngineView associated with a pane ID.
/// Checks for both WatchtowerWebView (WebKit) and ChromiumBrowserView (Chromium).
func findBrowserEngineView(for paneId: UUID, in view: NSView) -> (any BrowserEngineView)? {
    if let webView = view as? WatchtowerWebView,
       webView.browser?.id == paneId {
        return webView
    }
    if let chromiumView = view as? ChromiumBrowserView,
       chromiumView.browser?.id == paneId {
        return chromiumView
    }
    for subview in view.subviews {
        if let found = findBrowserEngineView(for: paneId, in: subview) {
            return found
        }
    }
    return nil
}

/// Find the currently focused browser model by walking a view hierarchy.
func findFocusedBrowserModel(in view: NSView) -> BrowserPaneModel? {
    if let webView = view as? WatchtowerWebView,
       let browser = webView.browser,
       browser.isFocused {
        return browser
    }
    if let chromiumView = view as? ChromiumBrowserView,
       let browser = chromiumView.browser,
       browser.isFocused {
        return browser
    }
    for subview in view.subviews {
        if let found = findFocusedBrowserModel(in: subview) {
            return found
        }
    }
    return nil
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var browserShortcutMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Apply dark appearance before first window presentation to avoid
        // transient light titlebar/chrome during launch.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)

        // Configure any windows that already exist this early in launch.
        for window in NSApp.windows {
            configureWindow(window)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize the history store early so pruning runs at startup.
        _ = HistoryStore.shared

        // Start the IPC server for CLI communication.
        IPCServer.shared.start()

        // Observe terminate: calls that weren't explicitly flagged by our
        // Cmd-Q / menu handler.  This covers the Dock "Quit" menu item,
        // which calls [NSApp terminate:nil] directly.  CefApplication.m
        // posts this notification instead of calling through when the flag
        // is not set.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTerminateAttempted(_:)),
            name: Notification.Name("WatchtowerTerminateAttempted"),
            object: nil
        )

        // Configure all existing windows immediately and set ourselves as delegate
        for window in NSApp.windows {
            configureWindow(window)
        }

        // Observe future window activation.
        // Re-apply window configuration when a window becomes key so late-created
        // SwiftUI windows are configured as soon as they appear.
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willEnterFullScreenNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowNeedsConfiguration(_:)),
                name: name,
                object: nil
            )
        }

        // Ensure app-level shortcuts (e.g. Cmd+R) are handled by the menu
        // system even when first responder is an internal browser subview
        // (WKContentView / CEF child views) that bypasses wrapper overrides.
        browserShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isWatchtowerAppShortcut(event) else { return event }

            let window = event.window ?? NSApp.keyWindow
            let browser = self.browserModelFromFirstResponder(window: window)
                ?? self.focusedBrowserModelInAppWindows()

            shortcutLogger.debug(
                "Shortcut event chars=\(event.charactersIgnoringModifiers ?? "?", privacy: .public) flags=\(event.modifierFlags.rawValue) keyWindow=\(self.describeWindow(NSApp.keyWindow), privacy: .public) eventWindow=\(self.describeWindow(window), privacy: .public) firstResponder=\(self.describeResponder(window?.firstResponder), privacy: .public) browserResolved=\(browser != nil)"
            )
            if let browser {
                shortcutLogger.debug(
                    "Resolved browser id=\(browser.id.uuidString, privacy: .public) engine=\(browser.engine.displayName, privacy: .public) isFocused=\(browser.isFocused)"
                )
            }

            // Make Cmd+R deterministic for browser panes even when SwiftUI
            // focusedSceneValue state is temporarily stale.
            if self.isBrowserReloadShortcut(event),
               let browser = browser {
                shortcutLogger.debug("Handling browser reload shortcut")
                browser.reloadOrStop()
                return nil
            }

                if self.isBrowserBackShortcut(event),
                    let browser = browser {
                     shortcutLogger.debug("Handling browser back shortcut")
                     browser.goBack()
                     return nil
                }

                if self.isBrowserForwardShortcut(event),
                    let browser = browser {
                     shortcutLogger.debug("Handling browser forward shortcut")
                     browser.goForward()
                     return nil
                }

            if self.isBrowserInspectorShortcut(event),
               let browser = browser {
                shortcutLogger.debug("Handling browser inspector shortcut")
                browser.openWebInspector()
                return nil
            }

            let menuHandled = NSApp.mainMenu?.performKeyEquivalent(with: event) == true
            shortcutLogger.debug("Main menu performKeyEquivalent handled=\(menuHandled)")
            if menuHandled {
                return nil
            }
            return event
        }
    }

    private func focusedBrowserModelInAppWindows() -> BrowserPaneModel? {
        for window in NSApp.windows {
            guard let contentView = window.contentView else { continue }
            if let browser = findFocusedBrowserModel(in: contentView) {
                shortcutLogger.debug(
                    "Focused browser found in app windows id=\(browser.id.uuidString, privacy: .public) window=\(self.describeWindow(window), privacy: .public)"
                )
                return browser
            }
        }
        shortcutLogger.debug("No focused browser found in app windows")
        return nil
    }

    private func browserModelFromFirstResponder(window: NSWindow?) -> BrowserPaneModel? {
        guard let responder = window?.firstResponder as? NSView else { return nil }

        var current: NSView? = responder
        while let view = current {
            if let webView = view as? WatchtowerWebView {
                shortcutLogger.debug("Resolved browser from first responder via WebKit")
                return webView.browser
            }
            if let chromiumView = view as? ChromiumBrowserView {
                shortcutLogger.debug("Resolved browser from first responder via Chromium")
                return chromiumView.browser
            }
            current = view.superview
        }

        return nil
    }

    private func describeWindow(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        let className = String(describing: type(of: window))
        let title = window.title.isEmpty ? "<untitled>" : window.title
        return "\(className){title=\(title)}"
    }

    private func describeResponder(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        return String(describing: type(of: responder))
    }

    private func isBrowserReloadShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock])

        guard flags == [.command] else { return false }
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return chars == "r"
    }

    private func isBrowserBackShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock])

        guard flags == [.command] else { return false }
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return chars == "["
    }

    private func isBrowserForwardShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock])

        guard flags == [.command] else { return false }
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return chars == "]"
    }

    private func isBrowserInspectorShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock])

        guard flags == [.command, .option] else { return false }
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return chars == "i"
    }

    @objc func windowNeedsConfiguration(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            configureWindow(window)
        }
    }

    private func configureWindow(_ window: NSWindow) {
        window.title = "Watchtower"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = false
        window.isOpaque = true
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .none
        }
        window.toolbar?.showsBaselineSeparator = false
        // Match the window background to the Ghostty terminal background.
        // Keep a native, opaque titlebar so there is no initial white flash.
        let bgColor = GhosttyAppManager.shared.backgroundColor
        let nsColor = NSColor(bgColor)
        window.backgroundColor = nsColor

        // In native full screen macOS may move titlebar chrome into
        // a separate private window. Apply the same color there too.
        styleTitlebarContainer(for: window, color: nsColor)

        // AppKit can lazily create titlebar subviews after initial window
        // configuration; apply once more on the next run loop so the color
        // stays exact and separators/materials remain hidden.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            self.styleTitlebarContainer(for: window, color: nsColor)
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }
            window.toolbar?.showsBaselineSeparator = false
        }
    }

    /// Finds the titlebar container for the given window (normal or fullscreen)
    /// and applies the background color to its layer.
    private func styleTitlebarContainer(for window: NSWindow, color: NSColor) {
        if let container = titlebarContainer(for: window) {
            container.wantsLayer = true
            container.layer?.backgroundColor = color.cgColor

            if let bgView = container.firstDescendant(withClassName: "NSTitlebarBackgroundView") {
                bgView.isHidden = true
            }

            if let effectView = container.firstDescendant(withClassName: "NSVisualEffectView") {
                effectView.isHidden = true
            }
        }
    }

    /// In normal mode, the titlebar container is in the window's own hierarchy.
    /// In native fullscreen, macOS moves it into a private child window.
    private func titlebarContainer(for window: NSWindow) -> NSView? {
        if !window.styleMask.contains(.fullScreen) {
            return window.contentView?
                .firstViewFromRoot(withClassName: "NSTitlebarContainerView")
        }

        for candidate in NSApplication.shared.windows {
            guard type(of: candidate).description() == "NSToolbarFullScreenWindow" else { continue }
            guard candidate.parent == window else { continue }
            return candidate.contentView?
                .firstViewFromRoot(withClassName: "NSTitlebarContainerView")
        }

        return nil
    }

    // MARK: - Dock Menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let newWindowItem = NSMenuItem(
            title: "New Window",
            action: #selector(newWindowFromDock(_:)),
            keyEquivalent: ""
        )
        newWindowItem.target = self
        menu.addItem(newWindowItem)
        return menu
    }

    @objc func newWindowFromDock(_ sender: Any?) {
        // Triggers SwiftUI's WindowGroup to open a new window,
        // equivalent to File > New Window (Cmd+N).
        NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil)
    }

    // MARK: - App Quit Confirmation

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = browserShortcutMonitor {
            NSEvent.removeMonitor(monitor)
            browserShortcutMonitor = nil
        }
        IPCServer.shared.stop()
        // Cleanly shut down CEF (invalidate pump timer, call cef_shutdown).
        ChromiumManager.shared.shutdown()
    }

    /// Called via notification when CefApplication.m's swizzled terminate:
    /// receives a call without the WatchtowerRequestQuit flag.  This covers
    /// Dock "Quit" and any other system-initiated terminate: that bypasses
    /// our SwiftUI Cmd-Q handler.  We set the flag and re-call terminate:
    /// so the swizzled method lets it through.
    @objc func handleTerminateAttempted(_ notification: Notification) {
        WatchtowerRequestQuit()
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasActive = NSApp.windows.contains { windowHasActiveSessions($0) }
        guard hasActive else { return .terminateNow }

        // Show the alert on the key window (or first window with active sessions)
        let targetWindow = NSApp.keyWindow ?? NSApp.windows.first { windowHasActiveSessions($0) }
        guard let window = targetWindow else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Quit Watchtower?"
        alert.informativeText = "There are still active terminal sessions. Quitting will terminate all sessions."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                NSApp.reply(toApplicationShouldTerminate: true)
            } else {
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }

        return .terminateLater
    }

    // MARK: - Helpers

    /// Check if a window contains any Ghostty surfaces with running processes.
    private func windowHasActiveSessions(_ window: NSWindow) -> Bool {
        guard let contentView = window.contentView else { return false }
        let terminalViews = GhosttyTerminalNSView.findAllTerminalViews(in: contentView)
        return terminalViews.contains { view in
            guard let surface = view.surface else { return false }
            return ghostty_surface_needs_confirm_quit(surface)
        }
    }
}

// MARK: - FocusedValues

/// Key for routing menu commands to the active window's PaneContainerViewModel.
struct FocusedPaneViewModelKey: FocusedValueKey {
    typealias Value = PaneContainerViewModel
}

extension FocusedValues {
    var paneViewModel: PaneContainerViewModel? {
        get { self[FocusedPaneViewModelKey.self] }
        set { self[FocusedPaneViewModelKey.self] = newValue }
    }
}
