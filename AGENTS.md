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
| `WatchtowerApp.swift` | App entry point, initializes GhosttyAppManager |
| `ContentView.swift` | Horizontal ScrollView of terminal panes |
| `TerminalModel.swift` | Class (not struct) with @Published properties for terminal state |
| `TerminalPaneView.swift` | Individual pane UI, uses GeometryReader to pass size |
| `GhosttyTerminalView.swift` | NSView + NSTextInputClient + NSViewRepresentable wrapping a ghostty surface |
| `GhosttyAppManager.swift` | Singleton managing `ghostty_app_t`, runtime callbacks |
| `GhosttyBridge.h` | Bridging header, `#include`s ghostty.h |

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

## Ghostty Reference Implementation

Useful files in `ghostty/macos/Sources/Ghostty/`:

- `Ghostty.App.swift` — app lifecycle, runtime config setup
- `Surface View/SurfaceView_AppKit.swift` — NSView implementation, key/mouse handling
- `Surface View/SurfaceView.swift` — SwiftUI wrapper
- `NSEvent+Extension.swift` — NSEvent to ghostty key translation
- `Ghostty.Input.swift` — input helpers
- `Ghostty.Config.swift` — config management

## Current State

- Build succeeds (both ghostty lib and Watchtower app)
- Not yet tested at runtime
- App sandbox is enabled with network client access; PTY spawning may need entitlement changes
- There are old `Eyes/` source files in the repo that should be ignored (the active code is in `Watchtower/Watchtower/`)
