# Fix CEF Crash on Browser Pane Close — COMPLETED

## Status

**RESOLVED.** Single-click close works cleanly with no crash and no stall.

## Problem

When closing a Chromium/CEF browser pane, the app crashes with `CrBrowserMain: EXC_BREAKPOINT (code=1)`. The crash is on CEF's internal CrBrowserMain thread, not the main thread.

## Background: isHandlingSendEvent (FIXED)

The original crash was `NSInvalidArgumentException — -[NSApplication isHandlingSendEvent]: unrecognized selector`. This was fixed by swizzling `NSApplication` in `CefApplication.m` via `+load` (the QCefView pattern). This is working correctly and is not the current issue.

## Current Architecture

### Two-Phase Close Design (Original Intent)

The original design for closing Chromium panes. Steps 3-4 turned out to be wrong — see "Observed Close Sequences" below.

1. `removePane(byId:)` sets `browser.isClosingCEF = true` and calls `closeCEFBrowser()`, but **does not remove the pane from the array** — the pane stays in the SwiftUI view hierarchy.
2. `closeCEFBrowser()` calls `close_browser(host, 0)` (graceful close).
3. CEF fires `do_close` callback → returns 0 (allow close). *(Wrong — this closes the entire window)*
4. CEF fires `on_before_close` callback → releases `ctx.cefBrowser`, calls `browserClosed()`, schedules a 250ms delayed block.
5. The 250ms delayed block posts `.cefBrowserDidClose` notification.
6. The `.onReceive` handler calls `finishRemovingCEFPane(byId:)` which removes the pane from the array.
7. SwiftUI calls `dismantleNSView` as part of view teardown.
8. 0.5s after `browserClosed()`, the message pump (`cef_do_message_loop_work()` timer) stops.

### The Problem: CEF's Close Sequence and SwiftUI's View Lifecycle Conflict

CEF's close is multi-stage: `close_browser()` → `do_close` → `on_before_close`. Between `do_close` and `on_before_close`, CEF's CrBrowserMain thread continues accessing the NSView. SwiftUI, meanwhile, detects structural changes to the view hierarchy and tears down the `NSViewRepresentable`, deallocating the NSView while CrBrowserMain is still using it.

The challenge is that CEF needs the view alive during its close sequence (CrBrowserMain accesses it), but also needs the app to signal that the close should complete (either via view hierarchy teardown or by calling `[Try]close_browser()` again).

Three return values from `do_close` have been tested:
- **Return 0 (false):** CEF sends `performClose:` to the top-level NSWindow, closing the entire app window.
- **Return 1 (true) + `removeFromSuperview()`:** Prevents window close, but `on_before_close` never fires. CEF's internal child view is still alive.
- **Return 1 (true) + `close_browser(force=1)` async (CURRENT):** Prevents window close. `close_browser(force=1)` re-triggers `do_close` (it does NOT skip to `on_before_close` as hoped). Added `didScheduleForceClose` guard on `CEFClientContext` so only the first `do_close` schedules the force-close; subsequent ones (from the loop) just return 1 and exit immediately.

### Observed Close Sequences

**Sequence A: `do_close` returns 0, no `strongBrowserView` (CRASH):**

```
1. removePane(byId:) — sets isClosingCEF=true
2. closeCEFBrowser() — close_browser(force=0)
3. do_close fires, returns 0
4. ★ dismantleNSView fires (SwiftUI tears down NSViewRepresentable)
5. ★ ChromiumBrowserView.deinit fires (NSView deallocated!)
6. on_before_close fires — ctx.browserView is nil (weak ref zeroed)
   - releases ctx.cefBrowser, calls browserClosed()
   - schedules 250ms delayed cleanup + notification
7. pty fd closed / surface closed (terminal pane dies — reason unknown)
8. browserClosed: activeBrowserCount=0, schedules 0.5s pump stop
9. [250ms] delayed block runs, posts cefBrowserDidClose
   - BUT: .onReceive handler never fires (SwiftUI view gone?)
   - finishRemovingCEFPane never runs
10. [0.5s] CRASH: CrBrowserMain EXC_BREAKPOINT
    (accessing freed NSView memory)
```

**Sequence B: `do_close` returns 0, `strongBrowserView` captured (WINDOW CLOSES):**

```
1. removePane(byId:) — sets isClosingCEF=true
2. closeCEFBrowser() — close_browser(force=0)
3. do_close fires, returns 0, captures strongBrowserView
4. ★ CEF sends performClose: to NSWindow — entire window closes
5. terminate: swizzle swallows CEF's quit attempt
6. App stays alive but window is gone
7. Pump continues ticking (no on_before_close, no browserClosed)
```

