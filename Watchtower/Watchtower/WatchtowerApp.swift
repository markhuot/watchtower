import SwiftUI

@main
struct WatchtowerApp: App {
    // Initialize Ghostty at app launch
    @StateObject private var ghosttyManager = GhosttyAppManager.shared

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

extension Notification.Name {
    static let addTerminal = Notification.Name("addTerminal")
    static let focusPreviousPane = Notification.Name("focusPreviousPane")
    static let focusNextPane = Notification.Name("focusNextPane")
}
