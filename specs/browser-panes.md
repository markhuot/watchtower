# Browser Panes

## Summary

Add a "New Browser" pane type that sits alongside terminal panes in Watchtower's horizontal scroll layout. Browser panes use `WKWebView` to render web content and share the same lifecycle as terminal panes — they can be added, focused, resized, reordered, and closed using the same mechanisms. The "New Browser" option appears as a default entry in the toolbar `+` dropdown menu, above custom actions.

## Motivation

Watchtower's horizontal pane layout is already a general-purpose workspace for development tasks. Developers constantly context-switch between terminals and browsers — checking local dev servers, reading documentation, reviewing PRs, watching CI dashboards, or testing API endpoints. Embedding a browser pane directly in the pane stack eliminates this context switch.

This is the natural next step in making Watchtower a complete development workspace. The pane abstraction already handles focus management, resizing, drag-to-reorder, and focus mode — browser panes plug into all of these without changing the external behavior.

## Detailed Design

### 1. Pane Model Abstraction

Currently, `TerminalContainerViewModel` holds `terminals: [TerminalModel]`, and every pane is a terminal. To support browser panes, introduce a class hierarchy rooted at `PaneModel`:

```swift
class PaneModel: Identifiable, ObservableObject {
    let id: UUID
    @Published var paneWidth: CGFloat
    @Published var isFocused: Bool = false
    @Published var isDragging: Bool = false

    // Subclasses override these
    var title: String { "" }
    var subtitle: String? { nil }
    var status: PaneStatus { .idle }
    var progress: Double? { nil }
    var directory: String? { nil }

    static let defaultPaneWidth: CGFloat = 80 * 9 + 40
}
```

`TerminalPaneModel` and `BrowserPaneModel` are subclasses:

```swift
class TerminalPaneModel: PaneModel {
    // Existing TerminalModel properties: title, status, directory, gitBranch,
    // command, env, waitAfterCommand — all live here.
    // Overrides PaneModel's computed title, subtitle, status, directory.
}

class BrowserPaneModel: PaneModel {
    @Published var url: URL
    @Published var pageTitle: String = "New Tab"
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var estimatedProgress: Double = 0.0
    @Published var httpStatusCode: Int? = nil

    // Overrides PaneModel's computed title, subtitle, status, progress.
}
```

`TerminalContainerViewModel.terminals` becomes `panes: [PaneModel]`. Code that needs terminal-specific behavior uses `as? TerminalPaneModel` downcasts. Code that operates on any pane (focus, resize, reorder, close) uses the base `PaneModel` interface.

This is a mechanical refactor — every `viewModel.terminals` reference becomes `viewModel.panes`, and terminal-specific code downcasts to `TerminalPaneModel` where needed.

**Properties that move up from `TerminalModel` to `PaneModel`:** `id`, `paneWidth`, `isFocused`, `isDragging`.

**Properties that stay on `TerminalPaneModel`:** `title`, `status`, `directory`, `gitBranch`, `command`, `env`, `waitAfterCommand`, the Combine subscription for git branch detection.

### 2. PaneStatus

A shared enum replacing `TerminalStatus`, used by all pane types:

```swift
enum PaneStatus {
    case active   // terminal: foreground process running; browser: page loading
    case idle     // terminal: shell prompt; browser: page loaded (HTTP 2xx)
    case failed   // terminal: non-zero exit; browser: navigation error or non-2xx HTTP status
}
```

For browser panes, the status mapping is:
- **`.active`** — `isLoading == true`
- **`.idle`** — page loaded successfully (HTTP 2xx or no HTTP status, e.g. `about:blank`)
- **`.failed`** — navigation error (connection refused, DNS failure, etc.) OR any non-2xx HTTP status code (4xx, 5xx, etc.)

### 3. Header Progress Bar

Every pane header gains a **4px bottom border** that acts as a progress bar. This is a universal pane feature, not browser-specific.

```
┌─────────────────────────────────────┐
│ ● title                    dir/branch│  ← header content
│▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░│  ← 4px progress bar (bottom border)
├─────────────────────────────────────┤
│                                     │
│           pane content              │
│                                     │
└─────────────────────────────────────┘
```

**Behavior:**
- When `PaneModel.progress` is `nil`, the bar renders as `Color.clear` — invisible, taking no visual space beyond its 4px allocation.
- When `progress` is non-nil (0.0–1.0), the bar renders as a filled portion using `appManager.highlightColor`, with the remaining portion clear.
- When progress reaches 1.0, it holds briefly (200ms) then fades to clear.

