import SwiftUI
import os

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
                        let browser = vm.addBrowser()
                        vm.focusPane(browser)
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

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize the history store early so pruning runs at startup.
        _ = HistoryStore.shared

        // Start the IPC server for CLI communication.
        IPCServer.shared.start()

        // Set dark appearance at the app level so all windows (including
        // the titlebar chrome, traffic lights, and title text) render
        // correctly against the dark terminal background.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)

        // Configure all existing windows immediately and set ourselves as delegate
        for window in NSApp.windows {
            configureWindow(window)
        }

        // Observe future window creation
        // Re-apply window configuration on key window changes and full screen transitions,
        // because macOS resets the window backgroundColor during the transition.
        for name in [
            NSWindow.didBecomeKeyNotification,
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
    }

    @objc func windowNeedsConfiguration(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            configureWindow(window)
        }
    }

    private func configureWindow(_ window: NSWindow) {
        window.title = "Watchtower"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        // Match the window background to the Ghostty terminal background
        // so the titlebar blends seamlessly
        let bgColor = GhosttyAppManager.shared.backgroundColor
        window.backgroundColor = NSColor(bgColor)

        // In native full screen the titlebar lives in a separate private
        // NSToolbarFullScreenWindow. Setting window.backgroundColor alone
        // won't color it — we must find the NSTitlebarContainerView and
        // set its layer background directly.
        styleTitlebarContainer(for: window, color: NSColor(bgColor))
    }

    /// Finds the NSTitlebarContainerView for the given window (handling both
    /// normal and fullscreen modes) and applies the background color to its layer.
    /// Also hides internal views (NSTitlebarBackgroundView, NSVisualEffectView)
    /// that composite their own colors on top.
    private func styleTitlebarContainer(for window: NSWindow, color: NSColor) {
        if let container = titlebarContainer(for: window) {
            container.wantsLayer = true
            container.layer?.backgroundColor = color.cgColor

            // macOS places a NSTitlebarBackgroundView inside the container that
            // forces its own opaque background on top of our layer color.
            if let bgView = container.firstDescendant(withClassName: "NSTitlebarBackgroundView") {
                bgView.isHidden = true
            }

            // On macOS 13–15 an NSVisualEffectView composites a translucent
            // material on top — hide it so our background color shows through.
            if let effectView = container.firstDescendant(withClassName: "NSVisualEffectView") {
                effectView.isHidden = true
            }
        }
    }

    /// In normal mode, the titlebar container is part of the window's own view
    /// hierarchy. In native fullscreen, macOS moves it into a separate private
    /// `NSToolbarFullScreenWindow` that is a child of the main window.
    private func titlebarContainer(for window: NSWindow) -> NSView? {
        if !window.styleMask.contains(.fullScreen) {
            return window.contentView?
                .firstViewFromRoot(withClassName: "NSTitlebarContainerView")
        }

        // In fullscreen, search for the private toolbar window parented to ours
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
        IPCServer.shared.stop()
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
