import AppKit
import Darwin

// Install signal handlers to catch what kills us
func signalHandler(_ sig: Int32) {
    let name: String
    switch sig {
    case SIGABRT: name = "SIGABRT"
    case SIGSEGV: name = "SIGSEGV"
    case SIGBUS: name = "SIGBUS"
    case SIGFPE: name = "SIGFPE"
    case SIGILL: name = "SIGILL"
    case SIGTRAP: name = "SIGTRAP"
    case SIGTERM: name = "SIGTERM"
    case SIGKILL: name = "SIGKILL"
    default: name = "SIG(\(sig))"
    }
    // Use write() since it's async-signal-safe (NSLog is NOT)
    let msg = "[SIGNAL] Caught \(name) (\(sig))\n"
    msg.withCString { ptr in
        _ = Darwin.write(STDERR_FILENO, ptr, strlen(ptr))
    }
    // Re-raise to get the default behavior (core dump etc)
    signal(sig, SIG_DFL)
    raise(sig)
}

for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP, SIGTERM] {
    signal(sig, signalHandler)
}

// Install atexit handler
atexit {
    let msg = "[ATEXIT] Process exiting normally\n"
    msg.withCString { ptr in
        _ = Darwin.write(STDERR_FILENO, ptr, strlen(ptr))
    }
}

// Register our custom NSApplication subclass that implements CefAppProtocol
// before SwiftUI's App lifecycle takes over. This is required by CEF on macOS.
// The class must be registered as the principal class before NSApplication.shared
// is first accessed.
_ = NSApplication.shared  // Force NSApplication initialization — our Info.plist
                           // sets NSPrincipalClass to CefNSApplication

// Eagerly initialize CEF if the user has Chromium engine configured.
// This ensures CEF's profile KeepAlive system has a browser window registered
// before the profile creation flow completes, preventing premature _exit().
if WatchtowerConfig.shared.browserEngine == .chromium {
    ChromiumManager.shared.ensureInitialized()
}

WatchtowerApp.main()
