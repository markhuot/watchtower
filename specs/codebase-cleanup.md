# Codebase Cleanup

## Summary

A focused cleanup pass across the Watchtower Swift codebase: remove dead code and unused imports, unify duplicated patterns into shared helpers, extract the overgrown `TerminalContainerViewModel` into its own file, fix a handful of correctness/edge-case issues, and tighten up readability in a few specific spots. No new features — just paying down the tech debt accumulated during the rapid feature sprints for user actions and the command palette.

## Motivation

Watchtower went from "first terminal renders" to "command palette with fuzzy search and user-configurable actions" in a few days. That pace was appropriate — but it left behind dead code paths, copy-pasted helpers, and a 907-line `ContentView.swift` that mixes view layout with a 480-line view model containing terminal management, focus logic, command palette state, drag-and-drop, git detection, action discovery, and action execution.

None of this is broken, but it's starting to slow down changes. Two concrete examples:

1. Adding a new built-in command palette item means reading through `ContentView.swift` to find `allItems`, understanding its relationship with `executeAction()`, and hoping the `CommandPaletteItem.id = UUID()` regeneration doesn't break SwiftUI diffing. A cleanup makes the next feature cheaper.
2. Three separate places build `NSAlert` confirmation dialogs with near-identical code. The next confirmation dialog will be a fourth copy, or worse, subtly different from the others.

This spec is intentionally scoped to mechanical cleanup — no architectural redesigns, no new features. Each section is independently mergeable.

## Detailed Design

### 1. Dead Code Removal

Remove the following unreferenced symbols. Each was verified by searching the entire codebase for call sites.

| Symbol | File | Lines | Why it's dead |
|---|---|---|---|
| `removeTerminal(_ terminal:)` | `ContentView.swift` | 695–697 | Convenience overload; all callers use `removeTerminal(at:)` directly |
| `sizeDebounceWorkItem` | `GhosttyTerminalView.swift` | 142 | Property declared but never read or written |
| `updateTerminal(_:)` | `GhosttyTerminalView.swift` | 270–272 | Public method with no call sites |
| `hasProjectActions(for:)` | `ActionDiscovery.swift` | 36–38 | Never called |
| `reloadGlobalActions()` | `ActionDiscovery.swift` | 60–62 | Never called (global actions cache is never invalidated) |
| `WordList.swift` | `WordList.swift` | entire file | `WordList.randomName()` is never referenced; the file was a leftover from the new-workspace spec |

**Unused imports to remove:**

| Import | File | Reason |
|---|---|---|
| `import UniformTypeIdentifiers` | `ContentView.swift` (line 2) | Only `GhosttyAppManager.swift` uses `UTType` |
| `import UniformTypeIdentifiers` | `TerminalPaneView.swift` (line 2) | Same — not used in this file |

### 2. Logger Subsystem Consistency

Five files use `"com.eyes.Watchtower"` as the `Logger` subsystem — a stale reference to the pre-rename bundle ID:

- `GhosttyTerminalView.swift:116`
- `GhosttyAppManager.swift:14`
- `WorkspaceManager.swift:7`
- `ActionParser.swift:7`
- `ActionDiscovery.swift:7`

Replace all five with a single shared constant:

```swift
// In a new extension or at the top of an existing shared file
import os

extension Logger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.watchtower.app"
}
```

Then each file uses `Logger(subsystem: Logger.subsystem, category: "TerminalView")` (etc.). This ensures the subsystem stays in sync with the actual bundle identifier and eliminates the hardcoded string.

Since adding a new Swift file to the Xcode project requires four `pbxproj` edits (PBXBuildFile, PBXFileReference, PBXGroup children, PBXSourcesBuildPhase), the `Logger` extension should be added to an existing file rather than creating a new one. A good candidate is `WatchtowerApp.swift` since it's the app entry point and is already imported everywhere implicitly.

### 3. Shared Confirmation Alert Helper

Three places build nearly identical `NSAlert` confirmation dialogs:

1. **`WatchtowerApp.swift:113–128`** — quit confirmation ("You have running terminals…")
2. **`ContentView.swift:635–645`** — close pane confirmation (from view model)
3. **`GhosttyTerminalView.swift:362–377`** — Cmd+W close confirmation

Extract a shared helper:

```swift
extension NSAlert {
    /// Creates a confirmation alert with Cancel and a destructive action button.
    static func confirmation(
        message: String,
        informative: String,
        destructiveTitle: String = "Close"
    ) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = .warning
        alert.addButton(withTitle: destructiveTitle)
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}
```

Each call site reduces to:

```swift
let alert = NSAlert.confirmation(
    message: "Close this terminal?",
    informative: "The process is still running."
)
if alert.runModal() == .alertFirstButtonReturn { /* close */ }
```

Add this extension to `GhosttyTerminalView.swift` (which already has `NSView` extensions and is the largest consumer) or to `WatchtowerApp.swift`.

### 4. Unified Shell Execution Helper

