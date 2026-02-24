# Command Palette

## Summary

Add a command palette (Cmd+K) that provides quick, fuzzy-searchable access to all Watchtower commands — built-in actions like "New Terminal" and "Close Terminal", macOS window commands like "Toggle Full Screen", plus any custom actions discovered for the focused terminal's directory. The palette appears as a floating overlay on top of the currently focused terminal pane, with the pane's focus outline redrawn around the overlay to make it visually clear which pane the palette is acting on. Results update as the user types, capped at 10 visible items with a "More..." indicator when results are truncated.

## Motivation

The toolbar dropdown menu works well for discoverability, but it doesn't scale. As users accumulate project and global actions, a scrolling dropdown becomes unwieldy. More importantly, keyboard-driven users — the primary audience for a terminal app — shouldn't have to reach for the mouse to trigger an action.

The user-actions spec (see `specs/user-actions.md`, Open Questions #2) explicitly noted a command palette as the natural next step:

> A future command palette (Cmd+K or similar) would be a natural way to access actions without the toolbar dropdown. When the command palette is implemented, actions should appear as searchable entries.

A command palette also provides a single, consistent surface for *all* commands — not just custom actions, but built-in operations like creating or closing terminals and standard macOS window commands. This unifies the keyboard shortcut system with the actions system.

## Detailed Design

### 1. Invocation and Dismissal

**Open:** Cmd+K toggles the command palette. If it's closed, it opens. If it's open, it closes. This shortcut is defined in `WatchtowerApp.swift`'s `.commands {}` block using the existing `@FocusedValue(\.terminalViewModel)` pattern.

**Dismiss:** The palette closes on:
- **Escape** — cancel, do nothing.
- **Enter** — execute the selected command, then close.
- **Cmd+K** — toggle off.
- **Clicking outside** the palette overlay.
- **Focusing a different pane** — clicking another pane's header or using Cmd+Shift+[ / Cmd+Shift+] to navigate between panes dismisses the palette. This is handled by having `focusTerminal(id:)` and `focusPreviousPane()` / `focusNextPane()` call `dismissCommandPalette()` when the palette is open.

**Focus restoration:** When the palette closes (by any means), keyboard focus returns to the previously focused terminal surface. This uses the existing `makeFocused(index:)` mechanism on `TerminalContainerViewModel`, which walks the NSView hierarchy and calls `window.makeFirstResponder(targetView)`.

### 2. Visual Design

The palette is a floating overlay positioned on top of the currently focused terminal pane, horizontally centered within that pane and near its top edge. The pane's existing focus outline (the `RoundedRectangle` stroke border drawn by `TerminalPaneView`) is redrawn around the palette overlay instead, making it immediately obvious which pane the command will act on.

```
┌──────────────────────────────────────────────────────┐
│                                                      │
│  ┌────────────┐ ┌────────────────────────┐ ┌──────┐ │
│  │  terminal   │ │ ╔══════════════════╗   │ │ term │ │
│  │  pane 1     │ │ ║ Filter commands… ║   │ │ pane │ │
│  │             │ │ ╠══════════════════╣   │ │  3   │ │
│  │             │ │ ║▸New Terminal  ⌘T ║   │ │      │ │
│  │             │ │ ║ Close Pane   ⌘W ║   │ │      │ │
│  │             │ │ ║ Full Screen  ⌃⌘F ║   │ │      │ │
│  │             │ │ ║ Rails Console    ║   │ │      │ │
│  │             │ │ ║     [project]    ║   │ │      │ │
│  │             │ │ ║ SSH Dev Box      ║   │ │      │ │
│  │             │ │ ║     [global]     ║   │ │      │ │
│  │             │ │ ╚══════════════════╝   │ │      │ │
│  │             │ │  focused pane 2        │ │      │ │
│  └────────────┘ └────────────────────────┘ └──────┘ │
└──────────────────────────────────────────────────────┘
```

The double-line border (╔═╗) represents the focus outline being drawn around the palette overlay rather than the pane itself.

**Layout constraints:**
- Max width: 500pt, but constrained to the focused pane's width minus padding if the pane is narrower.
- Positioned near the top of the focused pane (approximately 5% from the pane's top edge), horizontally centered within the pane.
- The results list shows a maximum of 10 items. If there are more matches, a "More..." row appears at the bottom (see Section 4).
- Background uses `.ultraThinMaterial` with a rounded corner radius and subtle shadow, consistent with the app's dark theme.

**Focus outline behavior:** When the palette is open, `TerminalPaneView`'s focus outline is hidden on the focused pane — the existing `highlightBorderColor` and `highlightShadowColor` computed properties return `Color.clear` when the palette is active. The `CommandPaletteView` draws its own border using the same visual style: `appManager.highlightColor` stroke (2pt), same corner radius, and the same `appManager.highlightColor.opacity(0.6)` shadow glow. There is no animated transition between the two outlines — the pane outline simply disappears and the palette outline appears independently. When the palette closes, the pane outline reappears as normal.

**Visual treatment of rows:**
- Each row shows the command name on the left.
- Built-in commands show their keyboard shortcut on the right (e.g., `⌘T`, `⌘W`, `⌃⌘F`).
- Custom actions show a subtle `[project]` or `[global]` tag on the right. This replaces section dividers — every row is self-describing.
- The selected row is highlighted. The first row is selected by default.
- Rows with descriptions (from `@description`) show the description as subtitle text below the command name, in a dimmer color.
- When fuzzy matching is active, the matched characters in the command name are highlighted (bold or accent color) to show why the result matched.

### 3. Command List

The palette presents a flat, unified list of commands. There are no section dividers — each row carries its own `[project]`/`[global]` tag for orientation. The ordering is:

1. **Built-in commands** — always present, always first:

   | Command | Action | Shortcut |
   |---|---|---|
   | New Terminal | `viewModel.addTerminal()` | ⌘T |
   | Close Terminal | Close the focused pane (via `closeCurrentPane()`) | ⌘W |
   | Toggle Full Screen | `NSApp.keyWindow?.toggleFullScreen(nil)` | ⌃⌘F |
   | Minimize | `NSApp.keyWindow?.miniaturize(nil)` | ⌘M |
   | Zoom | `NSApp.keyWindow?.zoom(nil)` | — |

2. **Project actions** — from `.watchtower/actions/` for the focused terminal's directory (same list as `viewModel.projectActions`). Each row tagged `[project]`.

3. **Global actions** — from `~/.config/watchtower/actions/` (same list as `viewModel.globalActions`). Each row tagged `[global]`.

**Why these built-in commands:** New Terminal and Close Terminal are the most common pane-management operations. Toggle Full Screen, Minimize, and Zoom are standard macOS window commands that users expect to find in a command palette — they're especially useful on systems where the green traffic-light button behavior has been customized. Focus navigation (previous/next pane, toggle focus mode) already has dedicated keyboard shortcuts and is less useful as a searchable command. Additional built-in commands can be added later without changing the architecture.

### 4. Filtering

As the user types in the search field, the list filters in real-time using fuzzy matching. The query characters must appear in order within the candidate string, but not necessarily contiguously.

**Fuzzy matching algorithm:**

A command matches if every character in the query appears (case-insensitively) in the command's display name or description, in order. The fuzzy matcher runs against both fields independently:

- **Name match** — the query is matched against the command's display name.
- **Description match** — the query is matched against the command's description text (if present).

A command is included in results if *either* match succeeds. When both match, the name match score is used (name matches always rank higher than description-only matches). This ensures that typing "mysql" surfaces "New MySQL Terminal" (name match) above a command whose description mentions MySQL.

For example:
- `mysql` matches "New **M**y**SQL** Terminal" (characters m-y-s-q-l appear in order in the name)
- `newt` matches "**New** **T**erminal" and "**New** MySQL **T**erminal" (characters n-e-w-t appear in order)
- `rc` matches "**R**ails **C**onsole"

When the match is in the name, matched characters in the name are highlighted (bold or accent color). When the match is description-only, matched characters in the description subtitle are highlighted instead.

**Scoring:** Matches are scored to rank better matches higher. The scoring heuristics:
1. **Consecutive character bonus** — matches where query characters are adjacent score higher (a substring match scores best).
2. **Word-boundary bonus** — matching at the start of a word (after a space, hyphen, or at the start of the string) scores higher.
3. **Prefix bonus** — matching from the start of the string scores higher.

These are the same heuristics used by most command palette implementations (VS Code, Sublime Text, etc.). The scoring function is isolated — it takes a query string and a candidate string and returns an optional score (nil = no match). This makes it testable and swappable.

**Results cap:** The filtered list shows a maximum of **10 results**. If there are more matches beyond 10, a non-selectable "More..." row appears at the bottom of the list, styled in a dimmer color. This row is not interactive — it's a visual indicator that the user should refine their query. The "More..." row does not count toward the 10-result limit (so the user sees 10 selectable rows + 1 indicator row).

When the search field is empty, the full command list is shown. If the full list exceeds 10 items, the same 10-item cap and "More..." indicator apply — the palette always shows at most 10 selectable rows.

If no commands match the query, a single row shows "No matching commands" in a dimmed style.

### 5. Keyboard Navigation

The palette is fully keyboard-navigable:

| Key | Behavior |
|---|---|
| **Up Arrow** / **Ctrl+P** | Move selection to previous item (wraps to bottom) |
| **Down Arrow** / **Ctrl+N** | Move selection to next item (wraps to top) |
| **Enter** | Execute selected command |
| **Escape** | Close palette, do nothing |
| **Tab** / **Shift+Tab** | Intercepted, does nothing (prevents focus from escaping the palette) |

The "More..." indicator row is skipped during keyboard navigation — it's not selectable.

When the selected row changes, the list scrolls to keep it visible (using `ScrollViewReader`).

### 6. Action Execution from the Palette

When a command is selected and executed:

- **Built-in commands** run their action closure directly (e.g., `addTerminal()`, `closeCurrentPane()`, `toggleFullScreen()`). The palette closes, focus returns to the terminal.
- **Custom actions without arguments** execute immediately, following the same path as the toolbar dropdown — `viewModel.triggerAction(action)` creates a new terminal pane running the script.
- **Custom actions with arguments** close the palette and open the existing action dialog sheet (`ActionDialogView`). This reuses the existing `viewModel.triggerAction(action)` path, which already handles the "has arguments -> show dialog" branch. Focus returns to the terminal after the dialog is dismissed.

This means the command palette doesn't need its own argument input UI. The palette is a launcher — it picks the command — and the existing dialog handles parameterized commands. This keeps the palette simple and avoids duplicating the argument resolution logic (async `$()` defaults, `@options` dropdowns, error hints).

### 7. Close Terminal Mechanics

The "Close Terminal" command in the palette cannot simply call `GhosttyTerminalNSView.performClose(_:)` directly — the palette is a SwiftUI overlay and doesn't have a reference to the NSView. Instead, the close logic needs to be extracted into the view model.

Add a `closeCurrentPane()` method on `TerminalContainerViewModel` that replicates the `performClose` logic:

```swift
func closeCurrentPane() {
    guard let focusedTerminal = terminals.first(where: { $0.isFocused }) else { return }
    guard let window = NSApp.keyWindow,
          let contentView = window.contentView else { return }

    let terminalViews = GhosttyTerminalNSView.findAllTerminalViews(in: contentView)

    if terminalViews.count > 1 {
        // Multiple panes — find the focused NSView and check for active session.
        if let targetView = terminalViews.first(where: { $0.terminal.id == focusedTerminal.id }),
           let surface = targetView.surface,
           ghostty_surface_needs_confirm_quit(surface) {
            // Show confirmation alert, then call removeTerminal(byId:) on confirm.
            let alert = NSAlert()
            alert.messageText = "Close Terminal?"
            alert.informativeText = "This terminal has an active session. Closing it will terminate the session."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    self?.removeTerminal(byId: focusedTerminal.id)
                }
            }
        } else {
            removeTerminal(byId: focusedTerminal.id)
        }
    } else {
        // Single pane — close the window.
        window.performClose(nil)
    }
}
```

This mirrors the existing `performClose` at `GhosttyTerminalView.swift:349-388` but is callable from the view model layer. Unlike the NSView's `performClose`, which posts a `.ghosttySurfaceClosed` notification (because the NSView can't access the view model), `closeCurrentPane()` calls `removeTerminal(byId:)` directly — it's already on the view model, so no notification indirection is needed. The key dependency is accessing the `GhosttyTerminalNSView` to call `ghostty_surface_needs_confirm_quit(surface)` — this uses the same `findAllTerminalViews(in:)` + terminal ID matching pattern already used by `makeFocused(index:)`.

The existing `performClose` on the NSView remains unchanged — Cmd+W still works through the responder chain as before. The palette's "Close Terminal" command is an alternative entry point to the same behavior.

### 8. Focus Management and First Responder

**Contextual terminal resolution:** When the palette is open, its NSTextField is the first responder — no terminal has `isFocused == true`. Any code that resolves the "current" terminal via `terminals.first(where: { $0.isFocused })` will return `nil` and fall back to defaults (e.g., `NSHomeDirectory()` for the working directory). This caused actions invoked from the palette to start in the wrong directory ("file does not exist") while the same action worked from the toolbar button.

The fix is `contextualTerminal` on `TerminalContainerViewModel`, which checks `commandPaletteTerminalId` first (since the palette tracks which terminal it was opened on), then falls back to `isFocused`:

```swift
var contextualTerminal: TerminalModel? {
    if let paletteId = commandPaletteTerminalId,
       let t = terminals.first(where: { $0.id == paletteId }) {
        return t
    }
    return terminals.first(where: { $0.isFocused })
}
```

All methods that need the "current" terminal — `focusedDirectory`, `addTerminal()`, `executeAction()`, `closeCurrentPane()`, `toggleFocusMode()` — must use `contextualTerminal` instead of the direct `isFocused` lookup.

Additionally, `executeSelected()` in `CommandPaletteView` must run the action **before** calling `dismissCommandPalette()`, so that `commandPaletteTerminalId` is still set when `contextualTerminal` is evaluated during action execution.

**Stealing focus on open:** When the palette appears, its text field must become the first responder so the user can type immediately. SwiftUI's `@FocusState` doesn't reliably make an overlay's text field first responder on macOS. The solution is an `NSViewRepresentable` focus injector — a tiny invisible NSView that calls `window.makeFirstResponder(textField)` when it appears.

Concretely, `CommandPaletteView` wraps its `NSTextField` (via `NSViewRepresentable`) rather than using a SwiftUI `TextField`. This gives direct control over first responder status:

```swift
struct CommandPaletteTextField: NSViewRepresentable {
    @Binding var text: String
    var onArrowUp: () -> Void
    var onArrowDown: () -> Void
    var onSubmit: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.placeholderString = "Filter commands..."
        // ... styling
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Become first responder when view appears
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}
```

The `NSTextField` delegate (the coordinator) intercepts arrow keys, Enter, Escape, and Tab/Shift-Tab in `control(_:textView:doCommandBy:)` and routes them to the palette's keyboard navigation handlers. Tab and Shift-Tab are consumed (returning `true` from the delegate method) to prevent focus from escaping the text field. All other keystrokes flow through normal text editing.

**Restoring focus on close:** When the palette is dismissed (by any means), focus must return to the previously focused terminal surface. The palette's dismissal path sets `isCommandPalettePresented = false`, and the view model restores focus:

```swift
func dismissCommandPalette() {
    isCommandPalettePresented = false
    // Restore focus to the currently focused terminal
    if let index = terminals.firstIndex(where: { $0.isFocused }) {
        makeFocused(index: index)
    }
}
```

This reuses the existing `makeFocused(index:)` at `ContentView.swift:695`, which finds the matching `GhosttyTerminalNSView` and calls `window.makeFirstResponder(targetView)`.

### 9. Click-Outside Dismissal

Clicking outside the palette should dismiss it. Because the palette is overlaid on a specific terminal pane (not the entire window), the dismissal layer covers just the focused pane's area behind the palette:

```swift
// Inside the focused pane's overlay
if viewModel.isCommandPalettePresented && terminal.isFocused {
    // Dismiss layer — covers the pane area behind the palette
    Color.clear
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.dismissCommandPalette()
        }

    // Palette itself — positioned near top of the pane, centered
    CommandPaletteView(viewModel: viewModel)
        .frame(maxWidth: min(500, paneWidth - 20))
        .padding(.top, paneHeight * 0.05)
        .transition(.opacity.combined(with: .move(edge: .top)))
}
```

Clicks on other (non-focused) panes go through the normal click-to-focus flow (`onHeaderTapped` -> `focusTerminal(id:)`), which dismisses the palette as part of the focus change (see Section 1).

### 10. Animation

The palette appears and disappears with a combined opacity fade and slight downward slide:

```swift
.transition(.opacity.combined(with: .move(edge: .top)))
.animation(.easeOut(duration: 0.15), value: viewModel.isCommandPalettePresented)
```

The animation is fast (150ms) to feel responsive — this is a utility UI, not a modal dialog. The slide direction (from top) reinforces the palette's position near the top of the pane.

### 11. Empty State

When no custom actions are discovered (no project or global actions), the palette shows only the built-in commands:

```
╔══════════════════════════════════════╗
║ Filter commands...                    ║
╠══════════════════════════════════════╣
║ ▸ New Terminal                  ⌘T   ║
║   Close Terminal                ⌘W   ║
║   Toggle Full Screen           ⌃⌘F   ║
║   Minimize                     ⌘M   ║
║   Zoom                               ║
╚══════════════════════════════════════╝
```

No tags are shown on built-in commands (they don't need a `[project]`/`[global]` label — they're self-evidently built-in). The palette is still useful in this state — it provides keyboard access to common pane and window operations. There is no "empty" placeholder or suggestion to add actions; the palette simply shows what's available.

### 12. Multiple Windows

Each window has its own `TerminalContainerViewModel` (created by `ContentView`), so `isCommandPalettePresented` is per-window. Opening the palette in one window does not affect other windows. The Cmd+K shortcut routes through `@FocusedValue(\.terminalViewModel)`, which resolves to the key window's view model — the same pattern used by all existing menu commands.

Each window's palette shows the actions relevant to *that window's* focused terminal. Two windows focused on terminals in different projects will show different action lists. This is consistent with how the toolbar dropdown already behaves.

### 13. State Management

Add to `TerminalContainerViewModel`:

```swift
@Published var isCommandPalettePresented: Bool = false
```

Add a toggle method and wiring into focus-change methods:

```swift
func toggleCommandPalette() {
    isCommandPalettePresented.toggle()
}

func focusTerminal(id: UUID) {
    if isCommandPalettePresented { dismissCommandPalette() }
    // ... existing focus logic
}

func focusPreviousPane() {
    if isCommandPalettePresented { dismissCommandPalette() }
    // ... existing logic
}

func focusNextPane() {
    if isCommandPalettePresented { dismissCommandPalette() }
    // ... existing logic
}
```

The palette view reads `viewModel.actions`, `viewModel.projectActions`, and `viewModel.globalActions` directly — no additional data flow is needed. These properties already exist and are reactively updated when the focused terminal's directory changes.

### 14. Responder Chain Considerations

The command palette's `NSTextField` (see Section 8) becomes the first responder when the palette opens. This means key events flow to the text field and **not** to the Ghostty terminal surface — typing a filter query does not send keystrokes to the terminal. This is the correct and expected behavior.

Cmd+K needs to work both to *open* the palette (when the terminal is first responder) and to *close* it (when the palette's text field is first responder). Because the shortcut is defined as a SwiftUI `.commands {}` menu shortcut, it routes through the application menu system, which sits above the responder chain. This means it works regardless of which view is first responder.

Arrow keys, Enter, and Escape are intercepted by the `NSTextField` delegate (see Section 8) and routed to palette navigation rather than being inserted as text. All other keystrokes flow through normal text editing.

### 15. Overlay Positioning Within a Pane

The palette overlay lives inside the `TerminalPaneView` hierarchy, not as a window-level overlay. This is important because:

1. **Positioning** — the palette is centered within and constrained to the focused pane's geometry, not the window. If the pane is 400pt wide, the palette is at most 380pt wide (400 - 20pt padding). If the pane is 600pt wide, the palette uses its max width of 500pt.
2. **Focus outline** — `TerminalPaneView` owns the focus outline and can suppress it when the palette is open. The palette draws its own matching outline independently (see Section 2).
3. **Scroll position** — the palette is inside the `ScrollView`'s content, so it scrolls with the pane. This is correct — if the user scrolls horizontally, the palette stays attached to its pane rather than floating in an arbitrary position.

**Clipping:** `TerminalPaneView` applies `.clipShape(RoundedRectangle(...))` to its VStack, which would clip any overlay that exceeds the pane bounds. The palette overlay must be added *outside* the clip shape — as a sibling in a `ZStack`, not as a child of the clipped VStack. The structure is:

```swift
// In TerminalPaneView
ZStack(alignment: .top) {
    // Existing pane content (header + terminal surface) — retains its .clipShape()
    VStack(spacing: 0) { ... }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(/* focus outline — hidden when palette is open */)

    // Command palette overlay (only on the focused pane) — outside the clip shape
    if viewModel.isCommandPalettePresented && terminal.isFocused {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { viewModel.dismissCommandPalette() }

        CommandPaletteView(viewModel: viewModel)
            .frame(maxWidth: min(500, terminal.paneWidth - 20))
            .padding(.top, paneHeight * 0.05)
    }
}
```

This ensures the palette is positioned relative to the pane but is not clipped by it. The palette's own background and outline handle its visual boundaries.

**ViewModel plumbing:** `TerminalPaneView` currently accepts only `terminal: TerminalModel` and two optional closures. To support the palette overlay, the view model must be passed in. `TerminalPaneWithHandle` already holds a `viewModel` reference and constructs `TerminalPaneView`, so it passes the view model through as a new `@ObservedObject var viewModel: TerminalContainerViewModel` parameter. This is a simple parameter addition — no architectural change.

### 16. Palette During Focus Mode

When focus mode is active, the palette should still be accessible via Cmd+K and should still show the full command list. Selecting "New Terminal" or an action while in focus mode should exit focus mode (since a new pane is being added). This matches the expected behavior — you're breaking out of single-pane focus to do something new.

## Open Questions

### 1. Fuzzy matching performance

The fuzzy matching algorithm is O(n*m) per candidate (n = query length, m = candidate length), applied to every command in the list on every keystroke. With the expected scale (tens of commands), this is not a performance concern. If the command list grows to hundreds of items, debouncing the input or caching scores may be worth revisiting — but the 10-result cap means rendering is always fast regardless of list size.

## Implementation Plan

1. **Fuzzy matching function** — implement a standalone `fuzzyMatch(query: String, candidate: String) -> (score: Int, matchedIndices: [Int])?` function. Returns nil for no match, or a score + the indices of matched characters for highlighting. The function must return matched indices from the start — this is required for the UI's character highlighting, not an optional enhancement. This is a pure function with no dependencies — it can be unit tested independently.
2. **Command palette data model** — define a `CommandPaletteItem` struct representing a single row (display name, optional description, optional keyboard shortcut string, optional source tag `[project]`/`[global]`, action closure). Add a method on `TerminalContainerViewModel` that builds the full command list from built-in commands (including macOS window commands) + discovered actions.
3. **Close terminal method** — extract the close/confirmation logic from `GhosttyTerminalNSView.performClose` into a `closeCurrentPane()` method on `TerminalContainerViewModel` (see Section 7). This is needed before the palette can offer "Close Terminal" as a command.
4. **Command palette NSTextField** — implement `CommandPaletteTextField` as an `NSViewRepresentable` wrapping an `NSTextField` with first responder management and key event interception for arrow keys, Enter, Escape, and Tab/Shift-Tab (see Section 8).
5. **Command palette view** — `CommandPaletteView.swift` as a SwiftUI view composing the `NSTextField`, a fuzzy-filtered list of rows (max 10 + "More..." indicator), keyboard navigation, and match character highlighting. Styled with `.ultraThinMaterial` background, max width 500pt (capped to pane width). Include the click-outside dismissal layer (see Section 9) and entry/exit animation (see Section 10).
6. **State management** — add `isCommandPalettePresented: Bool`, `toggleCommandPalette()`, and `dismissCommandPalette()` to `TerminalContainerViewModel`. `dismissCommandPalette()` restores focus to the terminal via `makeFocused(index:)`.
7. **Wire into TerminalPaneView** — present the palette as a `ZStack` overlay inside `TerminalPaneView`, gated on `viewModel.isCommandPalettePresented && terminal.isFocused`. Modify the focus outline overlay to draw around the palette instead of the pane when the palette is open.
8. **Keyboard shortcut** — add Cmd+K to `WatchtowerApp.swift`'s `.commands {}` block, calling `activeViewModel?.toggleCommandPalette()`.
9. **Action execution** — route built-in commands to their existing methods (`addTerminal()`, `closeCurrentPane()`) and macOS window commands to their `NSWindow` selectors; route custom actions through `viewModel.triggerAction(action)` (reusing the existing toolbar/dialog flow).

## Files to Create or Modify

| File | Action | Description |
|---|---|---|
| `CommandPaletteView.swift` | Create | SwiftUI view: `CommandPaletteTextField` (`NSViewRepresentable` wrapping `NSTextField` with first responder and key interception), fuzzy-filtered command list (max 10 rows + "More..." indicator), match character highlighting, keyboard navigation with `ScrollViewReader`, click-outside dismissal layer, material background styling, entry/exit animation |
| `FuzzyMatch.swift` | Create | Standalone `fuzzyMatch(query:candidate:)` function returning optional `(score: Int, matchedIndices: [Int])`. Pure function, no dependencies, unit-testable |
| `TerminalPaneView.swift` | Modify | Add `viewModel` parameter (`@ObservedObject`), add `ZStack` overlay for the command palette on the focused pane (outside `.clipShape` to avoid clipping), suppress focus outline when palette is open by returning `Color.clear` from `highlightBorderColor`/`highlightShadowColor` |
| `ContentView.swift` | Modify | Pass `viewModel` to `TerminalPaneView` so it can check `isCommandPalettePresented` and invoke palette actions |
| `TerminalContainerViewModel` (in `ContentView.swift`) | Modify | Add `isCommandPalettePresented: Bool`, `toggleCommandPalette()`, `dismissCommandPalette()` (with focus restoration), `closeCurrentPane()` (extracted from `performClose` logic), and a method to build the unified command list from built-ins + macOS window commands + actions |
| `WatchtowerApp.swift` | Modify | Add Cmd+K keyboard shortcut in `.commands {}` calling `activeViewModel?.toggleCommandPalette()` |
| `GhosttyTerminalView.swift` | No change | Existing `performClose` remains for Cmd+W; palette uses the new `closeCurrentPane()` on the view model instead |
| `ActionDialogView.swift` | No change | Reused as-is for parameterized actions launched from the palette |
| `Action.swift` | No change | Existing model provides all data the palette needs (`displayName`, `descriptionText`, `hasArguments`, `isGlobal`) |
| `ActionDiscovery.swift` | No change | Existing discovery pipeline feeds `viewModel.actions`, which the palette reads directly |
