# Focus Management Refactor

## Summary

Replace the fragile double-async `DispatchQueue.main.async { DispatchQueue.main.async { ... } }` focus management with a deterministic callback-driven approach. Pane creation methods return the model synchronously, and a `PendingFocus` token ensures focus is claimed when the NSView enters the window hierarchy via `viewDidMoveToWindow`. The goal is to make focus management read like:

```swift
let pane = addTerminal()
focusPane(pane)
```

## Motivation

The current focus system has five sites that use nested `DispatchQueue.main.async` to delay `makeFocused` by two run-loop ticks. This pattern was introduced because:

1. After mutating `@Published var panes`, SwiftUI needs one run-loop pass to reconcile the `ForEach` and call `makeNSView`.
2. After dismissing the command palette, its NSTextField needs one run-loop pass to fully resign first responder.

The double-async is a timing heuristic — it assumes two ticks is always sufficient. This causes several problems:

- **Race conditions**: When `focusPreviousPane()` or `focusNextPane()` are called while the command palette is open, they call `dismissCommandPalette()` (which enqueues a double-async restore to the *original* pane) and then immediately call `makeFocused` synchronously for the *target* pane. Two ticks later, the dismiss callback overwrites the correct focus.
- **Competing double-asyncs**: When an action creates a new pane from the command palette, both the action's double-async and the palette dismiss's double-async race to call `makeFocused`. The `actionDidManageFocus` flag was added as a workaround.
- **Silent failures**: If SwiftUI hasn't installed the NSView by the second tick (e.g., under heavy load), the view-hierarchy walk in `makeFocused` finds nothing and focus is silently lost.
- **Fragile coordination**: `CommandPaletteItem.managesFocus`, `actionDidManageFocus`, and `dismissCommandPalette(restoreFocus:)` form a three-way coordination protocol that is easy to get wrong when adding new actions.

## Detailed Design

### 1. `PendingFocus` — A One-Shot Focus Token

Introduce a lightweight object that represents "focus this pane when its view appears":

```swift
class PendingFocus {
    let paneId: UUID
    private(set) var fulfilled = false

    init(paneId: UUID) {
        self.paneId = paneId
    }

    /// Called by the NSView when it enters the window hierarchy.
    /// Returns true if this was the first call (focus should be claimed).
    func fulfill() -> Bool {
        guard !fulfilled else { return false }
        fulfilled = true
        return true
    }

    /// Cancel the pending focus (e.g., another focus request superseded this one).
    func cancel() {
        fulfilled = true
    }
}
```

### 2. Single `pendingFocus` on the View Model

Replace `actionDidManageFocus` and the five double-async sites with a single optional property:

```swift
class PaneContainerViewModel: ObservableObject {
    /// When set, the next NSView matching this pane ID to enter the window
    /// hierarchy will claim first responder. Setting a new value automatically
    /// cancels the previous one, preventing races.
    var pendingFocus: PendingFocus? {
        didSet { oldValue?.cancel() }
    }
    // ...
}
```

The `didSet` cancellation is the key mechanism that eliminates races. Only the most recent focus request can win.

### 3. NSView Reports Readiness via `viewDidMoveToWindow`

Both `GhosttyTerminalNSView` and `WatchtowerWebView` already have (or can override) `viewDidMoveToWindow()`. This AppKit callback fires when the NSView is added to a window — the exact moment it can accept first responder. Wire it to check `pendingFocus`:

```swift
// GhosttyTerminalNSView
override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window = self.window else { return }

    // Existing: update content scale
    if let screen = window.screen {
        let scale = screen.backingScaleFactor
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
    }

    // New: claim focus if this view was pending
    if let pending = viewModel?.pendingFocus,
       pending.paneId == terminal.id,
       pending.fulfill() {
        window.makeFirstResponder(self)
        viewModel?.pendingFocus = nil  // consumed — prevent stale token
    }
}
```

```swift
// WatchtowerWebView
override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window = self.window else { return }

    if let pending = viewModel?.pendingFocus,
       pending.paneId == browser?.id,
       pending.fulfill() {
        window.makeFirstResponder(self)
        viewModel?.pendingFocus = nil  // consumed — prevent stale token
    }
}
```

The NSViews need a weak reference to the `PaneContainerViewModel` (or just the `PendingFocus` object). This can be passed through the existing model objects or the NSViewRepresentable coordinator.

### 4. Pane Creation Becomes Synchronous + Declarative