`WorkspaceManager.runGitCommand()` (lines 33–64) and `ActionDialogView.runShellCommand()` (lines 240–270) both use an identical `Process` + `Pipe` + `withCheckedContinuation` + `waitUntilExit` pattern. Unify into a single async helper:

```swift
enum ShellError: Error {
    case nonZeroExit(Int32, stderr: String)
    case timeout
}

func runShellCommand(
    _ executable: String,
    arguments: [String],
    workingDirectory: String? = nil,
    timeout: Duration = .seconds(10)
) async throws -> String {
    // Process + Pipe setup, terminationHandler-based continuation,
    // stdout capture, stderr capture for error reporting
}
```

This also addresses the edge case that `ActionDialogView.runShellCommand()` currently has **no timeout** — a hung command blocks the dialog forever. The unified helper adds a configurable timeout with a sensible default.

Place this in `WorkspaceManager.swift` (rename to something like `ShellHelpers.swift` if desired, but avoiding new files is preferable per the AGENTS.md guidance on pbxproj edits). `WorkspaceManager` already owns the one shell-calling pattern; making it the home for the general version is natural.

### 5. Extract `TerminalContainerViewModel` to Its Own File

`ContentView.swift` is 907 lines. Roughly 480 of those are `TerminalContainerViewModel` — an `@Observable` class mixing:

- Terminal list management (add, remove, reorder)
- Focus tracking and pane navigation
- Command palette state and item computation
- Drag-and-drop state
- Git repo/branch detection
- Action discovery and execution

Extract `TerminalContainerViewModel` into `TerminalContainerViewModel.swift`. This is a pure move — no logic changes, no API changes, no renames. The only mechanical work is:

