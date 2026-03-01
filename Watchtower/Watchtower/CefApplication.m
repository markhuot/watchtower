// CefApplication.m
//
// Patches NSApplication to conform to CefAppProtocol via +load swizzling.
//
// CEF on macOS requires that NSApp respond to -isHandlingSendEvent /
// -setHandlingSendEvent: (defined in CefAppProtocol / CrAppProtocol), and that
// -sendEvent: wraps calls with the reentrancy tracking those methods provide.
// The canonical solution is a custom NSApplication subclass — but SwiftUI's
// App.main() ignores NSPrincipalClass and installs its own internal subclass,
// so any pre-existing singleton gets replaced.
//
// The QCefView project (which embeds CEF inside a Qt app the same way we embed
// it inside SwiftUI) solves this with an NSApplication category whose +load
// method runs at dyld time — before main(), before SwiftUI — and swizzles the
// three relevant methods onto whatever NSApplication class ends up being used.
// A global bool is used for the sendEvent-reentrancy flag instead of an ivar,
// avoiding ivar-layout hazards with SwiftUI's private NSApplication subclass.
//
// NOTE: This file is compiled as plain Objective-C (.m), not Objective-C++
// (.mm).  cef_application_mac.h wraps CefScopedSendingEvent in #ifdef __cplusplus,
// so we cannot use it here — its behaviour is inlined manually below.
//
// Reference: https://github.com/CefView/QCefView/blob/40d9155e/src/mac/details/QCefContextPrivate_mac.mm

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

// Define OS_MAC so that the ObjC-only declarations in cef_application_mac.h
// (CefAppProtocol, CrAppProtocol, CrAppControlProtocol) are visible.
// The file's __cplusplus guard is NOT defined here (plain .m), so CefScopedSendingEvent
// — a C++ class — is intentionally excluded.
#ifndef OS_MAC
#define OS_MAC 1
#endif
#include "include/cef_application_mac.h"

// Global reentrancy flag — avoids ivar layout issues with SwiftUI's NSApplication subclass.
static BOOL g_cef_handling_send_event = NO;

// Flag set by Swift code before calling [NSApp terminate:nil] to indicate
// this is a user-initiated quit (Cmd-Q, menu bar, dock) rather than a
// CEF-initiated terminate (e.g. last browser close).
static BOOL g_watchtower_quit_requested = NO;

void WatchtowerRequestQuit(void) {
    g_watchtower_quit_requested = YES;
}

BOOL WatchtowerIsQuitRequested(void) {
    return g_watchtower_quit_requested;
}

@interface NSApplication (CefAppProtocol) <CefAppProtocol>
- (void)_cef_swizzled_sendEvent:(NSEvent*)event;
- (void)_cef_swizzled_terminate:(id)sender;
@end

@implementation NSApplication (CefAppProtocol)

// +load fires at dyld time, before main() and before SwiftUI can touch NSApp.
+ (void)load {
    // Swizzle sendEvent:
    Method origSend = class_getInstanceMethod(self, @selector(sendEvent:));
    Method swizSend = class_getInstanceMethod(self, @selector(_cef_swizzled_sendEvent:));
    method_exchangeImplementations(origSend, swizSend);

    // Swizzle terminate:
    Method origTerm = class_getInstanceMethod(self, @selector(terminate:));
    Method swizTerm = class_getInstanceMethod(self, @selector(_cef_swizzled_terminate:));
    method_exchangeImplementations(origTerm, swizTerm);
}

// CrAppProtocol
- (BOOL)isHandlingSendEvent {
    return g_cef_handling_send_event;
}

// CrAppControlProtocol
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
    g_cef_handling_send_event = handlingSendEvent;
}

// Replaces sendEvent: — original is now at _cef_swizzled_sendEvent:.
// Inlines what CefScopedSendingEvent does (save, set YES, call original, restore).
- (void)_cef_swizzled_sendEvent:(NSEvent*)event {
    BOOL wasHandling = g_cef_handling_send_event;
    g_cef_handling_send_event = YES;
    // Calls the original implementation (the two impls were exchanged by +load).
    [self _cef_swizzled_sendEvent:event];
    g_cef_handling_send_event = wasHandling;
}

// Replaces terminate: — intercepts Chrome-initiated process exits.
//
// CEF may internally call [NSApp terminate:nil] (e.g. on last browser close).
// We must not let that kill the Watchtower process while there are still
// terminal panes open.
//
// Three quit paths exist:
// 1. Cmd-Q / menu Quit — Swift calls WatchtowerRequestQuit() then terminate:
// 2. Dock Quit — macOS calls terminate: directly (no flag set)
// 3. CEF-initiated — CEF calls terminate: internally (no flag set)
//
// For path 1: the flag is set, we call through immediately.
// For paths 2 & 3: we post a notification so AppDelegate can decide.
//    AppDelegate sets the flag and re-calls terminate: for path 2.
//    For path 3, AppDelegate detects a CEF close in progress and ignores it.
- (void)_cef_swizzled_terminate:(id)sender {
    if (g_watchtower_quit_requested) {
        g_watchtower_quit_requested = NO;
        // Calls the original terminate: (the two impls were exchanged by +load).
        [self _cef_swizzled_terminate:sender];
    } else {
        // Not explicitly requested — let AppDelegate decide.
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"WatchtowerTerminateAttempted"
            object:nil];
    }
}

@end