**Sequence C: `do_close` returns 1, `removeFromSuperview()` async (STALLS):**

```
1. removePane(byId:) — sets isClosingCEF=true
2. closeCEFBrowser() — close_browser(force=0)
3. do_close fires, returns 1, captures strongBrowserView
4. [async] removeFromSuperview() — removes ChromiumBrowserView from SwiftUI
5. ★ on_before_close NEVER fires
   - CEF's internal child view (CefBrowserHostView) is still alive
   - CEF doesn't consider the parent's removal as a close completion
6. Pane remains as empty header (browser view gone, pane still in array)
7. Message pump ticks indefinitely (no browserClosed ever called)
8. No crash, but close never completes
```

**Sequence D: `do_close` returns 1, `close_browser(force=1)` async (LOOPS then STALLS):**

```
1. removePane(byId:) — sets isClosingCEF=true
2. closeCEFBrowser() — close_browser(force=0)
3. do_close fires, returns 1, captures strongBrowserView, sets didScheduleForceClose=true
4. [async] close_browser(force=1) — scheduled by do_close
5. ★ do_close fires AGAIN (force=1 re-triggers do_close, does NOT skip to on_before_close)
   - didScheduleForceClose guard prevents infinite loop
6. ★ on_before_close NEVER fires
   - close_browser(force=1) alone, without view hierarchy teardown, is insufficient
   - CEF requires the NSView to actually be removed from its parent window
7. Message pump ticks indefinitely
8. Second click hits removePane again — isClosingCEF is already true, falls through
   to non-Chromium path, removes pane immediately → dismantleNSView fires
   → dismantleNSView calls close_browser(force=1) in "unexpected teardown" path
   → on_before_close fires → close completes correctly
```

## Relevant Files

| File | Role |
|---|---|
| `CefApplication.m` | ObjC category on `NSApplication` — swizzles `sendEvent:` and `terminate:` in `+load` (WORKING) |
| `CEFClientHandlers.swift` | CEF C callbacks: `do_close`, `on_before_close`, `on_after_created`, handler registries |
| `ChromiumBrowserView.swift` | `NSView` subclass hosting CEF. `closeCEFBrowser()`, `deinit`, `cefBrowser` property |
| `ChromiumBrowserRepresentable.swift` | `NSViewRepresentable` wrapper. `dismantleNSView` handles teardown |
| `ChromiumManager.swift` | CEF lifecycle singleton. Message pump timer (`cef_do_message_loop_work()`), `browserOpened/Closed` |
| `ContentView.swift` | `removePane(byId:)`, `finishRemovingCEFPane(byId:)`, `.onReceive(cefBrowserDidClose)` |
| `main.swift` | Entry point — signal handlers, eager CEF init, `WatchtowerApp.main()` |

## CEFClientContext State

```swift
class CEFClientContext {
    weak var browserModel: BrowserPaneModel?
    weak var browserView: ChromiumBrowserView?
    var strongBrowserView: ChromiumBrowserView?  // keeps NSView alive during close
    var cefBrowser: UnsafeMutablePointer<cef_browser_t>?
    var client, lifeSpanHandler, loadHandler, displayHandler, downloadHandler, focusHandler
    var devToolsObserver, devToolsRegistration
    var progressTimer: Timer?
}
```

## What We Know For Certain

1. The `isHandlingSendEvent` crash is fixed (swizzle works).
2. `do_close` fires on the main thread.
3. **`do_close` returning 0** causes CEF to send `performClose:` to the top-level NSWindow, closing the entire Watchtower window (not just the browser pane). The `terminate:` swizzle in `CefApplication.m` swallows CEF's quit attempt, so the app stays alive but the window is gone.
4. **`do_close` returning 1** prevents the `performClose:` call. No crash, no window close. But the app MUST complete the close itself.
5. `removeFromSuperview()` on the parent `ChromiumBrowserView` is NOT sufficient to trigger `on_before_close`. CEF monitors its own internal child view (`CefBrowserHostView`), not the parent.
6. `dismantleNSView` fires between `do_close` and `on_before_close` when SwiftUI detects structural changes — this is what caused the original crash (NSView freed while CrBrowserMain still uses it).
7. The `strongBrowserView` pattern successfully keeps the NSView alive through the close sequence, preventing the use-after-free crash.
8. The terminal pane's pty closes during the CEF close sequence (appears in logs as `pty fd closed` / `surface closed`). Our `closeSurface` callback is never called for this. This is unexplained but may be a consequence of the app being in a broken state from earlier approaches.
9. The crash is always `CrBrowserMain: EXC_BREAKPOINT` — a CHECK/DCHECK failure on CEF's internal thread, not the main thread. It occurs when CrBrowserMain accesses a freed NSView.
10. **`close_browser(force=1)` re-triggers `do_close`** rather than skipping to `on_before_close`. `didScheduleForceClose` flag on `CEFClientContext` breaks the resulting infinite loop.
11. **`close_browser(force=1)` alone does NOT fire `on_before_close`.** CEF requires the NSView to actually be removed from its parent window (i.e., `dismantleNSView` must run) before it will fire `on_before_close`. Calling `close_browser(force=1)` in isolation from our async block in `do_close` stalls — `on_before_close` never fires. But `close_browser(force=1)` called from `dismantleNSView` (when SwiftUI is tearing down the view) does fire `on_before_close` correctly.
12. **The correct sequence is:** `close_browser(force=1)` + remove the pane from the SwiftUI array in the same run loop tick. Removing the pane triggers `dismantleNSView`, which is what CEF is waiting for. The `strongBrowserView` keeps the NSView alive for CrBrowserMain so there's no crash.