1. Move the class (and any private helpers it uses that aren't shared with `ContentView`) to the new file.
2. Add the four required entries to `Watchtower.xcodeproj/project.pbxproj`.
3. Add any necessary imports to the new file (`SwiftUI`, `os`, `UniformTypeIdentifiers` if needed).

The view model is already a standalone class with no file-private dependencies on `ContentView`'s body — it communicates entirely through `@Observable` properties.

### 6. Terminal Insertion Helper

`addTerminal()` (lines 680–692) and `executeAction()` (lines 887–899) in `ContentView.swift` both:

1. Create a `TerminalModel`
2. Insert it after the focused terminal
3. Set `focusedTerminalId` to the new terminal
4. Dispatch `makeFocused(index:)` on the next run loop

Extract a shared `insertAndFocusTerminal(_ terminal: TerminalModel)` method on `TerminalContainerViewModel`:

```swift
func insertAndFocusTerminal(_ terminal: TerminalModel) {
    let insertIndex = focusedIndex.map { $0 + 1 } ?? terminals.count
    terminals.insert(terminal, at: insertIndex)
    focusedTerminalId = terminal.id
    let targetIndex = insertIndex
    DispatchQueue.main.async { [weak self] in
        self?.makeFocused(index: targetIndex)
    }
}
```

`addTerminal()` becomes `insertAndFocusTerminal(TerminalModel())`.  
`executeAction()` becomes `insertAndFocusTerminal(TerminalModel(command: command))`.

### 7. Color Conversion Helper

`readBackgroundColor()` and `readHighlightColor()` in `GhosttyAppManager.swift` repeat the same `ghostty_config_color_s` → `Color` conversion (read config key into a color struct, divide RGB by 255, construct `Color`). Extract:

```swift
private func configColor(forKey key: String) -> Color? {
    var color = ghostty_config_color_s()
    let found = ghostty_config_get(config, &color, key, UInt(key.utf8.count))
    guard found else { return nil }
    return Color(
        red: Double(color.r) / 255.0,
        green: Double(color.g) / 255.0,
        blue: Double(color.b) / 255.0
    )
}
```

Then `readBackgroundColor()` and `readHighlightColor()` each become one-liners.

### 8. Duplicate Parse Functions in ActionParser

`parseArgumentValue()` and `parseKeyValueAnnotation()` in `ActionParser.swift` (lines 198–214) are identical functions with different names — both split a string on `=` and return a `(key, value)` tuple. Remove `parseArgumentValue()` and update its one call site to use `parseKeyValueAnnotation()` instead (or vice versa — pick whichever name is clearer and keep that one).

### 9. Correctness Fixes

**9a. `makeFocused(index:)` bounds check**

`ContentView.swift:804` — `makeFocused(index:)` does not check that `index` is within `terminals.count`. If a terminal is removed between the `DispatchQueue.main.async` dispatch and execution, this could crash. Add a guard:

```swift
func makeFocused(index: Int) {
    guard index >= 0, index < terminals.count else { return }
    // ... existing logic
}
```

**9b. `CommandPaletteItem.id` stability**

`CommandPaletteItem.id = UUID()` is generated fresh each time `allItems` is computed. Since `allItems` is a computed property called on every keystroke in the palette, SwiftUI sees entirely new items each time, defeating its diffing and causing unnecessary view rebuilds.

Change `id` to be derived from the item's content:

```swift
struct CommandPaletteItem: Identifiable {
    let id: String  // e.g. "builtin:new-terminal" or "action:my-script.sh"
    // ...
}
```

This gives SwiftUI stable identifiers across recomputations and enables proper list animations.

**9c. `DragSourceNSView.terminal` implicitly unwrapped optional**

`DragSourceNSView` declares `var terminal: TerminalModel!` — if accessed before assignment, this crashes. Change to a non-optional with a required initializer, or change to an explicit optional with proper `guard let` unwrapping at use sites.

**9d. Silent failure in `executeAction()`**

When `buildCommand()` returns `nil`, `executeAction()` silently returns with no user feedback. At minimum, log a warning. Ideally, show a brief inline error (e.g., a transient status message or an alert).

### 10. Readability Improvements

**10a. Clean up debugging comment in `readClipboard()`**

`GhosttyAppManager.swift:418–433` has a 15-line stream-of-consciousness debugging comment ("I know this is weird...", "Let me explain..."). Condense to 2–3 lines explaining *what* the workaround is and *why* it's needed.

**10b. Simplify double-negative in `ActionDialogView`**

`fieldValues[varName]?.isEmpty != false` → `fieldValues[varName]?.isEmpty ?? true` or better, `!(fieldValues[varName]?.isEmpty == false)` → extract to a helper like `fieldIsEmpty(varName)`.

**10c. Double-nested `DispatchQueue.main.async` in `dismissCommandPalette()`**

The nested dispatch is fragile and the comment explaining it suggests it's a timing workaround. Document *exactly* what race it's avoiding, or replace with a `DispatchQueue.main.asyncAfter(deadline: .now())` which is equivalent but makes the "next run loop" intent explicit.

## Open Questions

1. **New file vs. extension in existing file for shared helpers.** The AGENTS.md notes that adding Swift files requires four `pbxproj` edits. Section 5 (ViewModel extraction) requires a new file and is worth the cost. But should the `NSAlert.confirmation` helper and the `Logger.subsystem` constant also go in new files, or tuck into existing ones? This spec recommends existing files to minimize pbxproj churn.

2. **`reloadGlobalActions()` — remove or fix?** This spec lists it as dead code for removal. But the *intent* (invalidating the global actions cache when files change) is valid. Should we instead wire it up to an `FSEvents` watcher? That feels like a feature addition and is out of scope for this cleanup, but worth noting.

3. **`ShellHelpers` naming.** Should the unified shell helper live in `WorkspaceManager.swift` (keeping file count down) or in a new `ShellHelpers.swift`? This spec recommends the former.

## Implementation Plan

The sections are ordered so each can be merged independently without conflicting with the others. If done sequentially, this order minimizes merge conflicts:

1. **Dead code removal** (Section 1) — pure deletions, no dependencies.
2. **Logger subsystem** (Section 2) — string replacements across 5 files.
3. **Duplicate parse function** (Section 8) — single-file change in `ActionParser.swift`.
4. **Color conversion helper** (Section 7) — single-file change in `GhosttyAppManager.swift`.
5. **Shared confirmation alert** (Section 3) — add helper, update 3 call sites.
6. **Unified shell execution** (Section 4) — consolidate 2 call sites, add timeout.
7. **Terminal insertion helper** (Section 6) — refactor within `ContentView.swift` / view model.
8. **Correctness fixes** (Section 9) — four independent fixes.
9. **Readability improvements** (Section 10) — three independent touch-ups.
10. **Extract ViewModel** (Section 5) — do last since it moves code other sections may have touched.

## Files to Create or Modify

| File | Action | Sections |
|---|---|---|
| `Watchtower/Watchtower/ContentView.swift` | Modify | 1, 3, 5, 6, 9a, 9b |
| `Watchtower/Watchtower/GhosttyTerminalView.swift` | Modify | 1, 3, 10c |
| `Watchtower/Watchtower/GhosttyAppManager.swift` | Modify | 2, 7, 10a |
| `Watchtower/Watchtower/WorkspaceManager.swift` | Modify | 2, 4 |
| `Watchtower/Watchtower/ActionParser.swift` | Modify | 2, 8 |
| `Watchtower/Watchtower/ActionDiscovery.swift` | Modify | 1, 2 |
| `Watchtower/Watchtower/ActionDialogView.swift` | Modify | 4, 10b |
| `Watchtower/Watchtower/WatchtowerApp.swift` | Modify | 2, 3 |
| `Watchtower/Watchtower/TerminalPaneView.swift` | Modify | 1 |
| `Watchtower/Watchtower/TerminalContainerViewModel.swift` | Create | 5 |
| `Watchtower/Watchtower/WordList.swift` | Delete | 1 |
| `Watchtower.xcodeproj/project.pbxproj` | Modify | 1 (remove WordList), 5 (add ViewModel file) |
