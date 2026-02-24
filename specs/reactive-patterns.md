# Reactive Patterns Audit

## Summary

A comprehensive audit of procedural patterns in the Watchtower codebase that could be replaced with reactive or structurally-correct alternatives. The core principle: state changes should be *consequences* of other state changes, not manual coordination that every call site must remember. This follows the same approach that fixed the command palette Esc-focus bug — where `focusPane()` now auto-dismisses the palette as a consequence of focus changing, rather than every caller manually calling `dismissCommandPalette()` first.

## Motivation

The `pendingFocus` / `focusGeneration` refactor proved that reactive patterns eliminate entire classes of bugs. That fix replaced a three-way coordination protocol (`managesFocus` + `actionDidManageFocus` + `dismissCommandPalette(restoreFocus:)`) with a single reactive rule: "palette dismisses itself when focus moves." This audit identifies every other place in the codebase where a similar transformation applies.

The findings are grouped into seven categories and prioritized by impact. Items marked "Active Bug" are observable defects; "Structural" items prevent future bugs; "Cleanup" items reduce maintenance burden.

---

## Critical: Active Bugs

### 1. ~~Focus mode drifts when navigating panes~~ (Fixed)

**Files:** `ContentView.swift` (focusPane), `ContentView.swift` (toggleFocusMode, focusPreviousPane / focusNextPane)

**Problem:** `focusPreviousPane()`, `focusNextPane()`, `addTerminal()`, and `addBrowser()` change which pane has first responder without updating `focusModePaneId`. After calling `focusNextPane()` in focus mode:

- `isFocusMode` remains `true`
- `focusModePaneId` still points to the *original* pane
- The original pane keeps the expanded width and shadow via `FocusModeWrapper`
- The user types into the *new* pane, which appears dimmed behind the overlay

This is the same class of bug as the original `pendingFocus` issue: state that should be a consequence of focus changing (`focusModePaneId`) is instead maintained independently, so it drifts.

**Resolution:** Applied the "focus mode follows the focused pane" variant (VS Code Zen mode behavior). Added a reactive update at the top of `focusPane(_:)` in `ContentView.swift`:

```swift
// Reactive focus-mode update: when focus mode is active, the spotlight
// follows the focused pane so it never drifts out of sync.
if isFocusMode {
    focusModePaneId = pane.id
}
```

This makes `focusModePaneId` a *consequence* of `focusPane()`, so all callers — `focusPreviousPane`, `focusNextPane`, `addTerminal` + focus, `addBrowser` + focus, `focusPane(id:)`, etc. — automatically keep focus mode in sync without any manual coordination.

### 2. `performClose` counts only terminal views, ignoring browser panes

**File:** `GhosttyTerminalView.swift:349-388`

**Problem:** When the user presses Cmd+W in a terminal, `performClose` calls `findAllTerminalViews(in: contentView)` and checks `terminalViews.count > 1`. If the window has 1 terminal + N browser panes, the count is 1 and the code falls through to `window.performClose(sender)`, which closes the entire window — destroying all browser panes without warning.

**Fix:** The terminal's NSView already has a path to the view model via `terminal.viewModel`. Use the model's pane count instead of walking the hierarchy:

```swift
@objc func performClose(_ sender: Any?) {
    guard let vm = terminal.viewModel else {
        window?.performClose(sender)
        return
    }
    if vm.panes.count > 1 {
        // Close just this pane (with confirmation if needed)
    } else {
        window?.performClose(sender)
    }
}
```

This also eliminates one of the four `findAllTerminalViews` call sites.

### 3. App losing focus during drag leaves permanent 50% opacity

**Files:** `ContentView.swift:601-628` (dragStarted / cleanupDragState), `TerminalPaneView.swift:297-364` (DragSourceNSView)

**Problem:** Drag cleanup relies on an `NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp)` handler. If the app loses focus mid-drag (Cmd+Tab, Mission Control, system dialog), the `leftMouseUp` event may never reach the monitor. Result:

- `draggedPaneId` stays set
- The dragged pane stays at 50% opacity (`isDragging = true`)
- `dropTargetIndex` may remain set (phantom drop indicator)
- The event monitor leaks until the next drag or `deinit`

**Fix:** `DragSourceNSView` already conforms to `NSDraggingSource` but only implements `draggingSession(_:sourceOperationMaskFor:)`. Add the canonical drag-end callback:

```swift
func draggingSession(
    _ session: NSDraggingSession,
    endedAt screenPoint: NSPoint,
    operation: NSDragOperation
) {
    pane.isDragging = false
    pane.viewModel?.cleanupDragState()
}
```

This fires regardless of whether the drop succeeded, was cancelled, or the app lost focus. It replaces the `NSEvent.addLocalMonitorForEvents` workaround entirely, along with the `DispatchQueue.main.async` ordering hack.

### 4. `formInteraction` handler crash on second browser pane

**File:** `BrowserWebView.swift:157-160` (makeNSView), `BrowserWebView.swift:188-193` (dismantleNSView)

**Problem:** Each `BrowserWebView.makeNSView` call registers `"formInteraction"` on the shared `BrowserConfiguration.shared.userContentController`. `WKUserContentController` does not support multiple handlers for the same name — the second registration crashes. Additionally, the first pane to close removes the handler for all remaining panes.

**Fix — Option A (minimal):** Register the handler once in `BrowserConfiguration.init()` with a long-lived coordinator that dispatches to the correct pane:

```swift
class BrowserConfiguration {
    static let shared: BrowserConfiguration = {
        let config = BrowserConfiguration()
        let dispatcher = FormInteractionDispatcher()
        config.userContentController.add(dispatcher, name: "formInteraction")
        return config
    }()
}
```

**Fix — Option B (isolated):** Give each browser pane its own `WKWebViewConfiguration` cloned from the shared template. This scopes registration/removal to the pane's lifecycle.

---

## High Priority: Structural Improvements

### 5. Replace view hierarchy walking with a pane view registry

**Files:** `GhosttyTerminalView.swift:784-794` (findAllTerminalViews), `WatchtowerApp.swift:115-127` (findWebView, free function), `ContentView.swift:957-969` (findWebView, private duplicate)

**Problem:** Two recursive `NSView.subviews` tree walks serve as the primary mechanism for resolving pane UUIDs to NSViews. Combined, they have 11+ call sites across 4 files. They break if SwiftUI restructures its internal hosting hierarchy (which varies across macOS versions), if views are lazily loaded/unloaded during scrolling, or if views are mid-transition during animations.

**Current call sites:**

| Function | File | Lines | Purpose |
|---|---|---|---|
| `findAllTerminalViews` | GhosttyTerminalView.swift | 357 | Cmd+W pane count |
| `findAllTerminalViews` | ContentView.swift | 688 | Close pane confirmation |
| `findAllTerminalViews` | ContentView.swift | 943 | Focus terminal pane |
| `findAllTerminalViews` | WatchtowerApp.swift | 227 | Quit confirmation |
| `findWebView` (free) | WatchtowerApp.swift | 80 | Menu: Go Back |
| `findWebView` (free) | WatchtowerApp.swift | 91 | Menu: Go Forward |
| `findWebView` (free) | WatchtowerApp.swift | 102 | Menu: Reload Page |
| `findWebView` (free) | CommandPaletteView.swift | 191 | Palette: Go Back |
| `findWebView` (free) | CommandPaletteView.swift | 199 | Palette: Go Forward |
| `findWebView` (free) | CommandPaletteView.swift | 207 | Palette: Reload Page |
| `findWebView` (private) | ContentView.swift | 949 | Focus browser pane |

**Fix:** Add a view registry to `PaneContainerViewModel`:

```swift
class PaneContainerViewModel {
    private(set) var viewRegistry: [UUID: NSView] = [:]
    
    func register(paneId: UUID, view: NSView) {
        viewRegistry[paneId] = view
    }
    
    func deregister(paneId: UUID) {
        viewRegistry.removeValue(forKey: paneId)
    }
    
    func terminalView(for paneId: UUID) -> GhosttyTerminalNSView? {
        viewRegistry[paneId] as? GhosttyTerminalNSView
    }
    
    func webView(for paneId: UUID) -> WatchtowerWebView? {
        viewRegistry[paneId] as? WatchtowerWebView
    }
    
    var allTerminalViews: [GhosttyTerminalNSView] {
        viewRegistry.values.compactMap { $0 as? GhosttyTerminalNSView }
    }
}
```

Views register in `viewDidMoveToWindow` (when `window != nil`) and deregister when `window == nil` or in `deinit`. All 11 call sites become O(1) lookups. Both `findAllTerminalViews(in:)` and both copies of `findWebView(for:in:)` are deleted.

