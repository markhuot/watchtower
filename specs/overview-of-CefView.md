Comprehensive Analysis of QCefView CEF Embedding Patterns
1. Message Pump When the Host Framework Owns the Run Loop
The Core Strategy: external_message_pump = true + periodic CefDoMessageLoopWork
File: src/mac/details/QCefContextPrivate_mac.mm, lines 202–204
// external_message_pump not supported on macOS
cef_settings.multi_threaded_message_loop = false;
cef_settings.external_message_pump = true;
The comment is confusing. What it means is: on macOS, you cannot use multi_threaded_message_loop = true (that belongs to Windows). You must use external_message_pump = true, which tells CEF "I own the run loop, I'll call CefDoMessageLoopWork on a schedule." This is exactly the mode needed when SwiftUI/NSApp already owns NSRunLoop.
Scheduling: src/details/QCefContextPrivate.cpp, lines 18 and 52–55
const int64_t kCefWorkerIntervalMs = (1000 / 60); // 60 fps
// start message pump timer
if (!config_->standaloneMessageLoopEnabled().toBool()) {
    cefWorkerTimer_.start(kCefWorkerIntervalMs);
}
A 60fps QTimer fires every ~16ms, calling performCefLoopWork() → CefDoMessageLoopWork(). The timer is attached to the Qt main thread's event loop, exactly as a Swift DispatchSourceTimer would be attached to the main queue.
The performCefLoopWork pump: src/details/QCefContextPrivate.cpp, lines 182–185
void QCefContextPrivate::performCefLoopWork() {
    CefDoMessageLoopWork();
}
This is the analog of calling cef_do_message_loop_work() in a timer callback on the main thread.
---
2. OnScheduleMessagePumpWork — Adaptive Scheduling
File: src/details/CCefAppDelegate.cpp, lines 44–49
void CCefAppDelegate::onScheduleMessageLoopWork(int64_t delay_ms) {
    if (pContext_) {
        pContext_->scheduleCefLoopWork(delay_ms);
    }
}
File: src/details/QCefContextPrivate.cpp, lines 138–143
void QCefContextPrivate::scheduleCefLoopWork(int64_t delayMs) {
    // calculate the effective delay number
    auto delay = qMax((int64_t)0, qMin(delayMs, kCefWorkerIntervalMs));
    QTimer::singleShot(static_cast<int>(delay), this, SLOT(performCefLoopWork()));
}
The key pattern: CEF calls OnScheduleMessagePumpWork(delay_ms) from inside its own internals when it needs a CefDoMessageLoopWork call sooner than the next timer tick. QCefView clamps delay_ms to [0, 16ms] and fires a singleShot timer. The base 60fps timer still runs; this just schedules extra work sooner when CEF needs it. This is the right approach — the periodic timer is the "heartbeat" and the OnScheduleMessagePumpWork callback provides the "burst on demand."
For Swift: Translate this as: set a 16ms DispatchSourceTimer as the heartbeat, and in OnScheduleMessagePumpWork(delay), do DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(min(max(0, delay), 16))) { cef_do_message_loop_work() }.
---
3. The NSApplication Swizzling Pattern (Lines 56–114)
File: src/mac/details/QCefContextPrivate_mac.mm, lines 56–114
This is the centerpiece. Because QCefView cannot change the NSApplication class (Qt created NSApp first), it uses Objective-C runtime swizzling to retroactively make NSApplication conform to CefAppProtocol:
bool g_handling_send_event = false;  // line 54
@interface NSApplication (CocoaCefApp)<CefAppProtocol>  // lines 56-61
- (void)_swizzled_sendEvent:(NSEvent*)event;
- (void)_swizzled_terminate:(id)sender;
- (void)_swizzled_run;
@end
@implementation NSApplication (CocoaCefApp)
+ (void)load  // lines 67-82: called at dylib load time, before main()
{
    // swizzle sendEvent:
    Method original_sendEvent = class_getInstanceMethod(self, @selector(sendEvent:));
    Method swizzled_sendEvent = class_getInstanceMethod(self, @selector(_swizzled_sendEvent:));
    method_exchangeImplementations(original_sendEvent, swizzled_sendEvent);
    // swizzle terminate:
    Method original_terminate = class_getInstanceMethod(self, @selector(terminate:));
    Method swizzled_terminate = class_getInstanceMethod(self, @selector(_swizzled_terminate:));
    method_exchangeImplementations(original_terminate, swizzled_terminate);
    // swizzle run — commented out, NOT enabled:
    // method_exchangeImplementations(original_run, swizzled_run);
}
- (BOOL)isHandlingSendEvent { return g_handling_send_event; }         // line 84-87
- (void)setHandlingSendEvent:(BOOL)h { g_handling_send_event = h; }   // line 89-92
- (void)_swizzled_sendEvent:(NSEvent*)event  // lines 94-99
{
    CefScopedSendingEvent sendingEventScoper;  // sets isHandlingSendEvent=YES, restores on destruct
    [self _swizzled_sendEvent:event];          // calls original sendEvent (names are swapped)
}
- (void)_swizzled_terminate:(id)sender  // lines 101-105 — passthrough (no special logic)
{
    [self _swizzled_terminate:sender];
}
- (void)_swizzled_run  // lines 107-113 — DISABLED but shows the alternative design
{
    // Un-swizzle run, then call CefRunMessageLoop instead of NSApp's run
    method_exchangeImplementations(...);
    CefRunMessageLoop();  // would replace NSRunLoop entirely — NOT used
}
@end
What this achieves:
- isHandlingSendEvent / setHandlingSendEvent: CEF's internal Chromium message pump checks this to know whether it is re-entering sendEvent:. Without it, CEF can deadlock or spin.
- The sendEvent: swizzle wraps every event dispatch with CefScopedSendingEvent, which sets handlingSendEvent = YES for the duration. This is required by CEF's internal MessagePumpCFRunLoop.
- The run swizzle is intentionally disabled (commented out lines 79-81). Using CefRunMessageLoop() would completely replace Qt's event loop — not desired. Instead, the timer-based CefDoMessageLoopWork approach is used.
For SwiftUI/Watchtower: You cannot subclass NSApplication (SwiftUI owns it), but you can apply the same swizzling from a Swift @objc class loaded at startup. The critical method to swizzle is sendEvent: to wrap it with CefScopedSendingEvent. The isHandlingSendEvent/setHandlingSendEvent methods must also be added via a category/extension.
---
4. Browser/View Close and Teardown Sequences
The top-level trigger — per-view: src/QCefView.cpp, lines 66–75
QCefView::~QCefView() {
    if (d_ptr) {
        d_ptr->destroyCefBrowser();  // synchronous request to close
        d_ptr.reset();               // release private data after
    }
}
destroyCefBrowser — the close initiator: src/details/QCefViewPrivate.cpp, lines 209–230
void QCefViewPrivate::destroyCefBrowser() {
    if (!pClient_) return;
    if (!isOSRModeEnabled_ && ncw.qBrowserWidget_) {
        // Detach the native CEF window widget from parent
        ncw.qBrowserWidget_->setParent(nullptr);
        ncw.qBrowserWidget_->deleteLater();
        ncw.qBrowserWindow_->detachCefWindow();
    }
    // Signal CEF to close all browsers on the UI thread
    pClient_->CloseAllBrowsers();
    // Null out our references immediately
    pClient_ = nullptr;
    pCefBrowser_ = nullptr;
    qApp->removeEventFilter(this);
}
Key insight: destroyCefBrowser does not wait for CEF to complete its asynchronous close. It fires CloseAllBrowsers(), nulls the local refs, and returns immediately. CEF completes the close asynchronously via its UI thread callbacks (DoClose → OnBeforeClose). The waiting happens at the app-quit level, not at the individual view level.
requestCloseFromWeb (web-initiated close): src/details/QCefViewPrivate.cpp, lines 433–448
bool QCefViewPrivate::requestCloseFromWeb(CefRefPtr<CefBrowser>& browser) {
    bool allowClose = q->onRequestCloseFromWeb();
    if (allowClose) {
        destroyCefBrowser();
    }
    return allowClose;
}
Default onRequestCloseFromWeb in QCefView.cpp line 347: calls deleteLater() on itself.
---
5. DoClose and OnBeforeClose Implementations
File: src/details/handler/CCefClientDelegate_LifeSpanHandler.cpp
doClose (lines 178–184) — called by CEF on UI thread when host->CloseBrowser() is processed:
bool CCefClientDelegate::doClose(CefRefPtr<CefBrowser>& browser) {
    qDebug() << "destroy browser from native";
    return false;  // return false = allow OS to destroy the window
}
This is intentionally minimal. Returning false tells CEF: "yes, allow the native window close to proceed." The CEF docs say: if you return false from DoClose, CEF will send an OS close event to the native window. On macOS for an embedded (non-popup) browser this triggers the normal window teardown.
onBeforeClose (lines 201–203) — called after the browser's native resources are actually freed:
void CCefClientDelegate::onBeforeClose(CefRefPtr<CefBrowser>& browser) {
    // empty — nothing to do here in QCefView's model
}
QCefView doesn't need to act in OnBeforeClose because:
- View-side cleanup (destroyCefBrowser) already happened synchronously before CloseBrowser() was called
- App-level safety check uses IsSafeToExit() polled on a timer, not OnBeforeClose
requestClose (web-initiated, lines 186–199):
bool CCefClientDelegate::requestClose(CefRefPtr<CefBrowser>& browser) {
    auto pCefViewPrivate = pCefViewPrivate_.lock();
    if (!pCefViewPrivate) return false;
    bool ignoreClose = false;
    runInMainThreadAndWait([&]() {
        ignoreClose = !(pCefViewPrivate->requestCloseFromWeb(browser));
    });
    return ignoreClose;
}
This is called on the CEF UI thread when JavaScript calls window.close(). It marshals to the Qt main thread and waits (using a nested QEventLoop to not block CEF's UI thread) for the main thread to decide.
---
6. Async Close / Deferred Shutdown — The IsSafeToExit Pattern
File: src/details/QCefContextPrivate.cpp, lines 146–178
void QCefContextPrivate::onAboutToQuit() {
    if (!pApp_) return;
    // Step 1: Close all live browsers
    QCefViewPrivate::destroyAllInstance();
    // Step 2: Check if CEF is done
    if (!pApp_->IsSafeToExit()) {
        // Step 3: Spin a nested event loop while CEF drains
        QEventLoop exitCleanLoop;
        QTimer exitCheckTimer;
        connect(&exitCheckTimer, &QTimer::timeout, [&]() {
            if (pApp_->IsSafeToExit())
                exitCleanLoop.quit();
        });
        exitCheckTimer.start(0);   // fires every event loop tick (0ms = as fast as possible)
        exitCleanLoop.exec();      // blocks here until IsSafeToExit() returns true
    }
    // CefShutdown() called next in uninitialize()
}
The full destruction order:
1. App receives aboutToQuit signal
2. destroyAllInstance() iterates all live QCefViewPrivate* instances and calls destroyCefBrowser() on each
3. Each destroyCefBrowser() calls pClient_->CloseAllBrowsers() and nulls refs
4. CEF processes closures asynchronously on its UI thread (which is the main thread in external_message_pump mode)
5. IsSafeToExit() polls whether all CEF browser references have been released
6. The 0ms timer keeps firing, keeping CEF's message loop alive via cefWorkerTimer_ still running during exitCleanLoop.exec()
7. Once IsSafeToExit() = true, the nested loop quits
8. uninitializeCef() is called: nulls pApp_, then CefShutdown(), then freeCefLibrary()
For Swift: The equivalent is: when the app is terminating, call closeBrowser() on all panes, then spin a RunLoop.main.run(until:) loop (or DispatchSemaphore) checking periodically until all browser reference counts drop to zero (you need to track this), then call cef_shutdown().
---
7. CEF Object Teardown Order
From src/mac/details/QCefContextPrivate_mac.mm, lines 230–243:
void QCefContextPrivate::uninitializeCef() {
    if (!pApp_) return;
    pAppDelegate_ = nullptr;   // 1. release app delegate (shared_ptr)
    pApp_ = nullptr;           // 2. release app CefRefPtr
    CefShutdown();             // 3. shutdown CEF — must happen with no live browsers
    freeCefLibrary();          // 4. unload the .framework dylib
}
The complete sequence (earliest to latest):
1. All QCefView destructors fire → destroyCefBrowser() → CloseAllBrowsers()
2. CEF processes browser closures on main thread (via CefDoMessageLoopWork in the spinning exitCleanLoop)
3. DoClose callback returns false → CEF destroys the native window
4. OnBeforeClose fires (empty in QCefView) → CEF releases the CefBrowser ref
5. IsSafeToExit() returns true (CefViewBrowserApp's ref count drops to 1)
6. pAppDelegate_ released
7. pApp_ (CefRefPtr) released
8. CefShutdown() called — this is the hard requirement: no live browsers
9. cef_unload_library() — unload dylib
---
8. The runInMainThreadAndWait Pattern (Cross-Thread Safety)
File: src/details/CCefClientDelegate.h, lines 72–95
This solves the race condition between CEF's internal UI thread callbacks and Swift/Qt view teardown:
template<typename Functor>
void runInMainThreadAndWait(Functor&& function) {
    if (QThread::currentThread() == qApp->thread()) {
        function();  // already on main thread, call directly
    } else {
        // Create a nested event loop on the CALLING thread (CEF UI thread)
        QEventLoop eventLoop;
        QMetaObject::invokeMethod(qApp, [&eventLoop, &function]() {
            function();   // run on main thread
            QMetaObject::invokeMethod(&eventLoop, &QEventLoop::quit);  // signal done
        });
        eventLoop.exec();  // don't block the CEF UI thread's event loop — spin nested loop
    }
}
Why this matters: CEF calls doClose and lifecycle callbacks on the CEF UI thread (which in external_message_pump mode IS the main thread, but abstractly it may not be). When this callback needs to touch Qt/SwiftUI objects (which must be on the main thread), it marshals to main and waits. Critically, it does NOT block the calling thread with a mutex — it runs a nested event loop so the calling thread keeps processing messages.
For Swift: Use DispatchSemaphore + DispatchQueue.main.async + semaphore.signal() after the main-thread work completes. Or use DispatchQueue.main.sync if calling from a background thread (CEF's internal threads, not the UI thread in external pump mode).
---
9. The SurfaceAboutToBeDestroyed Race Condition
File: src/details/QCefViewPrivate.cpp, lines 906–917
case QEvent::PlatformSurface: {
    if (!isOSRModeEnabled_) {
        auto t = static_cast<QPlatformSurfaceEvent*>(event)->surfaceEventType();
        if (QPlatformSurfaceEvent::SurfaceAboutToBeDestroyed == t) {
            if (watched == ncw.qBrowserWindow_->cefWindow()) {
                // Detach CEF window BEFORE the native surface is destroyed
                ncw.qBrowserWindow_->detachCefWindow();
            }
        }
    }
}
QCefView explicitly detaches the CEF native window from the Qt window hierarchy when the platform surface is about to be destroyed. This prevents CEF from accessing a deallocated NSView. The detachCefWindow() call removes the CEF NSView from its parent window before the parent is destroyed.
---
10. The _swizzled_run / CefRunMessageLoop Alternative (Not Used)
Lines 107–113 show the alternative design: if you could replace the entire run loop, you'd un-swizzle run, then call CefRunMessageLoop() which internally calls [NSApp run] after setting up CEF's integration. This is what cefsimple and cefclient do (line 191 and 625 respectively in their main functions).
QCefView intentionally does NOT do this because Qt already called [NSApp run]. The swizzle of run is commented out precisely because Qt owns the run loop.
Summary of the two modes:
- CEF owns the run loop (standalone app): CefRunMessageLoop() → [NSApp run] internally. Used by cefsimple and cefclient.
- Host framework owns the run loop (QCefView / Watchtower): external_message_pump = true + CefDoMessageLoopWork() on a timer + sendEvent: swizzle for CefScopedSendingEvent. This is what we need.
---
Key File:Line Reference Summary
| Pattern | File | Lines |
|---|---|---|
| external_message_pump = true (macOS) | src/mac/details/QCefContextPrivate_mac.mm | 202–204 |
| NSApplication swizzle (+load method) | src/mac/details/QCefContextPrivate_mac.mm | 56–114 |
| isHandlingSendEvent global state | src/mac/details/QCefContextPrivate_mac.mm | 54, 84–92 |
| sendEvent: wraps CefScopedSendingEvent | src/mac/details/QCefContextPrivate_mac.mm | 94–99 |
| _swizzled_run / CefRunMessageLoop (disabled) | src/mac/details/QCefContextPrivate_mac.mm | 107–113 |
| 60fps heartbeat timer | src/details/QCefContextPrivate.cpp | 18, 52–55 |
| OnScheduleMessagePumpWork → clamped singleShot | src/details/QCefContextPrivate.cpp | 138–143 |
| performCefLoopWork → CefDoMessageLoopWork | src/details/QCefContextPrivate.cpp | 182–185 |
| onAboutToQuit with IsSafeToExit spin loop | src/details/QCefContextPrivate.cpp | 146–178 |
| uninitializeCef teardown order | src/mac/details/QCefContextPrivate_mac.mm | 230–243 |
| destroyAllInstance (close all on quit) | src/details/QCefViewPrivate.cpp | 41–48 |
| destroyCefBrowser (view-level close) | src/details/QCefViewPrivate.cpp | 209–230 |
| QCefView::~QCefView destructor | src/QCefView.cpp | 66–75 |
| DoClose → returns false | src/details/handler/CCefClientDelegate_LifeSpanHandler.cpp | 178–184 |
| OnBeforeClose → empty | src/details/handler/CCefClientDelegate_LifeSpanHandler.cpp | 201–203 |
| requestClose (web-initiated) with nested loop | src/details/handler/CCefClientDelegate_LifeSpanHandler.cpp | 186–199 |
| runInMainThreadAndWait (nested event loop) | src/details/CCefClientDelegate.h | 72–95 |
| SurfaceAboutToBeDestroyed detach race guard | src/details/QCefViewPrivate.cpp | 906–917 |
| CEF's CefAppProtocol definition | chromium/include/cef_application_mac.h | 60–75 |
| CefScopedSendingEvent RAII class | chromium/include/cef_application_mac.h | 81–94 |
| cefsimple standalone: CefRunMessageLoop() mode | tests/cefsimple/cefsimple_mac.mm | 191 |
| cefsimple DoClose sets is_closing_ flag | tests/cefsimple/simple_handler.cc | 73–87 |
| OnBeforeClose calls CefQuitMessageLoop | tests/cefsimple/simple_handler.cc | 89–105 |