## What We Don't Know

1. **Will calling `close_browser(force=1)` + `finishRemovingCEFPane` in the same async block work cleanly?** This is the next thing to try. The `dismantleNSView` path works when the pane is force-removed on the second click — the same thing should work on the first click if we call both `close_browser(force=1)` AND remove the pane from the array (bypassing the two-phase guard since `isClosingCEF` is already set). The `strongBrowserView` should prevent the crash.

2. **Will the crash recur with the new sequence?** When `dismantleNSView` runs while `strongBrowserView` is held, CEF can call `on_before_close`. But we need to verify CrBrowserMain finishes its cleanup before we release `strongBrowserView` (the 250ms delay in `on_before_close` handles this).

3. **Why does the terminal pty close?** Still unexplained.

## Failed Approaches (Do NOT Retry)

1. **`installCefAppProtocolMethods()` via `class_addMethod` / `method_setImplementation`** — called too late (after SwiftUI installed its subclass). Caused the app to not launch.

2. **`object_setClass(NSApp, CefNSApplication.self)`** — rejected; ivar layout mismatch risk with SwiftUI's internal `NSApplication` subclass.

3. **`CefApplication.mm` (Objective-C++)** — `__cplusplus` defined causes `cef_application_mac.h` to pull in `cef_base.h` → `chromium/version` (plain text) → C++ parse failure.

4. **`do_close` returning 0 (false)** — CEF sends `performClose:` to the top-level NSWindow, closing the entire Watchtower window instead of just the browser pane. (CEF docs lines 191-196: "returning false from DoClose() will send the standard close notification to the browser's top-level parent window (e.g. performClose: on OS X).") User confirmed: "the entire window closed but the app did not crash. The console continues to show CEF pump tick logs."

5. **`do_close` returning 1 without any view teardown** — CEF expects the app to complete the close by tearing down the view hierarchy. Without that, `on_before_close` never fires and the pane hangs.

6. **Deferring `cefCleanupClientContext` to the 250ms delayed block** — moved handler cleanup later, but crash still happens. The handlers aren't the issue.

7. **`strongBrowserView` captured in `on_before_close`** — too late; the weak `browserView` reference is already nil by then (view deallocated between `dismantleNSView` and `on_before_close`).

8. **`strongBrowserView` captured in `do_close` (return 0)** — successfully keeps the NSView alive, but `on_before_close` never fires. CEF's close sequence stalls because it can't destroy the parent view, and it also sends `performClose:` to the window.

9. **`do_close` returning 1 + `removeFromSuperview()` async** — prevents the window close (good), doesn't crash (good), but `on_before_close` never fires. CEF doesn't consider `removeFromSuperview()` on the parent `ChromiumBrowserView` as sufficient "view hierarchy tear-down" — CEF created an internal child `CefBrowserHostView` inside our view and is watching for *that* to be destroyed, not the parent. The pane remains as an empty header with no browser view, and the message pump ticks indefinitely. No crash, but the close never completes.

10. **`do_close` returning 1 + `close_browser(force=1)` async (no view teardown)** — `close_browser(force=1)` re-triggers `do_close` (loop broken by `didScheduleForceClose` guard), then stalls. `on_before_close` never fires because CEF requires the NSView to actually be removed from its parent window — `close_browser(force=1)` alone is not sufficient.

## Current Approach (In Progress)

**Root cause (fully understood):** CEF fires `on_before_close` only when BOTH conditions are met:
1. `close_browser` has been called (with any force value)
2. The NSView is actually removed from its parent window (SwiftUI tears down `dismantleNSView`)

