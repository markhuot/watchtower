import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// Singleton that manages the Ghostty app-level state (ghostty_app_t).
/// This is the equivalent of Ghostty.App from the reference implementation,
/// simplified for Watchtower's needs.
class GhosttyAppManager: ObservableObject {
    static let shared = GhosttyAppManager()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.eyes.Watchtower",
        category: "GhosttyAppManager"
    )

    enum ReadyState {
        case loading
        case ready
        case error
    }

    @Published private(set) var readyState: ReadyState = .loading

    /// Background color from Ghostty config, updated dynamically if the terminal changes it.
    @Published private(set) var backgroundColor: Color = Color(white: 0.1)

    /// Highlight color for focused pane border, from Ghostty theme or system accent.
    @Published private(set) var highlightColor: Color = Color.accentColor

    /// Whether the application window is currently active (key window in foreground).
    @Published private(set) var isWindowActive: Bool = true

    /// The ghostty app instance. We only have one for the entire app.
    private(set) var app: ghostty_app_t? = nil

    /// The ghostty config.
    private(set) var config: ghostty_config_t? = nil

    private init() {
        // Initialize ghostty global state
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            Self.logger.critical("ghostty_init failed")
            readyState = .error
            return
        }

        // Create config
        guard let cfg = ghostty_config_new() else {
            Self.logger.critical("ghostty_config_new failed")
            readyState = .error
            return
        }

        // Load default config files (reads ~/.config/ghostty/config etc.)
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        self.config = cfg

        // Create the runtime config with our callbacks
        var runtime_cfg = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in
                GhosttyAppManager.wakeup(userdata)
            },
            action_cb: { app, target, action in
                GhosttyAppManager.handleAction(app!, target: target, action: action)
            },
            read_clipboard_cb: { userdata, loc, state in
                GhosttyAppManager.readClipboard(userdata, location: loc, state: state)
            },
            confirm_read_clipboard_cb: { userdata, str, state, request in
                // For simplicity, we auto-confirm clipboard reads
                GhosttyAppManager.confirmReadClipboard(userdata, string: str, state: state, request: request)
            },
            write_clipboard_cb: { userdata, loc, content, len, confirm in
                GhosttyAppManager.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyAppManager.closeSurface(userdata, processAlive: processAlive)
            }
        )

        // Create the ghostty app
        guard let ghosttyApp = ghostty_app_new(&runtime_cfg, cfg) else {
            Self.logger.critical("ghostty_app_new failed")
            readyState = .error
            return
        }
        self.app = ghosttyApp

        // Set initial focus state
        ghostty_app_set_focus(ghosttyApp, NSApp.isActive)

        // Listen for keyboard layout changes
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(keyboardSelectionDidChange),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        readyState = .ready

        // Read the background color from Ghostty config
        self.backgroundColor = Self.readBackgroundColor(from: cfg)

        // Read highlight color: try selection-background, then cursor-color, then system accent
        self.highlightColor = Self.readHighlightColor(from: cfg)

        Self.logger.info("GhosttyAppManager initialized successfully")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let app = app {
            ghostty_app_free(app)
        }
        if let config = config {
            ghostty_config_free(config)
        }
    }

    // MARK: - App Tick

    func appTick() {
        guard let app = self.app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Notifications

    @objc private func keyboardSelectionDidChange(notification: Notification) {
        guard let app = self.app else { return }
        ghostty_app_keyboard_changed(app)
    }

    @objc private func applicationDidBecomeActive(notification: Notification) {
        guard let app = self.app else { return }
        ghostty_app_set_focus(app, true)
        isWindowActive = true
    }

    @objc private func applicationDidResignActive(notification: Notification) {
        guard let app = self.app else { return }
        ghostty_app_set_focus(app, false)
        isWindowActive = false
    }

    // MARK: - Static Callbacks

    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata = userdata else { return }
        let manager = Unmanaged<GhosttyAppManager>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            manager.appTick()
        }
    }

    private static func handleAction(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            return setTitle(app, target: target, v: action.action.set_title)

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            return childExited(app, target: target, v: action.action.child_exited)

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            return commandFinished(app, target: target, v: action.action.command_finished)

        case GHOSTTY_ACTION_COLOR_CHANGE:
            return colorChange(app, target: target, v: action.action.color_change)

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            return setMouseShape(app, target: target, shape: action.action.mouse_shape)

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            setMouseVisibility(app, target: target, v: action.action.mouse_visibility)
            return true

        case GHOSTTY_ACTION_PWD:
            return setPwd(app, target: target, v: action.action.pwd)

        case GHOSTTY_ACTION_NEW_SPLIT,
             GHOSTTY_ACTION_NEW_WINDOW,
             GHOSTTY_ACTION_NEW_TAB,
             GHOSTTY_ACTION_CLOSE_TAB,
             GHOSTTY_ACTION_CLOSE_WINDOW:
            // We don't handle these yet but acknowledge them
            return false

        case GHOSTTY_ACTION_CELL_SIZE:
            return setCellSize(app, target: target, v: action.action.cell_size)

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            return rendererHealth(app, target: target, v: action.action.renderer_health)

        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return true

        default:
            // Many actions we can safely ignore for now
            return false
        }
    }

    // MARK: - Action Implementations

    private static func surfaceView(from surface: ghostty_surface_t) -> GhosttyTerminalNSView? {
        guard let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<GhosttyTerminalNSView>.fromOpaque(ud).takeUnretainedValue()
    }

    private static func setTitle(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_set_title_s
    ) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        guard let surface = target.target.surface else { return false }
        guard let view = surfaceView(from: surface) else { return false }
        guard let titlePtr = v.title else { return false }
        let title = String(cString: titlePtr)
        DispatchQueue.main.async {
            view.updateTitle(title)
        }
        return true
    }

    private static func childExited(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_surface_message_childexited_s
    ) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        guard let surface = target.target.surface else { return false }
        guard let view = surfaceView(from: surface) else { return false }
        let exitCode = v.exit_code
        let status: TerminalStatus = exitCode == 0 ? .idle : .failed
        DispatchQueue.main.async {
            view.updateStatus(status)
        }
        return true
    }

    private static func commandFinished(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_command_finished_s
    ) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        guard let surface = target.target.surface else { return false }
        guard let view = surfaceView(from: surface) else { return false }
        DispatchQueue.main.async {
            view.refreshStatusFromSurface()
        }
        return true
    }

    private static func setPwd(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_pwd_s
    ) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        guard let surface = target.target.surface else { return false }
        guard let view = surfaceView(from: surface) else { return false }
        guard let pwdPtr = v.pwd else { return false }
        let pwd = String(cString: pwdPtr)
        DispatchQueue.main.async {
            view.terminal.directory = pwd
            view.refreshStatusFromSurface()
        }
        return true
    }

    // MARK: - Theme Colors

    private static func readBackgroundColor(from config: ghostty_config_t) -> Color {
        var color = ghostty_config_color_s(r: 0, g: 0, b: 0)
        let key = "background"
        if ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) {
            return Color(
                red: Double(color.r) / 255,
                green: Double(color.g) / 255,
                blue: Double(color.b) / 255
            )
        }
        return Color(white: 0.1)
    }

    private static func readHighlightColor(from config: ghostty_config_t) -> Color {
        var color = ghostty_config_color_s(r: 0, g: 0, b: 0)

        // Try selection-background first
        let selKey = "selection-background"
        if ghostty_config_get(config, &color, selKey, UInt(selKey.lengthOfBytes(using: .utf8))) {
            return Color(
                red: Double(color.r) / 255,
                green: Double(color.g) / 255,
                blue: Double(color.b) / 255
            )
        }

        // Fallback to cursor-color
        let cursorKey = "cursor-color"
        if ghostty_config_get(config, &color, cursorKey, UInt(cursorKey.lengthOfBytes(using: .utf8))) {
            return Color(
                red: Double(color.r) / 255,
                green: Double(color.g) / 255,
                blue: Double(color.b) / 255
            )
        }

        // Fallback to system accent
        return Color.accentColor
    }

    private static func colorChange(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_color_change_s
    ) -> Bool {
        // Only handle background color changes
        guard v.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else { return false }
        let newColor = Color(
            red: Double(v.r) / 255,
            green: Double(v.g) / 255,
            blue: Double(v.b) / 255
        )
        DispatchQueue.main.async {
            shared.backgroundColor = newColor
        }
        return true
    }

    private static func setMouseShape(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        shape: ghostty_action_mouse_shape_e
    ) -> Bool {
        // We can handle cursor changes if needed; for now just acknowledge
        return true
    }

    private static func setMouseVisibility(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_mouse_visibility_e
    ) {
        let visible = v == GHOSTTY_MOUSE_VISIBLE
        NSCursor.setHiddenUntilMouseMoves(!visible)
    }

    private static func setCellSize(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_cell_size_s
    ) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        guard let surface = target.target.surface else { return false }
        guard let view = surfaceView(from: surface) else { return false }
        DispatchQueue.main.async {
            view.cellSize = NSSize(width: CGFloat(v.width), height: CGFloat(v.height))
        }
        return true
    }

    private static func rendererHealth(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_renderer_health_e
    ) -> Bool {
        // Log renderer health issues
        if v != GHOSTTY_RENDERER_HEALTH_OK {
            logger.warning("Renderer health issue: \(v.rawValue)")
        }
        return true
    }

    // MARK: - Clipboard Callbacks

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) {
        guard let userdata = userdata else { return }
        let manager = Unmanaged<GhosttyAppManager>.fromOpaque(userdata).takeUnretainedValue()

        // Read from the system pasteboard
        let pasteboard = NSPasteboard.general
        let str = pasteboard.string(forType: .string) ?? ""

        // We need to find the surface to complete the request
        // The userdata here is the app manager, but we need the surface
        // The state is opaque and must be passed back to ghostty
        // For clipboard reads, the surface is obtained via the callback context
        // We need to get it from the surface userdata
        // Actually, for clipboard reads, the userdata is the surface's userdata
        // Let's check - in the reference impl, readClipboard userdata is the surface view
        // But in our runtime config, userdata is the app manager
        // The clipboard callbacks receive the SURFACE's userdata, not the app's
        // Wait, looking more carefully: the runtime_config userdata is set to the App,
        // but clipboard callbacks receive the surface's userdata
        // Actually no - let me re-read. The callbacks on ghostty_runtime_config_s
        // have userdata that is the surface's userdata for clipboard operations
        
        // The read_clipboard_cb userdata is actually the surface userdata
        let surfaceView = Unmanaged<GhosttyTerminalNSView>.fromOpaque(userdata).takeUnretainedValue()
        guard let surface = surfaceView.surface else { return }
        
        str.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
        }
    }

    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        // Auto-confirm for Watchtower
        guard let userdata = userdata else { return }
        let surfaceView = Unmanaged<GhosttyTerminalNSView>.fromOpaque(userdata).takeUnretainedValue()
        guard let surface = surfaceView.surface else { return }
        
        let str = string.map { String(cString: $0) } ?? ""
        str.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, true)
        }
    }

    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let content = content, len > 0 else { return }

        // Parse all content items from the C array
        struct ClipboardItem {
            let mime: String
            let data: String
            let pasteboardType: NSPasteboard.PasteboardType
        }

        var items: [ClipboardItem] = []
        for i in 0..<len {
            let item = content[i]
            guard let mimePtr = item.mime,
                  let dataPtr = item.data else { continue }
            let mime = String(cString: mimePtr)
            let data = String(cString: dataPtr)
            guard let pbType = pasteboardType(fromMime: mime) else { continue }
            items.append(ClipboardItem(mime: mime, data: data, pasteboardType: pbType))
        }
        guard !items.isEmpty else { return }

        let pasteboard = NSPasteboard.general

        // Declare all types upfront, then set data for each
        let types = items.map { $0.pasteboardType }
        pasteboard.declareTypes(types, owner: nil)
        for item in items {
            pasteboard.setString(item.data, forType: item.pasteboardType)
        }
    }

    /// Convert a MIME type string to an NSPasteboard.PasteboardType.
    private static func pasteboardType(fromMime mime: String) -> NSPasteboard.PasteboardType? {
        switch mime {
        case "text/plain":
            return .string
        default:
            // Try to resolve via UTType, fall back to using the MIME string directly
            if let utType = UTType(mimeType: mime) {
                return NSPasteboard.PasteboardType(utType.identifier)
            }
            return NSPasteboard.PasteboardType(mime)
        }
    }

    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let userdata = userdata else { return }
        let surfaceView = Unmanaged<GhosttyTerminalNSView>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .ghosttySurfaceClosed,
                object: surfaceView
            )
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let ghosttySurfaceClosed = Notification.Name("ghosttySurfaceClosed")
}
