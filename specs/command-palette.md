# Command Palette

## Summary

Add a command palette (Cmd+K) that provides quick, searchable access to all Watchtower commands — built-in actions like "New Terminal" and "Close Terminal", plus any custom actions discovered for the focused terminal's directory. The palette appears as a floating overlay at the top of the window, accepts text filtering, and supports keyboard-only navigation.

## Motivation

The toolbar dropdown menu works well for discoverability, but it doesn't scale. As users accumulate project and global actions, a scrolling dropdown becomes unwieldy. More importantly, keyboard-driven users — the primary audience for a terminal app — shouldn't have to reach for the mouse to trigger an action.

The user-actions spec (see `specs/user-actions.md`, Open Questions #2) explicitly noted a command palette as the natural next step:

> A future command palette (Cmd+K or similar) would be a natural way to access actions without the toolbar dropdown. When the command palette is implemented, actions should appear as searchable entries.

A command palette also provides a single, consistent surface for *all* commands — not just custom actions, but built-in operations like creating or closing terminals, toggling focus mode, and navigating between panes. This unifies the keyboard shortcut system with the actions system.

## Detailed Design

### 1. Invocation and Dismissal

**Open:** Cmd+K toggles the command palette. If it's closed, it opens. If it's open, it closes. This shortcut is defined in `WatchtowerApp.swift`'s `.commands {}` block using the existing `@FocusedValue(\.terminalViewModel)` pattern.

**Dismiss:** The palette closes on:
- **Escape** — cancel, do nothing.
- **Enter** — execute the selected command, then close.
- **Cmd+K** — toggle off.
- **Clicking outside** the palette overlay.

**Focus restoration:** When the palette closes (by any means), keyboard focus returns to the previously focused terminal surface. This uses the existing `makeFocused(index:)` mechanism on `TerminalContainerViewModel`, which walks the NSView hierarchy and calls `window.makeFirstResponder(targetView)`.

### 2. Visual Design

The palette is a floating overlay positioned at the top of the window content area, horizontally centered:

```
┌──────────────────────────────────────────────────────┐
│  ┌──────────────────────────────────────────────┐    │
│  │ 🔍 Filter commands...                        │    │
│  ├──────────────────────────────────────────────┤    │
│  │ ▸ New Terminal                         ⌘T    │    │
│  │   Close Terminal                       ⌘W    │    │
│  │   ──────────────────────────────────────────  │    │
│  │   New Workspace...               (project)   │    │
│  │   New Agent...                   (project)   │    │
│  │   Rails Console                  (project)   │    │
│  │   ──────────────────────────────────────────  │    │
│  │   SSH Dev Box                     (global)   │    │
│  └──────────────────────────────────────────────┘    │
│                                                      │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐       │
│  │  terminal   │ │  terminal   │ │  terminal   │      │
│  │  pane 1     │ │  pane 2     │ │  pane 3     │      │
│  └────────────┘ └────────────┘ └────────────┘       │
└──────────────────────────────────────────────────────┘
```

**Layout constraints:**
- Max width: 500pt.
- Positioned ~5% from the top of the content area (matching Ghostty's own command palette positioning convention).
- The options list scrolls if it exceeds 300pt in height.
- Background uses `.ultraThinMaterial` with a rounded corner radius and subtle shadow, consistent with the app's dark theme.

**Visual treatment of rows:**
- Each row shows the command name on the left.
- Built-in commands show their keyboard shortcut on the right (e.g., `⌘T`, `⌘W`).
- Custom actions show their source — `(project)` or `(global)` — on the right, providing orientation when a user has both.
- The selected row is highlighted. The first row is selected by default.
- Rows with descriptions (from `@description`) show the description as subtitle text below the command name, in a dimmer color.

### 3. Command List

The palette presents a unified list of built-in commands and custom actions. The ordering is:

1. **Built-in commands** — always present, always first:

   | Command | Action | Shortcut |
   |---|---|---|
   | New Terminal | `viewModel.addTerminal()` | ⌘T |
   | Close Terminal | Close the focused pane (via the existing `performClose` path) | ⌘W |

2. **Separator** (only if custom actions exist)

3. **Project actions** — from `.watchtower/actions/` for the focused terminal's directory (same list as `viewModel.projectActions`).

4. **Separator** (only if both project and global actions exist)

5. **Global actions** — from `~/.config/watchtower/actions/` (same list as `viewModel.globalActions`).

This mirrors the ordering in the toolbar dropdown, keeping the mental model consistent. Users see the same commands in the same relative order regardless of whether they use the toolbar or the palette.

**Why only these built-in commands for v1:** New Terminal and Close Terminal are the most common pane-management operations and the ones most naturally triggered from a command palette. Focus navigation (previous/next pane, toggle focus mode) already has dedicated keyboard shortcuts and is less useful as a searchable command — you know which direction you want to go. Additional built-in commands can be added later without changing the architecture.

### 4. Filtering

As the user types in the search field, the list filters in real-time. A command is shown if the query matches:

- The command's **display name** (case-insensitive substring match), OR
- The command's **description** text (case-insensitive substring match), if present.

When the filter is active, separators between sections are hidden — the filtered list is a flat, unsectioned list of matches. When the filter is cleared, the full sectioned list reappears.

If no commands match the query, a single row shows "No matching commands" in a dimmed style.

**Why substring matching instead of fuzzy matching:** Substring matching is simpler to implement, predictable for users, and sufficient for the expected scale (tens of commands, not hundreds). If the command list grows large enough to warrant fuzzy matching in the future, the filtering function is a single isolated function that can be swapped.

### 5. Keyboard Navigation

The palette is fully keyboard-navigable:

| Key | Behavior |
|---|---|
| **Up Arrow** / **Ctrl+P** | Move selection to previous item (wraps to bottom) |
| **Down Arrow** / **Ctrl+N** | Move selection to next item (wraps to top) |
| **Enter** | Execute selected command |
| **Escape** | Close palette, do nothing |

Selection skips separator rows — they're visual-only and not selectable.

When the selected row is scrolled out of view, the list scrolls to keep it visible.

### 6. Action Execution from the Palette

When a command is selected and executed:

- **Built-in commands** run their action closure directly (e.g., `addTerminal()`, close the focused pane). The palette closes, focus returns to the terminal.
- **Custom actions without arguments** execute immediately, following the same path as the toolbar dropdown — `viewModel.triggerAction(action)` creates a new terminal pane running the script.
- **Custom actions with arguments** close the palette and open the existing action dialog sheet (`ActionDialogView`). This reuses the existing `viewModel.triggerAction(action)` path, which already handles the "has arguments → show dialog" branch. Focus returns to the terminal after the dialog is dismissed.

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

This mirrors the existing `performClose` at `GhosttyTerminalView.swift:349-388` but is callable from the view model layer. The key dependency is accessing the `GhosttyTerminalNSView` to call `ghostty_surface_needs_confirm_quit(surface)` — this uses the same `findAllTerminalViews(in:)` + terminal ID matching pattern already used by `makeFocused(index:)`.

The existing `performClose` on the NSView remains unchanged — Cmd+W still works through the responder chain as before. The palette's "Close Terminal" command is an alternative entry point to the same behavior.

### 8. Focus Management and First Responder

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

The `NSTextField` delegate (the coordinator) intercepts arrow keys, Enter, and Escape in `control(_:textView:doCommandBy:)` and routes them to the palette's keyboard navigation handlers. All other keystrokes flow through normal text editing.

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

Clicking outside the palette should dismiss it. The implementation is a full-size transparent background behind the palette that captures taps:

```swift
// In ContentView's overlay
if viewModel.isCommandPalettePresented {
    // Dismiss layer — covers entire content area behind the palette
    Color.clear
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.dismissCommandPalette()
        }

    // Palette itself — positioned at top center
    CommandPaletteView(viewModel: viewModel)
        .frame(maxWidth: 500)
        .padding(.top, geometry.size.height * 0.05)
        .transition(.opacity.combined(with: .move(edge: .top)))
}
```

The `Color.clear` with `.contentShape(Rectangle())` ensures the transparent area is hit-testable. It sits behind the palette in the `ZStack` so clicks on the palette itself don't trigger dismissal.

### 10. Animation

The palette appears and disappears with a combined opacity fade and slight downward slide:

```swift
.transition(.opacity.combined(with: .move(edge: .top)))
.animation(.easeOut(duration: 0.15), value: viewModel.isCommandPalettePresented)
```

The animation is fast (150ms) to feel responsive — this is a utility UI, not a modal dialog. The slide direction (from top) reinforces the palette's position at the top of the window.

### 11. Empty State

When no custom actions are discovered (no project or global actions), the palette shows only the two built-in commands:

```
┌──────────────────────────────────────────────┐
│ Filter commands...                            │
├──────────────────────────────────────────────┤
│ ▸ New Terminal                         ⌘T    │
│   Close Terminal                       ⌘W    │
└──────────────────────────────────────────────┘
```

No separators are shown. The palette is still useful in this state — it provides keyboard access to the two most common pane operations. There is no "empty" placeholder or suggestion to add actions; the palette simply shows what's available.

### 12. Multiple Windows

Each window has its own `TerminalContainerViewModel` (created by `ContentView`), so `isCommandPalettePresented` is per-window. Opening the palette in one window does not affect other windows. The Cmd+K shortcut routes through `@FocusedValue(\.terminalViewModel)`, which resolves to the key window's view model — the same pattern used by all existing menu commands.

Each window's palette shows the actions relevant to *that window's* focused terminal. Two windows focused on terminals in different projects will show different action lists. This is consistent with how the toolbar dropdown already behaves.

### 13. State Management

Add to `TerminalContainerViewModel`:

```swift
@Published var isCommandPalettePresented: Bool = false
```

Add a toggle method:

```swift
func toggleCommandPalette() {
    isCommandPalettePresented.toggle()
}
```

The palette view reads `viewModel.actions`, `viewModel.projectActions`, and `viewModel.globalActions` directly — no additional data flow is needed. These properties already exist and are reactively updated when the focused terminal's directory changes.

### 14. Responder Chain Considerations

The command palette's `NSTextField` (see Section 8) becomes the first responder when the palette opens. This means key events flow to the text field and **not** to the Ghostty terminal surface — typing a filter query does not send keystrokes to the terminal. This is the correct and expected behavior.

Cmd+K needs to work both to *open* the palette (when the terminal is first responder) and to *close* it (when the palette's text field is first responder). Because the shortcut is defined as a SwiftUI `.commands {}` menu shortcut, it routes through the application menu system, which sits above the responder chain. This means it works regardless of which view is first responder.

Arrow keys, Enter, and Escape are intercepted by the `NSTextField` delegate (see Section 8) and routed to palette navigation rather than being inserted as text. All other keystrokes flow through normal text editing.

## Open Questions

### 1. Cmd+K vs. Cmd+Shift+P

Cmd+K is used by Slack, Linear, and other modern apps for command palettes. Cmd+Shift+P is used by VS Code and Sublime Text. Cmd+K is shorter to type and doesn't conflict with any existing Watchtower shortcut. Since Watchtower is a terminal app (not a code editor), Cmd+K feels more natural than borrowing the code editor convention. That said, if user feedback requests Cmd+Shift+P as an alternative, it can be added as a second binding.

### 2. Search algorithm evolution

Substring matching is specified for v1. If the command list grows (e.g., users with many global actions), fuzzy matching or scored ranking could improve the experience. The filtering is isolated to a single function, so this is a straightforward future improvement.

### 3. Palette during focus mode

When focus mode is active, the palette should still be accessible via Cmd+K and should still show the full command list. Selecting "New Terminal" or an action while in focus mode should exit focus mode (since a new pane is being added). This matches the expected behavior — you're breaking out of single-pane focus to do something new.

## Implementation Plan

1. **Command palette data model** — define a `CommandPaletteItem` struct representing a single row (display name, optional description, optional keyboard shortcut string, source tag, action closure). Add a method on `TerminalContainerViewModel` that builds the full command list from built-in commands + discovered actions.
2. **Close terminal method** — extract the close/confirmation logic from `GhosttyTerminalNSView.performClose` into a `closeCurrentPane()` method on `TerminalContainerViewModel` (see Section 7). This is needed before the palette can offer "Close Terminal" as a command.
3. **Command palette NSTextField** — implement `CommandPaletteTextField` as an `NSViewRepresentable` wrapping an `NSTextField` with first responder management and key event interception for arrow keys, Enter, and Escape (see Section 8).
4. **Command palette view** — `CommandPaletteView.swift` as a SwiftUI view composing the `NSTextField`, a filtered `ScrollView` of rows, and keyboard navigation. Styled with `.ultraThinMaterial` background, max width 500pt, positioned at top of content area. Include the click-outside dismissal layer (see Section 9) and entry/exit animation (see Section 10).
5. **State management** — add `isCommandPalettePresented: Bool`, `toggleCommandPalette()`, and `dismissCommandPalette()` to `TerminalContainerViewModel`. `dismissCommandPalette()` restores focus to the terminal via `makeFocused(index:)`.
6. **Wire into ContentView** — present the palette as a `.overlay()` inside a `ZStack` on the main content area, gated on `viewModel.isCommandPalettePresented`. The overlay contains the transparent dismiss layer behind the palette view.
7. **Keyboard shortcut** — add Cmd+K to `WatchtowerApp.swift`'s `.commands {}` block, calling `activeViewModel?.toggleCommandPalette()`.
8. **Action execution** — route built-in commands to their existing methods (`addTerminal()`, `closeCurrentPane()`); route custom actions through `viewModel.triggerAction(action)` (reusing the existing toolbar/dialog flow).

## Files to Create or Modify

| File | Action | Description |
|---|---|---|
| `CommandPaletteView.swift` | Create | SwiftUI view: `CommandPaletteTextField` (`NSViewRepresentable` wrapping `NSTextField` with first responder and key interception), filtered command list with `ScrollViewReader`, click-outside dismissal layer, material background styling, entry/exit animation |
| `ContentView.swift` | Modify | Add `ZStack` overlay for the command palette and its dismiss layer, gated on `isCommandPalettePresented` |
| `TerminalContainerViewModel` (in `ContentView.swift`) | Modify | Add `isCommandPalettePresented: Bool`, `toggleCommandPalette()`, `dismissCommandPalette()` (with focus restoration), `closeCurrentPane()` (extracted from `performClose` logic), and a method to build the unified command list from built-ins + actions |
| `WatchtowerApp.swift` | Modify | Add Cmd+K keyboard shortcut in `.commands {}` calling `activeViewModel?.toggleCommandPalette()` |
| `GhosttyTerminalView.swift` | No change | Existing `performClose` remains for Cmd+W; palette uses the new `closeCurrentPane()` on the view model instead |
| `ActionDialogView.swift` | No change | Reused as-is for parameterized actions launched from the palette |
| `Action.swift` | No change | Existing model provides all data the palette needs (`displayName`, `descriptionText`, `hasArguments`, `isGlobal`) |
| `ActionDiscovery.swift` | No change | Existing discovery pipeline feeds `viewModel.actions`, which the palette reads directly |
