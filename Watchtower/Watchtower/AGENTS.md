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

## Ghostty Command Execution (surfaceConfig.command)

- **Do NOT prefix commands with `exec`**: On macOS, Ghostty wraps shell commands as `/usr/bin/login ... /bin/bash --noprofile --norc -c "exec -l <command>"`. Adding your own `exec` produces `exec -l exec /path/to/script` which tries to find a binary named "exec" → `exec: not found`. The `exec -l` wrapping is Ghostty's job. See `ghostty/src/termio/Exec.zig:1515-1531`.
- **User shell config is NOT loaded**: Ghostty uses `bash --noprofile --norc` for the command wrapper, so `~/.zshrc`, `~/.bash_profile`, etc. are never sourced. Commands that depend on user environment (TERM, PATH, SSH config) will fail. Workaround: wrap the command in `$SHELL -lic '<inner command>'` so the user's login shell boots with full config before running the script.
- **Command type heuristic**: Ghostty's `config/command.zig` parses the command string — plain strings become `.shell` (wrapped in `/bin/sh -c`), `direct:` prefix becomes `.direct` (passed to execvp as argv). For action scripts, use the `.shell` path (no prefix) so shell expansion works.

## Action System

- **Action discovery pipeline**: Wired into the same Combine `switchToLatest` pipeline as git detection in `TerminalContainerViewModel`. Both re-run when the focused terminal's directory changes.
- **Action deduplication**: Project actions (`.watchtower/actions/`) take precedence over global actions (`~/.config/watchtower/actions/`) when filenames match. The `id` field is the filename.

## NSViewRepresentable First Responder Pitfalls

- **`updateNSView` fires during SwiftUI view teardown**: When a view is removed from the hierarchy, SwiftUI still calls `updateNSView`. Any `makeFirstResponder` call in `updateNSView` will re-steal focus from whatever view was just focused. Place one-time first-responder grabs in `makeNSView` only.
- **Double-async for focus after state changes**: A single `DispatchQueue.main.async` is insufficient when SwiftUI must both tear down one view (e.g. command palette's NSTextField) and create/focus another (e.g. new terminal). Use nested `DispatchQueue.main.async { DispatchQueue.main.async { ... } }` so the first pass lets SwiftUI process the state change and the second ensures the old view has fully resigned.
- **Debugging first-responder timing**: `NSApp.keyWindow?.firstResponder` changes between async dispatches, making breakpoints and print statements unreliable. Write timestamped logs to a file (e.g. `/tmp/watchtower_debug.log`) to trace the exact sequence.

## Command Palette

- **Files that must change together**: `CommandPaletteView.swift` defines the `managesFocus` flag on each `CommandPaletteItem`, which controls the `restoreFocus` parameter passed to `dismissCommandPalette()` in `ContentView.swift`. Adding a new palette command that manages its own focus requires coordinating both files.
- **Focus lifecycle**: Palette open → `makeNSView` grabs focus once → user selects action → `dismissCommandPalette(restoreFocus: !managesFocus)` → action runs (e.g. `addTerminal`) → double-async `makeFocused` claims focus for the target terminal. The NSTextField must NOT re-grab focus during this sequence.
