import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "com.watchtower", category: "ChromiumManager")

/// Minimal singleton managing the CEF lifecycle.
/// Stripped to: init, message pump, shutdown, keep-alive browser.
class ChromiumManager {
    static let shared = ChromiumManager()
    private var initialized = false
    private var pumpTimer: Timer?

    /// Number of active CEF browsers. The message pump timer only runs
    /// while this is > 0. Incremented by `browserOpened()` (called from
    /// `on_after_created`), decremented by `browserClosed()` (called from
    /// `on_before_close`).
    private var activeBrowserCount = 0

    /// The remote debugging port CEF was initialized with (0 = disabled).
    /// Only valid after `ensureInitialized()` succeeds.
    private(set) var initializedRemoteDebuggingPort: Int = 0

    private var cefApp: UnsafeMutablePointer<cef_app_t>?
    private var browserProcessHandler: UnsafeMutablePointer<cef_browser_process_handler_t>?

    private init() {}

    func ensureInitialized() {
        guard !initialized else { return }

        NSLog("[CEF] Initializing CEF")

        // Configure API version (MUST be called first)
        let apiHash = cef_api_hash(Int32(CEF_API_VERSION_EXPERIMENTAL), 0)
        NSLog("[CEF] API hash: %@", apiHash != nil ? String(cString: apiHash!) : "nil")

        // Create cef_app_t
        let app: UnsafeMutablePointer<cef_app_t> = cefCreate()

        // Create browser process handler
        let bph: UnsafeMutablePointer<cef_browser_process_handler_t> = cefCreate()

        bph.pointee.on_context_initialized = { (selfPtr) in
            NSLog("[CEF] on_context_initialized")
        }

        bph.pointee.get_default_client = { (selfPtr) -> UnsafeMutablePointer<cef_client_t>? in
            NSLog("[CEF] get_default_client called")
            let client: UnsafeMutablePointer<cef_client_t> = cefCreate()
            return client
        }

        app.pointee.get_browser_process_handler = { (selfPtr) -> UnsafeMutablePointer<cef_browser_process_handler_t>? in
            let bph = ChromiumManager.shared.browserProcessHandler
            bph?.pointee.base.add_ref?(&bph!.pointee.base)
            return bph
        }

        // Command line processing — only disable Fontations (crash fix)
        app.pointee.on_before_command_line_processing = { (selfPtr, processType, commandLine) in
            guard let commandLine = commandLine else { return }
            withCEFString("disable-features") { switchName in
                withCEFString("Fontations") { switchValue in
                    commandLine.pointee.append_switch_with_value?(commandLine, &switchName, &switchValue)
                }
            }
            // Disable the overscroll-to-navigate-history gesture (scroll left/right
            // to go back/forward). Value "0" disables it; "1" enables (the default).
            withCEFString("overscroll-history-navigation") { switchName in
                withCEFString("0") { switchValue in
                    commandLine.pointee.append_switch_with_value?(commandLine, &switchName, &switchValue)
                }
            }
            withCEFString("disable-background-networking") { switchName in
                commandLine.pointee.append_switch?(commandLine, &switchName)
            }
            // Verbose logging to debug renderer process launch
            withCEFString("enable-logging") { switchName in
                commandLine.pointee.append_switch?(commandLine, &switchName)
            }
            withCEFString("v") { switchName in
                withCEFString("2") { switchValue in
                    commandLine.pointee.append_switch_with_value?(commandLine, &switchName, &switchValue)
                }
            }
        }

        self.cefApp = app
        self.browserProcessHandler = bph

        // Main args
        var mainArgs = cef_main_args_t()
        mainArgs.argc = CommandLine.argc
        mainArgs.argv = CommandLine.unsafeArgv

        // Settings — minimal
        var settings = cef_settings_t()
        settings.size = MemoryLayout<cef_settings_t>.size
        settings.no_sandbox = 1
        settings.external_message_pump = 1
        settings.multi_threaded_message_loop = 0

        // Cache dir (avoids keychain prompt)
        let cacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Watchtower")
            .appendingPathComponent("CEF")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cefStringSet(cacheDir.path, cefStr: &settings.root_cache_path)

        settings.persist_session_cookies = 0
        settings.cookieable_schemes_exclude_defaults = 1

        // Framework and helper paths
        let frameworkPath = Bundle.main.privateFrameworksPath.map { $0 + "/Chromium Embedded Framework.framework" } ?? ""
        cefStringSet(frameworkPath, cefStr: &settings.framework_dir_path)

        let helperPath = Bundle.main.bundlePath + "/Contents/Frameworks/Watchtower Helper.app/Contents/MacOS/Watchtower Helper"
        cefStringSet(helperPath, cefStr: &settings.browser_subprocess_path)

        // Remote debugging port — always enabled so "Inspect Element" can open
        // DevTools in an adjacent pane (like Chrome's docked DevTools).
        // Uses the user's configured port (default 9222).
        let effectivePort = WatchtowerConfig.shared.chromiumRemoteDebuggingPort
        settings.remote_debugging_port = Int32(effectivePort)
        initializedRemoteDebuggingPort = effectivePort
        settings.log_severity = LOGSEVERITY_VERBOSE

        // Verify CefApplication.m's +load swizzle installed isHandlingSendEvent on NSApp.
        // This must be true before cef_initialize() is called.
        assert(NSApp?.responds(to: Selector(("isHandlingSendEvent"))) == true,
               "[CEF] NSApp does not respond to isHandlingSendEvent — +load swizzle in CefApplication.m did not run")

        // Initialize
        NSLog("[CEF] Calling cef_initialize")
        let result = cef_initialize(&mainArgs, &settings, app, nil)
        NSLog("[CEF] cef_initialize returned: %d", result)

        // Clean up strings
        cef_string_utf16_clear(&settings.root_cache_path)
        cef_string_utf16_clear(&settings.framework_dir_path)
        cef_string_utf16_clear(&settings.browser_subprocess_path)

        if result == 0 {
            NSLog("[CEF] cef_initialize FAILED")
            return
        }

        initialized = true
        NSLog("[CEF] CEF initialized successfully")
        // Start the message pump immediately and keep it running for the
        // lifetime of the app. CEF's CrBrowserMain thread continues to
        // post work after on_before_close and needs the pump to drain its
        // internal queue at all times. Stopping the pump while any CEF
        // internal thread is alive (even after all browsers are closed)
        // causes CrBrowserMain to back up and post directly to NSApp's
        // event loop via _cef_swizzled_sendEvent → crash. The pump costs
        // almost nothing when idle (cef_do_message_loop_work returns
        // immediately when there is no work to do).
        startMessagePump()
    }