`addTerminal()` and `addBrowser()` return the created model instead of being void. All focus logic is removed from these methods — the caller decides whether to focus:

```swift
@discardableResult
func addTerminal() -> TerminalPaneModel {
    let terminal = TerminalPaneModel(/* ... */)
    // insert into panes array (uses contextualPane for position/directory)...
    return terminal
}

@discardableResult
func addBrowser(url: URL = URL(string: "about:blank")!) -> BrowserPaneModel {
    let browser = BrowserPaneModel(url: url, paneWidth: paneWidth)
    // insert into panes array...
    return browser
}
```

Call sites become straightforward:

```swift
// "New Terminal" action
let terminal = vm.addTerminal()
vm.focusPane(terminal)

// "Go to URL..." action
if let existingBrowser = vm.contextualPane as? BrowserPaneModel {
    existingBrowser.navigate(to: url)
    // No focus change needed — already focused
} else {
    let browser = vm.addBrowser(url: url)
    vm.focusPane(browser)
}
```

### 5. Command Palette Dismiss Simplification

The `dismissCommandPalette` method no longer needs `restoreFocus` or double-async. A `focusGeneration` counter on the view model tracks whether `focusPane` was called:

```swift
class PaneContainerViewModel: ObservableObject {
    /// Monotonically increasing counter bumped every time `focusPane` is
    /// called. Used by `dismissCommandPalette` to detect whether an action
    /// explicitly requested focus.
    private(set) var focusGeneration: UInt = 0
    // ...
}
```

The dismiss method accepts an optional `beforeGeneration` snapshot. If the generation hasn't advanced (action didn't call `focusPane`), focus is restored to the original pane. If it advanced, the action's focus is preserved:

```swift
func dismissCommandPalette(beforeGeneration: UInt? = nil) {
    guard let paneId = commandPalettePaneId else { return }
    commandPalettePaneId = nil  // tear down the palette UI
    // Restore focus unless an action explicitly called focusPane()
    if beforeGeneration == nil || focusGeneration == beforeGeneration {
        focusPaneById(paneId)
    }
}
```

When called without a generation (Esc key, click-to-dismiss), focus is always restored.

**Ordering constraint**: The action must run *before* `dismissCommandPalette()` because action closures call `vm.contextualPane`, which resolves via `commandPalettePaneId`. If we nil it out first, the action loses track of which pane was contextual when the palette opened.

The `executeSelected()` flow:

```swift
private func executeSelected() {
    let item = visibleItems[selectedIndex].item
    let gen = viewModel.focusGeneration   // snapshot BEFORE action runs
    item.action(viewModel)                // action runs (needs contextualPane via
                                          //   commandPalettePaneId, still set).
                                          //   May call focusPane() → bumps generation.
    viewModel.dismissCommandPalette(      // if generation advanced, preserves action's
        beforeGeneration: gen)            //   focus. Otherwise restores original pane.
}
```

#### Why `focusGeneration` instead of checking `pendingFocus == nil`

An earlier design checked `if pendingFocus == nil` in `dismissCommandPalette`. This had a bug: when `focusPane` was called for an *existing* pane already in the hierarchy, `makeFocusedImmediate` succeeded synchronously, the token was fulfilled and niled out, and by the time `dismissCommandPalette` ran (synchronously, on the same call stack), `pendingFocus` was already `nil`. Dismiss would then incorrectly restore focus to the original pane, overwriting the action's focus.

The `focusGeneration` counter avoids this because it's bumped in `focusPane` and never decremented. The snapshot comparison is stable regardless of whether `pendingFocus` was consumed.

### 5a. Auto-Dismiss from `focusPane`

The command palette auto-dismisses reactively when `focusPane()` targets a different pane. This is implemented at the top of `focusPane`:

```swift
func focusPane(_ pane: PaneModel) {
    // Auto-dismiss the command palette when focus moves to a different pane.
    if let paletteId = commandPalettePaneId, paletteId != pane.id {
        commandPalettePaneId = nil
    }
    // ... rest of focusPane
}
```

This eliminated manual `dismissCommandPalette()` calls from `focusPreviousPane`, `focusNextPane`, and `focusPane(id:)`. These methods now simply call `focusPane()` and the palette tears down automatically.

**Ordering safety**: All callers read `contextualPane` (which resolves via `commandPalettePaneId`) *before* calling `focusPane`, so the palette's pane ID is still available when needed.

