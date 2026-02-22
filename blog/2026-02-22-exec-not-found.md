---
title: "exec: not found — How Ghostty Runs Your Commands (And Why It Broke Our Actions System)"
date: 2026-02-22
author: Mark Huot
sessions:
  - ses_37a86c0bcffe6lPu2Jkh9j79m4  # User actions spec refinement Q&A
  - ses_37a767744ffeI3fR2EheNUZCV3  # Implement user actions system
  - ses_37a8d60d1ffe7cUrvH0quQ26ZM  # AGENTS.md learnings extraction
  - ses_37a92dfc7ffeoQmxGHEFRalAIC  # Build and run (smoke test)
  - ses_37a4f5ef5ffe5Z5vpvhzXVlQDL  # Command palette spec
  - ses_3863a4cc1ffeHm62NJ6UkaAimD  # Titlebar redesign
---

# exec: not found

The [first post](./2026-02-20-its-alive.md) covered getting Watchtower from zero to a working multi-terminal app in three days. This post is about what happened when we tried to make the terminals actually *do* things -- and the Ghostty command execution bug that blocked us for longer than it should have.

## From hardcoded to general-purpose

Watchtower already had one custom action: "New Workspace," which created a git worktree and opened a shell in it. The script path, the dialog fields (workspace name, base branch), and the execution logic were all hardcoded in `WorkspaceManager.swift` and `WorkspaceDialogView.swift`.

The idea behind user actions was to generalize this. Instead of one hardcoded action, users drop executable scripts into `.watchtower/actions/` (per-project) or `~/.config/watchtower/actions/` (global), and Watchtower discovers them, parses their metadata, and presents them in the toolbar dropdown. A script like this:

```bash
#!/bin/bash

# @name New Agent
# @description Start a Claude Code session with a task description
# @argument TASK Describe the task for the agent

exec claude "$TASK"
```

would show up as "New Agent..." in the menu, present a dialog with one text field, and open a new terminal pane running the command.

The spec was detailed -- 448 lines covering annotation parsing (`@name`, `@description`, `@argument`, `@default`, `@options`), discovery algorithm (walk up the directory tree looking for `.watchtower/actions/`), deduplication (project actions shadow global actions with the same filename), interpreter detection for non-executable scripts, and async resolution of `$(...)` shell commands for default values and option lists. Before implementation started, we spent a session refining the spec through ten pointed questions. Some of the answers reshaped the design:

- **Static vs. reactive discovery**: The original spec loaded actions once at app launch. The final design re-discovers per-directory actions whenever a terminal's working directory changes or focus switches between terminals. Global actions (`~/.config/watchtower/actions/`) are still loaded once and cached.
- **Per-terminal independence**: Each terminal independently tracks its own discovered actions based on its own cwd. The toolbar dropdown reflects whichever terminal is focused.
- **No `WATCHTOWER_PROJECT_ROOT`**: The spec originally defined a project root env var, but since action discovery walks up from the cwd and isn't tied to git, the concept became ambiguous. It was removed entirely. `WATCHTOWER_GIT_ROOT` stayed (useful, well-defined).
- **Dropdown only when needed**: When no custom actions exist, the toolbar shows a plain `+` button. The dropdown chevron only appears when there's something to put in it.

## Implementation: four new files, one deleted

The implementation touched eight files and landed in a single session. Four new Swift files:

- **`Action.swift`** -- the model (`Action`, `ActionArgument`) and `ActionInterpreter` with a `buildCommand(for:)` method that constructs the shell command string.
- **`ActionParser.swift`** -- reads the first 50 lines of each script, stops at the first non-comment/non-blank/non-shebang line, recognizes both `#` and `//` comment prefixes, and extracts annotation metadata. Display names are derived from filenames: strip extension, replace hyphens/underscores with spaces, title-case.
- **`ActionDiscovery.swift`** -- walks up the directory tree from the focused terminal's cwd looking for `.watchtower/actions/`, enumerates scripts, merges with cached global actions, deduplicates by filename.
- **`ActionDialogView.swift`** -- a generic SwiftUI sheet that renders one field per `@argument`. Text fields by default, dropdown pickers when `@options` is declared. All `$(...)` defaults and options resolve concurrently via `withTaskGroup` when the dialog opens. If a command fails, the dropdown falls back to a text field with an inline error hint.

