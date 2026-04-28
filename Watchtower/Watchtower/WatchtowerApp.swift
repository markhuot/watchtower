import SwiftUI
import os
import AppKit
import WebKit

private let shortcutLogger = Logger(subsystem: "com.watchtower", category: "ShortcutRouting")

struct WatchtowerApp: App {
    // Initialize Ghostty at app launch
    @StateObject private var ghosttyManager = GhosttyAppManager.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @FocusedValue(\.paneViewModel) var activeViewModel

    var body: some Scene {
        WindowGroup(for: URL.self) { $projectURL in
            let directory = projectURL?.path ?? NSHomeDirectory()
            ContentView(projectDirectory: directory)
                .environmentObject(ghosttyManager)
                .frame(minWidth: 900, minHeight: 600)
                .background(WindowRestorer(currentDirectory: directory))
                .background(WindowFrameAutosave(directory: directory))
        }
        .defaultSize(width: 1960, height: 1000)
        .commands {
            FileOpenCommand()
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

                Button("Close Pane") {
                    if let viewModel = activeViewModel,
                       viewModel.contextualPane != nil {
                        viewModel.closeCurrentPane()
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command])

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

            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    NSApp.sendAction(
                        #selector(NSSplitViewController.toggleSidebar(_:)),
                        to: nil,
                        from: nil
                    )
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
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
                let canFindInFocusedPane = {
                    guard let pane = activeViewModel?.contextualPane else { return false }
                    return pane is BrowserPaneModel || pane is TerminalPaneModel
                }()

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

                Button("Open WebKit Inspector Repro Window") {
                    let targetURL = (activeViewModel?.contextualPane as? BrowserPaneModel)?.url
                        ?? URL(string: "https://news.ycombinator.com/")!
                    WebKitInspectorReproManager.shared.open(url: targetURL)
                }

                Divider()

                Button("Find on Page") {
                    activeViewModel?.openFindInContext()
                }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(!canFindInFocusedPane)

                Button("Find Next") {
                    activeViewModel?.findNextInContext()
                }
                .keyboardShortcut("g", modifiers: [.command])
                .disabled(!canFindInFocusedPane)

                Button("Find Previous") {
                    activeViewModel?.findPreviousInContext()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!canFindInFocusedPane)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

/// Empty SwiftUI view, attached to every ContentView's background, that
/// fires once on the first window's appearance to reopen any other
/// persisted project windows via SwiftUI's `openWindow` action.
///
/// SwiftUI auto-opens a single "untitled" window at launch with a nil
/// URL value. If persisted state exists and that auto-opened window's
/// directory is not part of it, the restorer dismisses the auto-opened
/// window after queuing the persisted ones - so the user lands on
/// exactly the windows they had at quit, not those plus an extra blank.
private struct WindowRestorer: View {
    let currentDirectory: String
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onAppear { performRestoreOnce() }
    }

    private static var didRestore = false

    @MainActor
    private func performRestoreOnce() {
        guard !Self.didRestore else { return }
        Self.didRestore = true

        let directories = WindowStateStore.shared.persistedWindowDirectories
        guard !directories.isEmpty else { return }

        // Open one window per persisted directory, skipping any that
        // matches the current (auto-opened) window's directory - that
        // window's PaneContainerViewModel has already restored its
        // panes from the store, so opening another for the same URL
        // would produce two windows showing identical state.
        for dir in directories where dir != currentDirectory {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            openWindow(value: url.standardizedFileURL)
        }

        // If the auto-opened window's directory wasn't restored from disk
        // (i.e. it's the empty default), dismiss it on the next runloop
        // tick. Deferring guarantees the openWindow calls have been
        // realized before this window goes away, so the app doesn't see
        // a moment of "no windows open" and quit.
        if !directories.contains(currentDirectory) {
            DispatchQueue.main.async {
                dismissWindow()
            }
        }
    }
}

/// Persists window frame (origin + size) per project directory.
///
/// We can't use `setFrameAutosaveName` because SwiftUI's WindowGroup
/// installs its own autosave name keyed off the view hierarchy and our
/// override is silently ignored. Instead, we listen for windowDidMove
/// and windowDidResize on the hosting NSWindow, push the frame into
/// `WindowStateStore`, and apply the stored frame back when the
/// window first appears.
private struct WindowFrameAutosave: NSViewRepresentable {
    let directory: String

    func makeCoordinator() -> Coordinator { Coordinator(directory: directory) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            context.coordinator.attach(to: window)
        }
    }

    final class Coordinator {
        let directory: String
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var didRestore = false

        init(directory: String) {
            self.directory = directory
        }

        deinit {
            for token in observers {
                NotificationCenter.default.removeObserver(token)
            }
        }

        func attach(to window: NSWindow) {
            // The view's hosting window may swap as SwiftUI re-parents
            // (rare, but cheap to defend against).
            if self.window === window { return }
            for token in observers {
                NotificationCenter.default.removeObserver(token)
            }
            observers.removeAll()
            self.window = window

            // Apply the saved frame the first time we see this window.
            // We re-apply on a later runloop tick because SwiftUI's
            // WindowGroup may set its own default frame after we apply
            // ours; by deferring once we win the last write.
            if !didRestore, let savedFrame = WindowStateStore.shared.frame(for: directory) {
                didRestore = true
                window.setFrame(savedFrame, display: true, animate: false)
                DispatchQueue.main.async { [weak window] in
                    window?.setFrame(savedFrame, display: true, animate: false)
                }
            }

            let center = NotificationCenter.default
            let dir = directory
            observers.append(center.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                guard let w = window else { return }
                WindowStateStore.shared.recordFrame(w.frame, for: dir)
            })
            observers.append(center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                guard let w = window else { return }
                WindowStateStore.shared.recordFrame(w.frame, for: dir)
            })
        }
    }
}