For browser commands specifically, a complementary improvement is to add a weak `webView` reference on `BrowserPaneModel`:

```swift
class BrowserPaneModel {
    weak var webView: WatchtowerWebView?
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
}
```

This eliminates hierarchy walking for browser commands entirely.

### 6. Consolidate `isFocusMode` + `focusModePaneId` into a single optional

**File:** `ContentView.swift:456-460`

**Problem:** Two `@Published` properties represent one concept. Every mutation site must set both. The state `isFocusMode == true && focusModePaneId == nil` is invalid but structurally possible.

**Fix:**

```swift
// Before
@Published var isFocusMode: Bool = false
@Published var focusModePaneId: UUID? = nil

// After
@Published var focusModePaneId: UUID? = nil
var isFocusMode: Bool { focusModePaneId != nil }
```

Entering focus mode: `focusModePaneId = pane.id`. Exiting: `focusModePaneId = nil`. One property, one source of truth. The invalid state becomes structurally impossible.

Note: The `withAnimation` wrapper currently used in `toggleFocusMode()` and `exitFocusMode()` should wrap the `focusModePaneId` assignment to preserve the animation behavior.

### 7. Consolidate `showActionDialog` + `pendingAction` into `.sheet(item:)`

**File:** `ContentView.swift:492-496` (declarations), `ContentView.swift:1002-1009` (triggerAction), `ContentView.swift:122-133` (sheet)

**Problem:** Two `@Published` properties for one concept. `pendingAction` is never nilled on dialog dismissal — it persists as stale state until the next `triggerAction` call. The state `showActionDialog == true && pendingAction == nil` is invalid but possible.

**Fix:**

```swift
// Before
@Published var showActionDialog: Bool = false
@Published var pendingAction: Action? = nil

// After  
@Published var pendingAction: Action? = nil
// Use .sheet(item: $viewModel.pendingAction) in the view
```

SwiftUI's `.sheet(item:)` automatically sets the binding to `nil` on dismiss. The separate boolean and the stale-state problem both disappear.

### 8. Consolidate drag state into a single struct

**Files:** `ContentView.swift:449-452, 528` (properties), `ContentView.swift:618-628` (cleanupDragState), `PaneModel.swift:39` (per-pane isDragging)

**Problem:** Four properties must be cleaned up atomically: `draggedPaneId`, `dropTargetIndex`, per-pane `isDragging`, and `dragEndMonitor`. `cleanupDragState()` iterates all panes to reset `isDragging` — an O(n) workaround for state that belongs to a single pane.

**Fix:**

```swift
struct DragSession {
    let sourcePaneId: UUID
    var dropTargetSlot: Int?
}

@Published var activeDrag: DragSession? = nil
```

Derive `isDragging` as a computed property on `PaneModel`:

```swift
var isDragging: Bool { viewModel?.activeDrag?.sourcePaneId == id }
```

Cleanup becomes `activeDrag = nil`. One assignment, all state resets atomically.

### 9. Replace custom close notifications with direct calls

**Files:** `GhosttyAppManager.swift:566-582` (notification definitions), `GhosttyTerminalView.swift:371-382` (post), `BrowserWebView.swift:123-135` (post), `ContentView.swift:75-83` (observe)

**Problem:** `.ghosttySurfaceClosed` and `.browserPaneClosed` are global `NotificationCenter` broadcasts, but the posting NSViews already have indirect references to the view model:

- Terminal: `terminal.viewModel?.removePane(byId: terminal.id)`
- Browser: `browser?.viewModel?.removePane(byId: browser!.id)`

The notifications add string-based names, type-unsafe casting (`notification.object as?`, `userInfo?["paneId"] as?`), and global broadcast semantics where any object could accidentally observe them. There's also an asymmetry: `.ghosttySurfaceClosed` passes the NSView as `notification.object`, while `.browserPaneClosed` passes the UUID in `userInfo`.

**Fix:** Replace each `NotificationCenter.default.post(...)` with a direct method call:

```swift
// In GhosttyTerminalNSView:
terminal.viewModel?.removePane(byId: terminal.id)

// In WatchtowerWebView:
browser?.viewModel?.removePane(byId: browser?.id ?? UUID())
```

Delete both `Notification.Name` constants, both `.onReceive` handlers in `ContentView`, and the notification-posting code in `GhosttyAppManager.closeSurface`.

