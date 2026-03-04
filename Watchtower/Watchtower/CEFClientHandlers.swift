import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "com.watchtower", category: "CEFClientHandlers")

func cefOpenDevTools(
    for browser: UnsafeMutablePointer<cef_browser_t>,
    browserModel: BrowserPaneModel?,
    inspectPoint: cef_point_t = cef_point_t(x: 0, y: 0)
) {
    let port = ChromiumManager.shared.initializedRemoteDebuggingPort

    // If remote debugging is not available, fall back to popup window.
    guard port > 0 else {
        guard let host = browser.pointee.get_host?(browser) else { return }
        defer { _ = host.pointee.base.release?(&host.pointee.base) }

        var windowInfo = cef_window_info_t()
        memset(&windowInfo, 0, MemoryLayout<cef_window_info_t>.size)
        windowInfo.size = MemoryLayout<cef_window_info_t>.size
        var settings = cef_browser_settings_t()
        memset(&settings, 0, MemoryLayout<cef_browser_settings_t>.size)
        settings.size = MemoryLayout<cef_browser_settings_t>.size

        var point = inspectPoint
        host.pointee.show_dev_tools?(host, &windowInfo, nil, &settings, &point)
        return
    }

    // Fetch targets from remote debugging endpoint and open DevTools in an adjacent pane.
    let currentURL = browserModel?.url.absoluteString ?? ""
    let targetURL = URL(string: "http://localhost:\(port)/json")!
    let task = URLSession.shared.dataTask(with: targetURL) { data, response, error in
        guard let data = data,
              let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                        let errorDescription = error?.localizedDescription ?? "unknown"
                        logger.error("Failed to fetch DevTools targets from localhost:\(port)/json: \(errorDescription)")
            return
        }

        // Find matching target by URL, falling back to first page target.
        let matchingTarget = targets.first(where: { target in
            guard let type = target["type"] as? String, type == "page" else { return false }
            guard let url = target["url"] as? String else { return false }
            return url == currentURL
        }) ?? targets.first(where: { $0["type"] as? String == "page" })

        guard let target = matchingTarget,
              let targetId = target["id"] as? String else {
            logger.error("No matching DevTools target found for URL: \(currentURL)")
            return
        }

        // CEF's devtoolsFrontendUrl uses a devtools:// scheme that cannot be
        // loaded in a regular pane, so build the HTTP inspector URL directly.
        let devToolsURL = URL(string: "http://localhost:\(port)/devtools/inspector.html?ws=localhost:\(port)/devtools/page/\(targetId)")!

        DispatchQueue.main.async {
            guard let viewModel = browserModel?.viewModel else { return }
            // Use WebKit for DevTools; CEF drops the websocket when the
            // frontend itself runs inside CEF.
            let devToolsPane = viewModel.addBrowser(url: devToolsURL, engine: .webkit)
            viewModel.focusPane(devToolsPane)
        }
    }
    task.resume()
}

// MARK: - CEFClientContext

/// Minimal per-browser state accessible from CEF C callbacks.
class CEFClientContext {
    weak var browserModel: BrowserPaneModel?
    weak var browserView: ChromiumBrowserView?

    /// The CEF browser object, retained. Set in on_after_created.
    var cefBrowser: UnsafeMutablePointer<cef_browser_t>?

    /// The client struct pointer (we own it via ref count)
    var client: UnsafeMutablePointer<cef_client_t>?
    var lifeSpanHandler: UnsafeMutablePointer<cef_life_span_handler_t>?

    var loadHandler: UnsafeMutablePointer<cef_load_handler_t>?
    var displayHandler: UnsafeMutablePointer<cef_display_handler_t>?
    var downloadHandler: UnsafeMutablePointer<cef_download_handler_t>?
    var focusHandler: UnsafeMutablePointer<cef_focus_handler_t>?
    var contextMenuHandler: UnsafeMutablePointer<cef_context_menu_handler_t>?
    var progressTimer: Timer?

    /// DevTools message observer for Runtime.bindingCalled (form interaction JS→native).
    var devToolsObserver: UnsafeMutablePointer<cef_dev_tools_message_observer_t>?
    /// Registration returned by add_dev_tools_message_observer. Release to unregister.
    var devToolsRegistration: UnsafeMutablePointer<cef_registration_t>?

    /// Guards against scheduling the async close block more than once from do_close.
    /// close_browser(force=1) re-triggers do_close; we must only act on the first call.
    var didScheduleForceClose: Bool = false

    init(browserModel: BrowserPaneModel, browserView: ChromiumBrowserView) {
        self.browserModel = browserModel
        self.browserView = browserView
    }

