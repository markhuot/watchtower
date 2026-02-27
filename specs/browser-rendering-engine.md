# Browser Rendering Engine Selection

## Summary

Add a settings screen to Watchtower with a "Browser Rendering Engine" preference. Users can choose between **WebKit** (the existing `WKWebView` implementation, the default) and **Chromium** (a new `CEFBrowser` implementation via the Chromium Embedded Framework). Both engines present identical behavior to the rest of the app — the same `BrowserPaneModel` drives either backend, and all navigation events, KVO-equivalent observations, focus management, and delegate callbacks map to the same model properties.

## Motivation

WebKit is macOS-native and works well for many sites, but some web applications target Chromium specifically — dev tools dashboards, complex SPAs with Chrome-only APIs, sites that sniff User-Agent and serve degraded experiences to Safari/WebKit. Offering a Chromium option lets developers use Watchtower's browser panes for sites that don't render correctly in WebKit without leaving the app for a standalone Chromium browser.

The engine preference has two layers: a **global default** (set in settings / config file) that controls what engine "New Browser" uses, and a **per-pane override** via the command palette ("Switch to Chromium" / "Switch to WebKit") that lets users switch the engine on an individual browser pane. Switching an existing pane's engine destroys the current web view and creates a new one with the other engine, reloading the current URL. Both engines are always bundled in the app — CEF ships alongside WebKit in every build.

## Detailed Design

### 1. Settings Infrastructure