Alternatively, use a closure callback set during pane creation: `var onClose: ((UUID) -> Void)?`

### 10. Consolidate browser commands into `PaneContainerViewModel`

**Files:** `WatchtowerApp.swift:76-107` (menu commands), `CommandPaletteView.swift:187-211` (palette items)

**Problem:** Go Back, Go Forward, and Reload are each implemented identically in two places (6 total copies). Each copy: guard on `contextualPane as? BrowserPaneModel`, get `NSApp.keyWindow`, walk `contentView` via `findWebView`, call `goBack()` / `goForward()` / `reload()`.

**Fix:** Add methods to `PaneContainerViewModel`:

```swift
func browserGoBack() {
    guard let browser = contextualPane as? BrowserPaneModel else { return }
    browser.webView?.goBack()  // using the weak ref from §5
}
func browserGoForward() { ... }
func browserReloadPage() { ... }
```

Both menu commands and palette items become one-liners. Combined with the view registry from §5, this eliminates `findWebView` and `NSApp.keyWindow` usage from browser commands entirely.

---

## Medium Priority: Cleanup & Robustness

### 11. Add missing `deinit` cleanup

**Files and issues:**

| Class | Missing cleanup | File:Line |
|---|---|---|
| `TerminalPaneModel` | `progressClearTimer?.invalidate()` | TerminalModel.swift:28 |
| `TerminalPaneModel` | `branchDetectionTask?.cancel()` | TerminalModel.swift:31 |
| `PaneContainerViewModel` | `gitDetectionTask?.cancel()` | ContentView.swift:539 |
| `PaneContainerViewModel` | `actionDiscoveryTask?.cancel()` | ContentView.swift:542 |

The existing `PaneContainerViewModel.deinit` handles `dragEndMonitor` but not the async tasks. `TerminalPaneModel` has no `deinit` at all. The `[weak self]` captures prevent crashes but allow wasted background work (orphaned git processes, stale timer fires).

### 12. Clean up `pendingFocus` on pane removal

**File:** `ContentView.swift:807-828` (removePane)

**Problem:** If the pane targeted by `pendingFocus` is removed before the focus is delivered, the `PendingFocus` token persists until the next `focusPane()` call.

**Fix:** Add to `removePane(byId:)`:

```swift
if pendingFocus?.paneId == id { pendingFocus = nil }
```

### 13. Eliminate duplicate `findWebView`

**Files:** `WatchtowerApp.swift:115-127` (free function), `ContentView.swift:957-969` (private method)

**Problem:** Identical implementations of the same recursive walk. The private method is used only by `makeFocusedImmediate`. The free function is used by 6 other call sites.

**Fix:** Delete the private method and use the free function, or (better) implement §5's view registry which eliminates both.

### 14. Extract pane insertion helper

**File:** `ContentView.swift:758-767` (addTerminal), `ContentView.swift:777-786` (addBrowser), `ContentView.swift:1036-1045` (executeAction)

**Problem:** The "inherit width from contextual pane, set viewModel, insert after contextual pane's index or append" pattern is copy-pasted three times.

**Fix:**

```swift
private func insertPane(_ pane: PaneModel) {
    pane.viewModel = self
    if let source = contextualPane,
       let idx = panes.firstIndex(where: { $0.id == source.id }) {
        pane.paneWidth = source.paneWidth
        panes.insert(pane, at: idx + 1)
    } else {
        panes.append(pane)
    }
}
```

`addTerminal()`, `addBrowser()`, and `executeAction()` each construct their model and call `insertPane(...)`.

### 15. Extract close confirmation alert helper

**Files:** `GhosttyTerminalView.swift:361-377`, `BrowserWebView.swift:113-136`, `ContentView.swift:692-722`

**Problem:** Four near-identical `NSAlert` + `beginSheetModal` patterns. (Note: the existing `codebase-cleanup.md` spec §3 covers three of these but misses the browser variant in `BrowserWebView.swift`.)

**Fix:** Shared helper:

```swift
func confirmCloseSheet(
    on window: NSWindow,
    title: String,
    message: String,
    onConfirm: @escaping () -> Void
) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Close")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { response in
        if response == .alertFirstButtonReturn { onConfirm() }
    }
}
```

### 16. Consolidate git detection to avoid redundant shell processes