`WorkspaceDialogView.swift` was deleted. `WorkspaceManager.swift` was stripped from ~130 lines to ~50, keeping only `detectGitRepoRoot` and `currentBranch`. `ContentView.swift` got the most churn: the toolbar's hardcoded "New Workspace..." menu became a dynamic `Menu` populated from `viewModel.actions`, and `TerminalContainerViewModel` gained action-related `@Published` properties wired into the existing Combine pipeline that already tracked the focused terminal's directory for git detection.

Adding four Swift files to the Xcode project meant editing `project.pbxproj` in four places per file: `PBXBuildFile`, `PBXFileReference`, `PBXGroup` children, and `PBXSourcesBuildPhase`. Miss any one of the sixteen edits and the build fails silently or with cryptic errors. Removing `WorkspaceDialogView.swift` required the same four deletions in reverse. This is one of those things that's simple in principle and tedious in practice, and it's the kind of thing that an AI agent actually handles well because it doesn't get bored halfway through.

The build succeeded on the first attempt. Then we ran the app and tried an action script that SSH'd into a server.

## `exec: not found`

The script worked fine when run directly in a normal terminal:

```bash
#!/bin/bash
exec ssh dev-sandbox.internal
```

In Watchtower, it failed immediately: `exec: not found`.

## How Ghostty executes commands

To understand the bug, you need to understand how Ghostty turns a command string into a running process. The relevant code is in `ghostty/src/termio/Exec.zig`, around line 1515.

