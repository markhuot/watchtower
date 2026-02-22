import Foundation
import os

/// Handles git detection, script discovery, and workspace command building.
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

    // MARK: - Script Discovery

    /// Supported workspace script extensions and their interpreters, in priority order.
    private static let scriptSpecs: [(ext: String, interpreter: String)] = [
        ("sh", "/usr/bin/env bash"),
        ("py", "/usr/bin/env python3"),
        ("ts", "npx tsx"),
        ("rb", "/usr/bin/env ruby"),
        ("js", "node"),
    ]

    /// Find a workspace script in the given repo root.
    /// Looks for `.watchtower/new-workspace.*` files.
    /// Returns `(relativePath, interpreter)` or `nil` if none found.
    static func findWorkspaceScript(repoRoot: String) -> (path: String, interpreter: String?)? {
        let watchtowerDir = (repoRoot as NSString).appendingPathComponent(".watchtower")

        // Check each extension in priority order
        for spec in scriptSpecs {
            let filename = "new-workspace.\(spec.ext)"
            let fullPath = (watchtowerDir as NSString).appendingPathComponent(filename)
            if FileManager.default.isReadableFile(atPath: fullPath) {
                return (path: ".watchtower/\(filename)", interpreter: spec.interpreter)
            }
        }

        // Check for extensionless executable
        let noExtPath = (watchtowerDir as NSString).appendingPathComponent("new-workspace")
        if FileManager.default.isReadableFile(atPath: noExtPath) {
            return (path: ".watchtower/new-workspace", interpreter: nil)
        }

        return nil
    }

    // MARK: - Command Building

    /// Build the command string for a new workspace terminal.
    ///
    /// - Parameters:
    ///   - workspaceName: The name chosen in the dialog (branch/directory name)
    ///   - baseBranch: The branch to base the workspace on
    ///   - repoRoot: Absolute path to the git repo root
    /// - Returns: The shell command to run in the terminal
    static func buildCommand(
        workspaceName: String,
        baseBranch: String,
        repoRoot: String
    ) -> String {
        let escapedName = shellEscape(workspaceName)
        let escapedBranch = shellEscape(baseBranch)
        let escapedRoot = shellEscape(repoRoot)

        // Check for custom script
        if let script = findWorkspaceScript(repoRoot: repoRoot) {
            if let interpreter = script.interpreter {
                return "bash -c 'cd \(escapedRoot) && exec \(interpreter) \(script.path) \(escapedName) \(escapedBranch)'"
            } else {
                // Executable without extension
                return "bash -c 'cd \(escapedRoot) && exec ./\(script.path) \(escapedName) \(escapedBranch)'"
            }
        }

        // Default: git worktree flow
        return "bash -c 'cd \(escapedRoot) && git worktree add -b \(escapedName) \"./work/\(escapedName)\" \(escapedBranch) && cd \"./work/\(escapedName)\" && exec \"$SHELL\"'"
    }

    /// Build environment variables for the workspace script.
    static func buildEnvVars(
        workspaceName: String,
        baseBranch: String,
        repoRoot: String
    ) -> [String: String] {
        return [
            "WATCHTOWER_REPO_ROOT": repoRoot,
            "WATCHTOWER_WORKSPACE_NAME": workspaceName,
            "WATCHTOWER_BASE_BRANCH": baseBranch,
        ]
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

    /// Escape a string for safe inclusion in a single-quoted shell command.
    /// Uses double-quoting to handle spaces and special characters.
    private static func shellEscape(_ string: String) -> String {
        // Wrap in double quotes, escaping any embedded double quotes, dollar signs, and backslashes
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }
}
