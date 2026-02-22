import Foundation

/// Represents a single user action discovered from an actions directory.
struct Action: Identifiable {
    let id: String  // filename (used for deduplication)
    let displayName: String
    let descriptionText: String?
    let scriptPath: String  // absolute path to the script file
    let arguments: [ActionArgument]
    let defaults: [String: String]  // VARIABLE_NAME -> default value or "$(command)"
    let options: [String: String]   // VARIABLE_NAME -> "$(command)" or "a, b, c"
    let isGlobal: Bool
    let isExecutable: Bool
    let fileExtension: String?

    /// Whether this action requires a dialog (has arguments).
    var hasArguments: Bool {
        !arguments.isEmpty
    }

    /// The menu label, with ellipsis appended if the action has arguments.
    var menuLabel: String {
        hasArguments ? "\(displayName)..." : displayName
    }
}

/// Represents a single argument declared by an action script.
struct ActionArgument: Identifiable {
    let id: String  // same as variableName
    let variableName: String
    let label: String
}

/// Interpreter mapping for non-executable scripts with known extensions.
enum ActionInterpreter {
    static let interpretersByExtension: [String: String] = [
        "sh": "/usr/bin/env bash",
        "bash": "/usr/bin/env bash",
        "zsh": "/usr/bin/env zsh",
        "py": "/usr/bin/env python3",
        "rb": "/usr/bin/env ruby",
        "js": "/usr/bin/env node",
        "ts": "/usr/bin/env npx tsx",
    ]

    /// Build the command string for executing an action script.
    ///
    /// The returned string is passed to Ghostty's surface config `command` field.
    /// Ghostty wraps shell commands in `exec -l <command>` via a non-interactive
    /// bash with `--noprofile --norc`, which means user shell configuration
    /// (~/.zshrc, ~/.bash_profile, etc.) is never loaded. This is a problem
    /// for action scripts that depend on user config (e.g. TERM, PATH, SSH config).
    ///
    /// To fix this, we wrap the script invocation in the user's login shell
    /// with `-lic` (login + interactive + command), so that all rc/profile files
    /// are sourced before the script runs.
    ///
    /// - Parameters:
    ///   - action: The action to execute
    /// - Returns: The shell command string, or nil if the script can't be executed
    static func buildCommand(for action: Action) -> String? {
        let escapedPath = shellEscape(action.scriptPath)

        // Build the inner command that actually runs the script
        let innerCommand: String
        if action.isExecutable {
            innerCommand = escapedPath
        } else if let ext = action.fileExtension,
                  let interpreter = interpretersByExtension[ext] {
            innerCommand = "\(interpreter) \(escapedPath)"
        } else {
            // Not executable and no recognized extension
            let filename = (action.scriptPath as NSString).lastPathComponent
            return "echo \"Error: \(filename) is not executable and has no recognized extension\""
        }

        // Wrap in the user's shell so that rc/profile files are sourced.
        // Use -lic: -l = login shell (sources profile), -i = interactive
        // (sources rc), -c = run command.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let escapedInner = innerCommand
            .replacingOccurrences(of: "'", with: "'\\''")
        return "\(shell) -lic '\(escapedInner)'"
    }

    /// Escape a string for safe inclusion in a shell command.
    private static func shellEscape(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }
}