    /// Called from `on_after_created` when a new CEF browser is created.
    /// Tracks open browser count for logging only — pump lifecycle is
    /// independent of browser count.
    /// May be called from any thread — dispatches to main for safety.
    func browserOpened() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.activeBrowserCount += 1
            NSLog("[CEF] browserOpened: activeBrowserCount=%d", self.activeBrowserCount)
        }
    }

    /// Called from `on_before_close` when a CEF browser is fully closed.
    /// Tracks open browser count for logging only — the pump keeps running
    /// until `shutdown()` is called at app quit. Stopping the pump when
    /// browser count hits zero crashes the app because CrBrowserMain's
    /// internal threads continue to need the pump after on_before_close.
    /// May be called from any thread — dispatches to main for safety.
    func browserClosed() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.activeBrowserCount = max(0, self.activeBrowserCount - 1)
            NSLog("[CEF] browserClosed: activeBrowserCount=%d", self.activeBrowserCount)
        }
    }

    private func startMessagePump() {
        guard pumpTimer == nil else { return }
        NSLog("[CEF] startMessagePump called\n  backtrace:\n%@", Thread.callStackSymbols.joined(separator: "\n"))
        var pumpCount: UInt64 = 0
        pumpTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard self?.initialized == true else { return }
            pumpCount += 1
            if pumpCount <= 5 || pumpCount % 300 == 0 {
                NSLog("[CEF] pump tick #%llu", pumpCount)
            }
            cef_do_message_loop_work()
        }
        if let timer = pumpTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        NSLog("[CEF] Message pump started")
    }

    func shutdown() {
        guard initialized else { return }
        NSLog("[CEF] Shutting down")
        pumpTimer?.invalidate()
        pumpTimer = nil
        cef_shutdown()
        if let app = cefApp {
            app.pointee.base.release?(&app.pointee.base)
            cefApp = nil
        }
        if let bph = browserProcessHandler {
            bph.pointee.base.release?(&bph.pointee.base)
            browserProcessHandler = nil
        }
        initialized = false
    }

    var isInitialized: Bool { initialized }
}