    deinit {
        // Do NOT call release() on any C handler structs here.
        //
        // These structs were created with cefCreate() (refcount=1) and passed
        // to CEF, which add_ref's them internally. CEF's CrBrowserMain thread
        // continues to hold refs to these structs for an indeterminate period
        // after on_before_close fires — there is no safe moment to call release()
        // from our side without risking a use-after-free on CEF's side.
        //
        // The structs are intentionally leaked. Each browser pane creates ~8-10
        // small structs (total ~2-4 KB). This is an acceptable tradeoff for a
        // GUI app where browser panes are not created/destroyed thousands of times.
        //
        // The cef_browser_t ref (cefBrowser) is released in on_before_close
        // before deinit runs, so it is always nil here and does not leak.
        //
        // devToolsRegistration is released in cefCleanupClientContext at 250ms
        // after on_before_close, which unregisters the observer before deinit.
        NSLog("[CEF] CEFClientContext.deinit: intentionally skipping handler struct release to avoid use-after-free")
    }
}

// MARK: - Client Context Registry

private var contextRegistry: [UnsafeMutableRawPointer: CEFClientContext] = [:]

func cefRegisterContext(_ context: CEFClientContext, forClient client: UnsafeMutablePointer<cef_client_t>) {
    contextRegistry[UnsafeMutableRawPointer(client)] = context
}

func cefUnregisterContext(forClient client: UnsafeMutablePointer<cef_client_t>) {
    contextRegistry.removeValue(forKey: UnsafeMutableRawPointer(client))
}

private var handlerToContext: [UnsafeMutableRawPointer: CEFClientContext] = [:]

func cefRegisterHandler(_ ptr: UnsafeMutableRawPointer, context: CEFClientContext) {
    handlerToContext[ptr] = context
}

func cefUnregisterHandler(_ ptr: UnsafeMutableRawPointer) {
    handlerToContext.removeValue(forKey: ptr)
}

func cefContextForHandler(_ ptr: UnsafeMutableRawPointer) -> CEFClientContext? {
    return handlerToContext[ptr]
}

// MARK: - Factory: Create cef_client_t (MINIMAL)

/// Create a `cef_client_t` with life span, load, and display handlers.
func cefMakeClient(context: CEFClientContext) -> UnsafeMutablePointer<cef_client_t> {
    let client: UnsafeMutablePointer<cef_client_t> = cefCreate()
    context.client = client

    let lsh = cefMakeLifeSpanHandler(context: context)
    context.lifeSpanHandler = lsh

    let lh = cefMakeLoadHandler(context: context)
    context.loadHandler = lh

    let dh = cefMakeDisplayHandler(context: context)
    context.displayHandler = dh

    let dlh = cefMakeDownloadHandler(context: context)
    context.downloadHandler = dlh

    let fh = cefMakeFocusHandler(context: context)
    context.focusHandler = fh

    let cmh = cefMakeContextMenuHandler(context: context)
    context.contextMenuHandler = cmh

    cefRegisterContext(context, forClient: client)
    cefRegisterHandler(UnsafeMutableRawPointer(lsh), context: context)
    cefRegisterHandler(UnsafeMutableRawPointer(lh), context: context)
    cefRegisterHandler(UnsafeMutableRawPointer(dh), context: context)
    cefRegisterHandler(UnsafeMutableRawPointer(dlh), context: context)
    cefRegisterHandler(UnsafeMutableRawPointer(fh), context: context)
    cefRegisterHandler(UnsafeMutableRawPointer(cmh), context: context)

    client.pointee.get_life_span_handler = { (selfPtr) -> UnsafeMutablePointer<cef_life_span_handler_t>? in
        guard let selfPtr = selfPtr else { return nil }
        guard let ctx = contextRegistry[UnsafeMutableRawPointer(selfPtr)] else { return nil }
        guard let handler = ctx.lifeSpanHandler else { return nil }
        handler.pointee.base.add_ref?(&handler.pointee.base)
        return handler
    }

    client.pointee.get_load_handler = { (selfPtr) -> UnsafeMutablePointer<cef_load_handler_t>? in
        guard let selfPtr = selfPtr else { return nil }
        guard let ctx = contextRegistry[UnsafeMutableRawPointer(selfPtr)] else { return nil }
        guard let handler = ctx.loadHandler else { return nil }
        handler.pointee.base.add_ref?(&handler.pointee.base)
        return handler
    }

    client.pointee.get_display_handler = { (selfPtr) -> UnsafeMutablePointer<cef_display_handler_t>? in
        guard let selfPtr = selfPtr else { return nil }
        guard let ctx = contextRegistry[UnsafeMutableRawPointer(selfPtr)] else { return nil }
        guard let handler = ctx.displayHandler else { return nil }
        handler.pointee.base.add_ref?(&handler.pointee.base)
        return handler
    }

    client.pointee.get_download_handler = { (selfPtr) -> UnsafeMutablePointer<cef_download_handler_t>? in
        guard let selfPtr = selfPtr else { return nil }
        guard let ctx = contextRegistry[UnsafeMutableRawPointer(selfPtr)] else { return nil }
        guard let handler = ctx.downloadHandler else { return nil }
        handler.pointee.base.add_ref?(&handler.pointee.base)
        return handler
    }

    client.pointee.get_focus_handler = { (selfPtr) -> UnsafeMutablePointer<cef_focus_handler_t>? in
        guard let selfPtr = selfPtr else { return nil }
        guard let ctx = contextRegistry[UnsafeMutableRawPointer(selfPtr)] else { return nil }
        guard let handler = ctx.focusHandler else { return nil }
        handler.pointee.base.add_ref?(&handler.pointee.base)
        return handler
    }

    client.pointee.get_context_menu_handler = { (selfPtr) -> UnsafeMutablePointer<cef_context_menu_handler_t>? in
        guard let selfPtr = selfPtr else { return nil }
        guard let ctx = contextRegistry[UnsafeMutableRawPointer(selfPtr)] else { return nil }
        guard let handler = ctx.contextMenuHandler else { return nil }
        handler.pointee.base.add_ref?(&handler.pointee.base)
        return handler
    }

    return client
}