On macOS, when you give Ghostty a command string (via the surface config's `command` field), it doesn't just `execvp` it. Instead, it constructs this:

```
/usr/bin/login -flp <username> /bin/bash --noprofile --norc -c "exec -l <command>"
```

Breaking that down:

1. **`/usr/bin/login -flp <username>`** -- sets up a login session context (utmpx entries, PAM, etc.) without actually authenticating.
2. **`/bin/bash --noprofile --norc`** -- starts a non-interactive bash shell that explicitly skips all user config files.
3. **`-c "exec -l <command>"`** -- runs the command, with `exec -l` to replace the bash process with the command (the `-l` marks it as a login shell for process accounting).

The `exec -l` part is key. Ghostty *already* wraps your command in `exec`. If you write `exec ssh dev-sandbox.internal` in your script, and Watchtower's action system also prefixed it with `exec`, the actual command that ran was:

```
exec -l exec /path/to/ssh-dev.sh
```

Which tries to find a binary literally named `exec` in `$PATH`. There isn't one. Hence: `exec: not found`.

The fix for the double-exec was straightforward -- don't add `exec` yourself, let Ghostty handle it. But fixing that revealed a second, more subtle problem.

## `TERM=xterm-ghostty` and the dead SSH session

With the double-exec fixed, the SSH script ran. The connection established. Then the remote server's shell configuration broke because it didn't recognize `TERM=xterm-ghostty`.

Ghostty sets `TERM=xterm-ghostty` by default, which is correct for local use (it ships a proper terminfo entry). But remote servers don't have that terminfo. Normally this isn't a problem because your `~/.zshrc` or `~/.bash_profile` would set `TERM=xterm-256color` as a workaround before SSH-ing. But remember: Ghostty's command wrapper uses `bash --noprofile --norc`. User dotfiles are never sourced. The user's carefully configured shell environment doesn't exist.

This wasn't just a `TERM` issue. `PATH` modifications from `~/.zshrc` were missing too. SSH agent forwarding wasn't configured. NVM, pyenv, rbenv -- anything that hooks into shell initialization -- was absent.

## The `$SHELL -lic` fix

The solution was to wrap the script invocation in the user's actual shell:

```swift
let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
let escapedInner = innerCommand
    .replacingOccurrences(of: "'", with: "'\\''")
return "\(shell) -lic '\(escapedInner)'"
```

The flags matter:

- **`-l`** (login) -- sources `~/.zprofile`, `~/.bash_profile`, etc.
- **`-i`** (interactive) -- sources `~/.zshrc`, `~/.bashrc`, etc.
- **`-c`** (command) -- runs the following string as a command.

So the full execution chain for an action script becomes:

```
/usr/bin/login -flp <user> /bin/bash --noprofile --norc -c "exec -l /bin/zsh -lic '/path/to/script.sh'"
```

Ghostty's non-interactive bash boots, execs the user's actual shell as a login + interactive shell, which sources all config files, then runs the script. The user's `TERM`, `PATH`, SSH keys, and everything else are available.

This is `ActionInterpreter.buildCommand(for:)` in `Action.swift`:

```swift
static func buildCommand(for action: Action) -> String? {
    let escapedPath = shellEscape(action.scriptPath)

    let innerCommand: String
    if action.isExecutable {
        innerCommand = escapedPath
    } else if let ext = action.fileExtension,
              let interpreter = interpretersByExtension[ext] {
        innerCommand = "\(interpreter) \(escapedPath)"
    } else {
        let filename = (action.scriptPath as NSString).lastPathComponent
        return "echo \"Error: \(filename) is not executable and has no recognized extension\""
    }

    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let escapedInner = innerCommand
        .replacingOccurrences(of: "'", with: "'\\''")
    return "\(shell) -lic '\(escapedInner)'"
}
```

The interpreter fallback handles scripts without the executable bit set. If you have `deploy.py` without `chmod +x`, it runs as `/usr/bin/env python3 /path/to/deploy.py` through the user's shell. If it's not executable and has no recognized extension, you get an error message in the terminal.

## The Ghostty execution chain, diagrammed

For anyone embedding Ghostty's C API, here's the full picture of what happens when you set `surfaceConfig.command`:

```
Your command string: "/bin/zsh -lic '/path/to/script.sh'"
                          ↓
Ghostty (Exec.zig):  /usr/bin/login -flp <user>
                       /bin/bash --noprofile --norc
                         -c "exec -l /bin/zsh -lic '/path/to/script.sh'"
                          ↓
Result:              login session → bash (no config) → exec replaces bash →
                     zsh -lic (full config loaded) → script runs
```

Three shells deep. It's ugly. But it works, and it works because each layer serves a purpose: `login` for session accounting, bash as Ghostty's known-quantity execution wrapper, and the user's shell for their environment.

## Tracing through Ghostty's source

Figuring this out required reading Ghostty's Zig source. The relevant file is `ghostty/src/termio/Exec.zig`. The macOS execution path starts around line 1500, in the code that sets up argv for the child process:

```zig
// Exec.zig:1515-1531 (simplified)
argv[idx] = "/usr/bin/login";
argv[idx] = "-flp";
argv[idx] = user;
argv[idx] = "/bin/bash";
argv[idx] = "--noprofile";
argv[idx] = "--norc";
argv[idx] = "-c";
argv[idx] = "exec -l " ++ command;
```

Ghostty's own macOS reference app (`SurfaceView_AppKit.swift`) doesn't have this problem because it's running an interactive shell, not a command. When you open a normal Ghostty terminal, the surface config has no `command` set, so Ghostty spawns the user's default shell directly. The `login` + `bash -c` wrapper only kicks in when a specific command is provided -- which is exactly what Watchtower does for every action script.

The Ghostty reference implementation in `ghostty/macos/Sources/Ghostty/` was useful context for understanding the intended behavior, but since it doesn't use the `command` field for custom scripts the same way we do, the bug was unique to our embedding.

## What we learned about embedding Ghostty

Two rules, both now documented in the project's AGENTS.md:

1. **Never prefix commands with `exec`** when passing them to Ghostty's surface config. Ghostty already wraps commands in `exec -l`. Adding your own produces `exec -l exec /path/to/script`, which fails.

2. **User shell config is not loaded** by Ghostty's command execution path. If your embedded terminal needs the user's environment (PATH, TERM overrides, SSH config, language version managers), wrap the command in `$SHELL -lic '<command>'`.

Both of these are artifacts of Ghostty's design choice to use a non-interactive bash as the command wrapper. It's a reasonable default for security and reproducibility -- you don't want random shell config interfering with terminal initialization. But it means any embedder running user-provided scripts needs to opt back into the user's environment explicitly.

## The broader pattern

This bug is representative of a category of problems you hit when embedding a library that was designed as a standalone application. Ghostty's C API is remarkably capable -- it handles rendering, input, font shaping, scrollback, and the entire VT state machine. But its execution model was designed for the Ghostty terminal app, where the normal case is "spawn the user's default shell." The "run an arbitrary command" path is a secondary use case, and the non-interactive shell wrapping made sense for Ghostty's own needs. Watchtower's action system, where every terminal pane runs a user-provided script, exercised that secondary path in a way the original design didn't prioritize.

The fix was 5 lines of Swift. Finding the fix required reading Zig source, understanding the macOS `login` command, tracing through Ghostty's process spawning code, and understanding the difference between login shells, interactive shells, and non-interactive command execution. The kind of problem where the solution is trivial but the diagnosis requires understanding four layers of abstraction.