This replaces `managesFocus`, `actionDidManageFocus`, and `restoreFocus` with two mechanisms: the `focusGeneration` counter for `executeSelected`, and auto-dismiss for navigation.

### 6. `focusPane` — The Unified Focus Method

All focus changes flow through a single method that handles both new and existing panes:

```swift
/// Focus a pane. If the NSView is already in the hierarchy, focus it
/// immediately and fulfill the token. If not (just created), the token
/// remains pending and viewDidMoveToWindow will pick it up.
func focusPane(_ pane: PaneModel) {
    // Update the Combine pipeline for git detection / action discovery
    focusedPaneSubject.send(pane)

    // Bump the generation so dismissCommandPalette can detect that
    // an action explicitly requested focus.
    focusGeneration &+= 1

    // Set pendingFocus — cancels any prior pending focus via didSet
    pendingFocus = PendingFocus(paneId: pane.id)

    // Try immediate focus (view already in hierarchy)
    if makeFocusedImmediate(pane: pane) {
        pendingFocus?.fulfill()
        pendingFocus = nil  // consumed — prevent stale token
        return
    }

    // View doesn't exist yet (just added to panes array).
    // viewDidMoveToWindow on the NSView will check pendingFocus
    // and claim first responder when it enters the window.
    //
    // Single-async fallback for the case where the view IS in the
    // hierarchy but the command palette's NSTextField hasn't resigned
    // first responder yet (its teardown is asynchronous).
    DispatchQueue.main.async { [weak self] in
        guard let self = self,
              let pending = self.pendingFocus,
              pending.paneId == pane.id,
              !pending.fulfilled else { return }
        if self.makeFocusedImmediate(pane: pane) {
            pending.fulfill()
            self.pendingFocus = nil  // consumed — prevent stale token
        }
    }
}

/// Convenience for focusing by ID (used by dismissCommandPalette).
func focusPaneById(_ id: UUID) {
    guard let pane = panes.first(where: { $0.id == id }) else { return }
    focusPane(pane)
}

/// Try to find the pane's NSView in the hierarchy and make it first
/// responder. Returns true if successful.
private func makeFocusedImmediate(pane: PaneModel) -> Bool {
    guard let window = NSApp.keyWindow,
          let contentView = window.contentView else { return false }

    if pane is TerminalPaneModel {
        let allViews = GhosttyTerminalNSView.findAllTerminalViews(in: contentView)
        if let targetView = allViews.first(where: { $0.terminal.id == pane.id }) {
            window.makeFirstResponder(targetView)
            return true
        }
    } else if pane is BrowserPaneModel {
        if let webView = findWebView(for: pane.id, in: contentView) {
            window.makeFirstResponder(webView)
            return true
        }
    }
    return false
}
```

This replaces the current `makeFocused(index:)`. The key differences:

- Takes a `PaneModel` instead of an index (avoids stale-index bugs)
- Returns a success bool so callers know if the view was found
- Moves `focusedPaneSubject.send` into the unified method so it's never forgotten
- The single-async fallback is guarded by the `PendingFocus` token — if anything else calls `focusPane` in the interim, the fallback harmlessly no-ops

For methods that don't go through the command palette (`focusPreviousPane`, `focusNextPane`, click-to-focus), `makeFocusedImmediate` succeeds on the first try because the view is already in the hierarchy and no NSTextField is resigning. The async fallback never fires.

### 6a. Navigation Methods Using `focusPane`

`focusPreviousPane`, `focusNextPane`, and `focusPane(id:)` rely on `focusPane`'s auto-dismiss (section 5a) rather than manually calling `dismissCommandPalette`. They capture `contextualPane` *before* calling `focusPane`, because `focusPane` nils `commandPalettePaneId` (via auto-dismiss) which affects `contextualPane` resolution:

```swift
func focusPreviousPane() {
    let currentPane = contextualPane  // capture BEFORE focusPane auto-dismisses
    guard panes.count > 1 else { return }
    let currentIndex: Int
    if let p = currentPane, let idx = panes.firstIndex(where: { $0.id == p.id }) {
        currentIndex = idx
    } else {
        currentIndex = 0
    }
    let newIndex = (currentIndex - 1 + panes.count) % panes.count
    focusPane(panes[newIndex])  // auto-dismisses palette, focuses target
}
```

The same pattern for `focusNextPane` and `focusPane(id:)`. No explicit `dismissCommandPalette()` call is needed — `focusPane` handles it.

