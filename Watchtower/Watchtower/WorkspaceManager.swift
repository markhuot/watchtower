import Foundation
import Darwin
import os

/// Handles git detection utilities.
class WorkspaceManager {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.eyes.Watchtower",
        category: "WorkspaceManager"
    )
    private static let watcherQueue = DispatchQueue(label: "Watchtower.WorkspaceManager.GitWatcher")
    private static var repoWatchers: [String: RepoWatcher] = [:]

    // MARK: - Git Detection

    /// Detect the git repo root for a given directory.
    /// Returns `nil` if the directory is not inside a git repository.
    static func detectGitRepoRoot(for directory: String) async -> String? {
        await runGitCommand(["rev-parse", "--show-toplevel"], in: directory)
    }

    /// Resolve the actual git metadata directory for the repository containing `directory`.
    /// This handles both normal repos and linked worktrees.
    static func gitDirectory(for directory: String) async -> String? {
        guard let gitDir = await runGitCommand(["rev-parse", "--path-format=absolute", "--git-dir"], in: directory),
              !gitDir.isEmpty else {
            return nil
        }
        return gitDir
    }

    /// Get the current branch name for a directory.
    /// Falls back to the short HEAD hash for detached HEAD.
    static func currentBranch(for directory: String) async -> String {
        if let branch = await runGitCommand(["branch", "--show-current"], in: directory),
           !branch.isEmpty {
            return branch
        }
        // Detached HEAD fallback
        return await runGitCommand(["rev-parse", "--short", "HEAD"], in: directory) ?? "HEAD"
    }

    // MARK: - Helpers

    /// Subscribe to git branch changes for the repo containing `directory`.
    /// The callback is delivered on the main queue and is immediately invoked
    /// with the current branch state after the watcher is registered.
    @MainActor
    static func observeGitBranch(for directory: String, observer: AnyObject, onChange: @escaping (String?) -> Void) async -> String? {
        guard let root = await detectGitRepoRoot(for: directory),
              let gitDir = await gitDirectory(for: directory) else {
            onChange(nil)
            return nil
        }

        return await withCheckedContinuation { continuation in
            watcherQueue.async {
                let watcher: RepoWatcher
                if let existing = repoWatchers[root] {
                    watcher = existing
                } else if let created = RepoWatcher(repoRoot: root, gitDirectory: gitDir) {
                    watcher = created
                    repoWatchers[root] = created
                } else {
                    DispatchQueue.main.async {
                        onChange(nil)
                    }
                    continuation.resume(returning: nil)
                    return
                }

                watcher.addObserver(observer, onChange: onChange)
                continuation.resume(returning: root)
            }
        }
    }

    /// Remove a previously registered git branch observer.
    static func removeGitBranchObserver(_ observer: AnyObject, repoRoot: String?) {
        guard let repoRoot else { return }
        watcherQueue.async {
            guard let watcher = repoWatchers[repoRoot] else { return }
            watcher.removeObserver(observer)
            if watcher.isEmpty {
                repoWatchers[repoRoot] = nil
            }
        }
    }

    private static func removeStaleObservers(_ ids: [ObjectIdentifier], repoRoot: String) {
        guard !ids.isEmpty else { return }
        watcherQueue.async {
            guard let watcher = repoWatchers[repoRoot] else { return }
            watcher.removeObservers(withIDs: ids)
            if watcher.isEmpty {
                repoWatchers[repoRoot] = nil
            }
        }
    }

    /// Run a git command and return trimmed stdout, or nil on failure.
    private static func runGitCommand(_ args: [String], in directory: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory] + args
            process.standardInput = FileHandle.nullDevice

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                logger.error("Failed to run git \(args.joined(separator: " ")): \(error.localizedDescription)")
                continuation.resume(returning: nil)
                return
            }

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                continuation.resume(returning: nil)
                return
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.resume(returning: output)
        }
    }

    private final class RepoWatcher {
        private let repoRoot: String
        private let watchURL: URL
        private let source: DispatchSourceFileSystemObject
        private var observers: [ObjectIdentifier: Observer] = [:]
        private var refreshTask: Task<Void, Never>? = nil

        var isEmpty: Bool {
            observers.isEmpty
        }

        init?(repoRoot: String, gitDirectory: String) {
            self.repoRoot = repoRoot
            self.watchURL = URL(fileURLWithPath: gitDirectory)

            let fd = open(watchURL.path, O_EVTONLY)
            guard fd >= 0 else {
                WorkspaceManager.logger.error("Failed to watch git dir at \(self.watchURL.path, privacy: .public)")
                return nil
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: WorkspaceManager.watcherQueue
            )
            self.source = source

            source.setEventHandler { [weak self] in
                self?.handleFileEvent()
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
        }

        deinit {
            refreshTask?.cancel()
            source.cancel()
        }

        func addObserver(_ observer: AnyObject, onChange: @escaping (String?) -> Void) {
            let id = ObjectIdentifier(observer)
            observers[id] = Observer(observer: observer, onChange: onChange)
            refreshBranch()
        }

        func removeObserver(_ observer: AnyObject) {
            let id = ObjectIdentifier(observer)
            observers[id] = nil
            let shouldCancel = observers.isEmpty
            if shouldCancel {
                refreshTask?.cancel()
                source.cancel()
            }
        }

        func removeObservers(withIDs ids: [ObjectIdentifier]) {
            for id in ids {
                observers[id] = nil
            }

            if observers.isEmpty {
                refreshTask?.cancel()
                source.cancel()
            }
        }

        private func handleFileEvent() {
            refreshBranch()
        }

        private func refreshBranch() {
            refreshTask?.cancel()
            let snapshot = observers
            refreshTask = Task {
                let branch = await WorkspaceManager.currentBranch(for: repoRoot)
                guard !Task.isCancelled else { return }

                let staleObserverIds = snapshot.compactMap { id, observer in
                    observer.observer == nil ? id : nil
                }
                WorkspaceManager.removeStaleObservers(staleObserverIds, repoRoot: repoRoot)

                DispatchQueue.main.async {
                    for observer in snapshot.values where observer.observer != nil {
                        observer.onChange(branch)
                    }
                }
            }
        }

        private struct Observer {
            weak var observer: AnyObject?
            let onChange: (String?) -> Void
        }
    }
}
