import SwiftUI

@main
struct WatchtowerApp: App {
    // Initialize Ghostty at app launch
    @StateObject private var ghosttyManager = GhosttyAppManager.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @FocusedValue(\.terminalViewModel) var activeViewModel

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ghosttyManager)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Terminal") {
                    activeViewModel?.addTerminal()
                }
                .keyboardShortcut("t", modifiers: [.command])
            }
            CommandGroup(after: .toolbar) {
                Button("Focus Previous Pane") {
                    activeViewModel?.focusPreviousPane()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Button("Focus Next Pane") {
                    activeViewModel?.focusNextPane()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set dark appearance at the app level so all windows (including
        // the titlebar chrome, traffic lights, and title text) render
        // correctly against the dark terminal background.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)

        // Configure all existing windows immediately
        for window in NSApp.windows {
            configureWindow(window)
        }

        // Observe future window creation
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeAvailable(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc func windowDidBecomeAvailable(_ notification: Notification) {
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

        // Set ourselves as the window delegate so we can intercept close
        window.delegate = self
    }

    // MARK: - Window Close Confirmation

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard windowHasActiveSessions(sender) else { return true }
        showCloseConfirmation(for: sender)
        return false
    }

    // MARK: - App Quit Confirmation

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
        let terminalViews = findAllTerminalViews(in: contentView)
        return terminalViews.contains { view in
            guard let surface = view.surface else { return false }
            return ghostty_surface_needs_confirm_quit(surface)
        }
    }

    /// Show an alert sheet asking the user to confirm closing a window.
    private func showCloseConfirmation(for window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "Close Window?"
        alert.informativeText = "There are still active terminal sessions in this window. Closing the window will terminate the sessions."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                // User confirmed — close without re-checking
                window.delegate = nil
                window.close()
            }
        }
    }

    /// Recursively find all GhosttyTerminalNSView instances in a view hierarchy.
    private func findAllTerminalViews(in view: NSView) -> [GhosttyTerminalNSView] {
        var results: [GhosttyTerminalNSView] = []
        if let tv = view as? GhosttyTerminalNSView {
            results.append(tv)
        }
        for subview in view.subviews {
            results.append(contentsOf: findAllTerminalViews(in: subview))
        }
        return results
    }
}

// MARK: - FocusedValues

/// Key for routing menu commands to the active window's TerminalContainerViewModel.
struct FocusedTerminalViewModelKey: FocusedValueKey {
    typealias Value = TerminalContainerViewModel
}

extension FocusedValues {
    var terminalViewModel: TerminalContainerViewModel? {
        get { self[FocusedTerminalViewModelKey.self] }
        set { self[FocusedTerminalViewModelKey.self] = newValue }
    }
}