/// Walk the view hierarchy to find a BrowserEngineView associated with a pane ID.
/// Checks for both WatchtowerWebView (WebKit) and ChromiumBrowserView (Chromium).
func findBrowserEngineView(for paneId: UUID, in view: NSView) -> (any BrowserEngineView)? {
    if let engineView = view as? any BrowserEngineView,
       engineView.browser?.id == paneId {
        return engineView
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
    if let engineView = view as? any BrowserEngineView,
       let browser = engineView.browser,
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
    private var appearanceObserver: NSKeyValueObservation?

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

        appearanceObserver = NSApplication.shared.observe(\ .effectiveAppearance, options: [.new, .initial]) { _, _ in
            GhosttyAppManager.shared.syncColorScheme()
        }

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

            if self.isFindShortcut(event),
               let browser,
               let viewModel = browser.viewModel {
                shortcutLogger.debug("Handling find shortcut")
                viewModel.openFindInContext()
                return nil
            }

            if self.isFindNextShortcut(event),
               let browser,
               let viewModel = browser.viewModel {
                shortcutLogger.debug("Handling find-next shortcut")
                viewModel.findNextInContext()
                return nil
            }

            if self.isFindPreviousShortcut(event),
               let browser,
               let viewModel = browser.viewModel {
                shortcutLogger.debug("Handling find-previous shortcut")
                viewModel.findPreviousInContext()
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
            if let engineView = view as? any BrowserEngineView {
                shortcutLogger.debug("Resolved browser from first responder via BrowserEngineView")
                return engineView.browser
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

    private func isFindShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock])

        guard flags == [.command] else { return false }
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return chars == "f"
    }

    private func isFindNextShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock])

        guard flags == [.command] else { return false }
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return chars == "g"
    }

    private func isFindPreviousShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock])

        guard flags == [.command, .shift] else { return false }
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return chars == "g"
    }

    @objc func windowNeedsConfiguration(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            configureWindow(window)
        }
    }

    private func configureWindow(_ window: NSWindow) {
        // Title is set by ContentView's WindowCaptureView based on the
        // window's project directory; don't overwrite it here.
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unified
        }
        window.backgroundColor = NSColor(GhosttyAppManager.shared.backgroundColor)
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
        // Persist current window/pane layout so the next launch can
        // reconstruct it.
        WindowStateStore.shared.flush()

        appearanceObserver = nil
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

// MARK: - File > Open command

/// Adds a "File > Open Folder…" menu item that prompts for a directory and
/// opens a new window scoped to it. Lives in its own Commands struct so it
/// can read the openWindow environment value from SwiftUI.
struct FileOpenCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.prompt = "Open"
                panel.message = "Choose a folder to open as a project"
                panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
                guard panel.runModal() == .OK, let url = panel.url else { return }
                openWindow(value: url.standardizedFileURL)
            }
            .keyboardShortcut("o", modifiers: [.command])
        }
    }
}

final class WebKitInspectorReproManager: NSObject {
    static let shared = WebKitInspectorReproManager()

    private var windows: [NSWindow] = []

    func open(url: URL) {
        let controller = WebKitInspectorReproViewController(initialURL: url)
        let window = NSWindow(
            contentRect: NSRect(x: 220, y: 220, width: 1200, height: 840),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WebKit Inspector Repro"
        window.contentViewController = controller
        window.isReleasedWhenClosed = false

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )

        windows.append(window)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeAll { $0 === window }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
    }
}

final class WebKitInspectorReproViewController: NSViewController {
    private let initialURL: URL
    private let webView: WKWebView
    private let urlField = NSTextField(string: "")

    init(initialURL: URL) {
        self.initialURL = initialURL

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        self.webView = WKWebView(frame: .zero, configuration: config)

        super.init(nibName: nil, bundle: nil)

        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        urlField.isEditable = true
        urlField.isBezeled = true
        urlField.lineBreakMode = .byTruncatingMiddle
        urlField.target = self
        urlField.action = #selector(loadFromField)

        let loadButton = NSButton(title: "Load", target: self, action: #selector(loadFromField))
        let inspectButton = NSButton(title: "Open Inspector", target: self, action: #selector(openInspector))

        bar.addArrangedSubview(urlField)
        bar.addArrangedSubview(loadButton)
        bar.addArrangedSubview(inspectButton)

        webView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(bar)
        root.addSubview(webView)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            webView.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        urlField.stringValue = initialURL.absoluteString
        webView.load(URLRequest(url: initialURL))
    }

    @objc private func loadFromField() {
        guard let url = URL(string: urlField.stringValue) else { return }
        webView.load(URLRequest(url: url))
    }

    @objc private func openInspector() {
        let selector = NSSelectorFromString("_inspector")
        if webView.responds(to: selector),
           let inspector = webView.perform(selector)?.takeUnretainedValue() as AnyObject? {
            let show = NSSelectorFromString("show")
            if inspector.responds(to: show) {
                _ = inspector.perform(show)
                return
            }
        }

        let fallbacks = [
            NSSelectorFromString("_showWebInspector"),
            NSSelectorFromString("_showWebInspector:"),
            NSSelectorFromString("showWebInspector"),
            NSSelectorFromString("showWebInspector:")
        ]
        for selector in fallbacks where webView.responds(to: selector) {
            _ = webView.perform(selector, with: nil)
            return
        }
    }
}
