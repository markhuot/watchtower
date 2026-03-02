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

        // Set dark appearance at the app level so all windows (including
        // the titlebar chrome, traffic lights, and title text) render
        // correctly against the dark terminal background.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)

        // Configure all existing windows immediately and set ourselves as delegate
        for window in NSApp.windows {
            configureWindow(window)
        }

        // Observe future window activation.
        // Re-apply window configuration when a window becomes key so late-created
        // SwiftUI windows are configured as soon as they appear.
        for name in [
            NSWindow.didBecomeKeyNotification,
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
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = false
        // Match the window background to the Ghostty terminal background.
        // Keep a native, opaque titlebar so there is no initial white flash.
        let bgColor = GhosttyAppManager.shared.backgroundColor
        window.backgroundColor = NSColor(bgColor)
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