### 7. Remove Pane Focus

When a pane is removed, focus the neighbor using the same mechanism:

```swift
func removePane(byId id: UUID) {
    guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
    let neighborId: UUID
    if panes.count > 1 {
        let focusIndex = index > 0 ? index - 1 : 1
        neighborId = panes[focusIndex].id
    } else {
        let newTerminal = addTerminal()
        neighborId = newTerminal.id
    }
    panes.remove(at: index)
    focusPaneById(neighborId)
}
```

### 8. Fix `findWebView` Bug

The current `findWebView(for:in:)` accepts a `paneId` parameter but never checks it — it returns the first `WatchtowerWebView` in the hierarchy. Fix this by checking `webView.browser?.id`:

```swift
private func findWebView(for paneId: UUID, in view: NSView) -> WatchtowerWebView? {
    if let webView = view as? WatchtowerWebView,
       webView.browser?.id == paneId {
        return webView
    }
    for subview in view.subviews {
        if let found = findWebView(for: paneId, in: subview) {
            return found
        }
    }
    return nil
}
```

### 9. Plumbing the ViewModel Reference

The NSViews need access to `pendingFocus`. Two options:

**Option A: Pass through the model.** Add a weak `var viewModel: PaneContainerViewModel?` to `PaneModel`. Set it when the pane is added to `panes`. The NSView reads `terminal.viewModel?.pendingFocus` in `viewDidMoveToWindow`.

**Option B: Pass through the NSViewRepresentable coordinator.** The coordinator already has access to the model. Add `var pendingFocus: PendingFocus?` to the coordinator, updated in `updateNSView`. The NSView reads the coordinator's reference.

Option A is simpler and avoids coordinator coupling. The weak reference prevents retain cycles.

## What Gets Deleted

- `actionDidManageFocus` flag on `PaneContainerViewModel`
- `managesFocus` property on `CommandPaletteItem`
- `restoreFocus` parameter on `dismissCommandPalette`
- All five double-async `DispatchQueue.main.async { DispatchQueue.main.async { ... } }` blocks in `addTerminal`, `addBrowser`, `removePane`, `dismissCommandPalette`, `executeAction`
- The `NSViewRepresentable First Responder Pitfalls` section in `Watchtower/Watchtower/AGENTS.md` about double-async

## Files Changed

| File | Changes |
|---|---|
| `ContentView.swift` | Replace five double-async sites with `focusPane()` calls. Add `PendingFocus` class. Add `pendingFocus` property to `PaneContainerViewModel`. Change `addTerminal()`/`addBrowser()` to return the model. Simplify `dismissCommandPalette`. Fix `findWebView` bug. Remove `actionDidManageFocus`. |
| `CommandPaletteView.swift` | Remove `managesFocus` from `CommandPaletteItem`. Simplify `executeSelected()` to call action then dismiss (no flag checks needed). |
| `GhosttyTerminalView.swift` | Add `viewDidMoveToWindow` focus-claim logic. |
| `BrowserWebView.swift` | Add `viewDidMoveToWindow` override with focus-claim logic. |
| `PaneModel.swift` | Add `weak var viewModel: PaneContainerViewModel?` property. |
| `Watchtower/Watchtower/AGENTS.md` | Update focus management documentation. |

## Migration

This is a pure refactor with no user-visible behavior changes. The focus behavior should be identical (or better — the `focusPreviousPane`/`focusNextPane` race is fixed). No new features are added.

## Test Plan

Manual testing scenarios:

1. **New terminal from menu/shortcut**: New pane appears and receives focus.
2. **New terminal from command palette**: Palette dismisses, new pane receives focus.
3. **New browser from command palette**: Palette dismisses, browser pane receives focus.
4. **"Go to URL..." on existing browser**: Palette dismisses, existing browser retains focus, page navigates.
5. **"Go to URL..." on terminal (creating new browser)**: Palette dismisses, new browser receives focus.
6. **Focus Previous/Next while palette is open**: Palette dismisses, correct neighbor pane receives focus (not the original pane).
7. **Close pane**: Neighbor pane receives focus.
8. **Close last pane**: New terminal is created and receives focus.
9. **Click pane header**: Pane receives focus.
10. **Click inside pane body**: Pane receives focus.
11. **Rapid Cmd+T**: Each new terminal receives focus, no stale focus on old panes.
12. **Multiple browser panes**: `findWebView` focuses the correct one (not the first in hierarchy).
