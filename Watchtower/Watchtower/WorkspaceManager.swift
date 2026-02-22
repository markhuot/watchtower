import Foundation
import os

/// Handles git detection utilities.
class WorkspaceManager {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.eyes.Watchtower",
        category: "WorkspaceManager"
    )

    // MARK: - Git Detection

    /// Detect the git repo root for a given directory.
    /// Returns `nil` if the directory is not inside a git repository.
    static func detectGitRepoRoot(for directory: String) async -> String? {
        await runGitCommand(["rev-parse", "--show-toplevel"], in: directory)
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
}