// MARK: - Factory: cef_life_span_handler_t (MINIMAL)

private func cefMakeLifeSpanHandler(context: CEFClientContext) -> UnsafeMutablePointer<cef_life_span_handler_t> {
    let handler: UnsafeMutablePointer<cef_life_span_handler_t> = cefCreate()

    // on_after_created: store the browser reference, set up DevTools observer
    handler.pointee.on_after_created = { (selfPtr, browser) in
        NSLog("[CEF] on_after_created called")
        guard let selfPtr = selfPtr else { return }
        guard let ctx = cefContextForHandler(UnsafeMutableRawPointer(selfPtr)) else {
            NSLog("[CEF] on_after_created: no context for handler")
            return
        }
        guard let browser = browser else { return }

        // Retain the browser reference
        browser.pointee.base.add_ref?(&browser.pointee.base)
        ctx.cefBrowser = browser

        // Track active browser count — starts the message pump if needed
        ChromiumManager.shared.browserOpened()

        // Register DevTools message observer for Runtime.bindingCalled events
        cefSetupDevToolsObserver(context: ctx, browser: browser)

        // Store the browser on the view and load the pending URL
        DispatchQueue.main.async {
            ctx.browserView?.cefBrowser = browser
            ctx.browserView?.loadPendingURLIfNeeded()
        }
    }

    handler.pointee.do_close = { (selfPtr, browser) -> Int32 in
        NSLog("[CEF] do_close called (isMain=%d)", Thread.isMainThread ? 1 : 0)

        // We return TRUE (1) here to tell CEF "the app handles the close".
        // CEF will NOT send performClose: to the NSWindow — instead it waits
        // for us to call close_browser(force=1) to finish. But we don't want
        // that either; what we actually want is for SwiftUI to tear down the
        // view hierarchy (by removing the pane from the array), which causes
        // CEF to detect its CefBrowserHostView is gone and fire on_before_close.
        //
        // So the sequence is:
        //   1. do_close fires → we dispatch finishRemovingCEFPane on main queue
        //      and return TRUE (1) to suppress performClose: on the NSWindow.
        //   2. finishRemovingCEFPane removes the pane from the SwiftUI array.
        //   3. SwiftUI tears down the view → dismantleNSView runs.
        //   4. CEF detects its CefBrowserHostView is gone → fires on_before_close.
        //   5. on_before_close calls browserClosed() → pump stops when count=0.

        guard let selfPtr = selfPtr,
              let ctx = cefContextForHandler(UnsafeMutableRawPointer(selfPtr)) else {
            NSLog("[CEF] do_close: no context — returning true to suppress window close")
            return 1
        }

        // Guard: do_close may fire more than once (force=1 re-triggers it).
        // Only act on the first call.
        guard !ctx.didScheduleForceClose else {
            NSLog("[CEF] do_close: already scheduled — skipping (loop guard)")
            return 1
        }
        ctx.didScheduleForceClose = true

        // CEF fires on_before_close only when BOTH conditions are true:
        //   1. close_browser has been called (any force value)
        //   2. The NSView is removed from its parent window (dismantleNSView)
        //
        // We satisfy both by calling close_browser(force=1) and then
        // finishRemovingCEFPane in the same async block. finishRemovingCEFPane
        // removes the pane from SwiftUI's array, which triggers dismantleNSView.
        // dismantleNSView sees isClosingCEF=true and skips its own force-close.
        // CEF detects the view removal and fires on_before_close.
        if let paneId = ctx.browserModel?.id,
           let vm = ctx.browserModel?.viewModel,
           let browser = browser {
            browser.pointee.base.add_ref?(&browser.pointee.base)
            NSLog("[CEF] do_close: dispatching force=1 + finishRemovingCEFPane for pane %@", paneId.uuidString)
            DispatchQueue.main.async {
                NSLog("[CEF] do_close [async]: calling close_browser(force=1) for %@", paneId.uuidString)
                if let host = browser.pointee.get_host?(browser) {
                    host.pointee.close_browser?(host, 1)
                    _ = host.pointee.base.release?(&host.pointee.base)
                }
                _ = browser.pointee.base.release?(&browser.pointee.base)
                NSLog("[CEF] do_close [async]: calling finishRemovingCEFPane for %@", paneId.uuidString)
                vm.finishRemovingCEFPane(byId: paneId)
            }
        }

        return 1 // suppress performClose: on the NSWindow
    }

    handler.pointee.on_before_close = { (selfPtr, browser) in
        NSLog("[CEF] on_before_close called (isMain=%d)", Thread.isMainThread ? 1 : 0)
        guard let selfPtr = selfPtr else { return }
        guard let ctx = cefContextForHandler(UnsafeMutableRawPointer(selfPtr)) else {
            NSLog("[CEF] on_before_close: no context found for handler!")
            return
        }

        let paneId = ctx.browserModel?.id
        let isClosingCEF = ctx.browserModel?.isClosingCEF ?? false
        NSLog("[CEF] on_before_close: paneId=%@, isClosingCEF=%d, cefBrowser=%@",
              paneId?.uuidString ?? "nil", isClosingCEF ? 1 : 0,
              String(describing: ctx.cefBrowser))

        if let b = ctx.cefBrowser {
            NSLog("[CEF] on_before_close: releasing ctx.cefBrowser")
            b.pointee.base.release?(&b.pointee.base)
            ctx.cefBrowser = nil
        }

        // Track active browser count — starts a grace period before the
        // message pump is stopped, giving CEF's CrBrowserMain thread time
        // to finish internal cleanup.
        NSLog("[CEF] on_before_close: calling browserClosed()")
        ChromiumManager.shared.browserClosed()

        // Delay the view teardown to give CEF's CrBrowserMain thread time
        // to finish its internal cleanup AFTER on_before_close returns.
        // Without this delay, removing the pane from the array triggers
        // SwiftUI to call dismantleNSView immediately, which tears down
        // the NSView hierarchy while CrBrowserMain is still accessing it,
        // causing EXC_BREAKPOINT.
        // Defer ALL cleanup to give CEF's CrBrowserMain thread time to
        // finish its internal cleanup AFTER on_before_close returns.
        // Previously cefCleanupClientContext ran immediately here, but
        // CrBrowserMain was still accessing the handler objects, causing
        // EXC_BREAKPOINT.
        NSLog("[CEF] on_before_close: scheduling 250ms delayed cleanup + cefBrowserDidClose notification")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSLog("[CLOSE-DEBUG] on_before_close [delayed]: ENTERED 250ms block, paneId=%@, browserView=%@",
                  paneId?.uuidString ?? "nil",
                  ctx.browserView.map { String(describing: $0) } ?? "nil")
            ctx.browserView?.cefBrowser = nil

            // Clean up the context registry. Deferred to here (not immediately
            // in on_before_close) because CrBrowserMain continues accessing
            // handler objects after on_before_close returns.
            NSLog("[CLOSE-DEBUG] on_before_close [delayed]: calling cefCleanupClientContext")
            cefCleanupClientContext(ctx)

            // CEF is fully done with this browser. Post a notification so
            // the view model can now safely remove the pane from the array
            // (which will tear down the SwiftUI view and the NSView).
            if let paneId = paneId {
                NSLog("[CLOSE-DEBUG] on_before_close [delayed]: about to post cefBrowserDidClose for pane %@", paneId.uuidString)
                NotificationCenter.default.post(
                    name: .cefBrowserDidClose,
                    object: nil,
                    userInfo: ["paneId": paneId]
                )
                NSLog("[CLOSE-DEBUG] on_before_close [delayed]: posted cefBrowserDidClose for pane %@", paneId.uuidString)
            } else {
                NSLog("[CLOSE-DEBUG] on_before_close [delayed]: paneId is nil, NOT posting notification")
            }
        }
        NSLog("[CEF] on_before_close: done (cleanup deferred to 250ms block)")
    }

    return handler
}

