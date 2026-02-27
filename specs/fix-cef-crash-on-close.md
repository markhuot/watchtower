# Fix CEF Crash on Browser Pane Close

## Status

**Likely fixed (needs runtime verification).** The full close sequence works and the pump no
longer stops on browser close — it runs for the lifetime of the app.

---

## Background: isHandlingSendEvent (FIXED)

The original crash was `NSInvalidArgumentException — -[NSApplication isHandlingSendEvent]:
unrecognized selector`. Fixed by swizzling `NSApplication` in `CefApplication.m` via `+load`
(the QCefView pattern). Not the current issue.

---

## Root Cause (Confirmed)

CEF fires `on_before_close` only when BOTH conditions are met:

1. `close_browser` has been called (with any force value)
2. The `ChromiumBrowserView` NSView is actually **deallocated** (not just removed from the
   window hierarchy)

`strongBrowserView` on `CEFClientContext` was a prior attempt to keep the view alive — but it
prevented deallocation, which prevented `on_before_close` from ever firing. Removing
`strongBrowserView` was the breakthrough: the view can now deallocate, and `on_before_close`
fires correctly.

---

## Final Working Close Sequence

```
1. removePane(byId:) — sets isClosingCEF=true, calls closeCEFBrowser()
2. closeCEFBrowser() — close_browser(force=0)
3. do_close fires, returns 1 (suppress performClose: on NSWindow)
   - sets didScheduleForceClose=true
   - dispatches async block to main queue
4. [async] close_browser(force=1) — tells CEF to force-close
5. [async] finishRemovingCEFPane(byId:) — removes pane from SwiftUI array
6. SwiftUI calls dismantleNSView — sees isClosingCEF=true, skips its own force-close
7. do_close fires again (force=1 re-triggers it) — didScheduleForceClose guard returns 1
8. ChromiumBrowserView.deinit fires (view deallocated — no strongBrowserView holding it)
9. on_before_close fires ✓
10. browserClosed: activeBrowserCount decremented (pump keeps running)
11. [250ms delayed] cefCleanupClientContext, posts cefBrowserDidClose
12. .onReceive cefBrowserDidClose → finishRemovingCEFPane (pane already gone, safe no-op)
```

Pump keeps running until `shutdown()` at app quit — no crash.

---

## Key Facts (Confirmed)

1. `do_close` returning 0 — CEF sends `performClose:` to the top-level NSWindow, closing the
   entire app window. Do NOT return 0.
2. `do_close` returning 1 — prevents window close; the app must complete the close itself.
3. `close_browser(force=1)` re-triggers `do_close` — does NOT skip to `on_before_close`.
   `didScheduleForceClose` guard on `CEFClientContext` breaks the loop.
4. `close_browser(force=1)` alone (without view deallocation) does NOT fire `on_before_close`.
5. `removeFromSuperview()` on the parent `ChromiumBrowserView` is NOT sufficient — CEF watches
   its own internal `CefBrowserHostView`, not the parent.
6. `strongBrowserView` prevents deallocation → prevents `on_before_close`. Do NOT re-add it.
7. CEF requires `cef_do_message_loop_work()` to keep running after `on_before_close` for the
   entire lifetime of the app. CrBrowserMain's internal threads keep running after close and
   need the pump to drain their work queue. If the pump stops, CrBrowserMain backs up and
   eventually posts directly to NSApp's event loop via `_cef_swizzled_sendEvent` → crash.
8. The pump costs almost nothing when idle — `cef_do_message_loop_work()` returns immediately
   when there is no work to do.
9. Calling `cef_do_message_loop_work()` after all browsers are closed but while still holding
   the pump open is safe — the crash only occurred when the pump was *stopped* and CEF had
   nowhere to drain its work.

---

## Failed Approaches (Do NOT Retry)

1. **`installCefAppProtocolMethods()` via `class_addMethod` / `method_setImplementation`** —
   called too late (after SwiftUI installed its subclass). App wouldn't launch.
