import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "com.watchtower", category: "CEFClientHandlers")

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
    var progressTimer: Timer?

    /// DevTools message observer for Runtime.bindingCalled (form interaction JS→native).
    var devToolsObserver: UnsafeMutablePointer<cef_dev_tools_message_observer_t>?
    /// Registration returned by add_dev_tools_message_observer. Release to unregister.
    var devToolsRegistration: UnsafeMutablePointer<cef_registration_t>?

    init(browserModel: BrowserPaneModel, browserView: ChromiumBrowserView) {
        self.browserModel = browserModel
        self.browserView = browserView
    }

    deinit {
        if let client = client {
            _ = client.pointee.base.release?(&client.pointee.base)
        }
        if let lsh = lifeSpanHandler {
            _ = lsh.pointee.base.release?(&lsh.pointee.base)
        }
        if let lh = loadHandler {
            _ = lh.pointee.base.release?(&lh.pointee.base)
        }
        if let dh = displayHandler {
            _ = dh.pointee.base.release?(&dh.pointee.base)
        }
        if let dlh = downloadHandler {
            _ = dlh.pointee.base.release?(&dlh.pointee.base)
        }
        if let fh = focusHandler {
            _ = fh.pointee.base.release?(&fh.pointee.base)
        }
        // Release DevTools registration first (unregisters observer), then the observer itself
        if let reg = devToolsRegistration {
            _ = reg.pointee.base.release?(&reg.pointee.base)
        }
        if let obs = devToolsObserver {
            _ = obs.pointee.base.release?(&obs.pointee.base)
        }
        if let browser = cefBrowser {
            _ = browser.pointee.base.release?(&browser.pointee.base)
        }
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

    cefRegisterContext(context, forClient: client)
    cefRegisterHandler(UnsafeMutableRawPointer(lsh), context: context)
    cefRegisterHandler(UnsafeMutableRawPointer(lh), context: context)
    cefRegisterHandler(UnsafeMutableRawPointer(dh), context: context)
    cefRegisterHandler(UnsafeMutableRawPointer(dlh), context: context)
    cefRegisterHandler(UnsafeMutableRawPointer(fh), context: context)

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

        // Register DevTools message observer for Runtime.bindingCalled events
        cefSetupDevToolsObserver(context: ctx, browser: browser)

        // Store the browser on the view and load the pending URL
        DispatchQueue.main.async {
            ctx.browserView?.cefBrowser = browser
            ctx.browserView?.loadPendingURLIfNeeded()
        }
    }

    handler.pointee.do_close = { (selfPtr, browser) -> Int32 in
        return 0 // allow close
    }

    handler.pointee.on_before_close = { (selfPtr, browser) in
        guard let selfPtr = selfPtr else { return }
        guard let ctx = cefContextForHandler(UnsafeMutableRawPointer(selfPtr)) else { return }

        if let b = ctx.cefBrowser {
            b.pointee.base.release?(&b.pointee.base)
            ctx.cefBrowser = nil
        }
        DispatchQueue.main.async {
            ctx.browserView?.cefBrowser = nil
        }
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
        let allowed = ctx.browserView?.cefHasFocus == true
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
            browserModel.isFocused = true

            // Notify the view model so focusModePaneId is updated and
            // other panes' isFocused flags are cleared.
            if let vm = browserModel.viewModel {
                if vm.focusModePaneId != browserModel.id || vm.contextualPane?.id != browserModel.id {
                    vm.focusPane(id: browserModel.id)
                }
            }

            // Scroll the pane into view
            ctx.browserView?.scrollToVisibleInEnclosingScrollView()
            DispatchQueue.main.async {
                ctx.browserView?.scrollToVisibleInEnclosingScrollView()
            }
        }
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
}