// MARK: - Factory: cef_load_handler_t

private func cefMakeLoadHandler(context: CEFClientContext) -> UnsafeMutablePointer<cef_load_handler_t> {
    let handler: UnsafeMutablePointer<cef_load_handler_t> = cefCreate()

    // on_loading_state_change: update isLoading, canGoBack, canGoForward
    handler.pointee.on_loading_state_change = { (selfPtr, browser, isLoading, canGoBack, canGoForward) in
        guard let selfPtr = selfPtr else { return }
        guard let ctx = cefContextForHandler(UnsafeMutableRawPointer(selfPtr)) else { return }
        DispatchQueue.main.async {
            ctx.browserModel?.isLoading = isLoading != 0
            ctx.browserModel?.canGoBack = canGoBack != 0
            ctx.browserModel?.canGoForward = canGoForward != 0
        }
    }

    // on_load_start: main frame only — set initial progress, reset form interaction, clear status code, start progress timer
    handler.pointee.on_load_start = { (selfPtr, browser, frame, transitionType) in
        guard let selfPtr = selfPtr else { return }
        guard let ctx = cefContextForHandler(UnsafeMutableRawPointer(selfPtr)) else { return }

        // Only handle main frame loads
        guard let frame = frame else { return }
        let isMain = frame.pointee.is_main?(frame) ?? 0
        guard isMain != 0 else { return }

        DispatchQueue.main.async {
            ctx.browserModel?.estimatedProgress = 0.1
            ctx.browserModel?.hasInteractedForms = false
            ctx.browserModel?.httpStatusCode = nil

            // Start progress estimation timer
            ctx.progressTimer?.invalidate()
            ctx.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak ctx] _ in
                guard let ctx = ctx, let model = ctx.browserModel else { return }
                if model.estimatedProgress < 0.9 {
                    model.estimatedProgress = min(model.estimatedProgress + 0.1, 0.9)
                }
            }
        }
    }

    // on_load_end: main frame only — set progress to 1.0, stop timer, capture HTTP status, record history, inject form detection JS
    handler.pointee.on_load_end = { (selfPtr, browser, frame, httpStatusCode) in
        guard let selfPtr = selfPtr else { return }
        guard let ctx = cefContextForHandler(UnsafeMutableRawPointer(selfPtr)) else { return }

        // Only handle main frame loads
        guard let frame = frame else { return }
        let isMain = frame.pointee.is_main?(frame) ?? 0
        guard isMain != 0 else { return }

        // Get the URL from the frame
        let frameUrl = cefStringUserfreeToSwift(frame.pointee.get_url?(frame))

        // Inject form interaction detection JavaScript.
        cefInjectFormDetectionJS(frame: frame)

        DispatchQueue.main.async {
            ctx.progressTimer?.invalidate()
            ctx.progressTimer = nil
            ctx.browserModel?.estimatedProgress = 1.0
            ctx.browserModel?.isLoading = false
            ctx.browserModel?.httpStatusCode = Int(httpStatusCode)

            // Record the visit to history (mirrors WebKit's didFinish behavior)
            if let model = ctx.browserModel, !frameUrl.isEmpty, let url = URL(string: frameUrl) {
                model.url = url
                let cleanURL = HistoryStore.stripQueryString(from: url).absoluteString
                if cleanURL != "about:blank" && cleanURL != model.lastRecordedURL {
                    model.lastRecordedURL = cleanURL
                    let source = model.navigationSource
                    model.navigationSource = "navigation"
                    HistoryStore.shared.recordVisit(
                        url: url,
                        title: model.pageTitle.isEmpty || model.pageTitle == "New Tab" ? nil : model.pageTitle,
                        source: source
                    )
                }
            }
        }
    }

    // on_load_error: main frame only — mark as failed
    // Skip ERR_ABORTED (-3) which fires when navigation is cancelled by a new load
    handler.pointee.on_load_error = { (selfPtr, browser, frame, errorCode, errorString, failedUrl) in
        guard let selfPtr = selfPtr else { return }
        guard let ctx = cefContextForHandler(UnsafeMutableRawPointer(selfPtr)) else { return }

        // Only handle main frame errors
        guard let frame = frame else { return }
        let isMain = frame.pointee.is_main?(frame) ?? 0
        guard isMain != 0 else { return }

        // ERR_ABORTED fires when a navigation is cancelled by a new load — not a real error
        guard errorCode.rawValue != -3 else { return }

        let errorStr = cefStringToSwift(errorString)
        let failedUrlStr = cefStringToSwift(failedUrl)
        NSLog("[CEF] on_load_error: code=\(errorCode.rawValue) error=\(errorStr) url=\(failedUrlStr)")

        DispatchQueue.main.async {
            ctx.progressTimer?.invalidate()
            ctx.progressTimer = nil
            ctx.browserModel?.isLoading = false
            ctx.browserModel?.httpStatusCode = 0
            ctx.browserModel?.estimatedProgress = 0.0
        }
    }

    return handler
}

