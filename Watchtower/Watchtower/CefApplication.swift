import AppKit

/// Custom NSApplication subclass required by CEF on macOS.
///
/// CEF requires that the application's NSApplication class conforms to `CefAppProtocol`
/// (which extends `CrAppControlProtocol` / `CrAppProtocol`). This tracks whether
/// `-[NSApplication sendEvent:]` is currently on the stack, which CEF's internal
/// message loop integration needs to avoid reentrancy issues.
///
/// Registered as the principal class via Info.plist `NSPrincipalClass` and
/// initialized in `main.swift` before `WatchtowerApp.main()` is called.
class CefNSApplication: NSApplication, CefAppProtocol {
    private var _handlingSendEvent: Bool = false

    /// Required by `CrAppProtocol`: returns true if `-sendEvent:` is currently on the stack.
    @objc func isHandlingSendEvent() -> Bool {
        return _handlingSendEvent
    }

    /// Required by `CrAppControlProtocol`: sets the sendEvent tracking flag.
    @objc func setHandlingSendEvent(_ handlingSendEvent: Bool) {
        _handlingSendEvent = handlingSendEvent
    }

    override func sendEvent(_ event: NSEvent) {
        let wasHandling = _handlingSendEvent
        _handlingSendEvent = true
        defer { _handlingSendEvent = wasHandling }
        super.sendEvent(event)
    }

    override func terminate(_ sender: Any?) {
        NSLog("[CEF] CefNSApplication.terminate called — intercepting to prevent Chrome-initiated exit")
        // Chrome's shutdown path calls [NSApp terminate:]. We intercept it here
        // to prevent Chrome from killing the Watchtower process. Instead of
        // terminating, we just log and return. The app will shut down properly
        // via its own lifecycle.
        //
        // If we actually want to terminate (user clicked Quit), the normal
        // SwiftUI app lifecycle will handle it.
    }
}
