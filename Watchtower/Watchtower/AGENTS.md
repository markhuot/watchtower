# AGENTS.md - Watchtower Swift Source

Non-obvious learnings specific to the Swift source files in this directory.

## TerminalModel

- **Extended fields for workspaces**: `command: String?`, `env: [String: String]?`, `waitAfterCommand: Bool` propagate through to GhosttyTerminalView's surface config for workspace terminals.
- **Terminal status truth**: Use `ghostty_surface_needs_confirm_quit()` as single source of truth for "is something running" — custom command tracking was unreliable.
- **TerminalStatus enum naming**: `.running`/`.succeeded` were renamed to `.active`/`.idle` to match Ghostty's actual reports.

## ContentView / TerminalContainerViewModel

- **Focus mode**: Uses `ScrollViewReader` + `scrollProxy.scrollTo(id, anchor: .center)`, with a separate `FocusModeWrapper` view to avoid bloating ContentView.
- **Combine pipeline for git detection**: `CurrentValueSubject<TerminalModel?, Never>` + `switchToLatest` tracks focused terminal's `$directory` for git repo detection.
- **Last terminal removal**: `removeTerminal(byId:)` auto-creates a new terminal when the last one is removed, so `closeCurrentPane()` must check count before removing.

## Workspace Terminals

- **Scripts as terminal commands**: Scripts become the terminal command via Ghostty's surface config `command` field rather than running before the terminal opens — avoids race conditions with the shell not being ready.
- **Programmatic text input**: `ghostty_surface_text(surface, ptr, len)` sends text/commands to a terminal surface programmatically.
