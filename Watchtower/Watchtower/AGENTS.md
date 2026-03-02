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

## Focus Management (PendingFocus Pattern)

- **Callback-driven, not timer-driven**: Focus is managed via a `PendingFocus` token, not double-async `DispatchQueue.main.async` heuristics. `focusPane(_ pane:)` is the single unified entry point for all focus changes.
- **PendingFocus token**: A one-shot object with `fulfill()` and `cancel()`. Stored as `var pendingFocus: PendingFocus?` on `PaneContainerViewModel` with a `didSet { oldValue?.cancel() }` that ensures only the most recent focus request can win. After `fulfill()`, the token is niled out to prevent stale references.
- **NSView claims focus in `viewDidMoveToWindow`**: Both `GhosttyTerminalNSView` and `WatchtowerWebView` check `terminal.viewModel?.pendingFocus` (or `browser?.viewModel?.pendingFocus`) when entering the window hierarchy. If the token matches their pane ID, they call `fulfill()`, `makeFirstResponder(self)`, and nil out `pendingFocus`.
- **Pane creation returns the model**: `addTerminal() -> TerminalPaneModel` and `addBrowser() -> BrowserPaneModel` return synchronously. Callers decide focus: `let t = vm.addTerminal(); vm.focusPane(t)`.
- **`focusGeneration` counter**: A monotonically increasing `UInt` bumped every time `focusPane` is called. `executeSelected()` snapshots this before running the action, then passes it to `dismissCommandPalette(beforeGeneration:)`. If the generation advanced (action called `focusPane`), dismiss preserves the action's focus. If not, dismiss restores focus to the original pane.
- **Auto-dismiss**: `focusPane()` automatically nils `commandPalettePaneId` when focus moves to a different pane. This eliminated manual `dismissCommandPalette()` calls from `focusPreviousPane`, `focusNextPane`, and `focusPane(id:)`.
- **`updateNSView` fires during SwiftUI view teardown**: When a view is removed from the hierarchy, SwiftUI still calls `updateNSView`. Any `makeFirstResponder` call in `updateNSView` will re-steal focus. Place one-time first-responder grabs in `makeNSView` only.

## IPC Server (IPCServer.swift)

- **Unix domain socket** at `~/.config/watchtower/watchtower.sock`. Created on app launch, removed on termination.
- **View model registry**: `register(_ viewModel:)` / `unregister(_ viewModel:)` hold weak references to every window's `PaneContainerViewModel`. Called from ContentView's `.onAppear`/`.onDisappear`.
- **JSON protocol**: Requests are `{"command": "new-terminal", "paneId": "<uuid>", ...}`. Responses are `{"success": true}` or `{"success": false, "error": "..."}`.
- **Pane lookup**: `paneId` from the request is matched against all registered view models to find the originating pane. New panes are inserted adjacent (index + 1) to the source pane.
- **Commands**: `new-terminal` (optional `directory`, `command`) and `new-browser` (required `url`). Both create the pane, focus it via `focusPane()`, and inherit the working directory from the source pane when not explicitly provided.
- **Thread safety**: Socket reads happen on a background `DispatchQueue`; command handlers dispatch to `DispatchQueue.main.async` for all UI/model work.
- **`WATCHTOWER_PANE_ID` env var**: Injected into every Ghostty terminal surface in `GhosttyTerminalView.setupView()`. The CLI reads this to identify which pane it's running in.

## CLI (`cli/` directory)

- **Built with Bun + TypeScript**. Entry point: `cli/src/index.ts`.
- **Commands**: `watchtower new terminal [--directory <path>] [--command <cmd>]` and `watchtower new browser [--webkit] [--chrome] [--remote-debugging-port <port>] <url>`.
- **IPC client** (`cli/src/ipc.ts`): Connects to `~/.config/watchtower/watchtower.sock`, sends JSON, reads response. Reads `WATCHTOWER_PANE_ID` env var to identify the calling pane.
- **Compile to binary**: `bun build --compile cli/src/index.ts --outfile watchtower`.
- **CI build**: GitHub Actions runs this in `.github/workflows/build.yml` ("Build CLI") and the bundle step includes the binary.
- **Local build**: The Watchtower target includes a "Build CLI" shell script phase that runs bun; ensure `bun` is installed locally or the build will fail.

## Command Palette

- **No `managesFocus` flag**: The old `CommandPaletteItem.managesFocus` / `actionDidManageFocus` / `restoreFocus` three-way protocol is replaced by the `focusGeneration` counter and auto-dismiss in `focusPane`. Actions that need to manage focus call `vm.focusPane()` directly.
- **`executeSelected()` flow**: Snapshots `focusGeneration`, runs the action (needs `contextualPane` via `commandPalettePaneId`, still set), then calls `dismissCommandPalette(beforeGeneration: gen)`. If the generation advanced, dismiss preserves the action's focus; otherwise it restores focus to the original pane.
- **Navigation from palette**: `focusPreviousPane`/`focusNextPane` capture `contextualPane` before calling `focusPane()`, which auto-dismisses the palette and focuses the target pane. No explicit `dismissCommandPalette()` call needed.