**Files:** `ContentView.swift:974-982` (PaneContainerViewModel.detectGitRepo), `TerminalModel.swift:95-108` (TerminalPaneModel.detectGitBranch)

**Problem:** Both independently call `WorkspaceManager.detectGitRepoRoot` for the same directory. When a focused terminal changes directories, two `git rev-parse` processes are spawned for the same path.

**Fix:** Have `TerminalPaneModel.detectGitBranch` publish its `gitRepoRoot` result (e.g., as a `@Published` property), and have `PaneContainerViewModel` read it from the focused pane model instead of running its own detection.

### 17. Replace 0.5s magic delay with event-driven trigger

**File:** `GhosttyTerminalView.swift:245`

**Problem:** After `ghostty_surface_new()`, a `DispatchQueue.main.asyncAfter(deadline: .now() + 0.5)` polls terminal status. This is the only true timing heuristic in the codebase — a magic delay guessing when the shell will be ready.

**Fix:** Ghostty already sends `setTitle` and `setPwd` callbacks when the shell starts. Hook into one of these as the trigger for `refreshStatusFromSurface()` instead of the fixed delay. The `setPwd` callback already calls `refreshStatusFromSurface()` (GhosttyAppManager.swift:299-307), so this may already be covered — verify and remove the redundant delay.

### 18. Use `process.terminationHandler` instead of `waitUntilExit()`

**Files:** `WorkspaceManager.swift:34-63`, `ActionDialogView.swift:241-271`

**Problem:** Both use `withCheckedContinuation` wrapping `Process.waitUntilExit()`, which blocks a Swift cooperative thread pool thread. Under concurrent git operations (multiple panes changing directories simultaneously), this can exhaust the pool.

**Fix:** Replace `waitUntilExit()` with `process.terminationHandler`:

```swift
process.terminationHandler = { _ in
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    continuation.resume(returning: String(data: data, encoding: .utf8))
}
try process.run()
```

(Note: the existing `codebase-cleanup.md` spec §4 covers unifying these two into a shared helper. This recommendation adds the `terminationHandler` change to that unification.)

### 19. Add cancellation support to `ActionDialogView.runShellCommand`

**File:** `ActionDialogView.swift:240-271`

**Problem:** When the action dialog is dismissed, `.task` cancellation fires, but the spawned `Process` is not terminated. Long-running commands continue executing in the background with results discarded.

**Fix:** Use `withTaskCancellationHandler`:

```swift
await withTaskCancellationHandler {
    await withCheckedContinuation { continuation in
        // ... existing Process setup ...
        process.terminationHandler = { ... continuation.resume(...) }
        try? process.run()
    }
} onCancel: {
    process.terminate()
}
```

---

## Low Priority: Refinements

### 20. Single `focusedPaneId` instead of per-pane `isFocused`

**Files:** `PaneModel.swift:38`, `GhosttyTerminalView.swift:278-344`, `BrowserWebView.swift:52-68`

**Problem:** Every `PaneModel` has `@Published var isFocused: Bool`, set by `becomeFirstResponder` / `resignFirstResponder` on the respective NSViews. Multiple panes can theoretically have `isFocused = true` simultaneously. The `GhosttyTerminalNSView` additionally maintains a local `focused` Bool that shadows `terminal.isFocused`.

**Fix:** Replace per-pane `isFocused` with a single `@Published var focusedPaneId: UUID?` on `PaneContainerViewModel`. Derive `isFocused` as computed: `var isFocused: Bool { viewModel?.focusedPaneId == id }`. Eliminate the local `focused` shadow on `GhosttyTerminalNSView`. This makes it structurally impossible for multiple panes to be focused simultaneously.

### 21. Browser navigation lifecycle as a state machine

**File:** `BrowserWebView.swift:294-330` (delegate methods), `BrowserPaneModel.swift`

**Problem:** `isLoading`, `httpStatusCode`, and `hasInteractedForms` are independently managed across four WKNavigationDelegate methods. `hasInteractedForms` is only reset in `didStartProvisionalNavigation` — fragment-only navigations don't reset it.

**Fix:**

```swift
enum NavigationState {
    case idle(httpStatus: Int?)
    case loading(progress: Double)
    case failed(error: Error?)
}
@Published var navigationState: NavigationState = .idle(httpStatus: nil)
```

Derive `isLoading`, status, and progress from this enum. Reset `hasInteractedForms` on every transition to `.loading`.

