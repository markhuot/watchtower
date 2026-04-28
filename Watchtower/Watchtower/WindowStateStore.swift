import Foundation
import AppKit
import Combine
import os

/// Persists window+pane layout to disk so that quitting and relaunching
/// Watchtower restores each project window with the same panes (and the
/// same UUIDs, which lets the tmux save/restore mechanism find each pane's
/// scrollback file).
///
/// Persistence is per-project-directory. Each `PaneContainerViewModel`
/// registers itself at init and is unregistered on deinit. Whenever its
/// `panes` array changes, the store coalesces a debounced write.
///
/// The store is intended to be used only on the main thread (all
/// callers run from SwiftUI publishers or AppDelegate hooks that already
/// fire on main). It is not annotated `@MainActor` so AppDelegate's
/// terminate hook can call `flush()` without an explicit hop.
final class WindowStateStore {
    static let shared = WindowStateStore()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.eyes.Watchtower",
        category: "WindowStateStore"
    )

    /// Live view models, keyed by their project directory. We key by
    /// directory because Watchtower's WindowGroup is `for: URL.self` and
    /// only one window per project URL is meaningful.
    private var liveModels: [String: WeakViewModel] = [:]

    /// Latest known NSWindow frame per directory, populated by the
    /// WindowFrameAutosave representable as the user moves/resizes.
    /// Read back on next launch to position the restored window.
    private var liveFrames: [String: NSRect] = [:]

    /// In-memory snapshot loaded from disk at launch. Used to provide
    /// initial pane lists to view models that init for a known directory.
    private var loadedState: PersistedAppState

    /// Debounce timer for save-on-change.
    private var saveWorkItem: DispatchWorkItem?

    private init() {
        self.loadedState = Self.loadFromDisk() ?? PersistedAppState(windows: [])
    }

    // MARK: - Disk paths

    private static var stateFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("Watchtower", isDirectory: true)
            .appendingPathComponent("window-state.json")
    }

    // MARK: - View model registration

    /// Register a view model so its state will be persisted when its panes
    /// change. Returns the persisted panes for the model's directory if
    /// any were saved on the previous run; the caller should rehydrate
    /// the view model's `panes` array from this list.
    func register(_ model: PaneContainerViewModel) -> [PersistedPane] {
        liveModels[model.projectDirectory] = WeakViewModel(value: model)
        let restored = loadedState.windows
            .first { $0.projectDirectory == model.projectDirectory }?
            .panes ?? []
        return restored
    }

    func unregister(_ model: PaneContainerViewModel) {
        if let entry = liveModels[model.projectDirectory], entry.value === model {
            liveModels.removeValue(forKey: model.projectDirectory)
        }
        scheduleSave()
    }

    /// Variant of `unregister` that releases by project directory only.
    /// Used from `deinit` paths where we can't dereference the model.
    /// Drops the entry only if its weak ref has already gone nil, so a
    /// freshly-registered replacement model isn't accidentally evicted.
    func unregisterByDirectory(_ directory: String) {
        if let entry = liveModels[directory], entry.value == nil {
            liveModels.removeValue(forKey: directory)
        }
        scheduleSave()
    }

    /// Project directories that had persisted panes on the last save.
    /// Used by the AppDelegate to reopen windows on launch.
    var persistedWindowDirectories: [String] {
        return loadedState.windows.map { $0.projectDirectory }
    }

    /// Pinned pane id persisted for the given project directory, if any.
    func persistedPinnedPaneId(for directory: String) -> UUID? {
        return loadedState.windows
            .first { $0.projectDirectory == directory }?
            .pinnedPaneId
    }

    /// Last-known window frame for the given directory. Returns the
    /// in-memory cached frame if the user has moved/resized this session,
    /// otherwise the value persisted on the previous launch.
    func frame(for directory: String) -> NSRect? {
        if let live = liveFrames[directory] {
            return live
        }
        return loadedState.windows
            .first { $0.projectDirectory == directory }?
            .frame
            .map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }

    /// Record an updated NSWindow frame for the given directory and
    /// schedule a debounced save. Called from WindowFrameAutosave on
    /// every windowDidMove / windowDidResize notification.
    func recordFrame(_ frame: NSRect, for directory: String) {
        liveFrames[directory] = frame
        scheduleSave()
    }

    // MARK: - Saving

    /// Coalesce calls into a single write 200ms after the last mutation.
    /// Pane mutations often arrive in bursts (drag-reorder, multi-pane open).
    func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Synchronously serialize and write current state. Called by the
    /// AppDelegate at applicationWillTerminate to guarantee the latest
    /// pane list reaches disk before the process exits.
    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        saveNow()
    }

    private func saveNow() {
        let snapshot = currentSnapshot()
        loadedState = snapshot
        do {
            let url = Self.stateFileURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Failed to save window state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func currentSnapshot() -> PersistedAppState {
        var windows: [PersistedWindow] = []
        for (dir, weakModel) in liveModels {
            guard let model = weakModel.value else { continue }
            let panes = model.panes.compactMap(persistedPane(from:))
            // Pull the latest captured frame, falling back to whatever
            // was on disk so we don't drop a frame just because the user
            // never moved the window this session.
            let frame: PersistedFrame? = {
                if let live = liveFrames[dir] {
                    return PersistedFrame(rect: live)
                }
                return loadedState.windows
                    .first { $0.projectDirectory == dir }?
                    .frame
            }()
            // Persist any open window, even ones with no panes - the
            // user may have intentionally moved an empty scratch window
            // and expects it to come back where they left it.
            windows.append(PersistedWindow(
                projectDirectory: dir,
                pinnedPaneId: model.pinnedPaneId,
                panes: panes,
                frame: frame
            ))
        }
        return PersistedAppState(windows: windows)
    }

    private func persistedPane(from pane: PaneModel) -> PersistedPane? {
        if let terminal = pane as? TerminalPaneModel {
            // Action panes (custom command, ephemeral) are intentionally
            // not persisted - rerunning a build on launch would be surprising.
            guard terminal.command == nil else { return nil }
            return PersistedPane(
                id: terminal.id,
                kind: .terminal,
                directory: terminal.terminalDirectory,
                url: nil,
                title: terminal.terminalTitle,
                paneWidth: Double(terminal.paneWidth),
                isCollapsed: terminal.isCollapsed
            )
        }
        if let browser = pane as? BrowserPaneModel {
            return PersistedPane(
                id: browser.id,
                kind: .browser,
                directory: nil,
                url: browser.url.absoluteString,
                title: browser.pageTitle,
                paneWidth: Double(browser.paneWidth),
                isCollapsed: browser.isCollapsed
            )
        }
        return nil
    }

    // MARK: - Loading

    private static func loadFromDisk() -> PersistedAppState? {
        let url = stateFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(PersistedAppState.self, from: data)
        } catch {
            logger.error("Failed to load window state: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Helpers

    private struct WeakViewModel {
        weak var value: PaneContainerViewModel?
    }
}

// MARK: - Persisted models

struct PersistedAppState: Codable {
    var windows: [PersistedWindow]
}

struct PersistedWindow: Codable {
    var projectDirectory: String
    var pinnedPaneId: UUID?
    var panes: [PersistedPane]
    var frame: PersistedFrame?
}

struct PersistedFrame: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(rect: NSRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }
}

struct PersistedPane: Codable {
    enum Kind: String, Codable {
        case terminal
        case browser
    }

    var id: UUID
    var kind: Kind
    var directory: String?
    var url: String?
    var title: String?
    var paneWidth: Double
    var isCollapsed: Bool
}