The working path (second click, accidental) proves this: `close_browser(force=1)` in `dismantleNSView` works because both happen simultaneously. The failing path (first click, `close_browser(force=1)` in isolation) fails because the NSView is still in the hierarchy.

**Next step — call `close_browser(force=1)` AND `finishRemovingCEFPane` from the same async block in `do_close`:**

In `do_close`'s async block, after calling `close_browser(force=1)`, also call `finishRemovingCEFPane(byId:)` (or post the `.cefBrowserDidClose` notification directly). This removes the pane from the SwiftUI array, which triggers `dismantleNSView`. At that point, `dismantleNSView` will see `isClosingCEF=true` and skip its own force-close (it already happened). CEF sees the view disappear and fires `on_before_close`. The `strongBrowserView` keeps the NSView alive for CrBrowserMain.

The `on_before_close` handler already handles the 250ms delayed cleanup. We should NOT post `.cefBrowserDidClose` a second time from `do_close` — `on_before_close` handles that. We just need to trigger `dismantleNSView` by removing the pane from the array.

### Expected close sequence (after applying the fix):
```
1. removePane(byId:) — sets isClosingCEF=true, calls closeCEFBrowser()
2. closeCEFBrowser() — close_browser(force=0)
3. do_close fires, returns 1, captures strongBrowserView, sets didScheduleForceClose=true
4. [async] close_browser(force=1) — tells CEF to force-close
5. [async] finishRemovingCEFPane(byId:) — removes pane from SwiftUI array
6. SwiftUI calls dismantleNSView — sees isClosingCEF=true, skips its own force-close
7. NSView removed from parent window → CEF detects view teardown
8. do_close fires again (from force=1) — hits didScheduleForceClose guard, returns 1
9. on_before_close fires — releases cefBrowser, calls browserClosed()
10. [250ms] releases strongBrowserView, calls cefCleanupClientContext, posts cefBrowserDidClose
11. .onReceive cefBrowserDidClose — pane already removed (step 5), no-op or safe double-call
```

## Current State of the Code

## Final Working State

### Solution summary:

CEF fires `on_before_close` only when BOTH of the following happen:
1. `close_browser` has been called (with any force value)
2. The NSView is actually removed from its parent window

In `do_close`'s async block, call `close_browser(force=1)` then `finishRemovingCEFPane(byId:)` in the same run loop tick. `finishRemovingCEFPane` removes the pane from SwiftUI's array, triggering `dismantleNSView`. `dismantleNSView` sees `isClosingCEF=true` and skips its own force-close. CEF detects the view removal and fires `on_before_close`. `strongBrowserView` keeps the NSView alive for CrBrowserMain throughout.

### Changes in the codebase:
- `CEFClientContext`: `strongBrowserView` and `didScheduleForceClose` properties (`CEFClientHandlers.swift`)
- `do_close`: returns 1, captures `strongBrowserView`, guards with `didScheduleForceClose`, async block calls `close_browser(force=1)` + `finishRemovingCEFPane(byId:)`
- `on_before_close`: 250ms delayed block releases `strongBrowserView`, calls `cefCleanupClientContext`, posts `.cefBrowserDidClose` (safe no-op if pane already removed)
- `dismantleNSView`: sees `isClosingCEF=true`, skips redundant force-close
- `CefApplication.m`: `+load` swizzle for `isHandlingSendEvent` and `terminate:`

### Working close sequence:
```
1. removePane(byId:) — sets isClosingCEF=true, calls closeCEFBrowser()
2. closeCEFBrowser() — close_browser(force=0)
3. do_close fires — strongBrowserView captured, didScheduleForceClose=true, async block queued
4. [async] close_browser(force=1) + finishRemovingCEFPane(byId:)
5. SwiftUI calls dismantleNSView — sees isClosingCEF=true, skips
6. CEF detects view removal → on_before_close fires
7. [250ms] strongBrowserView released, cefCleanupClientContext, cefBrowserDidClose posted
8. .onReceive cefBrowserDidClose → finishRemovingCEFPane (pane already gone, safe no-op)
```

### Cleanup still needed (before merging):
- Re-enable IPC server: `WatchtowerApp.swift:151`, `ContentView.swift:74,77`
- Consider removing verbose diagnostic logging once confident in stability

## Build & Test

```bash
# Build
xcodebuild -project Watchtower.xcodeproj -scheme Watchtower -configuration Debug build

# Test: open app, open a browser pane (Cmd+T or similar), close the browser pane
# Observe logs in Xcode console for the close sequence
```