// MARK: - Factory: cef_display_handler_t

private func cefMakeDisplayHandler(context: CEFClientContext) -> UnsafeMutablePointer<cef_display_handler_t> {
    let handler: UnsafeMutablePointer<cef_display_handler_t> = cefCreate()

    // on_title_change: update the page title
    handler.pointee.on_title_change = { (selfPtr, browser, title) in
        guard let selfPtr = selfPtr else { return }
        guard let ctx = cefContextForHandler(UnsafeMutableRawPointer(selfPtr)) else { return }
        let titleStr = cefStringToSwift(title)
        DispatchQueue.main.async {
            if !titleStr.isEmpty {
                ctx.browserModel?.pageTitle = titleStr
            }
        }
    }

    // on_address_change: update the URL (main frame only)
    handler.pointee.on_address_change = { (selfPtr, browser, frame, url) in
        guard let selfPtr = selfPtr else { return }
        guard let ctx = cefContextForHandler(UnsafeMutableRawPointer(selfPtr)) else { return }

        // Only handle main frame URL changes
        guard let frame = frame else { return }
        let isMain = frame.pointee.is_main?(frame) ?? 0
        guard isMain != 0 else { return }

        let urlStr = cefStringToSwift(url)
        DispatchQueue.main.async {
            if let newURL = URL(string: urlStr) {
                ctx.browserModel?.url = newURL
            }
        }
    }

    return handler
}