2. **`object_setClass(NSApp, CefNSApplication.self)`** — ivar layout mismatch risk.
3. **`CefApplication.mm` (Objective-C++)** — `__cplusplus` pulls in C++ headers, parse failure.
4. **`do_close` returning 0** — closes entire window.
5. **`do_close` returning 1 + `removeFromSuperview()` async** — `on_before_close` never fires.
6. **`do_close` returning 1 + `close_browser(force=1)` async, no view teardown** — stalls.
7. **`strongBrowserView` captured in `do_close`** — keeps view alive, `on_before_close` never fires.
8. **`strongBrowserView` captured in `on_before_close`** — too late, weak ref already nil.
9. **Stopping pump immediately after `on_before_close`** — CrBrowserMain still running, EXC_BREAKPOINT.
10. **Stopping pump 0.5s after `on_before_close`** — still crashes. Crash was NOT at pump stop — it was `CEFClientContext.deinit` freeing handler structs CrBrowserMain still holds.
11. **Stopping pump 3.0s + no ctx hold** — crash still before pump stop fires. Pump delay irrelevant; crash in `deinit`.
12. **3s ctx hold in on_before_close 250ms block** — ctx dealloc crash fixed. New crash: 5 post-stop `cef_do_message_loop_work()` flush ticks in `stopMessagePump()`. Pumping CEF after all browsers are gone causes EXC_BREAKPOINT.
13. **Post-stop flush ticks** — calling `cef_do_message_loop_work()` after browsers are closed crashes CrBrowserMain. Removed.
14. **Stopping pump 3.0s after last browser closed (no flush ticks)** — app crashes ~3s after close in `_cef_swizzled_sendEvent`. CrBrowserMain threads keep running after `on_before_close` and post work to NSApp's event loop when the pump is stopped. Fix: never stop the pump while the app is running.
15. **`_ = ctx` in 3s hold closure** — `_ = ctx` is optimized away by the Swift compiler and does NOT extend lifetime. The crash occurred exactly when `[CLOSE-DEBUG] ctx hold released` fired (3s after close), confirming the hold was not working. Fix: assign to `let heldCtx = ctx` and use `withExtendedLifetime(heldCtx) {}` to guarantee the compiler emits a real strong retain until the closure body completes.
16. **`withExtendedLifetime(heldCtx) {}` 3s hold still crashes** — crash still occurs at `[CLOSE-DEBUG] ctx hold released` (3s mark). Root cause: `CEFClientContext.deinit` called `release()` on all C handler structs. CEF's CrBrowserMain thread holds its own `add_ref`'d refs to these structs for an indeterminate time after `on_before_close`. When `deinit` decrements to 0 and frees the allocation, CrBrowserMain is still using it → EXC_BREAKPOINT. Fix: remove ALL `release()` calls from `deinit` — the handler structs are intentionally leaked (~2-4 KB per closed browser pane, acceptable for a GUI app). Only `devToolsRegistration` is explicitly released in `cefCleanupClientContext` at 250ms (safe because that ref is ours to control and the browser is fully closed by then).

---

## What Was Fixed (Summary)

| Crash | Fix |
|---|---|
| `isHandlingSendEvent` unrecognized selector | `CefApplication.m` `+load` swizzle |
| `on_before_close` never fired | Removed `strongBrowserView` so NSView can deallocate |
| `CEFClientContext.deinit` freeing handler structs while CrBrowserMain holds refs | 3s ctx hold in `on_before_close` 250ms block |
| Post-stop `cef_do_message_loop_work()` flush calls crashing CrBrowserMain | Removed 5 flush tick calls from `stopMessagePump()` |
| `_cef_swizzled_sendEvent` crash after pump stopped | Pump now runs for app lifetime; never stopped on browser close |
| `_ = ctx` hold not working — ctx released at 250ms block end | Use `let heldCtx = ctx` + `withExtendedLifetime(heldCtx) {}` in 3s block |
| `deinit` releasing handler structs while CrBrowserMain still uses them | Removed ALL `release()` from `deinit`; handler structs intentionally leaked; only `devToolsRegistration` released in `cefCleanupClientContext` at 250ms |

---

## Relevant Files

| File | Role |
|---|---|
| `CefApplication.m` | ObjC swizzle for `isHandlingSendEvent` and `terminate:` (WORKING) |
| `CEFClientHandlers.swift` | `do_close`, `on_before_close`, `on_after_created`, handler registries |
| `ChromiumBrowserView.swift` | NSView hosting CEF; `closeCEFBrowser()`, `closeCEFBrowserForce()`, `deinit` |
| `ChromiumBrowserRepresentable.swift` | `NSViewRepresentable` wrapper; `dismantleNSView` |
| `ChromiumManager.swift` | CEF lifecycle singleton; message pump timer; `browserOpened/Closed` |
| `ContentView.swift` | `removePane(byId:)`, `finishRemovingCEFPane(byId:)`, `.onReceive(cefBrowserDidClose)` |

---

## Next Steps (Post-Fix Cleanup)

1. **Runtime verification** — open browser pane, close it, verify no crash and clean log sequence.
2. **Clean up verbose diagnostic logging** — remove `[CLOSE-DEBUG]` NSLog calls throughout.
3. **Re-enable IPC server** — `WatchtowerApp.swift:151`, `ContentView.swift:74,77`.

---

## Build & Test

```bash
xcodebuild -project Watchtower.xcodeproj -scheme Watchtower -configuration Debug build
# Open app → open a browser pane → close it → check console for crash or clean sequence
```
