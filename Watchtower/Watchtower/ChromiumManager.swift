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

        settings.remote_debugging_port = Int32(WatchtowerConfig.shared.chromiumRemoteDebuggingPort)
        initializedRemoteDebuggingPort = WatchtowerConfig.shared.chromiumRemoteDebuggingPort
        settings.log_severity = LOGSEVERITY_VERBOSE

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
        startMessagePump()
    }

    private func startMessagePump() {
        guard pumpTimer == nil else { return }
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
