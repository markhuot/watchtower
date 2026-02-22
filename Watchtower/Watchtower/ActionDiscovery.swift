import Foundation
import os

/// Discovers action scripts from project and global directories.
class ActionDiscovery {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.eyes.Watchtower",
        category: "ActionDiscovery"
    )

    /// The global actions directory path.
    static let globalActionsPath: String = {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".config/watchtower/actions")
    }()

    /// Cached global actions (loaded once at app launch).
    private static var cachedGlobalActions: [Action]? = nil

    // MARK: - Discovery

    /// Discover all actions for a given working directory.
    /// Returns merged list: project actions first, then global actions (deduped by filename).
    static func discoverActions(for directory: String) -> [Action] {
        let projectActions = discoverProjectActions(for: directory)
        let globalActions = loadGlobalActions()

        // Deduplicate: project actions take precedence over global actions with same filename
        let projectFilenames = Set(projectActions.map { $0.id })
        let filteredGlobal = globalActions.filter { !projectFilenames.contains($0.id) }

        return projectActions + filteredGlobal
    }

    /// Check if there are any project actions (used to determine separator placement).
    static func hasProjectActions(for directory: String) -> Bool {
        return !discoverProjectActions(for: directory).isEmpty
    }

    /// Discover project-specific actions by walking up from the given directory.
    static func discoverProjectActions(for directory: String) -> [Action] {
        guard let actionsDir = findActionsDirectory(from: directory) else {
            return []
        }
        return enumerateActions(in: actionsDir, isGlobal: false)
    }

    /// Load global actions from ~/.config/watchtower/actions/.
    /// Cached after first load.
    static func loadGlobalActions() -> [Action] {
        if let cached = cachedGlobalActions {
            return cached
        }
        let actions = enumerateActions(in: globalActionsPath, isGlobal: true)
        cachedGlobalActions = actions
        return actions
    }

    /// Force reload of global actions cache.
    static func reloadGlobalActions() {
        cachedGlobalActions = nil
    }

    // MARK: - Directory Walking

    /// Walk up from the given directory looking for `.watchtower/actions/`.
    /// Stops at filesystem root or user's home directory.
    private static func findActionsDirectory(from startDirectory: String) -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var current = startDirectory

        while true {
            let candidate = (current as NSString).appendingPathComponent(".watchtower/actions")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }

            // Stop conditions: reached root or home directory
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current {
                // Reached filesystem root
                break
            }
            if current == home {
                // Reached home directory, don't go higher
                break
            }
            current = parent
        }

        return nil
    }

    // MARK: - Enumeration

    /// Enumerate all action files in a directory.
    /// Filters out hidden files. Sorts alphabetically by filename.
    private static func enumerateActions(in directory: String, isGlobal: Bool) -> [Action] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else {
            return []
        }

        var actions: [Action] = []

        let sortedEntries = entries.sorted()

        for entry in sortedEntries {
            // Skip hidden files (dotfiles)
            if entry.hasPrefix(".") { continue }

            let fullPath = (directory as NSString).appendingPathComponent(entry)

            // Skip directories
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                continue
            }

            if let action = ActionParser.parse(filePath: fullPath, isGlobal: isGlobal) {
                actions.append(action)
            }
        }

        return actions
    }
}