// MARK: - Factory: cef_download_handler_t

private func cefMakeDownloadHandler(context: CEFClientContext) -> UnsafeMutablePointer<cef_download_handler_t> {
    let handler: UnsafeMutablePointer<cef_download_handler_t> = cefCreate()

    // can_download: allow all downloads
    handler.pointee.can_download = { (selfPtr, browser, url, requestMethod) -> Int32 in
        return 1 // allow
    }

    // on_before_download: show NSSavePanel, then call callback.cont with the chosen path
    handler.pointee.on_before_download = { (selfPtr, browser, downloadItem, suggestedName, callback) -> Int32 in
        guard let selfPtr = selfPtr else { return 0 }
        guard let callback = callback else { return 0 }

        let suggestedFileName = cefStringToSwift(suggestedName)
        let downloadUrl = cefStringUserfreeToSwift(downloadItem?.pointee.get_url?(downloadItem!))

        NSLog("[CEF] on_before_download: suggestedName=\(suggestedFileName) url=\(downloadUrl)")

        // Retain the callback so it survives until the save panel completes
        callback.pointee.base.add_ref?(&callback.pointee.base)

        DispatchQueue.main.async {
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = suggestedFileName
            savePanel.canCreateDirectories = true

            savePanel.begin { result in
                if result == .OK, let url = savePanel.url {
                    NSLog("[CEF] Download: user chose \(url.path)")
                    // Remove existing file if present — CEF may or may not
                    // handle this, but matching WebKit's behavior is safest.
                    try? FileManager.default.removeItem(at: url)

                    withCEFString(url.path) { cefPath in
                        callback.pointee.cont?(callback, &cefPath, 0)
                    }
                } else {
                    NSLog("[CEF] Download: user cancelled save panel")
                    // Pass empty path to cancel the download
                    withCEFString("") { emptyPath in
                        callback.pointee.cont?(callback, &emptyPath, 0)
                    }
                }
                // Release our retained reference to the callback
                _ = callback.pointee.base.release?(&callback.pointee.base)
            }
        }

        return 1 // we handle the callback
    }

    // on_download_updated: log progress, no UI for now (matches WebKit's simple approach)
    handler.pointee.on_download_updated = { (selfPtr, browser, downloadItem, callback) in
        guard let downloadItem = downloadItem else { return }

        let isComplete = downloadItem.pointee.is_complete?(downloadItem) ?? 0
        let isCanceled = downloadItem.pointee.is_canceled?(downloadItem) ?? 0
        let isInterrupted = downloadItem.pointee.is_interrupted?(downloadItem) ?? 0

        if isComplete != 0 {
            let fullPath = cefStringUserfreeToSwift(downloadItem.pointee.get_full_path?(downloadItem))
            NSLog("[CEF] Download finished: \(fullPath)")
        } else if isCanceled != 0 {
            NSLog("[CEF] Download cancelled")
        } else if isInterrupted != 0 {
            let reason = downloadItem.pointee.get_interrupt_reason?(downloadItem)
            NSLog("[CEF] Download interrupted: reason=\(reason?.rawValue ?? 0)")
        }
    }

    return handler
}

// MARK: - Factory: cef_focus_handler_t