Watchtower currently has no settings UI, no UserDefaults usage, and no config file of its own (it inherits Ghostty's config). This spec introduces all three: a config file, a Settings window that edits it, and runtime storage.

**Config file:** `~/.config/watchtower/config.json` — a JSON file. Example:

```json
{
    "browser-engine": "webkit"
}
```

The config file is the source of truth. It is read at app startup and whenever the Settings window saves a change. If the file does not exist or is missing keys, defaults are used (`"webkit"` for `browser-engine`). The file is created on first write (e.g., when the user changes a setting in the Settings window).

**Settings window:** A SwiftUI `Settings` scene (Cmd+,) that provides a GUI for editing the config file. When the user changes a value in the Settings window, it writes back to `~/.config/watchtower/config.json`. This keeps the file as the source of truth while providing a discoverable GUI.

**Runtime storage:** The parsed config values are held in a `WatchtowerConfig` singleton (or on `GhosttyAppManager`) so that code doesn't re-parse the file on every access. The Settings window reads from and writes to this singleton, which serializes to JSON on save.

**Enum:**

```swift
enum BrowserEngine: String, CaseIterable {
    case webkit = "webkit"
    case chromium = "chromium"

    var displayName: String {
        switch self {
        case .webkit: return "WebKit"
        case .chromium: return "Chromium"
        }
    }

    var description: String {
        switch self {
        case .webkit: return "macOS native engine (Safari). Best performance and energy efficiency."
        case .chromium: return "Chromium engine (CEF). Best compatibility with Chrome-targeted web apps."
        }
    }
}
```

### 2. Settings View

A new `SettingsView.swift` presented via SwiftUI's `Settings` scene in `WatchtowerApp.swift`:

```swift
// In WatchtowerApp.swift
Settings {
    SettingsView()
}
```

The settings window uses `TabView` with `.tabViewStyle(.automatic)` for future expansion (additional tabs can be added later). The first and only tab is "General".

**General tab layout:**

```
┌─ General ─────────────────────────────────────┐
│                                                │
│  Browser Rendering Engine                      │
│  ┌──────────────────────────┐                  │
│  │ WebKit                 ▾ │                  │
│  └──────────────────────────┘                  │
│  macOS native engine (Safari). Best            │
│  performance and energy efficiency.            │
│                                                │
│  Changes apply to new browser panes.           │
│  Existing panes keep their current engine      │
│  until switched via the command palette.       │
│                                                │
└────────────────────────────────────────────────┘
```

The picker is a standard SwiftUI `Picker` with `.pickerStyle(.menu)`. Below the picker, a caption in secondary text shows the description for the currently selected engine, plus a note about scope.

The Settings window reads from and writes to `WatchtowerConfig`. On save, `WatchtowerConfig` writes the updated values back to `~/.config/watchtower/config`.

```swift
struct SettingsView: View {
    @ObservedObject private var config = WatchtowerConfig.shared

    var body: some View {
        TabView {
            Form {
                Picker("Browser Rendering Engine", selection: $config.browserEngine) {
                    ForEach(BrowserEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.menu)
                Text(config.browserEngine.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Changes apply to new browser panes. Existing panes keep their current engine until switched via the command palette.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 450, height: 200)
    }
}
```

**Opening settings:** Standard macOS `Cmd+,` shortcut. SwiftUI's `Settings` scene handles this automatically. No custom menu item needed.

### 3. Protocol Abstraction: BrowserEngine Protocol

Currently, `BrowserPaneModel` holds a `weak var webView: WKWebView?` directly, and `BrowserWebView` is a concrete `NSViewRepresentable` wrapping `WatchtowerWebView` (a `WKWebView` subclass). Navigation methods on `BrowserPaneModel` call `webView?.goBack()`, `webView?.goForward()`, etc.

To support two engines, introduce a protocol that both backends conform to:

```swift
protocol BrowserEngineView: NSView {
    /// The browser pane model this view is bound to.
    var browser: BrowserPaneModel? { get set }

    /// Load the given URL request.
    func loadRequest(_ request: URLRequest)

    /// Navigate back in history.
    func goBack()

    /// Navigate forward in history.
    func goForward()

    /// Reload the current page.
    func reload()

    /// Stop loading the current page.
    func stopLoading()

    /// Whether the web developer inspector is enabled.
    var isInspectable: Bool { get set }

    /// Execute JavaScript in the main frame and return the result.
    /// Used for form interaction detection and potential future features.
    func evaluateJavaScript(_ script: String) async throws -> Any?
}
```

Both `WatchtowerWebView` and the new `ChromiumBrowserView` conform to this protocol. `BrowserPaneModel.webView` changes type from `WKWebView?` to `(any BrowserEngineView)?`.

**JavaScript execution:** The `evaluateJavaScript` method wraps `WKWebView.evaluateJavaScript` on the WebKit side and `cef_frame_t.execute_javascript` (with a result callback via `cef_message_router`) on the CEF side. This is used internally for form interaction detection and is available for future features that need to inject or query scripts.

**User-Agent:** Each engine uses its own default User-Agent string. WebKit sends Safari's UA, Chromium sends Chrome's UA. This is the natural behavior and matches user expectations — the point of switching engines is to get the other engine's behavior, including how servers respond to its UA.

**DevTools / Inspector:** Both engines support web developer tools. WebKit uses `isInspectable = true` (right-click -> Inspect Element opens Safari's Web Inspector). CEF opens a separate DevTools window via `cef_browser_host_t.show_dev_tools()`. The `isInspectable` property on the protocol controls whether DevTools are available; both engines set it to `true` by default.

**BrowserPaneModel changes:**

```swift
class BrowserPaneModel: PaneModel {
    // ...existing @Published properties unchanged...

    /// The rendering engine for this pane. Defaults to the global setting
    /// from WatchtowerConfig. Can be changed per-pane via the command palette,
    /// which triggers a view rebuild (old engine torn down, new one created).
    @Published var engine: BrowserEngine

    /// Weak reference to the underlying engine view.
    weak var engineView: (any BrowserEngineView)?

    init(url: URL = URL(string: "about:blank")!,
         engine: BrowserEngine = WatchtowerConfig.shared.browserEngine,
         paneWidth: CGFloat = PaneModel.defaultPaneWidth) {
        self.engine = engine
        self.url = url
        super.init(id: UUID(), paneWidth: paneWidth)
    }

    /// Switch this pane to a different rendering engine. Resets navigation
    /// state since the back/forward stack does not transfer between engines.
    func switchEngine(to newEngine: BrowserEngine) {
        guard newEngine != engine else { return }
        canGoBack = false
        canGoForward = false
        hasInteractedForms = false
        httpStatusCode = nil
        engine = newEngine
        // The @Published change triggers SwiftUI to rebuild the view,
        // which tears down the old NSViewRepresentable and creates
        // the new one. The new view loads browser.url on creation.
        navigationGeneration += 1
    }
}
```

Each pane knows which engine it is using. The global setting controls the default for new panes, but any pane can be switched individually via `switchEngine(to:)`.

### 4. WebKit Backend (Existing, Refactored)

`WatchtowerWebView` gains conformance to `BrowserEngineView`. Most methods are already present on `WKWebView` — the protocol conformance is largely a formalization:

```swift
extension WatchtowerWebView: BrowserEngineView {
    func loadRequest(_ request: URLRequest) {
        load(request)
    }
    // goBack(), goForward(), reload(), stopLoading() already exist on WKWebView.
    // isInspectable already exists on WKWebView.
    // evaluateJavaScript(_:) already exists on WKWebView (async variant).
}
```

The existing `BrowserWebView` (`NSViewRepresentable`) and its `Coordinator` are unchanged in structure. They continue to use `WatchtowerWebView` internally.

`BrowserWebView` is renamed to `WebKitBrowserView` for clarity, since there will now be two `NSViewRepresentable` wrappers.

### 5. Chromium Backend (New)

#### 5a. Chromium Embedded Framework (CEF)

The Chromium engine is provided by the [Chromium Embedded Framework (CEF)](https://bitbucket.org/chromiumembedded/cef). CEF provides a C/C++ API for embedding a full Chromium browser into a host application. The macOS distribution includes the framework, helper app binaries, and all required resources.

**Integration approach:** Use the CEF C API directly via a bridging header (same pattern as the Ghostty integration). CEF's C API is in `include/capi/cef_capi.h`. This avoids pulling in C++ dependencies into Swift and keeps the integration pattern consistent with how Ghostty is already integrated.

**Build integration:** CEF is distributed as a prebuilt binary framework. It will be placed at `chromium/` in the project root (parallel to `ghostty/`). The Xcode project adds:
- Library search path: `$(PROJECT_DIR)/chromium/Release/Chromium Embedded Framework.framework`
- Framework search path: `$(PROJECT_DIR)/chromium/Release`
- Linked framework: `Chromium Embedded Framework.framework`
- Header search path: `$(PROJECT_DIR)/chromium/`
- Bridging header includes: `#include <include/capi/cef_client_capi.h>` (and related headers)

**CEF helper processes:** Chromium requires separate helper processes for the renderer, GPU, and utility. CEF provides a `cef_execute_process()` entry point that must be called early in `main()` for helper process variants. This requires:
- A helper app target in the Xcode project (`Watchtower Helper.app`) with its own `main.swift` that calls `cef_execute_process()`.
- The helper is embedded in `Watchtower.app/Contents/Frameworks/Watchtower Helper.app`.
- There are actually four helper variants needed: the base helper, plus GPU, Renderer, and Plugin variants (e.g., `Watchtower Helper (GPU).app`). These can be symlinks or copies with different `Info.plist` values.

**CEF lifecycle:** CEF requires explicit initialization and shutdown:
- `cef_initialize()` must be called once during app startup (in `WatchtowerApp.init` or `AppDelegate.applicationDidFinishLaunching`), but only if Chromium is the selected engine or might be needed.
- `cef_shutdown()` must be called during app termination.
- `cef_do_message_loop_work()` must be called periodically from the main thread — integrated via a `CVDisplayLink` or `NSTimer` to pump the CEF message loop alongside the macOS run loop.

**Lazy initialization:** CEF is heavyweight (~300MB of frameworks and resources). To avoid penalizing startup when the user has WebKit selected, CEF initialization is deferred until the first Chromium browser pane is created. A `ChromiumManager` singleton (parallel to `GhosttyAppManager`) handles this:

```swift
class ChromiumManager {
    static let shared = ChromiumManager()
    private var initialized = false

    func ensureInitialized() {
        guard !initialized else { return }
        initialized = true

        var settings = cef_settings_t()
        // Enable remote debugging if configured
        let port = WatchtowerConfig.shared.chromiumRemoteDebuggingPort
        settings.remote_debugging_port = Int32(port)
        // ... other settings ...
        // cef_initialize(..., &settings, ...)
        // Start message loop pump timer
    }

    func shutdown() {
        guard initialized else { return }
        // cef_shutdown()
    }
}
```

#### 5b. ChromiumBrowserView (NSView subclass)

```swift
class ChromiumBrowserView: NSView, BrowserEngineView {
    weak var browser: BrowserPaneModel?
    var isInspectable: Bool = true

    // CEF browser handle
    private var cefBrowser: OpaquePointer?  // cef_browser_t*

    func loadRequest(_ request: URLRequest) {
        guard let url = request.url?.absoluteString else { return }
        // cef_frame_load_url(mainFrame, url)
    }

    func goBack() {
        // cef_browser_go_back(cefBrowser)
    }

    func goForward() {
        // cef_browser_go_forward(cefBrowser)
    }

    func reload() {
        // cef_browser_reload(cefBrowser)
    }

    func stopLoading() {
        // cef_browser_stop_load(cefBrowser)
    }
}
```

The view creates a CEF browser instance on `viewDidMoveToWindow()` using `cef_browser_host_create_browser()`, passing its own `NSView` as the parent window handle.

#### 5c. CEF Client Callbacks → BrowserPaneModel

CEF uses a client/handler pattern where you provide callback structs. The key handlers and their WebKit equivalents:

| WebKit (current) | CEF equivalent | Mapped `BrowserPaneModel` property |
|---|---|---|
| KVO `title` | `cef_display_handler_t.on_title_change` | `pageTitle` |
| KVO `isLoading` | `cef_load_handler_t.on_loading_state_change` | `isLoading` |
| KVO `canGoBack` | `cef_load_handler_t.on_loading_state_change` | `canGoBack` |
| KVO `canGoForward` | `cef_load_handler_t.on_loading_state_change` | `canGoForward` |
| KVO `estimatedProgress` | No direct equivalent — synthesize from `on_load_start`/`on_load_end` | `estimatedProgress` |
| KVO `url` | `cef_display_handler_t.on_address_change` | `url` |
| `decidePolicyFor navigationAction:` | `cef_request_handler_t.on_before_browse` | Navigation policy |
| `decidePolicyFor navigationResponse:` | `cef_resource_request_handler_t.on_resource_response` | `httpStatusCode` |
| `didStartProvisionalNavigation:` | `cef_load_handler_t.on_load_start` | `isLoading`, `hasInteractedForms` reset |
| `didFinish:` | `cef_load_handler_t.on_load_end` | `isLoading`, history recording |
| `didFail:` / `didFailProvisionalNavigation:` | `cef_load_handler_t.on_load_error` | `httpStatusCode = 0` |
| `createWebViewWith:` (target=_blank) | `cef_life_span_handler_t.on_before_popup` | Cancel popup, load in same view |
| `WKScriptMessageHandler` (form interaction) | `cef_message_router` or `cef_frame_t.execute_javascript` | `hasInteractedForms` |
| `WKDownloadDelegate` | `cef_download_handler_t.on_before_download` / `on_download_updated` | Download save panel |
| `WKUIDelegate` (JavaScript dialogs) | `cef_jsdialog_handler_t` | Alert/confirm/prompt dialogs |

**Progress estimation:** CEF does not expose an `estimatedProgress` equivalent. Instead, synthesize it:
- `on_load_start`: set `estimatedProgress = 0.1`
- Tick up by 0.1 every 500ms while loading (capped at 0.9)
- `on_load_end`: set `estimatedProgress = 1.0`

This matches the behavior users expect from progress bars even without granular data.

**Form interaction detection:** Inject the same JavaScript snippet used for WebKit via `cef_frame_t.execute_javascript()` at document start. CEF's `cef_message_router` provides a JavaScript → native bridge similar to `WKScriptMessageHandler`. Register a handler for `"formInteraction"` messages that sets `browser.hasInteractedForms = true`.

**HTTP status code:** In CEF, the HTTP status code is available on the `cef_response_t` object passed to `on_resource_response` for the main frame resource. Filter by checking `cef_request_t.is_main_frame()` to capture only the main document's status code.

#### 5d. Focus Management

`ChromiumBrowserView` implements the same focus tracking as `WatchtowerWebView`:

```swift
override var acceptsFirstResponder: Bool { true }

override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result {
        browser?.isFocused = true
        // Same pendingFocus / focusPane / scrollToVisible logic
        // as WatchtowerWebView.becomeFirstResponder
    }
    return result
}

override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result { browser?.isFocused = false }
    return result
}
```

The `performKeyEquivalent` override also mirrors `WatchtowerWebView` — passing Cmd+Shift+[/] and Cmd+L through to the menu system.

The `performClose` override mirrors the same Cmd+W interception pattern (form confirmation, `.browserPaneClosed` notification).

#### 5e. Appearance Syncing

CEF does not have an `appearance` property like `WKWebView`. Instead, to sync dark/light theme for `prefers-color-scheme`:
- Use `cef_browser_host_t.execute_dev_tools_method` to call `Emulation.setEmulatedMedia` with `features: [{ name: "prefers-color-scheme", value: "dark" }]` (or `"light"`).
- Alternatively, inject a `matchMedia` override via JavaScript, though the DevTools Protocol approach is more reliable.

#### 5f. Shared State Across Panes

**Within the same engine:** WebKit shares state via a common `WKProcessPool`. CEF shares state by default — all browsers in the same `cef_request_context_t` share cookies, localStorage, and cache. Using the global request context (returned by `cef_request_context_get_global_context()`) gives the same cross-pane session sharing behavior.

**Across engines:** Cookies, localStorage, and session state are **not shared** between WebKit and Chromium. Each engine maintains its own stores. Logging in to a site in a WebKit pane does not carry over to a Chromium pane and vice versa. This is the natural behavior — the engines have completely separate storage backends — and avoids complex cross-engine synchronization.

**History:** Both engines record visits to the same `HistoryStore` (SQLite at `~/Library/Application Support/Watchtower/history.db`). History search does not distinguish by engine — a visit is a visit regardless of which engine rendered the page. The `didFinish` / `on_load_end` handlers in both engine coordinators call `HistoryStore.shared.recordVisit()` identically.

#### 5g. Chrome DevTools Protocol (CDP) Remote Debugging

CEF supports Chromium's built-in remote debugging server. This is enabled by setting `remote_debugging_port` in `cef_settings_t` during initialization:

```c
cef_settings_t settings = {};
settings.remote_debugging_port = 9222;  // or any available port
```

Once enabled, CEF starts an HTTP server on `localhost:<port>` that speaks the Chrome DevTools Protocol. External tools can connect to it:

- **Playwright / Puppeteer:** `browserType.connectOverCDP('http://localhost:9222')` — enables automated testing, scraping, or scripting of Watchtower's Chromium browser panes from a terminal pane or external process.
- **Chrome DevTools:** Navigate to `chrome://inspect` in a standalone Chrome and the CEF instance appears as a remote target.
- **Custom CDP clients:** Any WebSocket client can connect to `ws://localhost:9222/devtools/page/<id>` for individual page targets.

**Configuration:** The remote debugging port is configurable in `~/.config/watchtower/config.json`:

```json
{
    "browser-engine": "chromium",
    "chromium-remote-debugging-port": 9222
}
```

A value of `0` (the default) disables the remote debugging server. Any non-zero port enables it. `ChromiumManager` reads this value from `WatchtowerConfig` at initialization time.

**Per-browser target endpoints:** CEF exposes each browser instance (each pane) as a separate CDP target. The listing endpoint `http://localhost:9222/json` returns all active targets with their WebSocket debug URLs:

```json
[
    {
        "id": "...",
        "title": "Page Title",
        "url": "https://example.com",
        "webSocketDebuggerUrl": "ws://localhost:9222/devtools/page/..."
    }
]
```

This means external tools can target a specific Chromium pane by ID.

**Security note:** The remote debugging port is bound to `localhost` only (not `0.0.0.0`), so it is not accessible from the network. This is CEF's default behavior and matches Chrome's `--remote-debugging-port` behavior.

**WebKit limitation:** WebKit/WKWebView does not support CDP. Remote debugging of WebKit panes uses Safari's Web Inspector (via `isInspectable = true`), which requires Safari to be running. There is no programmatic CDP-style control of WebKit panes. This is one of the key reasons a user might prefer Chromium — to enable programmatic browser automation from Watchtower's own terminal panes.

### 6. NSViewRepresentable Routing

`TerminalPaneView.swift` currently renders `BrowserWebView(browser: browser)` when the pane is a `BrowserPaneModel`. This becomes a routing layer:

```swift
} else if let browser = pane as? BrowserPaneModel {
    if browser.engine == .chromium {
        ChromiumBrowserRepresentable(browser: browser)
    } else {
        WebKitBrowserView(browser: browser)
    }
}
```

**Engine assignment:** When a new `BrowserPaneModel` is created (in `addBrowser()`), it reads the current engine from `WatchtowerConfig.shared.browserEngine`:

```swift
class BrowserPaneModel: PaneModel {
    @Published var engine: BrowserEngine  // mutable for per-pane switching

    init(url: URL = URL(string: "about:blank")!,
         engine: BrowserEngine = WatchtowerConfig.shared.browserEngine,
         paneWidth: CGFloat = PaneModel.defaultPaneWidth) {
        self.engine = engine
        self.url = url
        super.init(id: UUID(), paneWidth: paneWidth)
    }
}
```

Each pane stores which engine it is using. The global config sets the default; the command palette's "Switch to Chromium/WebKit" changes it per-pane by calling `browser.switchEngine(to:)`.

### 7. ChromiumBrowserRepresentable (NSViewRepresentable)

A new `NSViewRepresentable` wrapper parallel to `WebKitBrowserView`:

```swift
struct ChromiumBrowserRepresentable: NSViewRepresentable {
    @ObservedObject var browser: BrowserPaneModel
    @ObservedObject private var appManager = GhosttyAppManager.shared

    func makeCoordinator() -> Coordinator {
        Coordinator(browser: browser)
    }

    func makeNSView(context: Context) -> ChromiumBrowserView {
        ChromiumManager.shared.ensureInitialized()
        let view = ChromiumBrowserView(frame: .zero)
        view.browser = browser
        browser.engineView = view
        context.coordinator.view = view
        // Setup CEF client handlers on coordinator
        // Load initial URL
        return view
    }

    func updateNSView(_ view: ChromiumBrowserView, context: Context) {
        // Same generation-based navigation check as WebKitBrowserView
    }

    static func dismantleNSView(_ nsView: ChromiumBrowserView, coordinator: Coordinator) {
        // Close CEF browser, teardown handlers
    }

    class Coordinator: NSObject {
        var browser: BrowserPaneModel
        weak var view: ChromiumBrowserView?
        // CEF handler structs stored here
        // Progress estimation timer
    }
}
```

### 8. Scroll Forwarding

`ContentView.swift` has scroll event forwarding logic that detects when the mouse is over a `WKWebView` and forwards horizontal scroll to the parent `NSScrollView`. This check (`hitView.isOrHasAncestor(ofType: WKWebView.self)`) must also check for `ChromiumBrowserView`:

```swift
guard hitView.isOrHasAncestor(ofType: WKWebView.self)
   || hitView.isOrHasAncestor(ofType: ChromiumBrowserView.self) else { return }
```

Similarly, the `findParentScrollView` logic that skips WebKit-internal scroll views must also skip CEF-internal scroll views.

### 9. Menu Bar / Command Palette

Browser-specific commands (Go Back, Go Forward, Reload) already operate through `BrowserPaneModel` methods, which delegate to the `engineView` protocol. The commands work identically regardless of which engine is active.

**New command palette entries (browser pane focused only):**

| Command | Action | Condition |
|---|---|---|
| Switch to Chromium | Switch this pane's engine to Chromium | Current pane engine is WebKit |
| Switch to WebKit | Switch this pane's engine to WebKit | Current pane engine is Chromium |

Only the applicable command appears — if the pane is already using Chromium, only "Switch to WebKit" is shown, and vice versa.

**Engine switch behavior:** When the user selects "Switch to Chromium" (or "Switch to WebKit"):
1. Show a confirmation alert: **"Switch to [Chromium/WebKit]?"** with informative text *"The page will reload in the new engine. Navigation history (back/forward) will be lost."* Buttons: **Switch** and **Cancel**.
2. If confirmed, capture the current URL from `browser.url`.
3. Set `browser.engine` to the new value (this is a `@Published var`).
4. SwiftUI's view diffing detects the engine change and tears down the old `NSViewRepresentable` (calling `dismantleNSView`), then creates the new one (calling `makeNSView`).
5. The new engine view loads the captured URL.
6. Navigation history is lost — back/forward stack resets.
7. `canGoBack` and `canGoForward` reset to `false`. `hasInteractedForms` resets to `false`.

The engine switch is intentionally per-pane. The global setting in Settings/config is not changed — it continues to control what engine "New Browser" uses.

### 10. `findWebView` Utility

`WatchtowerApp.swift` and `ContentView.swift` have a `findWebView` helper that walks the NSView hierarchy looking for `WKWebView` instances. This must also find `ChromiumBrowserView` instances. Rename to `findBrowserEngineView` and return `(any BrowserEngineView)?`:

```swift
func findBrowserEngineView(in view: NSView) -> (any BrowserEngineView)? {
    if let engineView = view as? BrowserEngineView {
        return engineView
    }
    for subview in view.subviews {
        if let found = findBrowserEngineView(in: subview) {
            return found
        }
    }
    return nil
}
```

## Open Questions

### 1. CEF Version Pinning

CEF releases track Chromium versions. The project needs a strategy for which CEF version to pin to and how to update. A `chromium/VERSION` file (parallel to how `ghostty/` is a submodule) could track this.

### 2. Code Signing and Notarization

CEF's helper processes must be signed with the same team identity and include appropriate entitlements. The helper apps need hardened runtime enabled and may need the `com.apple.security.cs.disable-library-validation` entitlement for CEF's dynamically loaded libraries.

### 3. CEF Message Loop Integration

CEF's message loop must be pumped from the main thread. The recommended approach for external message loop mode (`cef_settings_t.external_message_loop = 1`) is calling `cef_do_message_loop_work()` on a timer. The timer interval affects responsiveness vs. CPU usage. 1/60th of a second (matching display refresh) is a reasonable starting point, but may need tuning.

### 4. CEF Sandbox

CEF has its own sandbox support separate from macOS App Sandbox. Since Watchtower has App Sandbox disabled, this is not an immediate concern, but if App Sandbox is re-enabled in the future, CEF's sandbox helper library (`cef_sandbox.a`) may be needed.

## Implementation Plan

1. **Config infrastructure** — create `WatchtowerConfig.swift` with a singleton that reads `~/.config/watchtower/config.json` at startup (JSON format), exposes `@Published var browserEngine: BrowserEngine`, and writes changes back to the file on save.
2. **`BrowserEngine` enum** — define `BrowserEngine` enum in `BrowserEngine.swift` with display names and descriptions.
3. **`SettingsView`** — create `SettingsView.swift` with the General tab containing the engine picker, backed by `WatchtowerConfig`. Register the `Settings` scene in `WatchtowerApp.swift`.
4. **`BrowserEngineView` protocol** — define the protocol in `BrowserEngineView.swift`. Make `WatchtowerWebView` conform. Change `BrowserPaneModel.webView` to `engineView: (any BrowserEngineView)?` and update all call sites (`goBack`, `goForward`, `reloadOrStop`, `navigate`).
5. **Rename `BrowserWebView` -> `WebKitBrowserView`** — rename the struct and file. Update `TerminalPaneView.swift` import.
6. **`engine` property on `BrowserPaneModel`** — add `@Published var engine: BrowserEngine` defaulting from `WatchtowerConfig`. Add `switchEngine(to:)` method.
7. **Command palette engine switching** — add "Switch to Chromium" / "Switch to WebKit" entries to the command palette, visible only when a browser pane is focused and using the other engine.
8. **View routing in `TerminalPaneView`** — branch on `browser.engine` to render either `WebKitBrowserView` or `ChromiumBrowserRepresentable`.
9. **CEF integration (build)** — download CEF binary distribution, place in `chromium/`, add Xcode build settings (framework search paths, linked frameworks). Create helper app targets. Add CEF headers to bridging header.
10. **`ChromiumManager` singleton** — lazy CEF initialization, message loop pump timer, shutdown hook.
11. **`ChromiumBrowserView` (NSView)** — CEF browser creation, `BrowserEngineView` conformance, focus management, key equivalent passthrough, `performClose` interception.
12. **CEF client handlers** — implement `cef_client_t` with all handler callbacks mapped to `BrowserPaneModel` properties (see Section 5c mapping table).
13. **`ChromiumBrowserRepresentable`** — `NSViewRepresentable` wrapper with coordinator, generation-based navigation, appearance syncing.
14. **Form interaction JS injection** — port the form detection script to CEF's `execute_javascript` + `cef_message_router`.
15. **Download handling** — implement `cef_download_handler_t` with `NSSavePanel` (same UX as WebKit downloads).
16. **Scroll forwarding** — update `ContentView.swift` scroll interception to detect `ChromiumBrowserView` in addition to `WKWebView`.
17. **`findBrowserEngineView` utility** — update `findWebView` references in `WatchtowerApp.swift` and `ContentView.swift`.
18. **Progress estimation** — implement the synthetic progress bar for CEF (no native `estimatedProgress`).
19. **Appearance syncing** — implement dark/light theme sync via CEF DevTools Protocol.
20. **Testing** — verify both engines produce the same `BrowserPaneModel` state for identical navigations. Test focus management, Cmd+W, Cmd+Shift+[/], scroll forwarding, downloads, form interaction detection, dark mode, and per-pane engine switching with both engines.

## Current Implementation Status

> **Last updated:** 2026-02-26
>
> The Chromium/CEF integration is functional — Chromium browser panes render pages and all helper processes spawn correctly. However, several CEF handler callbacks were stripped to reach a minimal working state. This section documents exactly what is done, what remains, and the critical technical knowledge needed to continue.

### What Is Complete (Working)

All infrastructure and the core rendering pipeline are done:

| Step | Status | Notes |
|------|--------|-------|
| 1. Config infrastructure (`WatchtowerConfig.swift`) | **Done** | Reads/writes `~/.config/watchtower/config.json` |
| 2. `BrowserEngine` enum | **Done** | In `BrowserEngine.swift` |
| 3. `SettingsView` | **Done** | General tab with engine picker |
| 4. `BrowserEngineView` protocol | **Done** | In `BrowserEngineView.swift`. `WatchtowerWebView` conforms. `isInspectable` removed from protocol (requires macOS 13.3+), guarded with `if #available` at call site instead. |
| 5. `BrowserWebView` → `WebKitBrowserView` | **Done** | Struct renamed in `BrowserWebView.swift` |
| 6. `engine` property on `BrowserPaneModel` | **Done** | `@Published var engine: BrowserEngine` with `switchEngine(to:)` |
| 7. Command palette engine switching | **Done** | "Switch to Chromium/WebKit" in `CommandPaletteView.swift` |
| 8. View routing in `TerminalPaneView` | **Done** | Branches on `browser.engine` |
| 9. CEF integration (build) | **Done** | CEF framework linked/embedded, helper target, bridging header, search paths |
| 10. `ChromiumManager` singleton | **Done** | Init, message pump (60Hz Timer), shutdown |
| 11. `ChromiumBrowserView` (NSView) | **Partial** | Core works: loadRequest, goBack/Forward/Reload/Stop, focus, key equiv passthrough, performClose. Appearance sync (`syncAppearance`) working via `send_dev_tools_message` with raw JSON. Missing: close confirmation with `hasInteractedForms` (Feature F), collapsed-pane key handling (Feature G). |
| 12. CEF client handlers | **Partial** | Life span handler, load handler (A), display handler (B), progress timer (C), appearance syncing (D) all working. DevTools observer for form detection (E) implemented but disabled — needs `execute_dev_tools_method` → `send_dev_tools_message` conversion for `Runtime.addBinding`. Missing: download handler. |
| 13. `ChromiumBrowserRepresentable` | **Done** | Uses `cef_browser_host_create_browser_sync`. Generation-based navigation. |
| 16. Scroll forwarding | **Done** | `ContentView.swift` checks `ChromiumBrowserView` in addition to `WKWebView` |
| 17. `findBrowserEngineView` utility | **Done** | Updated in `ContentView.swift` |

### What Remains (Stripped/Missing)

These features were deliberately stripped to achieve a minimal working render. They should be re-enabled one at a time, building and testing after each:

#### A. Load Handler (`cef_load_handler_t`) — DONE

**File:** `CEFClientHandlers.swift`

Implemented and verified working. Callbacks: `on_loading_state_change` (isLoading, canGoBack, canGoForward), `on_load_start` (progress, form reset, status reset), `on_load_end` (progress=1.0, httpStatusCode, history recording), `on_load_error` (with ERR_ABORTED/-3 filtering via `errorCode.rawValue`).

#### B. Display Handler (`cef_display_handler_t`) — DONE

**File:** `CEFClientHandlers.swift`

Implemented and verified working. Callbacks: `on_title_change` (pageTitle) and `on_address_change` (URL, main frame only).

#### C. Progress Estimation Timer — DONE

**File:** `CEFClientHandlers.swift` (on `CEFClientContext`)

Implemented and verified working. Timer stored on `CEFClientContext.progressTimer`. Started in `on_load_start` (0.5s interval, increments by 0.1 up to 0.9), stopped in both `on_load_end` and `on_load_error`. Timer must be started/stopped on `DispatchQueue.main` since `Timer.scheduledTimer` requires a run loop.

#### D. Appearance Syncing — DONE

**File:** `ChromiumBrowserView.swift` and `ChromiumBrowserRepresentable.swift`

Implemented and verified working. Uses DevTools Protocol `Emulation.setEmulatedMedia` with `features: [{name: "prefers-color-scheme", value: "dark"|"light"}]` via `cef_browser_host_t.send_dev_tools_message` with a raw UTF-8 JSON string.

**Critical discovery:** The original implementation used `execute_dev_tools_method` with nested `cef_dictionary_value_create`/`cef_list_value_create` objects for the params. Building nested CEF value objects (dict containing list containing dict) crashed the app. The fix was to switch to `send_dev_tools_message` with a raw JSON string containing the full CDP message (including `"id"` and `"method"` fields), which is simpler and avoids the crash entirely.

`send_dev_tools_message` takes `(host, void_pointer_to_utf8_bytes, byte_count)` and returns `Int32` (1 = success, 0 = failure).

`syncAppearance` is called from two places:
1. `ChromiumBrowserView.loadPendingURLIfNeeded()` — called by `on_after_created` when the browser is first ready
2. `ChromiumBrowserRepresentable.updateNSView` — called on theme changes, with `lastSyncedIsDark: Bool?` on Coordinator for change detection

#### E. Form Interaction JS Injection — IMPLEMENTED BUT DISABLED

**File:** `CEFClientHandlers.swift`

Implementation exists using DevTools Protocol `Runtime.addBinding` approach (not the document title hack):
1. `cefSetupDevToolsObserver` — registers a `cef_dev_tools_message_observer_t` via `host.add_dev_tools_message_observer` and calls `Runtime.addBinding` with binding name `"watchtowerFormInteraction"`.
2. `cefInjectFormDetectionJS` — injects form detection JS in `on_load_end` via `cef_frame_t.execute_java_script`. The JS listens for input/textarea/select events and calls `watchtowerFormInteraction("formInteraction")`.
3. Observer's `on_dev_tools_event` callback receives `Runtime.bindingCalled` events and sets `hasInteractedForms = true`.

Currently disabled: `cefSetupDevToolsObserver` has an early return at line 347, and the `cefInjectFormDetectionJS` call is commented out at line 242 in `on_load_end`.

**CRITICAL:** The `Runtime.addBinding` call inside `cefSetupDevToolsObserver` still uses `execute_dev_tools_method` with `cef_dictionary_value_create` — this MUST be converted to `send_dev_tools_message` with raw JSON (same pattern as the fixed `syncAppearance` in Feature D) before re-enabling, or it will crash.

Key details: `cef_dev_tools_message_observer_t` is allocated client-side via `cefCreate()`. `add_dev_tools_message_observer` returns a `cef_registration_t*` that must be held alive. The `on_dev_tools_event` callback receives `method` as `cef_string_t*` and `params` as `const void*` (UTF-8 JSON bytes) with `params_size`. The header `cef_devtools_message_observer_capi.h` is transitively included via `cef_browser_capi.h`.

#### F. Close Confirmation with `hasInteractedForms` — NOT STARTED

**File:** `ChromiumBrowserView.swift`

Add a confirmation dialog to `ChromiumBrowserView.performClose` that checks `browser.hasInteractedForms` before closing, mirroring the WebKit behavior in `BrowserWebView.swift` (`WatchtowerWebView.performClose`). If the user has interacted with forms on the page, show an alert asking them to confirm they want to close the pane and lose unsaved form data.

#### G. Key Event Handling for Collapsed Panes — NOT STARTED

**File:** `ChromiumBrowserView.swift`

Currently missing `keyDown(with:)` and `keyUp(with:)` overrides that match `WatchtowerWebView`'s behavior:
- When collapsed, swallow all key events
- Enter/Return/Space expands the pane
- `keyUp` is also swallowed when collapsed

#### H. Download Handler (`cef_download_handler_t`) — LOW PRIORITY

**File:** `CEFClientHandlers.swift`

Callbacks needed:
- **`on_before_download(browser, downloadItem, suggestedName, callback)`** — Show `NSSavePanel`, call `callback.pointee.cont(callback, path, showDialog=0)` with the chosen path.
- **`on_download_updated(browser, downloadItem, callback)`** — Optional: track progress, handle completion/failure.

Wire into `cef_client_t` via `get_download_handler`.

### Technical Knowledge for Continuing

#### CEF C API Patterns Used in This Codebase

**Struct allocation:** All client-side CEF structs are allocated via `cefCreate<T>()` in `CEFHelpers.swift`. This handles the `cef_base_ref_counted_t` setup with atomic reference counting. The pattern:
```swift
let handler: UnsafeMutablePointer<cef_load_handler_t> = cefCreate()
handler.pointee.on_loading_state_change = { (selfPtr, browser, isLoading, canGoBack, canGoForward) in
    // ... callback implementation
}
```

**Handler → Context lookup:** CEF C callbacks receive only `selfPtr` (the handler struct pointer). The codebase uses two global dictionaries in `CEFClientHandlers.swift`:
- `contextRegistry` maps client pointers → `CEFClientContext`
- `handlerToContext` maps handler pointers → `CEFClientContext`

When creating a new handler, register it: `cefRegisterHandler(UnsafeMutableRawPointer(handler), context: context)`

Then in callbacks: `guard let ctx = cefContextForHandler(UnsafeMutableRawPointer(selfPtr)) else { return }`

**String conversion:** Use `cefStringToSwift(_:)` to convert `cef_string_t` or `UnsafePointer<cef_string_t>?` to Swift `String`. Use `withCEFString(_:body:)` to create temporary `cef_string_t` values.

**Main frame check:** CEF callbacks fire for all frames (main + iframes). Filter with:
```swift
guard let frame = browser?.pointee.get_main_frame?(browser!) else { return }
let isMain = frame.pointee.is_main?(frame) ?? 0
_ = frame.pointee.base.release?(&frame.pointee.base)
guard isMain != 0 else { return }
```

Or compare frame identifiers if you have the frame pointer from the callback.

**DispatchQueue.main.async:** All `BrowserPaneModel` property updates from CEF callbacks must be dispatched to the main queue (CEF callbacks may fire on background threads):
```swift
DispatchQueue.main.async {
    ctx.browserModel?.isLoading = isLoading != 0
}
```

#### Wiring a New Handler Into the Client

To add a new handler (e.g., load handler), follow this pattern:

1. **Create the factory function** (e.g., `cefMakeLoadHandler(context:)`) — allocates via `cefCreate()`, sets callback function pointers, returns the pointer.

2. **Add storage to `CEFClientContext`** — e.g., `var loadHandler: UnsafeMutablePointer<cef_load_handler_t>?`

3. **Register the handler** in `cefMakeClient(context:)`:
```swift
let lh = cefMakeLoadHandler(context: context)
context.loadHandler = lh
cefRegisterHandler(UnsafeMutableRawPointer(lh), context: context)
```

4. **Wire the getter** on the client:
```swift
client.pointee.get_load_handler = { (selfPtr) -> UnsafeMutablePointer<cef_load_handler_t>? in
    guard let selfPtr = selfPtr else { return nil }
    guard let ctx = contextRegistry[UnsafeMutableRawPointer(selfPtr)] else { return nil }
    guard let handler = ctx.loadHandler else { return nil }
    handler.pointee.base.add_ref?(&handler.pointee.base)
    return handler
}
```

5. **Cleanup** in `cefCleanupClientContext()` — unregister the handler pointer.

6. **Release** in `CEFClientContext.deinit` — release the handler struct.

#### Build & Test Procedure

```bash
# 1. Build
xcodebuild -project Watchtower.xcodeproj -scheme Watchtower -configuration Debug build 2>&1 | tail -20

# 2. Kill existing instances
pkill -f Watchtower; pkill -f "Watchtower Helper"; sleep 2

# 3. Clean singleton locks (CEF uses a process singleton lock — stale locks from killed processes block init)
rm -f ~/Library/Application\ Support/Watchtower/CEF/SingletonLock \
      ~/Library/Application\ Support/Watchtower/CEF/SingletonSocket \
      ~/Library/Application\ Support/Watchtower/CEF/SingletonCookie

# 4. Launch
/Users/markhuot/Library/Developer/Xcode/DerivedData/Watchtower-hdvmmdolozizpchhfyhjyfxspgcs/Build/Products/Debug/Watchtower.app/Contents/MacOS/Watchtower > /Users/markhuot/Sites/eyes/.tmp/watchtower-stdout.log 2>&1 &

# 5. Wait for CEF init (~8-10 seconds), then open a browser pane
sleep 10
cd /Users/markhuot/Sites/eyes/cli && bun run src/index.ts new browser https://example.com

# 6. Check logs
cat /Users/markhuot/Sites/eyes/.tmp/watchtower-stdout.log
cat ~/Library/Application\ Support/Watchtower/CEF/chrome_debug.log
```

**Config file:** `~/.config/watchtower/config.json` must have `{"browser-engine": "chromium"}` for Chromium to be the default engine.

#### Critical Gotchas

1. **CEF `cef_api_hash()` must be called before `cef_initialize()`** — without it, `cef_api_version()` returns -1 and helper processes crash with `CefApp_0_CToCpp called with invalid version -1`.
2. **Specialized helper binaries are required** — `Watchtower Helper (Renderer).app`, `(GPU).app`, `(Plugin).app`, `(Alerts).app`. Created by a shell script build phase.
3. **Install name fix** — The framework's install name was changed to `@rpath/...` so helpers can find it from their different `@executable_path`.
4. **Re-signing** — CEF's internal dylibs ship adhoc-signed. A build phase re-signs them with the app's identity.
5. **`--disable-features=Fontations`** — Required. The Rust font backend crashes helper subprocesses.
6. **Singleton lock** — If the app is killed, stale `SingletonLock`/`SingletonSocket`/`SingletonCookie` files in `~/Library/Application Support/Watchtower/CEF/` prevent the next launch from initializing CEF. Must be removed.
7. **LSP false positives** — SourceKit reports errors for all `cef_*` types and cross-file types. These are false positives; the bridging header is only resolved during actual Xcode builds.
8. **`multi_threaded_message_loop` is NOT supported on macOS** — must use `external_message_pump = 1`.
9. **Sandbox is disabled** — `com.apple.security.app-sandbox = false`. `ENABLE_USER_SCRIPT_SANDBOXING = NO`.
10. **Do NOT use `cef_dictionary_value_create`/`cef_list_value_create` for nested DevTools Protocol params** — Building nested CEF value objects (dict containing list containing dict) crashes the app. Use `host.pointee.send_dev_tools_message` with a raw UTF-8 JSON string instead of `host.pointee.execute_dev_tools_method` with `cef_dictionary_value_t*` params. `send_dev_tools_message` takes `(host, void_pointer_to_utf8_bytes, byte_count)` and returns `Int32` (1 = success). The JSON must include `"id"` and `"method"` fields (full CDP message format).
11. **`NSLog` variadic format arguments** — `NSLog("%@", someVar)` is unavailable from Swift closures in this SDK version. Use string interpolation: `NSLog("[CEF] msg: \(value)")`.
12. **CEF `ERR_ABORTED` (-3)** — Fires when navigation is cancelled by a new load (e.g., double-loading the URL). Harmless; filter in `on_load_error` with `guard errorCode.rawValue != -3`.

#### Known Issues

1. **Click crash** — User reported a crash when clicking the rendered Chromium browser pane. Not yet investigated. Likely related to first responder handling or CEF's internal event processing.
2. **Message pump efficiency** — Using a simple 60Hz Timer. The spec mentions `on_schedule_message_pump_work` for demand-driven pumping, but the timer works fine for now.

#### Xcode Project ID Scheme

PBXProj IDs use sequential human-readable IDs with prefix `AA`:
- File refs: `AA00000200000000000000XX`
- Build files: `AA00000100000000000000XX`
- Product refs: `AA00000300000000000000XX`
- Shell script build phases: `AA0000100000000000000001` (re-sign), `AA0000100000000000000002` (create helper variants)
- **Highest suffix in use: `2F` (IPCServer.swift). Next available: `30`.**

## Files to Create or Modify

| File | Action | Status | Description |
|---|---|---|---|
| `WatchtowerConfig.swift` | Create | **Done** | Config singleton: reads/writes `~/.config/watchtower/config.json` (JSON), exposes `@Published var browserEngine`. |
| `BrowserEngine.swift` | Create | **Done** | `BrowserEngine` enum (`webkit`, `chromium`) with display names and descriptions. |
| `BrowserEngineView.swift` | Create | **Done** | `BrowserEngineView` protocol defining the interface both engines implement. |
| `SettingsView.swift` | Create | **Done** | Settings window with General tab containing the engine picker, backed by `WatchtowerConfig`. |
| `ChromiumManager.swift` | Create | **Done** | Singleton for lazy CEF initialization, message loop integration, shutdown. |
| `ChromiumBrowserView.swift` | Create | **Partial** | Core works (load, navigate, focus, key equiv, close). Appearance sync working via `send_dev_tools_message` with raw JSON. Missing: close confirmation with `hasInteractedForms` (Feature F), collapsed-pane key handling (Feature G). |
| `ChromiumBrowserRepresentable.swift` | Create | **Done** | `NSViewRepresentable` wrapper using `cef_browser_host_create_browser_sync`. Appearance sync in `updateNSView` with `lastSyncedIsDark` change detection working. |
| `CEFHelpers.swift` | Create | **Done** | `CEFRefCount`, `cefCreate<T>()`, string conversion, userdata helpers. |
| `CEFClientHandlers.swift` | Create | **Partial** | Life span, load, display handlers and progress timer all working. DevTools observer for form detection implemented but disabled — needs `execute_dev_tools_method` → `send_dev_tools_message` conversion. Missing: download handler. |
| `CefApplication.swift` | Create | **Done** | `CefNSApplication` with CefAppProtocol conformance. |
| `main.swift` | Create | **Done** | Entry point: NSApplication init, signal handlers, atexit, CEF eager init. |
| `WatchtowerHelper/main.c` | Create | **Done** | Helper app entry point calling `cef_execute_process()`. |
| `WatchtowerHelper/Info.plist` | Create | **Done** | Helper app Info.plist. |
| `scripts/download-cef.sh` | Create | **Done** | Downloads CEF, restructures framework, fixes install name. |
| `BrowserWebView.swift` | Rename/Modify | **Done** | Struct renamed to `WebKitBrowserView`. `WatchtowerWebView` conforms to `BrowserEngineView`. |
| `BrowserPaneModel.swift` | Modify | **Done** | `engineView: (any BrowserEngineView)?`, `@Published var engine`, `switchEngine(to:)`. |
| `TerminalPaneView.swift` | Modify | **Done** | Branches on `browser.engine`. |
| `ContentView.swift` | Modify | **Done** | Scroll forwarding + `findBrowserEngineView` both check `ChromiumBrowserView`. |
| `WatchtowerApp.swift` | Modify | **Done** | `@main` removed (moved to `main.swift`), `Settings` scene added. |
| `CommandPaletteView.swift` | Modify | **Done** | "Switch to Chromium/WebKit" commands. |
| `GhosttyBridge.h` | Modify | **Done** | CEF C API headers + `cef_api_hash.h` + `cef_values_capi.h`. |
| `Info.plist` | Modify | **Done** | `NSPrincipalClass` → `$(PRODUCT_MODULE_NAME).CefNSApplication`. |
| `Watchtower.xcodeproj` | Modify | **Done** | All files, framework, helper target, build phases, search paths. |
