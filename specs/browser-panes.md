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
    var progress: PaneProgress? { nil }
    var directory: String? { nil }

    static let defaultPaneWidth: CGFloat = 80 * 9 + 40
}
```

`TerminalPaneModel` and `BrowserPaneModel` are subclasses:

```swift
class TerminalPaneModel: PaneModel {
    // Existing TerminalModel properties: title, status, directory, gitBranch,
    // command, env, waitAfterCommand — all live here.
    // Overrides PaneModel's computed title, subtitle, status, progress, directory.
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

**PaneProgress model:**

```swift
struct PaneProgress {
    enum State {
        case normal       // standard progress (accent color)
        case error        // error state (red)
        case paused       // paused state (orange)
        case indeterminate // bouncing animation, no percentage
    }

    let state: State
    let value: Double?    // 0.0–1.0, nil for indeterminate
}
```

**Rendering behavior:**
- When `PaneModel.progress` is `nil`, the bar renders as `Color.clear` — invisible, taking no visual space beyond its 4px allocation.
- When `progress` is non-nil with a `value`, the bar fills proportionally using the state's color.
- When `state` is `.indeterminate`, a bouncing/sliding animation plays (matching Ghostty's reference implementation).
- When `state` is `.error`, the bar renders in red.
- When `state` is `.paused`, the bar renders in orange.
- When progress reaches 1.0 in the `.normal` state, it holds briefly (200ms) then fades to clear.

**For browser panes:** `progress` returns `PaneProgress(state: .normal, value: estimatedProgress)` while loading, `nil` otherwise.

**For terminal panes:** `progress` is driven by Ghostty's `GHOSTTY_ACTION_PROGRESS_REPORT` action (see Section 4).

### 4. Terminal Progress via Ghostty

Ghostty supports the ConEmu OSC 9;4 progress reporting protocol. Terminal processes can report progress by printing the escape sequence `ESC ] 9 ; 4 ; <state> ; <progress> ST`. Watchtower wires this into the universal header progress bar.

**Ghostty C API:**

```c
typedef enum {
    GHOSTTY_PROGRESS_STATE_REMOVE,        // clear the progress bar
    GHOSTTY_PROGRESS_STATE_SET,           // set to a specific percentage
    GHOSTTY_PROGRESS_STATE_ERROR,         // error state (red)
    GHOSTTY_PROGRESS_STATE_INDETERMINATE, // bouncing animation
    GHOSTTY_PROGRESS_STATE_PAUSE,         // paused state (orange)
} ghostty_action_progress_report_state_e;

typedef struct {
    ghostty_action_progress_report_state_e state;
    int8_t progress;  // -1 if no progress, otherwise 0-100
} ghostty_action_progress_report_s;
```

This is delivered via the `action_cb` callback with `GHOSTTY_ACTION_PROGRESS_REPORT` tag, targeting a specific surface.

**Mapping to PaneProgress:**

| Ghostty State | PaneProgress |
|---|---|
| `REMOVE` | `nil` (clear the bar) |
| `SET` with progress 0–100 | `.normal`, value = progress/100 |
| `SET` with progress -1 | `.indeterminate` |
| `ERROR` with progress 0–100 | `.error`, value = progress/100 |
| `ERROR` with progress -1 | `.error`, value = nil (indeterminate error) |
| `INDETERMINATE` | `.indeterminate` |
| `PAUSE` with progress 0–100 | `.paused`, value = progress/100 |
| `PAUSE` with progress -1 | `.paused`, value = 1.0 (full bar, matching Ghostty reference) |

**Implementation:** In `GhosttyAppManager.swift`'s `action_cb`, handle the `GHOSTTY_ACTION_PROGRESS_REPORT` case. Resolve the surface to its `TerminalPaneModel` (via the surface's userdata → `GhosttyTerminalNSView` → pane model) and write the mapped `PaneProgress` to a new `@Published var progressReport: PaneProgress?` property on `TerminalPaneModel`. The `progress` computed property override reads from `progressReport`.

**Auto-clear timer:** Following the Ghostty reference implementation, progress reports auto-clear after 15 seconds of inactivity (no new progress report received). This prevents stale progress bars from lingering if a process crashes or forgets to send the remove signal.

**Practical use:** Build tools like `cmake`, `ninja`, and `cargo` can emit ConEmu progress sequences. Users can also add progress reporting to their own scripts:

```bash
# Report 42% progress
echo -ne '\033]9;4;1;42\033\\'
# Report completion
echo -ne '\033]9;4;0;\033\\'
```

### 5. BrowserPaneModel

```swift
class BrowserPaneModel: PaneModel {
    @Published var url: URL
    @Published var pageTitle: String = "New Tab"
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var estimatedProgress: Double = 0.0
    @Published var httpStatusCode: Int? = nil
    @Published var hasInteractedForms: Bool = false

    override var title: String { pageTitle }
    override var subtitle: String? { url.host }
    override var directory: String? { nil }

    override var status: PaneStatus {
        if isLoading { return .active }
        if let code = httpStatusCode, !(200..<300).contains(code) { return .failed }
        return .idle
    }

    override var progress: PaneProgress? {
        isLoading ? PaneProgress(state: .normal, value: estimatedProgress) : nil
    }

    init(url: URL = URL(string: "about:blank")!, paneWidth: CGFloat = PaneModel.defaultPaneWidth) {
        self.url = url
        super.init(id: UUID(), paneWidth: paneWidth)
    }
}
```

`BrowserPaneModel` is intentionally minimal. It mirrors the observable state that `WKWebView` exposes via KVO (`title`, `isLoading`, `canGoBack`, `canGoForward`, `estimatedProgress`, `url`) plus the HTTP status code from navigation responses and form interaction tracking.

**Page title as pane title:** The `<title>` of the loaded page becomes the pane's title in the header, shown to the left. While loading a new page, the title updates when `WKWebView` reports a new title via KVO. Before any page loads (on `about:blank`), the title is "New Tab".

### 6. Browser Pane Layout

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

### 7. Command Palette: Contextual Commands

The command palette is **contextually aware** of the focused pane type. Commands that only apply to one pane type appear only when that pane type is focused.

**Always visible (any pane type focused):**

| Command | Action | Shortcut |
|---|---|---|
| New Terminal | `viewModel.addTerminal()` | ⌘T |
| New Browser | `viewModel.addBrowser()` | — |
| Go to URL... | Navigate or open browser pane to the typed URL | — |
| Search the web... | Search DuckDuckGo for the typed query | — |
| Close Pane | Close the focused pane | ⌘W |
| Toggle Full Screen | `NSApp.keyWindow?.toggleFullScreen(nil)` | ⌃⌘F |
| Minimize | `NSApp.keyWindow?.miniaturize(nil)` | ⌘M |
| Zoom | `NSApp.keyWindow?.zoom(nil)` | — |

**Only when a browser pane is focused:**

| Command | Action | Shortcut |
|---|---|---|
| Go Back | `webView.goBack()` | ⌘[ |
| Go Forward | `webView.goForward()` | ⌘] |
| Reload Page | `webView.reload()` | ⌘R |

Go Back, Go Forward, and Reload Page do **not** appear in the palette when a terminal pane is focused. They are browser-specific operations with no terminal equivalent. The corresponding menu bar items follow the same rule — they are disabled (greyed out) when the focused pane is not a browser pane.

### 8. Command Palette: "Go to URL..." and "Search the web..."

These two commands are **always available** regardless of which pane type is focused, and they use the palette's query text as their input rather than matching against it.

**"Go to URL..."** — takes the current palette query text and navigates to it as a URL:
- If the focused pane is a browser pane, navigates that pane to the URL.
- If the focused pane is a terminal pane (or any non-browser pane), creates a new browser pane and navigates it to the URL.
- If the input has no scheme, `https://` is prepended (with an exception for `localhost` and IP addresses, which get `http://`).

**"Search the web..."** — takes the current palette query text and searches DuckDuckGo:
- Constructs `https://duckduckgo.com/?q=<url-encoded query>`.
- Same pane behavior as "Go to URL...": navigates the focused browser pane, or creates a new one if focused on a terminal.

**Focus restoration (`managesFocus: false`):** Both query actions use `managesFocus: false`, meaning the command palette's standard focus restoration runs after dismissal. This is critical because the action branches at runtime: when navigating an **existing** browser pane (just setting `browser.url`), no focus management happens inside the action — the palette's `dismissCommandPalette(restoreFocus: true)` double-async restores focus to the browser pane. When creating a **new** browser pane via `addBrowser()`, that method has its own double-async focus logic that runs after the palette's restoration and wins. Using `managesFocus: true` would skip focus restoration entirely, leaving focus in limbo when navigating an existing browser.

**Fuzzy matching exception:** These two commands are **exempt from fuzzy matching**. They always appear in the results list when the query is non-empty, regardless of whether the query text fuzzy-matches "Go to URL" or "Search the web". They appear at the **bottom** of the filtered results, below any fuzzy-matched commands, as special "act on query" entries. When the query is empty, they do not appear (there is nothing to navigate to or search for).

**Smart default selection:** The ordering of "Go to URL..." and "Search the web..." relative to each other — and which one is pre-selected — depends on whether the query text looks like a URL:

A query is considered **URL-like** if it matches any of these heuristics:
- Contains a scheme (`http://`, `https://`, `file://`, etc.)
- Starts with `localhost` (with or without a port)
- Looks like a domain: contains a dot with no spaces and a valid TLD-like suffix (e.g., `example.com`, `github.com/foo/bar`, `192.168.1.1:8080`)

When the query **looks like a URL:**
- "Go to URL..." appears **first** (above "Search the web...") and is **pre-selected** if no fuzzy-matched commands are above it.
- Pressing Enter immediately navigates to the URL.

```
╔══════════════════════════════════════╗
║ localhost:3000                        ║
╠══════════════════════════════════════╣
║ ─────────────────────────────────── ║
║ ▸ Go to URL       localhost:3000     ║
║   Search the web  localhost:3000     ║
╚══════════════════════════════════════╝
```

When the query **does not look like a URL** (natural language, single words without dots, etc.):
- "Search the web..." appears **first** (above "Go to URL...") and is **pre-selected** if no fuzzy-matched commands are above it.
- Pressing Enter immediately searches.

```
╔══════════════════════════════════════╗
║ how do I compile swift code           ║
╠══════════════════════════════════════╣
║ ─────────────────────────────────── ║
║ ▸ Search the web  how do I compile…  ║
║   Go to URL       how do I compile…  ║
╚══════════════════════════════════════╝
```

When there **are** fuzzy-matched results above (e.g., the query matches a command like "New Terminal"), the first fuzzy-matched result is selected as normal. "Go to URL..." and "Search the web..." appear below, still in their contextual order, and the user can arrow down to them.

```
╔══════════════════════════════════════╗
║ new                                   ║
╠══════════════════════════════════════╣
║ ▸ New Terminal                  ⌘T   ║
║   New Browser                        ║
║ ─────────────────────────────────── ║
║   Search the web  new                ║
║   Go to URL       new                ║
╚══════════════════════════════════════╝
```

**Visual treatment:** These two items are visually distinct from normal results — they show the query text inline as a preview of what will happen. The right side shows the query text (or a truncated version if long). This makes it clear that selecting "Go to URL" will navigate to `example.com` and selecting "Search the web" will search for `example.com`. A thin separator divides the fuzzy-matched results from these two entries.

**Keyboard selection:** Arrow keys navigate through both fuzzy-matched results and these special entries. The selection wraps as normal. The contextual ordering ensures that the most likely intent is always closest to the user's current selection.

### 9. WKWebView Wrapper

A new `BrowserWebView.swift` containing the `NSViewRepresentable` wrapper and a custom `WatchtowerWebView` subclass of `WKWebView`:

```swift
/// Custom WKWebView subclass that participates in the app's focus tracking,
/// lets app-level keyboard shortcuts pass through to the menu system, and
/// intercepts Cmd+W to close just the pane.
class WatchtowerWebView: WKWebView {
    weak var browser: BrowserPaneModel?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        // Bridge into PaneModel.isFocused — matching GhosttyTerminalNSView's pattern
        let result = super.becomeFirstResponder()
        if result { browser?.isFocused = true }
        return result
    }

    override func resignFirstResponder() -> Bool {
        // Clear isFocused when another view becomes first responder
        let result = super.resignFirstResponder()
        if result { browser?.isFocused = false }
        return result
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // WKWebView internally consumes Cmd+[ and Cmd+] (and their Shift variants)
        // for browser back/forward. We must let Cmd+Shift+[/] pass through to the
        // menu system for pane navigation.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .shift],
           let chars = event.charactersIgnoringModifiers,
           chars == "[" || chars == "]" {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func performClose(_ sender: Any?) {
        // Intercept Cmd+W — close just this pane, not the window.
        // Posts .browserPaneClosed notification (parallel to .ghosttySurfaceClosed
        // used by GhosttyTerminalNSView). Includes form interaction confirmation.
        ...
    }
}

struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var browser: BrowserPaneModel

    func makeNSView(context: Context) -> WatchtowerWebView {
        let webView = WatchtowerWebView(frame: .zero, configuration: BrowserConfiguration.shared)
        webView.browser = browser
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // KVO observers for title, isLoading, canGoBack, canGoForward, estimatedProgress, url
        return webView
    }

    func updateNSView(_ webView: WatchtowerWebView, context: Context) {
        // Navigate only when the model's URL changes and differs from the web view's current URL
    }
}
```

**Why a subclass is required (not a plain WKWebView):** Three behaviors require overriding `WKWebView` methods that `NSViewRepresentable` cannot intercept:

1. **Focus tracking** — `WKWebView` is Apple's class with no hooks for `becomeFirstResponder`/`resignFirstResponder`. Without overrides, `PaneModel.isFocused` is never cleared when focus leaves a browser pane (e.g., clicking on a terminal), causing stale focus rings. The `GhosttyTerminalNSView` handles this via its own overrides; `WatchtowerWebView` mirrors that pattern.

2. **Keyboard shortcut passthrough** — `WKWebView`'s internal `performKeyEquivalent` returns `true` for Cmd+[ and Cmd+] (browser back/forward), and the Shift modifier does not prevent WebKit from claiming them. This blocks Cmd+Shift+[/] (pane navigation) from reaching the SwiftUI menu system. The override returns `false` for Cmd+Shift+[/] specifically.

3. **Cmd+W interception** — Without a `performClose` override, Cmd+W propagates up the responder chain to `NSWindow.performClose`, closing the entire window. The override posts a `.browserPaneClosed` notification (see Section 14) to close just the pane, matching `GhosttyTerminalNSView`'s pattern with `.ghosttySurfaceClosed`.

**KVO bridge:** The coordinator observes `WKWebView`'s KVO properties and writes them back to `BrowserPaneModel`'s `@Published` properties. This is the same pattern as `GhosttyTerminalView` bridging Ghostty's C callbacks to `TerminalModel`'s published properties.

**HTTP status code capture:** The navigation delegate's `decidePolicyFor navigationResponse` callback exposes the `HTTPURLResponse`, from which the status code is read and written to `BrowserPaneModel.httpStatusCode`. This drives the red status dot for non-2xx responses.

**Shared WKWebViewConfiguration:** All browser panes share a single `WKWebViewConfiguration` instance (and therefore a single `WKWebsiteDataStore`). This means cookies, localStorage, and session state are shared across all browser panes — logging into a service in one pane makes you logged in across all of them. This is the desired behavior for dev workflows where multiple panes may hit the same local dev server or dashboard. The shared configuration is created once (e.g., as a static property or on the view model) and passed to every new `BrowserWebView`.

**First responder:** When a browser pane is focused, the `WatchtowerWebView` becomes first responder so keyboard events (scrolling, form input, keyboard shortcuts on web pages) work correctly. `makeFocused(index:)` walks the NSView hierarchy looking for `WatchtowerWebView` instances (in addition to `GhosttyTerminalNSView`) and calls `window.makeFirstResponder`. The `WatchtowerWebView` subclass's `becomeFirstResponder`/`resignFirstResponder` overrides keep `PaneModel.isFocused` in sync automatically.

### 10. Toolbar Integration

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

### 11. Adding a Browser Pane

A new `addBrowser(url:)` method on the view model (renamed from `TerminalContainerViewModel` — see Section 17), following the same pattern as `addTerminal()`:

1. Get the `contextualPane` to determine insertion position and inherit pane width.
2. Create a `BrowserPaneModel` with the given URL (defaults to `about:blank`).
3. Insert after the contextual pane (or append if none focused).
4. Double-async focus the new pane.

The default URL is `about:blank` — a neutral starting point that loads instantly. The user invokes "Go to URL..." from the command palette (Cmd+K → type URL → Enter) to navigate.

The `url:` parameter allows callers like "Go to URL..." and "Search the web..." to create a browser pane pre-navigated to a specific URL.

### 12. Focus Management

Browser panes participate in the same focus system as terminal panes:

- **Cmd+Shift+[ / ]** navigates between all panes (both terminal and browser).
- **Cmd+Shift+Return** (focus mode) works on browser panes — expands the focused browser to fill the viewport.
- **Click-to-focus** on the header works the same way.
- **Click-to-focus on the content area** also works — clicking directly on the `WatchtowerWebView` triggers macOS's first-responder system, which calls `becomeFirstResponder` on the web view and `resignFirstResponder` on the previously focused view.
- **`makeFocused(index:)`** handles both pane types. It walks the NSView hierarchy looking for `GhosttyTerminalNSView` (for terminals) or `WatchtowerWebView` (for browsers) and calls `window.makeFirstResponder(targetView)`.

**Focus ring symmetry:** Both `GhosttyTerminalNSView` and `WatchtowerWebView` override `becomeFirstResponder()` and `resignFirstResponder()` to set/clear `PaneModel.isFocused`. This means focus tracking is fully symmetric — when any view becomes first responder, the previously focused view's `isFocused` is automatically cleared by macOS's responder chain. `makeFocused(index:)` does not need to manually clear `isFocused` on other panes; the responder lifecycle handles it.

**WKWebView keyboard shortcut interception:** `WKWebView` internally consumes Cmd+[ and Cmd+] (and their Shift-modified variants) via its `performKeyEquivalent` implementation, treating them as browser back/forward navigation. Without intervention, Cmd+Shift+[/] would never reach the SwiftUI menu system. `WatchtowerWebView` overrides `performKeyEquivalent` to return `false` for Cmd+Shift+[/] specifically, letting the pane navigation shortcuts work. Plain Cmd+[/] (without Shift) is still consumed by WebKit for browser back/forward when a browser pane is focused.

### 13. Resize and Reorder

Browser panes use the same `paneWidth` property (on `PaneModel`) and participate in the same drag-to-resize and drag-to-reorder systems. No changes needed to `PaneWithHandle`, `FocusModeWrapper`, or the drop delegates — they already operate on the array of panes by index and ID.

The existing `snapToGrid()` function (at `ContentView.swift:183`) aligns pane widths to an estimated terminal character grid during resize drags. This function is **removed** as part of this spec. Grid snapping was designed for terminals but provides no benefit for browser panes, and mixed-type pane stacks would require different snapping behavior per pane type — added complexity for marginal value. Pane widths are set directly from the drag gesture without snapping. The `estimatedCellWidth` constant and the anchor-based drag logic remain; only the `snapToGrid()` call is removed.

### 14. Closing Panes

`closeCurrentPane()` handles both pane types. For terminal panes, it checks `ghostty_surface_needs_confirm_quit()` before closing. For browser panes, it checks whether any form elements have been interacted with:

```swift
func closeCurrentPane() {
    guard let pane = contextualPane else { return }
    if let terminal = pane as? TerminalPaneModel {
        // Existing confirmation logic for active terminal sessions
        ...
    } else if let browser = pane as? BrowserPaneModel {
        if browser.hasInteractedForms {
            // Show confirmation: "There are changes on this page that will be lost."
            let alert = NSAlert()
            alert.messageText = "Close Browser Pane?"
            alert.informativeText = "There are unsaved changes on this page that will be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    self?.removePaneById(pane.id)
                }
            }
        } else {
            removePaneById(pane.id)
        }
    }
}
```

**Cmd+W interception via `performClose`:** macOS routes the "Close" menu item (Cmd+W) by sending `performClose(_:)` to the first responder. For terminal panes, `GhosttyTerminalNSView` overrides `performClose` to post a `.ghosttySurfaceClosed` notification instead of closing the window. Browser panes require the same treatment — `WatchtowerWebView` overrides `performClose` to:

1. Check `browser.hasInteractedForms` and show a confirmation alert if needed.
2. Post a `.browserPaneClosed` notification (defined alongside `.ghosttySurfaceClosed` in `GhosttyAppManager.swift`) with the pane ID in `userInfo`.
3. ContentView listens for `.browserPaneClosed` and calls `removePane(byId:)`, which handles focus transfer and the last-pane edge case.

Without this override, Cmd+W on a focused browser pane would propagate up the responder chain to `NSWindow.performClose`, closing the entire window.

**Form interaction detection:** `WKWebView` does not provide a native `beforeunload` API on macOS. Instead, a small JavaScript snippet is injected via `WKUserScript` at document start that listens for `input`, `change`, and `textarea` events on form elements and posts a message back via `WKScriptMessageHandler`:

```javascript
(function() {
    var changed = false;
    document.addEventListener('input', function(e) {
        if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.tagName === 'SELECT') {
            if (!changed) {
                changed = true;
                window.webkit.messageHandlers.formInteraction.postMessage(true);
            }
        }
    }, true);
    // Reset on navigation
    window.addEventListener('beforeunload', function() { changed = false; });
})();
```

The `WKScriptMessageHandler` on the coordinator receives the message and sets `BrowserPaneModel.hasInteractedForms = true`. The flag resets to `false` on each new navigation (in the `didStartProvisionalNavigation` delegate callback).

### 15. Git and Action Discovery

The Combine pipeline that tracks the focused terminal's working directory for git detection and action discovery currently reads `focusedTerminal.$directory`. When a browser pane is focused, `PaneModel.directory` returns `nil`.

**Behavior:** When a browser pane is focused, `focusedDirectory` becomes `nil`. The git root clears to `nil` and the action list clears to empty. This is the correct semantic — there is no active directory, so there are no project actions and no git context. The `+` dropdown shows only the built-in items (New Terminal, New Browser) plus any global actions.

This is a clean signal to the rest of the system. Any code that depends on a working directory can check for `nil` and handle it explicitly rather than operating on stale data from a previously focused terminal.

### 16. Navigation Delegate Behavior

The `WKNavigationDelegate` on the coordinator handles:

- **`decidePolicyFor navigationAction:`** — allow all navigations. New-window requests (target=_blank) open in the same web view rather than spawning a system browser or creating a new pane.
- **`decidePolicyFor navigationResponse:`** — capture the HTTP status code from `HTTPURLResponse` and write to `BrowserPaneModel.httpStatusCode`.
- **`didStartProvisionalNavigation:`** — update `BrowserPaneModel.isLoading`, reset `hasInteractedForms` to `false`.
- **`didFinish:`** — update `BrowserPaneModel.isLoading`, sync URL/title.
- **`didFail:`** / **`didFailProvisionalNavigation:`** — set error state on the model (status becomes `.failed`).

No download handling, no custom URL schemes, no authentication challenges. These can be added later if needed.

### 17. Naming Conventions

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

### 18. App Sandbox and Entitlements

`WKWebView` works within App Sandbox when the app has the `com.apple.security.network.client` entitlement, which Watchtower already has. No additional entitlements are needed for basic web browsing.

JavaScript is enabled by default in `WKWebView`. This is required for most modern websites to function. The shared `WKWebViewConfiguration` needs a `WKUserContentController` with the form interaction detection script (see Section 14), but no other custom content rules or message handlers.

## Open Questions

### 1. Search Engine Choice

The spec hardcodes DuckDuckGo for "Search the web...". This could be configurable in the future, but a single default keeps the implementation simple for now. DuckDuckGo is a reasonable default for a developer audience.

## Implementation Plan

1. **PaneModel base class** — create `PaneModel.swift` with the base class: `id`, `paneWidth`, `isFocused`, `isDragging`, and overridable computed properties for `title`, `subtitle`, `status`, `progress`, `directory`. Define `PaneStatus` enum and `PaneProgress` struct.
2. **TerminalPaneModel** — rename `TerminalModel` to `TerminalPaneModel`, make it a subclass of `PaneModel`. Move `id`, `paneWidth`, `isFocused`, `isDragging` up to the superclass. Override `title`, `subtitle`, `status`, `progress`, `directory`. Keep terminal-specific properties (`command`, `env`, `waitAfterCommand`, `gitBranch`). Add `@Published var progressReport: PaneProgress?` for Ghostty progress reports.
3. **BrowserPaneModel** — create `BrowserPaneModel.swift` as a subclass of `PaneModel` with URL, pageTitle, loading state, navigation state, HTTP status code, form interaction tracking. Override `title`, `subtitle`, `status`, `progress`.
4. **Refactor view model** — rename `TerminalContainerViewModel` to `PaneContainerViewModel`, rename `terminals` to `panes`, change the type to `[PaneModel]`. Update all methods. Rename `contextualTerminal` to `contextualPane`, `removeTerminal(byId:)` to `removePane(byId:)`, etc. Add `addBrowser(url:)`.
5. **Header progress bar** — add a 4px bottom border to `PaneHeaderView` (renamed from `TerminalHeaderView`) that renders `PaneModel.progress`. Supports determinate, indeterminate, error, and paused states. Clear when nil, filled proportionally when non-nil.
6. **Ghostty progress integration** — handle `GHOSTTY_ACTION_PROGRESS_REPORT` in `GhosttyAppManager.swift`'s `action_cb`. Map the 5 ghostty progress states to `PaneProgress`. Write to `TerminalPaneModel.progressReport`. Add 15-second auto-clear timer.
7. **Rename views** — `TerminalPaneView` → `PaneView`, `TerminalHeaderView` → `PaneHeaderView`, `TerminalPaneWithHandle` → `PaneWithHandle`. Update `PaneView` to accept `PaneModel` and switch on the concrete subclass to render either `GhosttyTerminalView` or `BrowserWebView`.
8. **BrowserWebView** — create `BrowserWebView.swift` with `WatchtowerWebView` (WKWebView subclass) implementing `becomeFirstResponder`/`resignFirstResponder` for focus tracking, `performKeyEquivalent` to pass Cmd+Shift+[/] to the menu system, and `performClose` for Cmd+W interception via `.browserPaneClosed` notification. Create the `BrowserWebView` `NSViewRepresentable` wrapper using `WatchtowerWebView`, with KVO observers bridging to `BrowserPaneModel`, navigation delegate with HTTP status code capture. Shared `WKWebViewConfiguration` across all browser panes. Form interaction detection via injected `WKUserScript` and `WKScriptMessageHandler`.
9. **Remove snapToGrid** — delete the `snapToGrid()` static method and `estimatedCellWidth` constant from `PaneWithHandle`. Remove the `snapToGrid()` call from the resize drag gesture. Pane widths are set directly from the drag delta.
10. **Toolbar integration** — replace the conditional `if/else` toolbar with a single `Menu` that always renders. "New Terminal" and "New Browser" as the first two items, divider, then actions.
11. **Focus management** — update `makeFocused(index:)` to handle both `GhosttyTerminalNSView` and `WatchtowerWebView` first responder targets. Focus tracking is symmetric via `becomeFirstResponder`/`resignFirstResponder` overrides on both view types — no manual `isFocused` clearing needed in `makeFocused`.
12. **closeCurrentPane() update** — use `as? TerminalPaneModel` / `as? BrowserPaneModel` to determine confirmation behavior. Terminal panes check `ghostty_surface_needs_confirm_quit()`. Browser panes check `hasInteractedForms`. Add `.browserPaneClosed` notification (defined in `GhosttyAppManager.swift` alongside `.ghosttySurfaceClosed`) posted by `WatchtowerWebView.performClose` and handled by ContentView to call `removePane(byId:)`.
13. **Git and action discovery** — update the Combine pipeline to emit `nil` for `focusedDirectory` when a browser pane is focused, clearing git root and project actions.
14. **Command palette updates** — rename "Close Terminal" to "Close Pane". Add "New Browser" to built-ins. Add contextual browser commands (Go Back, Go Forward, Reload Page) that only appear when a browser pane is focused. Add "Go to URL..." and "Search the web..." as always-visible, fuzzy-match-exempt entries that use the query text as input with `managesFocus: false` (critical for focus restoration when navigating an existing browser pane). Implement `isURLLike()` heuristic to determine their ordering and default selection (URL-like queries select "Go to URL..." first, non-URL queries select "Search the web..." first). Handle cross-pane behavior (navigate existing browser or create new one).
15. **Menu bar updates** — add browser navigation commands to the menu bar (Go Back ⌘[, Go Forward ⌘], Reload ⌘R), disabled when the focused pane is not a browser pane. Add "New Browser" menu item. Rename "Close Terminal" to "Close Pane".
16. **Update all references** — `FocusModeWrapper`, `PaneWithHandle`, drop delegates, `ContentView`, `WatchtowerApp`, `GhosttyTerminalView`, `CommandPaletteView`, `GhosttyAppManager` callbacks.

## Files to Create or Modify

| File | Action | Description |
|---|---|---|
| `PaneModel.swift` | Create | Base `PaneModel` class with shared properties, overridable computed properties for title/subtitle/status/progress/directory. `PaneStatus` enum. `PaneProgress` struct with state and value. |
| `BrowserPaneModel.swift` | Create | `PaneModel` subclass for browser state: URL, pageTitle, loading, navigation, HTTP status code, form interaction tracking |
| `BrowserWebView.swift` | Create | `WatchtowerWebView` (WKWebView subclass) with `becomeFirstResponder`/`resignFirstResponder` for focus tracking, `performKeyEquivalent` to pass Cmd+Shift+[/] to the menu system, `performClose` for Cmd+W interception via `.browserPaneClosed` notification. `BrowserWebView` NSViewRepresentable wrapper with KVO bridge, navigation delegate, HTTP status code capture, shared `WKWebViewConfiguration`, form interaction `WKUserScript` + `WKScriptMessageHandler` |
| `TerminalModel.swift` | Rename/Modify | Rename to `TerminalPaneModel.swift`. Make subclass of `PaneModel`. Remove `id`, `paneWidth`, `isFocused`, `isDragging` (moved to superclass). Add `progressReport: PaneProgress?` for Ghostty progress. Rename `TerminalStatus` to `PaneStatus` (moved to `PaneModel.swift`). |
| `TerminalPaneView.swift` | Rename/Modify | Rename to `PaneView.swift`. Accept `PaneModel`, switch on concrete subclass to render `GhosttyTerminalView` or `BrowserWebView`. Rename `TerminalHeaderView` to `PaneHeaderView`. Add 4px progress bar with determinate/indeterminate/error/paused states. |
| `ContentView.swift` | Modify | Rename `TerminalContainerViewModel` to `PaneContainerViewModel`. Change `terminals` to `panes: [PaneModel]`. Always render `Menu` for `+` button (remove conditional). Add "New Browser" item. Remove `snapToGrid()` and related constants. Update all array references and naming. Listen for `.browserPaneClosed` notification (alongside `.ghosttySurfaceClosed`) to call `removePane(byId:)`. |
| `WatchtowerApp.swift` | Modify | Add "New Browser" menu command. Add browser navigation commands (Go Back, Go Forward, Reload). Rename "Close Terminal" to "Close Pane". Update `FocusedTerminalViewModelKey` naming. |
| `GhosttyTerminalView.swift` | Modify | Update references from `TerminalModel` to `TerminalPaneModel` |
| `GhosttyAppManager.swift` | Modify | Handle `GHOSTTY_ACTION_PROGRESS_REPORT` in `action_cb`. Map ghostty progress states to `PaneProgress`. Resolve surface to `TerminalPaneModel` and write `progressReport`. Define `.browserPaneClosed` notification name alongside `.ghosttySurfaceClosed`. |
| `CommandPaletteView.swift` | Modify | Rename "Close Terminal" to "Close Pane". Add "New Browser" to built-ins. Add contextual browser commands (Go Back, Go Forward, Reload Page). Add "Go to URL..." and "Search the web..." as fuzzy-match-exempt query-action entries. |
| `Action.swift` | No change | Actions still create terminal panes |
| `ActionDialogView.swift` | No change | Action dialogs still create terminal panes |
| `ActionDiscovery.swift` | No change | Discovery pipeline unchanged, but results clear when browser pane is focused |