private func cefMakeFocusHandler(context: CEFClientContext) -> UnsafeMutablePointer<cef_focus_handler_t> {
    let handler: UnsafeMutablePointer<cef_focus_handler_t> = cefCreate()

    // on_take_focus: CEF is giving up focus (e.g. Tab from last element).
    // No action needed — the next responder will handle it.
    handler.pointee.on_take_focus = { (selfPtr, browser, next) in
    }

    // on_set_focus: CEF is requesting focus. Return 0 to allow, 1 to cancel.
    // Only allow when our ChromiumBrowserView has intentionally granted CEF
    // focus (cefHasFocus == true). This prevents CEF from stealing focus
    // back after we've moved it to another pane or the command palette.
    handler.pointee.on_set_focus = { (selfPtr, browser, source) -> Int32 in
        guard let selfPtr = selfPtr else { return 1 }
        guard let ctx = cefContextForHandler(UnsafeMutableRawPointer(selfPtr)) else { return 1 }
        guard let browserModel = ctx.browserModel,
              let vm = browserModel.viewModel else {
            return 1
        }
        let isContextual = vm.contextualPane?.id == browserModel.id
        let isPending = vm.pendingFocus?.paneId == browserModel.id
        let allowed = ctx.browserView?.cefHasFocus == true && (isContextual || isPending)
        return allowed ? 0 : 1
    }

    // on_got_focus: CEF has received focus. Only propagate to the view model
    // when our ChromiumBrowserView intentionally granted focus. This prevents
    // CEF from reclaiming app-level focus after we've moved it elsewhere.
    //
    // IMPORTANT: The cefHasFocus guard MUST be inside the DispatchQueue.main.async
    // block because on_got_focus is called from CEF's thread. The KVO observer
    // on window.firstResponder may clear cefHasFocus on the main thread between
    // the time this callback fires and the time the async block executes.
    handler.pointee.on_got_focus = { (selfPtr, browser) in
        guard let selfPtr = selfPtr else { return }
        guard let ctx = cefContextForHandler(UnsafeMutableRawPointer(selfPtr)) else { return }
        DispatchQueue.main.async {
            // Re-check cefHasFocus on the main thread. If the KVO observer
            // already cleared it (focus moved to another pane), bail out.
            guard ctx.browserView?.cefHasFocus == true else {
                return
            }
            guard let browserModel = ctx.browserModel else { return }
            guard let vm = browserModel.viewModel else { return }
            let isContextual = vm.contextualPane?.id == browserModel.id
            let isPending = vm.pendingFocus?.paneId == browserModel.id
            guard isContextual || isPending else { return }
            browserModel.isFocused = true

            // Notify the view model so focusModePaneId is updated and
            // other panes' isFocused flags are cleared.
            if vm.focusModePaneId != browserModel.id || vm.contextualPane?.id != browserModel.id {
                vm.focusPane(id: browserModel.id)
            }

        }
    }

    return handler
}

// MARK: - Factory: cef_context_menu_handler_t

/// Custom command ID for the "Inspect Element" menu item.
private let kMenuIdInspectElement: Int32 = 26500  // MENU_ID_USER_FIRST

private func cefMakeContextMenuHandler(context: CEFClientContext) -> UnsafeMutablePointer<cef_context_menu_handler_t> {
    let handler: UnsafeMutablePointer<cef_context_menu_handler_t> = cefCreate()

    // on_before_context_menu: append "Inspect Element" to the default menu
    handler.pointee.on_before_context_menu = { (selfPtr, browser, frame, params, model) in
        guard let model = model else { return }
        model.pointee.add_separator?(model)
        withCEFString("Inspect Element") { label in
            model.pointee.add_item?(model, kMenuIdInspectElement, &label)
        }
    }

    // on_context_menu_command: open DevTools when "Inspect Element" is selected
    handler.pointee.on_context_menu_command = { (selfPtr, browser, frame, params, commandId, eventFlags) -> Int32 in
        guard commandId == kMenuIdInspectElement else { return 0 }
        guard let browser = browser else { return 0 }
        guard let selfPtr = selfPtr else { return 0 }
        guard let context = cefContextForHandler(UnsafeMutableRawPointer(selfPtr)) else { return 0 }

        var point = cef_point_t(x: 0, y: 0)
        if let params = params {
            point.x = Int32(params.pointee.get_xcoord?(params) ?? 0)
            point.y = Int32(params.pointee.get_ycoord?(params) ?? 0)
        }
        cefOpenDevTools(for: browser, browserModel: context.browserModel, inspectPoint: point)

        return 1
    }

    return handler
}

// MARK: - DevTools Observer Setup (Form Interaction JS→Native)

