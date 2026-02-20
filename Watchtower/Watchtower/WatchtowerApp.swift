import SwiftUI

@main
struct WatchtowerApp: App {
    // Initialize Ghostty at app launch
    @StateObject private var ghosttyManager = GhosttyAppManager.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ghosttyManager)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Terminal") {
                    NotificationCenter.default.post(name: .addTerminal, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command])
            }
            CommandGroup(after: .toolbar) {
                Button("Focus Previous Pane") {
                    NotificationCenter.default.post(name: .focusPreviousPane, object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                Button("Focus Next Pane") {
                    NotificationCenter.default.post(name: .focusNextPane, object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
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
    }
}

extension Notification.Name {
    static let addTerminal = Notification.Name("addTerminal")
    static let focusPreviousPane = Notification.Name("focusPreviousPane")
    static let focusNextPane = Notification.Name("focusNextPane")
}