**For browser panes:** `progress` returns `estimatedProgress` while loading, `nil` otherwise.

**For terminal panes:** `progress` returns `nil` (terminals don't have progress). This leaves the door open for future features (e.g., build progress parsing) without any structural changes.

### 4. BrowserPaneModel

```swift
class BrowserPaneModel: PaneModel {
    @Published var url: URL
    @Published var pageTitle: String = "New Tab"
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var estimatedProgress: Double = 0.0
    @Published var httpStatusCode: Int? = nil

    override var title: String { pageTitle }
    override var subtitle: String? { url.host }
    override var directory: String? { nil }

    override var status: PaneStatus {
        if isLoading { return .active }
        if let code = httpStatusCode, !(200..<300).contains(code) { return .failed }
        return .idle
    }

    override var progress: Double? {
        isLoading ? estimatedProgress : nil
    }

    init(url: URL = URL(string: "about:blank")!, paneWidth: CGFloat = PaneModel.defaultPaneWidth) {
        self.url = url
        super.init(id: UUID(), paneWidth: paneWidth)
    }
}
```

`BrowserPaneModel` is intentionally minimal. It mirrors the observable state that `WKWebView` exposes via KVO (`title`, `isLoading`, `canGoBack`, `canGoForward`, `estimatedProgress`, `url`) plus the HTTP status code from navigation responses.

**Page title as pane title:** The `<title>` of the loaded page becomes the pane's title in the header, shown to the left. While loading a new page, the title updates when `WKWebView` reports a new title via KVO. Before any page loads (on `about:blank`), the title is "New Tab".

### 5. Browser Pane Layout

Browser panes have **no browser toolbar**. There are no back/forward buttons, no reload button, and no URL bar visible in the pane. The pane is just the shared header + WKWebView content:

```
┌─────────────────────────────────────┐
│ ● Page Title             localhost   │  ← shared header
│▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░│  ← progress bar
├─────────────────────────────────────┤
│                                     │
│          WKWebView content          │
│                                     │
│                                     │
└─────────────────────────────────────┘
```

Navigation controls (back, forward, reload) and URL input are handled through the **command palette** and **menu bar**, not inline UI. This keeps browser panes visually consistent with terminal panes — both are just a header + content area. It also maximizes the content area for the web page.

**Command palette commands for browser panes:**

| Command | Action | Shortcut |
|---|---|---|
| Navigate To... | Prompt for a URL, navigate the focused browser pane | — |
| Go Back | `webView.goBack()` | ⌘[ |
| Go Forward | `webView.goForward()` | ⌘] |
| Reload Page | `webView.reload()` | ⌘R |

These commands are contextual — they only appear in the command palette (and are only enabled in the menu bar) when the focused pane is a browser pane.

**"Navigate To..." behavior:** When selected from the command palette, replaces the palette's filter field with a URL input field. The user types a URL and presses Enter to navigate. If the input has no scheme, `https://` is prepended. Pressing Escape returns to the normal palette filter.

### 6. WKWebView Wrapper

A new `BrowserWebView.swift` containing the `NSViewRepresentable` wrapper for `WKWebView`:

```swift
struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var browser: BrowserPaneModel

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // KVO observers for title, isLoading, canGoBack, canGoForward, estimatedProgress, url
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Navigate only when the model's URL changes and differs from the web view's current URL
    }
}
```

**KVO bridge:** The coordinator observes `WKWebView`'s KVO properties and writes them back to `BrowserPaneModel`'s `@Published` properties. This is the same pattern as `GhosttyTerminalView` bridging Ghostty's C callbacks to `TerminalModel`'s published properties.

**HTTP status code capture:** The navigation delegate's `didReceiveServerRedirectForProvisionalNavigation` and `decidePolicyFor navigationResponse` callbacks expose the `HTTPURLResponse`, from which the status code is read and written to `BrowserPaneModel.httpStatusCode`. This is what drives the red status dot for non-2xx responses.

**First responder:** When a browser pane is focused, the `WKWebView` should become first responder so keyboard events (scrolling, form input, keyboard shortcuts on web pages) work correctly. This follows the same pattern as `makeFocused(index:)` finding `GhosttyTerminalNSView` instances — it additionally looks for `WKWebView` instances.

### 7. Toolbar Integration

The `+` button is **always** a dropdown menu. The previous conditional logic — plain `+` button when no actions, dropdown when actions exist — is removed. There are always at least two built-in options (New Terminal, New Browser), so the dropdown is always warranted.

```
[Click +]          → New terminal (primary action, unchanged)
[Click chevron ▾]  →  New Terminal
                      New Browser
                      ─────────────
                      New Workspace...
                      New Agent...
                      ─────────────
                      SSH Dev Box
```

The primary click action (clicking `+` directly) remains "New Terminal" — terminals are the more common operation.

**Simplified toolbar code:** The `if viewModel.actions.isEmpty { Button(...) } else { Menu(...) }` conditional is replaced with a single `Menu` that always renders. "New Terminal" and "New Browser" are always the first two items, followed by a divider, then project actions, separator, global actions (as before, but without the conditional).

**Keyboard shortcut:** Cmd+T remains "New Terminal". No default keyboard shortcut for "New Browser" initially — it can be added later or accessed via the command palette.

### 8. Command Palette Integration

"New Browser" is added to the built-in commands in the command palette. "Close Terminal" is renamed to **"Close Pane"** to reflect that it works for any pane type:

| Command | Action | Shortcut |
|---|---|---|
| New Terminal | `viewModel.addTerminal()` | ⌘T |
| New Browser | `viewModel.addBrowser()` | — |
| Close Pane | Close the focused pane | ⌘W |
| Toggle Full Screen | `NSApp.keyWindow?.toggleFullScreen(nil)` | ⌃⌘F |
| Minimize | `NSApp.keyWindow?.miniaturize(nil)` | ⌘M |
| Zoom | `NSApp.keyWindow?.zoom(nil)` | — |

Additionally, when the focused pane is a browser pane, the contextual browser commands appear (see Section 5): Navigate To..., Go Back, Go Forward, Reload Page.

**Renaming "Close Terminal" to "Close Pane":** This rename applies everywhere — the command palette, the menu bar, and any keyboard shortcut labels. "Close Pane" is accurate for both pane types and doesn't mislead users into thinking browser panes can't be closed with the same command.

### 9. Adding a Browser Pane

A new `addBrowser()` method on the view model (renamed from `TerminalContainerViewModel` — see Section 14), following the same pattern as `addTerminal()`:

1. Get the `contextualPane` to determine insertion position and inherit pane width.
2. Create a `BrowserPaneModel` with `about:blank`.
3. Insert after the contextual pane (or append if none focused).
4. Double-async focus the new pane.

The default URL is `about:blank` — a neutral starting point that loads instantly. The user invokes "Navigate To..." from the command palette (Cmd+K → type URL) to navigate.

### 10. Focus Management

Browser panes participate in the same focus system as terminal panes:

- **Cmd+Shift+[ / ]** navigates between all panes (both terminal and browser).
- **Cmd+Shift+Return** (focus mode) works on browser panes — expands the focused browser to fill the viewport.
- **Click-to-focus** on the header works the same way.
- **`makeFocused(index:)`** needs to handle both pane types. Currently it walks the NSView hierarchy looking for `GhosttyTerminalNSView`. It must also look for the browser's `WKWebView` to make it first responder.

### 11. Resize and Reorder

Browser panes use the same `paneWidth` property (on `PaneModel`) and participate in the same drag-to-resize and drag-to-reorder systems. No changes needed to `TerminalPaneWithHandle`, `FocusModeWrapper`, or the drop delegates — they already operate on the array of panes by index and ID.

The `snapToGrid()` function (which aligns pane widths to the terminal character grid) could optionally skip snapping for browser panes, since browsers don't have a character grid. However, for visual consistency in the horizontal layout, all panes snap to the same grid. This can be revisited if it feels wrong in practice.

### 12. Closing Panes

`closeCurrentPane()` handles both pane types. For terminal panes, it checks `ghostty_surface_needs_confirm_quit()` before closing. For browser panes, no confirmation is needed — there's no running process to interrupt:

```swift
func closeCurrentPane() {
    guard let pane = contextualPane else { return }
    if let terminal = pane as? TerminalPaneModel {
        // Existing confirmation logic for active terminal sessions
        ...
    } else {
        // Browser panes (and any future pane types) — no confirmation needed
        removePaneById(pane.id)
    }
}
```

### 13. Git and Action Discovery

The Combine pipeline that tracks the focused terminal's working directory for git detection and action discovery currently reads `focusedTerminal.$directory`. When a browser pane is focused, `PaneModel.directory` returns `nil`.

**Behavior:** When a browser pane is focused, `focusedDirectory` becomes `nil`. The git root clears to `nil` and the action list clears to empty. This is the correct semantic — there is no active directory, so there are no project actions and no git context. The `+` dropdown shows only the built-in items (New Terminal, New Browser) plus any global actions.

This is a clean signal to the rest of the system. Any code that depends on a working directory can check for `nil` and handle it explicitly rather than operating on stale data from a previously focused terminal.

### 14. Naming Conventions

With the introduction of browser panes, several names shift from "terminal" to "pane":

| Old Name | New Name |
|---|---|
| `TerminalModel` | `TerminalPaneModel` (subclass of `PaneModel`) |
| `TerminalStatus` | `PaneStatus` |
| `terminals: [TerminalModel]` | `panes: [PaneModel]` |
| `addTerminal()` | `addTerminal()` (unchanged — still creates a terminal pane) |
| `removeTerminal(byId:)` | `removePane(byId:)` |
| `closeCurrentPane()` | `closeCurrentPane()` (unchanged) |
| `contextualTerminal` | `contextualPane` |
| `focusedTerminalSubject` | `focusedPaneSubject` |
| `TerminalContainerViewModel` | `PaneContainerViewModel` |
| `TerminalHeaderView` | `PaneHeaderView` |
| `TerminalPaneView` | `PaneView` |
| `TerminalPaneWithHandle` | `PaneWithHandle` |
| Close Terminal (command palette) | Close Pane |

Methods that are terminal-specific keep "terminal" in their name: `addTerminal()` creates a terminal pane, `executeAction()` creates a terminal pane. The new `addBrowser()` creates a browser pane. Generic operations use "pane": `closeCurrentPane()`, `removePane(byId:)`, `movePane(id:toSlot:)`.

### 15. App Sandbox and Entitlements

`WKWebView` works within App Sandbox when the app has the `com.apple.security.network.client` entitlement, which Watchtower already has. No additional entitlements are needed for basic web browsing.

JavaScript is enabled by default in `WKWebView`. This is required for most modern websites to function. The default `WKWebViewConfiguration` is sufficient — no custom content rules, user scripts, or message handlers are needed initially.

### 16. Navigation Delegate Behavior

The `WKNavigationDelegate` on the coordinator handles:

- **`decidePolicyFor navigationAction:`** — allow all navigations. New-window requests (target=_blank) open in the same web view rather than spawning a system browser or creating a new pane.
- **`decidePolicyFor navigationResponse:`** — capture the HTTP status code from `HTTPURLResponse` and write to `BrowserPaneModel.httpStatusCode`.
- **`didStartProvisionalNavigation:`** — update `BrowserPaneModel.isLoading`.
- **`didFinish:`** — update `BrowserPaneModel.isLoading`, sync URL/title.
- **`didFail:`** / **`didFailProvisionalNavigation:`** — set error state on the model (status becomes `.failed`).

No download handling, no custom URL schemes, no authentication challenges. These can be added later if needed.

## Open Questions

### 1. Multiple Browser Panes Sharing State

Should browser panes share cookies/session state (one `WKWebsiteDataStore`) or be isolated? The default `WKWebViewConfiguration` shares state across all web views in the process, which means logging into a service in one browser pane makes you logged in across all of them. This is probably desirable for dev workflows.

### 2. Grid Snapping for Browser Panes

Should browser pane widths snap to the terminal character grid? The spec says yes for visual consistency, but browsers don't benefit from grid alignment. This is a minor UX detail to decide during implementation.

### 3. Navigate To... UX

The "Navigate To..." command in the palette replaces the filter field with a URL input. An alternative is to open a separate small dialog (like the action dialog). The inline approach is cleaner but adds complexity to the palette's state machine. To be decided during implementation.

## Implementation Plan

1. **PaneModel base class** — create `PaneModel.swift` with the base class: `id`, `paneWidth`, `isFocused`, `isDragging`, and overridable computed properties for `title`, `subtitle`, `status`, `progress`, `directory`.
2. **PaneStatus enum** — create `PaneStatus` (replacing `TerminalStatus`) with `.active`, `.idle`, `.failed` cases.
3. **TerminalPaneModel** — rename `TerminalModel` to `TerminalPaneModel`, make it a subclass of `PaneModel`. Move `id`, `paneWidth`, `isFocused`, `isDragging` up to the superclass. Override `title`, `subtitle`, `status`, `directory`. Keep terminal-specific properties (`command`, `env`, `waitAfterCommand`, `gitBranch`).
4. **BrowserPaneModel** — create `BrowserPaneModel.swift` as a subclass of `PaneModel` with URL, pageTitle, loading state, navigation state, HTTP status code. Override `title`, `subtitle`, `status`, `progress`.
5. **Refactor view model** — rename `TerminalContainerViewModel` to `PaneContainerViewModel`, rename `terminals` to `panes`, change the type to `[PaneModel]`. Update all methods. Rename `contextualTerminal` to `contextualPane`, `removeTerminal(byId:)` to `removePane(byId:)`, etc. Add `addBrowser()`.
6. **Header progress bar** — add a 4px bottom border to `PaneHeaderView` (renamed from `TerminalHeaderView`) that renders `PaneModel.progress`. Clear when nil, filled proportionally when non-nil.
7. **Rename views** — `TerminalPaneView` → `PaneView`, `TerminalHeaderView` → `PaneHeaderView`, `TerminalPaneWithHandle` → `PaneWithHandle`. Update `PaneView` to accept `PaneModel` and switch on the concrete subclass to render either `GhosttyTerminalView` or `BrowserWebView`.
8. **BrowserWebView** — create `BrowserWebView.swift` with the `NSViewRepresentable` WKWebView wrapper, KVO observers bridging to `BrowserPaneModel`, navigation delegate with HTTP status code capture.
9. **Toolbar integration** — replace the conditional `if/else` toolbar with a single `Menu` that always renders. "New Terminal" and "New Browser" as the first two items, divider, then actions.
10. **Focus management** — update `makeFocused(index:)` to handle both `GhosttyTerminalNSView` and `WKWebView` first responder targets.
11. **closeCurrentPane() update** — use `as? TerminalPaneModel` to determine whether confirmation is needed.
12. **Git and action discovery** — update the Combine pipeline to emit `nil` for `focusedDirectory` when a browser pane is focused, clearing git root and project actions.
13. **Command palette updates** — rename "Close Terminal" to "Close Pane", add "New Browser" to built-ins, add contextual browser commands (Navigate To..., Go Back, Go Forward, Reload Page).
14. **Menu bar updates** — add browser navigation commands to the menu bar (Go Back ⌘[, Go Forward ⌘], Reload ⌘R), enabled only when a browser pane is focused. Add "New Browser" menu item.
15. **Update all references** — `FocusModeWrapper`, `PaneWithHandle`, drop delegates, `ContentView`, `WatchtowerApp`, `GhosttyTerminalView`, `CommandPaletteView`, `GhosttyAppManager` callbacks.

## Files to Create or Modify

| File | Action | Description |
|---|---|---|
| `PaneModel.swift` | Create | Base `PaneModel` class with shared properties and overridable computed properties for title, subtitle, status, progress, directory. `PaneStatus` enum. |
| `BrowserPaneModel.swift` | Create | `PaneModel` subclass for browser state: URL, pageTitle, loading, navigation, HTTP status code |
| `BrowserWebView.swift` | Create | `NSViewRepresentable` wrapping `WKWebView` with KVO bridge, navigation delegate, HTTP status code capture |
| `TerminalModel.swift` | Rename/Modify | Rename to `TerminalPaneModel.swift`. Make subclass of `PaneModel`. Remove `id`, `paneWidth`, `isFocused`, `isDragging` (moved to superclass). Rename `TerminalStatus` to `PaneStatus` (moved to `PaneModel.swift`). |
| `TerminalPaneView.swift` | Rename/Modify | Rename to `PaneView.swift`. Accept `PaneModel`, switch on concrete subclass to render `GhosttyTerminalView` or `BrowserWebView`. Rename `TerminalHeaderView` to `PaneHeaderView`. Add 4px progress bar. |
| `ContentView.swift` | Modify | Rename `TerminalContainerViewModel` to `PaneContainerViewModel`. Change `terminals` to `panes: [PaneModel]`. Always render `Menu` for `+` button (remove conditional). Add "New Browser" item. Update all array references and naming. |
| `WatchtowerApp.swift` | Modify | Add "New Browser" menu command. Add browser navigation commands (Go Back, Go Forward, Reload). Rename "Close Terminal" to "Close Pane". Update `FocusedTerminalViewModelKey` naming. |
| `GhosttyTerminalView.swift` | Modify | Update references from `TerminalModel` to `TerminalPaneModel` |
| `CommandPaletteView.swift` | Modify | Rename "Close Terminal" to "Close Pane". Add "New Browser" to built-ins. Add contextual browser commands (Navigate To..., Go Back, Go Forward, Reload Page). |
| `GhosttyAppManager.swift` | Modify | Update any references to `TerminalModel` → `TerminalPaneModel` if present in callbacks |
| `Action.swift` | No change | Actions still create terminal panes |
| `ActionDialogView.swift` | No change | Action dialogs still create terminal panes |
| `ActionDiscovery.swift` | No change | Discovery pipeline unchanged, but results clear when browser pane is focused |