/// Create and register a DevTools message observer that listens for
/// `Runtime.bindingCalled` events from the `watchtowerFormInteraction` binding.
/// Also calls `Runtime.addBinding` to register the binding in the page.
///
/// Called from `on_after_created` once the browser is available.
func cefSetupDevToolsObserver(context: CEFClientContext, browser: UnsafeMutablePointer<cef_browser_t>) {
    guard let host = browser.pointee.get_host?(browser) else {
        NSLog("[CEF] cefSetupDevToolsObserver: could not get browser host")
        return
    }
    defer { _ = host.pointee.base.release?(&host.pointee.base) }

    // 1. Create the observer struct
    let observer: UnsafeMutablePointer<cef_dev_tools_message_observer_t> = cefCreate()
    cefRegisterHandler(UnsafeMutableRawPointer(observer), context: context)

    // on_dev_tools_message: return 0 to let events flow to on_dev_tools_event
    observer.pointee.on_dev_tools_message = { (selfPtr, browser, message, messageSize) -> Int32 in
        return 0
    }

    // on_dev_tools_method_result: no-op
    observer.pointee.on_dev_tools_method_result = { (selfPtr, browser, messageId, success, result, resultSize) in
    }

    // on_dev_tools_event: check for Runtime.bindingCalled with our binding name
    observer.pointee.on_dev_tools_event = { (selfPtr, browser, method, params, paramsSize) in
        guard let selfPtr = selfPtr else { return }
        guard let method = method else { return }

        let methodStr = cefStringToSwift(method)
        guard methodStr == "Runtime.bindingCalled" else { return }

        // Parse the UTF-8 JSON params to find binding name
        guard let params = params, paramsSize > 0 else { return }
        let data = Data(bytes: params, count: paramsSize)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bindingName = json["name"] as? String,
              bindingName == "watchtowerFormInteraction" else { return }

        NSLog("[CEF] Runtime.bindingCalled: watchtowerFormInteraction")

        guard let ctx = cefContextForHandler(UnsafeMutableRawPointer(selfPtr)) else { return }
        DispatchQueue.main.async {
            ctx.browserModel?.hasInteractedForms = true
        }
    }

    // on_dev_tools_agent_attached / detached: no-op
    observer.pointee.on_dev_tools_agent_attached = { (selfPtr, browser) in
        NSLog("[CEF] DevTools agent attached")
    }
    observer.pointee.on_dev_tools_agent_detached = { (selfPtr, browser) in
        NSLog("[CEF] DevTools agent detached")
    }

    // 2. Register the observer — returns a cef_registration_t* (hold to keep alive)
    let registration = host.pointee.add_dev_tools_message_observer?(host, observer)
    context.devToolsObserver = observer
    context.devToolsRegistration = registration

    // 3. Call Runtime.addBinding to register the JS function via raw JSON
    //    (Using send_dev_tools_message instead of execute_dev_tools_method
    //     to avoid crashes from nested cef_dictionary_value_t construction)
    let json = """
    {"id":2,"method":"Runtime.addBinding","params":{"name":"watchtowerFormInteraction"}}
    """
    let jsonData = Array(json.utf8)
    let result = jsonData.withUnsafeBufferPointer { buf -> Int32 in
        guard let base = buf.baseAddress else { return 0 }
        return host.pointee.send_dev_tools_message?(host, base, jsonData.count) ?? 0
    }

    NSLog("[CEF] DevTools observer registered, Runtime.addBinding send_dev_tools_message returned \(result)")
}

// MARK: - Form Detection JS Injection

/// Inject form interaction detection JavaScript into a frame.
/// Uses the `watchtowerFormInteraction` binding registered via `Runtime.addBinding`
/// in `cefSetupDevToolsObserver`. The injected script listens for input/textarea/select
/// events and calls the binding, which fires a `Runtime.bindingCalled` DevTools event
/// caught by our observer.
///
/// Called from `on_load_end` for main frame loads.
func cefInjectFormDetectionJS(frame: UnsafeMutablePointer<cef_frame_t>) {
    let script = """
    (function() {
        var changed = false;
        document.addEventListener('input', function(e) {
            if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.tagName === 'SELECT') {
                if (!changed) {
                    changed = true;
                    watchtowerFormInteraction('formInteraction');
                }
            }
        }, true);
        window.addEventListener('beforeunload', function() { changed = false; });
    })();
    """

    withCEFString(script) { cefScript in
        withCEFString("") { scriptUrl in
            frame.pointee.execute_java_script?(frame, &cefScript, &scriptUrl, 0)
        }
    }
}

// MARK: - Cleanup

func cefCleanupClientContext(_ context: CEFClientContext) {
    // Unregister from our Swift lookup dictionaries so no further callbacks
    // can reach this context.
    if let client = context.client {
        cefUnregisterContext(forClient: client)
    }
    if let lsh = context.lifeSpanHandler {
        cefUnregisterHandler(UnsafeMutableRawPointer(lsh))
    }
    if let lh = context.loadHandler {
        cefUnregisterHandler(UnsafeMutableRawPointer(lh))
    }
    if let dh = context.displayHandler {
        cefUnregisterHandler(UnsafeMutableRawPointer(dh))
    }
    if let dlh = context.downloadHandler {
        cefUnregisterHandler(UnsafeMutableRawPointer(dlh))
    }
    if let fh = context.focusHandler {
        cefUnregisterHandler(UnsafeMutableRawPointer(fh))
    }
    if let obs = context.devToolsObserver {
        cefUnregisterHandler(UnsafeMutableRawPointer(obs))
    }

    // Release the DevTools registration. This unregisters the observer from CEF
    // and is safe to do after on_before_close + 250ms grace period. The
    // registration object is separate from the observer and is our ref to hold.
    // Note: do NOT release the observer itself here — CEF holds its own refs
    // to it and will release them internally. See deinit comments.
    if let reg = context.devToolsRegistration {
        _ = reg.pointee.base.release?(&reg.pointee.base)
        context.devToolsRegistration = nil
    }
}
