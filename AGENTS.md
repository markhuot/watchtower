# AGENTS.md - Watchtower

Technical reference for LLM agents working on this codebase.

## What This Is

Watchtower is a macOS SwiftUI app embedding the Ghostty terminal emulator via its C API (`libghostty`). It presents multiple 80-column terminals in a horizontal scroll layout. The directory is `/Users/markhuot/Sites/eyes` (was renamed from "Eyes" to "Watchtower"; directory name unchanged).

## Build Commands

### Build Ghostty (libghostty.a)

```bash
cd ghostty
zig build -Doptimize=ReleaseFast -Demit-docs=false -Demit-xcframework=true -Demit-macos-app=false
```

- Requires Zig 0.15.2 (matches ghostty's `minimum_zig_version`)
- Produces: `ghostty/macos/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a` (272MB)
- Ghostty's own AGENTS.md says: use `zig build`, never xcodebuild, never create issues/PRs on the ghostty repo

### Build Watchtower

```bash
xcodebuild -project Watchtower.xcodeproj -scheme Watchtower -configuration Debug build
```

Or open `Watchtower.xcodeproj` in Xcode.

## Source Files

All under `Watchtower/Watchtower/`:

| File | Purpose |
|---|---|
| `WatchtowerApp.swift` | App entry point, initializes GhosttyAppManager, menu commands via `@FocusedValue` |
| `ContentView.swift` | Horizontal ScrollView of terminal panes, `TerminalContainerViewModel` |
| `TerminalModel.swift` | Class (not struct) with @Published properties for terminal state |
| `TerminalPaneView.swift` | Individual pane UI, uses GeometryReader to pass size |
| `GhosttyTerminalView.swift` | NSView + NSTextInputClient + NSViewRepresentable wrapping a ghostty surface |
| `GhosttyAppManager.swift` | Singleton managing `ghostty_app_t`, runtime callbacks |
| `GhosttyBridge.h` | Bridging header, `#include`s ghostty.h |
| `WorkspaceManager.swift` | Git detection utilities (detectGitRepoRoot, currentBranch) |
| `Action.swift` | Action model, ActionArgument, ActionInterpreter with command building |
| `ActionParser.swift` | Parses script annotation comments (@name, @description, @argument, etc.) |
| `ActionDiscovery.swift` | Discovers action scripts in .watchtower/actions/ and ~/.config/watchtower/actions/ |
| `ActionDialogView.swift` | SwiftUI dialog for action arguments with async default/options resolution |
| `WordList.swift` | Word list utility (used for workspace name generation) |
| `IPCServer.swift` | Unix domain socket server for CLI↔app IPC, view model registry, command handlers |

## Xcode Project

`Watchtower.xcodeproj/project.pbxproj` — all build settings, framework links, library search paths, and header search paths are configured. Key settings:

- Library search path: `$(PROJECT_DIR)/ghostty/macos/GhosttyKit.xcframework/macos-arm64_x86_64`
- Header search path: `$(PROJECT_DIR)/ghostty/macos/GhosttyKit.xcframework/macos-arm64_x86_64/Headers`
- Linked frameworks: Metal, MetalKit, QuartzCore, CoreText, plus libghostty.a
- Bridging header: `$(PROJECT_DIR)/Watchtower/Watchtower/GhosttyBridge.h`

## Ghostty C API Patterns

The canonical header is at `ghostty/macos/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h`.

### Init Flow

```
ghostty_init()
-> ghostty_config_new()
-> ghostty_config_load_default_files(config)
-> ghostty_config_load_recursive_files(config)
-> ghostty_config_finalize(config)
-> ghostty_app_new(&runtime_cfg, config)
-> ghostty_surface_new(app, &surface_cfg)
```

### Runtime Config (`ghostty_runtime_config_s`)

Struct with callback function pointers:
- `wakeup_cb` — receives runtime config's `userdata` (the app manager)
- `action_cb` — receives app_t, target, and action structs
- `read_clipboard_cb`, `confirm_read_clipboard_cb`, `write_clipboard_cb`, `close_surface_cb` — receive the **surface's** userdata (the NSView)

Pass `self` as userdata via `Unmanaged.passUnretained(self).toOpaque()`.

### Surface Config (`ghostty_surface_config_s`)

```swift
var surfaceCfg = ghostty_surface_config_new()
surfaceCfg.platform_tag = GHOSTTY_PLATFORM_MACOS
surfaceCfg.platform.macos.nsview = Unmanaged.passUnretained(nsView).toOpaque()
surfaceCfg.userdata = Unmanaged.passUnretained(nsView).toOpaque()
surfaceCfg.scale_factor = nsView.window?.backingScaleFactor ?? 2.0
```

### Input

- **Keyboard**: `ghostty_surface_key(surface, key_ev)` with `ghostty_input_key_s` struct
- **Mouse buttons**: `GHOSTTY_MOUSE_LEFT`, `GHOSTTY_MOUSE_RIGHT` (NOT `GHOSTTY_MOUSE_BUTTON_LEFT`)
- **Mouse position**: `ghostty_surface_mouse_pos(surface, x, y, mods)` — 4 params, last is `ghostty_input_mods_e`
- **Mouse scroll**: `ghostty_surface_mouse_scroll(surface, x, y, scrollMods)` — `scrollMods` is `ghostty_input_scroll_mods_t` (Int32), packed bitmask: bit 0 = precision, bits 1-3 = momentum phase. Reference impl uses 2x multiplier for precise scrolling.
- **Sizing**: `ghostty_surface_set_size(surface, width_px, height_px)` — backing-scaled pixel sizes

## Compile Pitfalls

These were discovered during development and are already fixed in the current code:

- `doCommand(by:)` needs `override` keyword (overrides NSResponder)
- Logger string interpolation of `self.terminal.title` in closures needs explicit `self.`
- Mouse button enums: `GHOSTTY_MOUSE_LEFT` not `GHOSTTY_MOUSE_BUTTON_LEFT`
- `ghostty_surface_mouse_pos` takes 4 args (surface, x, y, mods), not 3
- `ghostty_surface_mouse_scroll` scroll mods param is `Int32`, not `ghostty_input_mods_e`

## Non-Obvious Learnings

### Adding New Swift Files

Both `PBXBuildFile` and `PBXFileReference` entries must be added to `Watchtower.xcodeproj/project.pbxproj` for each new `.swift` file. There are four places to update: PBXBuildFile section, PBXFileReference section, PBXGroup children list, and PBXSourcesBuildPhase files list. Missing any will cause build failures. Similarly, removing a file requires removing from all four places.

### LSP False Positives

After editing files that use ghostty C types, SourceKit reports ~90+ "Cannot find type" errors for all ghostty C types. These are false positives from the bridging header not being resolved by SourceKit. Ignore them.

### Menu Command Routing

`WatchtowerApp.swift` and `ContentView.swift` must change together when adding menu commands. The command definition lives in WatchtowerApp via `@FocusedValue(\.terminalViewModel)` but the logic lives in `TerminalContainerViewModel` inside `ContentView.swift`.

### Clipboard Callback

`write_clipboard_cb` receives a MIME array of `ghostty_clipboard_content_s` (each with `.mime` and `.data`). Must declare ALL pasteboard types first, then set data for each. Requires `import UniformTypeIdentifiers` for `UTType(mimeType:)` conversion.

### Programmatic Terminal Input

`ghostty_surface_text(surface, ptr, len)` sends text/commands to a terminal surface programmatically. Workspace scripts use this via Ghostty's surface config `command` field rather than running before the terminal opens.

## Ghostty Reference Implementation

Useful files in `ghostty/macos/Sources/Ghostty/`:

- `Ghostty.App.swift` — app lifecycle, runtime config setup
- `Surface View/SurfaceView_AppKit.swift` — NSView implementation, key/mouse handling
- `Surface View/SurfaceView.swift` — SwiftUI wrapper
- `NSEvent+Extension.swift` — NSEvent to ghostty key translation
- `Ghostty.Input.swift` — input helpers
- `Ghostty.Config.swift` — config management

## Temporary Files

Never read from or write to `/tmp` or any system temporary directory. If you need a temporary directory, use `.tmp/` in the project root (`/Users/markhuot/Sites/eyes/.tmp/`). Create it if it doesn't exist. This directory is gitignored and keeps all scratch files local to the project.

## Current State

- Build succeeds (both ghostty lib and Watchtower app)
- App sandbox is enabled with network client access; PTY spawning may need entitlement changes
- There are old `Eyes/` source files in the repo that should be ignored (the active code is in `Watchtower/Watchtower/`)

## CLI (Bun/TypeScript)

Located in `cli/` at the project root. Communicates with the running Watchtower app via Unix domain socket IPC.

### Build & Run

```bash
cd cli && bun install          # install deps (first time)
bun run src/index.ts --help    # run directly
bun build --compile src/index.ts --outfile watchtower  # compile to standalone binary
```

### Commands

- `watchtower new terminal [--directory <path>] [--command <cmd>]` — open a new terminal pane adjacent to the calling pane
- `watchtower new browser <url>` — open a new browser pane adjacent to the calling pane

### IPC Protocol

- Socket path: `~/.config/watchtower/watchtower.sock`
- JSON request/response over Unix domain socket
- Pane identification: `WATCHTOWER_PANE_ID` env var (UUID) is injected into every terminal surface by `GhosttyTerminalView.setupView()`
- Request format: `{"command": "new-terminal", "paneId": "<uuid>", "directory": "...", "command": "..."}`
- Response format: `{"success": true}` or `{"success": false, "error": "..."}`

### Source Files

| File | Purpose |
|---|---|
| `cli/src/index.ts` | Entry point, subcommand routing |
| `cli/src/ipc.ts` | Unix domain socket client, `sendCommand()`, `getPaneId()` |
| `cli/src/commands/new-terminal.ts` | `watchtower new terminal` command |
| `cli/src/commands/new-browser.ts` | `watchtower new browser` command |

### Xcode Project ID Scheme

Sequential human-readable IDs with prefix `AA`. Next available suffix: `0030`. Used suffixes: `002F` (IPCServer.swift build file and file reference).