### 22. Extract `PaneModel.claimPendingFocus(for:)` helper

**Files:** `GhosttyTerminalView.swift:390-408`, `BrowserWebView.swift:70-86`

**Problem:** Identical `viewDidMoveToWindow` pending-focus logic duplicated in both NSView subclasses.

**Fix:**

```swift
extension PaneModel {
    func claimPendingFocus(for view: NSView) {
        guard let window = view.window,
              let pending = viewModel?.pendingFocus,
              pending.paneId == self.id,
              pending.fulfill() else { return }
        viewModel?.pendingFocus = nil
        window.makeFirstResponder(view)
    }
}
```

### 23. Remove unused `sizeDebounceWorkItem`

**File:** `GhosttyTerminalView.swift:142`

Dead code. `private var sizeDebounceWorkItem: DispatchWorkItem? = nil` is never read, written, or cancelled. (Also covered by `codebase-cleanup.md` §1.)

---

## Relationship to Other Specs

- **`codebase-cleanup.md`** covers dead code removal (§1), the confirmation alert helper (§3), unified shell execution (§4), terminal insertion helper (§6), and color conversion helper (§7). This spec extends those with deeper structural changes (§§5-10) and new findings (§§1-4, 11-12, 16-22).
- **`focus-management.md`** introduced the `PendingFocus` token and `focusGeneration` mechanism. This spec builds on that by identifying remaining focus-related drift issues (§§1, 12, 20) and proposing the view registry (§5) that further decouples focus management from view hierarchy walking.

Where both specs recommend the same change (e.g., close confirmation helper), this spec defers to the existing one and notes the overlap.

---

## Implementation Order

Dependencies between items are noted. Items within each tier are independent of each other unless stated.

**Tier 1 — Bug fixes (no architectural dependencies):**
1. ~~§1: Focus mode drift fix (standalone change to `focusPane`)~~ **Done**
2. §2: `performClose` pane count (standalone change to `GhosttyTerminalView`)
3. §4: `formInteraction` handler crash (standalone change to `BrowserWebView`)

**Tier 2 — Structural consolidation (each independent):**
4. §6: `isFocusMode` → single optional
5. §7: `showActionDialog` → `.sheet(item:)`
6. §8: Drag state → single struct (enables §3)
7. §3: Drag end via `draggingSession(endedAt:)` (depends on §8 for clean API)
8. §9: Notifications → direct calls

**Tier 3 — View registry (enables many downstream simplifications):**
9. §5: Implement `PaneViewRegistry`
10. §10: Browser commands → view model methods (depends on §5 or §5's `BrowserPaneModel.webView` variant)
11. §13: Delete duplicate `findWebView` (subsumed by §5)
12. §2 completion: Use registry in `performClose` instead of model access (refinement)

**Tier 4 — Cleanup (all independent):**
13. §11: Missing `deinit` cleanup
14. §12: `pendingFocus` cleanup on pane removal
15. §14: Pane insertion helper
16. §15: Close confirmation helper (overlaps codebase-cleanup.md §3)
17. §16: Consolidate git detection
18. §17: Remove 0.5s magic delay
19. §18: `terminationHandler` instead of `waitUntilExit()`
20. §19: Process cancellation in `ActionDialogView`

**Tier 5 — Refinements (all independent):**
21. §20: Single `focusedPaneId`
22. §21: Navigation state machine
23. §22: `claimPendingFocus` helper
24. §23: Remove `sizeDebounceWorkItem`

## Files to Modify

| File | Sections |
|---|---|
| `ContentView.swift` | 1, 5, 6, 7, 8, 9, 10, 12, 13, 14, 16, 20 |
| `GhosttyTerminalView.swift` | 2, 5, 17, 20, 22, 23 |
| `BrowserWebView.swift` | 4, 5, 9, 15, 21, 22 |
| `TerminalPaneView.swift` | 3, 8 |
| `WatchtowerApp.swift` | 5, 9, 10, 13 |
| `CommandPaletteView.swift` | 10 |
| `PaneModel.swift` | 8, 20 |
| `BrowserPaneModel.swift` | 5, 21 |
| `TerminalModel.swift` | 11, 16 |
| `GhosttyAppManager.swift` | 9, 17 |
| `WorkspaceManager.swift` | 18 |
| `ActionDialogView.swift` | 19 |
