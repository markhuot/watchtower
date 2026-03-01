//
//  GhosttyBridge.h
//  Watchtower
//
//  Bridging header for Ghostty and CEF C APIs
//

#ifndef GhosttyBridge_h
#define GhosttyBridge_h

// Ghostty
#include "ghostty.h"

// CEF (Chromium Embedded Framework) C API
// Headers use paths relative to the chromium/ root (e.g., "include/capi/...")
// so $(PROJECT_DIR)/chromium must be in the header search paths.
#include "include/cef_api_hash.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_request_handler_capi.h"
#include "include/capi/cef_download_handler_capi.h"
#include "include/capi/cef_focus_handler_capi.h"
#include "include/capi/cef_keyboard_handler_capi.h"
#include "include/capi/cef_context_menu_handler_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_values_capi.h"

// CEF macOS-specific (CefAppProtocol for NSApplication subclass)
#include "include/cef_application_mac.h"

// CEF internal types (cef_settings_t, cef_browser_settings_t, cef_window_info_t)
#include "include/internal/cef_types.h"
#include "include/internal/cef_types_mac.h"

// CefApplication.m helpers — allow Swift to signal user-initiated quit
// before calling [NSApp terminate:nil], so the swizzled terminate: knows
// to call through to the original implementation.
void WatchtowerRequestQuit(void);
BOOL WatchtowerIsQuitRequested(void);

#endif /* GhosttyBridge_h */
