import SwiftUI
import AppKit
import os

// MARK: - Modifier Helpers

/// Translate NSEvent.ModifierFlags to ghostty_input_mods_e.
/// Equivalent to Ghostty.ghosttyMods() in the reference implementation.
func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

    // Handle sided modifiers
    let rawFlags = flags.rawValue
    if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

    return ghostty_input_mods_e(mods)
}

/// Convert ghostty_input_mods_e back to NSEvent.ModifierFlags
func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
    var flags = NSEvent.ModifierFlags(rawValue: 0)
    if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
    if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
    if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
    if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
    return flags
}

// MARK: - NSEvent Extension

extension NSEvent {
    /// Create a ghostty_input_key_s from this event, matching Ghostty's NSEvent+Extension.
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key_ev = ghostty_input_key_s()
        key_ev.action = action
        key_ev.keycode = UInt32(keyCode)
        key_ev.text = nil
        key_ev.composing = false

        key_ev.mods = ghosttyMods(modifierFlags)
        key_ev.consumed_mods = ghosttyMods(
            (translationMods ?? modifierFlags)
                .subtracting([.control, .command])
        )

        key_ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                key_ev.unshifted_codepoint = codepoint.value
            }
        }

        return key_ev
    }

    /// Returns the text suitable for sending to Ghostty's key event.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            // Control characters are handled by Ghostty's KeyEncoder
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            // PUA range = function keys, don't send
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}

// MARK: - SwiftUI Wrapper

/// SwiftUI wrapper for the Ghostty terminal view
struct GhosttyTerminalView: NSViewRepresentable {
    let terminal: TerminalPaneModel
    let size: CGSize

    func makeNSView(context: Context) -> GhosttyTerminalNSView {
        let view = GhosttyTerminalNSView(model: terminal)
        return view
    }

    func updateNSView(_ nsView: GhosttyTerminalNSView, context: Context) {
        nsView.sizeDidChange(size)
    }
}

// MARK: - GhosttyTerminalNSView

/// NSView that hosts a Ghostty terminal surface.
/// This view:
/// - Creates a ghostty_surface_t when initialized
/// - Forwards keyboard input via NSTextInputClient
/// - Handles mouse events
/// - Manages surface sizing
class GhosttyTerminalNSView: NSView, NSTextInputClient {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.eyes.Watchtower",
        category: "GhosttyTerminalNSView"
    )

    // The terminal model this view represents
    private(set) var terminal: TerminalPaneModel

    // The Ghostty surface for this terminal
    private(set) var surface: ghostty_surface_t? = nil

    // Cell size (set by Ghostty via action callback)
    var cellSize: NSSize = .zero

    // Marked text for IME composition
    private var markedText: NSMutableAttributedString = NSMutableAttributedString()

    // Accumulator for text during keyDown processing
    private var keyTextAccumulator: [String]? = nil

    // Whether this surface has focus
    private var focused: Bool = false

    // Track content size for backing property changes
    private var contentSize: CGSize = .zero

    // Debounce timer for size updates to reduce jitter during live resize
    private var sizeDebounceWorkItem: DispatchWorkItem? = nil

    init(model: TerminalPaneModel) {
        self.terminal = model
        super.init(frame: NSMakeRect(0, 0, 800, 600))
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let surface = surface {
            ghostty_surface_free(surface)
        }
    }

    private func setupView() {
        // We need a layer-backed view for Metal rendering
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        // Create the Ghostty surface
        guard let app = GhosttyAppManager.shared.app else {
            Self.logger.error("GhosttyAppManager not ready, cannot create surface")
            return
        }

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(self).toOpaque()
            )
        )

        if let screen = NSScreen.main {
            surfaceConfig.scale_factor = screen.backingScaleFactor
        } else {
            surfaceConfig.scale_factor = 2.0
        }

        // Set wait_after_command for workspace terminals with custom scripts
        if terminal.waitAfterCommand {
            surfaceConfig.wait_after_command = true
        }

        // Allocate stable C strings for env vars using strdup.
        // These are freed after ghostty_surface_new consumes them.
        var envVarStructs: [ghostty_env_var_s] = []
        var envAllocations: [UnsafeMutablePointer<CChar>] = []

        // Always inject WATCHTOWER_PANE_ID so CLI tools can identify
        // which pane they are running in.
        var mergedEnv = terminal.env ?? [:]
        mergedEnv["WATCHTOWER_PANE_ID"] = terminal.id.uuidString

        for (key, value) in mergedEnv {
            let cKey = strdup(key)!
            let cVal = strdup(value)!
            envAllocations.append(cKey)
            envAllocations.append(cVal)
            envVarStructs.append(ghostty_env_var_s(
                key: UnsafePointer(cKey),
                value: UnsafePointer(cVal)
            ))
        }

        // Set working directory and optional command/env, then create surface
        terminal.terminalDirectory.withCString { cDir in
            surfaceConfig.working_directory = cDir

            envVarStructs.withUnsafeMutableBufferPointer { buf in
                if !buf.isEmpty {
                    surfaceConfig.env_vars = buf.baseAddress
                    surfaceConfig.env_var_count = buf.count
                }

                if let command = terminal.command {
                    command.withCString { cCmd in
                        surfaceConfig.command = cCmd
                        self.surface = ghostty_surface_new(app, &surfaceConfig)
                    }
                } else {
                    self.surface = ghostty_surface_new(app, &surfaceConfig)
                }
            }
        }

        // Free env var allocations
        for ptr in envAllocations {
            free(ptr)
        }

        guard surface != nil else {
            Self.logger.error("ghostty_surface_new failed")
            return
        }

        Self.logger.info("Created Ghostty surface for terminal: \(self.terminal.title)")

        // If the terminal has initial input, send it once the shell is ready.
        // We delay briefly to give the shell time to start and show its prompt.
        // Text is sent via ghostty_surface_text, then Enter is simulated via
        // ghostty_surface_key (since \n and \r sent as text are treated as
        // literal characters, not key presses).
        if let initialInput = terminal.initialInput {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let surface = self?.surface else { return }

                // Send the command text
                initialInput.withCString { ptr in
                    ghostty_surface_text(surface, ptr, UInt(initialInput.utf8.count))
                }

                // Simulate pressing Enter (Return keycode = 36 on macOS)
                var key_ev = ghostty_input_key_s()
                key_ev.action = GHOSTTY_ACTION_PRESS
                key_ev.keycode = 36
                key_ev.mods = GHOSTTY_MODS_NONE
                key_ev.consumed_mods = GHOSTTY_MODS_NONE
                key_ev.unshifted_codepoint = 0x0D
                key_ev.text = nil
                key_ev.composing = false
                ghostty_surface_key(surface, key_ev)

                // Release the key
                key_ev.action = GHOSTTY_ACTION_RELEASE
                ghostty_surface_key(surface, key_ev)
            }
        }

        // Schedule an initial status check after the surface has had time to
        // initialize.  This ensures the icon reflects the actual Ghostty state
        // rather than the hard-coded `.active` default.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshStatusFromSurface()
        }
    }

    // MARK: - Public API

    func updateTitle(_ title: String) {
        terminal.terminalTitle = title
    }

    func updateStatus(_ status: PaneStatus) {
        terminal.terminalStatus = status
    }

    /// Query Ghostty's own surface state to determine whether the surface
    /// has an active foreground process. This is the same check used by
    /// the window-close confirmation, ensuring the status icon stays in
    /// sync with that behavior.
    func refreshStatusFromSurface() {
        guard let surface = surface else { return }
        let needsConfirm = ghostty_surface_needs_confirm_quit(surface)
        terminal.terminalStatus = needsConfirm ? .active : .idle
    }

    func updateTerminal(_ terminal: TerminalPaneModel) {
        self.terminal = terminal
    }

    // MARK: - View Lifecycle

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            focused = true
            terminal.isFocused = true
            if let surface = surface {
                ghostty_surface_set_focus(surface, true)
            }

            // Notify the view model so focusModePaneId is updated (which
            // drives the focus-mode width expansion). Without this, direct
            // clicks on the terminal bypass focusPane() entirely.
            if let vm = terminal.viewModel {
                if vm.focusModePaneId != terminal.id || vm.contextualPane?.id != terminal.id {
                    vm.focusPane(id: terminal.id)
                }
            }

        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            focused = false
            terminal.isFocused = false
            if let surface = surface {
                ghostty_surface_set_focus(surface, false)
            }
        }
        return result
    }

    /// Intercept the "Close" menu item (Cmd+W). Close just this terminal pane,
    /// with a confirmation dialog if an active session is running.
    /// When this is the last pane, the empty state is shown instead of closing the window.
    @objc func performClose(_ sender: Any?) {
        guard let window = self.window else {
            window?.performClose(sender)
            return
        }

        if let surface = surface, ghostty_surface_needs_confirm_quit(surface) {
            let alert = NSAlert()
            alert.messageText = "Close Terminal?"
            alert.informativeText = "This terminal has an active session. Closing it will terminate the session."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")

            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self = self else { return }
                if response == .alertFirstButtonReturn {
                    NotificationCenter.default.post(
                        name: .ghosttySurfaceClosed,
                        object: self
                    )
                }
            }
        } else {
            NotificationCenter.default.post(
                name: .ghosttySurfaceClosed,
                object: self
            )
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let surface = surface else { return }

        if let window = self.window {
            // Update scale when we get a window
            if let screen = window.screen {
                let scale = screen.backingScaleFactor
                ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
            }

            // Claim focus if this view was pending
            if let pending = terminal.viewModel?.pendingFocus,
               pending.paneId == terminal.id,
               pending.fulfill() {
                terminal.viewModel?.pendingFocus = nil
                window.makeFirstResponder(self)
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface = surface else { return }

        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
            ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))

            // Re-set the size with new backing scale
            if contentSize.width > 0 && contentSize.height > 0 {
                let scaledSize = convertToBacking(contentSize)
                ghostty_surface_set_size(
                    surface,
                    UInt32(scaledSize.width),
                    UInt32(scaledSize.height)
                )
            }
        }
    }

    func sizeDidChange(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        guard let surface = surface else { return }

        // Skip if the size hasn't meaningfully changed (within 0.5pt)
        if abs(contentSize.width - size.width) < 0.5 &&
           abs(contentSize.height - size.height) < 0.5 {
            return
        }

        contentSize = size
        let scaledSize = convertToBacking(size)
        ghostty_surface_set_size(
            surface,
            UInt32(scaledSize.width),
            UInt32(scaledSize.height)
        )
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        sizeDidChange(bounds.size)
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        // When collapsed, swallow all key events. Enter/Return/Space expands the pane.
        if terminal.isCollapsed {
            if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 { // Return, Enter, or Space
                terminal.viewModel?.toggleCollapsePane()
            }
            return
        }

        guard let surface = self.surface else {
            self.interpretKeyEvents([event])
            return
        }

        // Translate mods for option-as-alt handling
        let translationModsGhostty = eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(
                surface,
                ghosttyMods(event.modifierFlags)
            )
        )

        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        // Build the translation event
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Start accumulating text
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0

        self.interpretKeyEvents([translationEvent])

        // Sync preedit state
        syncPreedit(clearIfNeeded: markedTextBefore)

        var consumed = false
        if let list = keyTextAccumulator, list.count > 0 {
            // We composed text
            for text in list {
                if keyAction(
                    action,
                    event: event,
                    translationEvent: translationEvent,
                    text: text
                ) {
                    consumed = true
                }
            }
        } else {
            // Normal key event
            consumed = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                composing: markedText.length > 0 || markedTextBefore
            )
        }

        // After Ghostty processes Cmd+K (clear_screen), the scrollback buffer
        // is cleared but the viewport may still be scrolled up into what were
        // active screen rows. Ghostty's own SurfaceScrollView handles this via
        // scrollbar state notifications, but Watchtower doesn't use that component.
        // Snap the viewport to the bottom so there's nothing left to scroll to.
        if consumed,
           event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "k" {
            let action = "scroll_to_bottom"
            ghostty_surface_binding_action(
                surface,
                action,
                UInt(action.utf8.count)
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        if terminal.isCollapsed { return }
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if terminal.isCollapsed { return }

        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        if hasMarkedText() { return }

        let mods = ghosttyMods(event.modifierFlags)

        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                sidePressed = true
            }

            if sidePressed {
                action = GHOSTTY_ACTION_PRESS
            }
        }

        _ = keyAction(action, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }

        // When collapsed, block key equivalents from reaching the terminal.
        // Return false so menu shortcuts (Cmd+Shift+P, Cmd+L, etc.) still
        // propagate through the responder chain to the menu system.
        if terminal.isCollapsed { return false }

        guard focused else { return false }

        // Check for control key events that need special handling
        switch event.charactersIgnoringModifiers {
        case "\r":
            if !event.modifierFlags.contains(.control) {
                return false
            }
            let finalEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            )
            if let finalEvent = finalEvent {
                self.keyDown(with: finalEvent)
            }
            return true

        case "/":
            if event.modifierFlags.contains(.control) &&
               event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) {
                let finalEvent = NSEvent.keyEvent(
                    with: .keyDown,
                    location: event.locationInWindow,
                    modifierFlags: event.modifierFlags,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    characters: "_",
                    charactersIgnoringModifiers: "_",
                    isARepeat: event.isARepeat,
                    keyCode: event.keyCode
                )
                if let finalEvent = finalEvent {
                    self.keyDown(with: finalEvent)
                }
                return true
            }
            return false

        default:
            return false
        }
    }

    // MARK: - Key Action Helper

    @discardableResult
    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface = self.surface else { return false }

        var key_ev = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        key_ev.composing = composing

        if let text = text, text.count > 0,
           let codepoint = text.utf8.first, codepoint >= 0x20 {
            return text.withCString { ptr in
                key_ev.text = ptr
                return ghostty_surface_key(surface, key_ev)
            }
        } else {
            return ghostty_surface_key(surface, key_ev)
        }
    }

    // MARK: - Preedit / IME

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface = surface else { return }

        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: - NSTextInputClient

    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length - 1))
    }

    func selectedRange() -> NSRange {
        return NSRange()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            self.markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            self.markedText = NSMutableAttributedString(string: v)
        default:
            break
        }

        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface = self.surface else {
            return NSMakeRect(frame.origin.x, frame.origin.y, 0, 0)
        }

        var x: Double = 0
        var y: Double = 0
        var width: Double = cellSize.width
        var height: Double = cellSize.height

        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        // Convert from top-left to bottom-left coordinates
        let viewRect = NSMakeRect(x, frame.size.height - y, 0, max(height, cellSize.height))

        let winRect = self.convert(viewRect, to: nil)
        guard let window = self.window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }

        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        // Clear preedit state
        unmarkText()

        // If we're in keyDown, accumulate text
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        // Direct text insertion (outside keyDown)
        guard let surface = surface else { return }
        let len = chars.utf8CString.count
        if len > 1 { // > 1 because of null terminator
            chars.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(len - 1))
            }
        }
    }

    override func doCommand(by selector: Selector) {
        // Prevent NSBeep for unhandled commands
    }

    // MARK: - View Hierarchy Helpers

    /// Recursively find all GhosttyTerminalNSView instances in a view hierarchy.
    static func findAllTerminalViews(in view: NSView) -> [GhosttyTerminalNSView] {
        var results: [GhosttyTerminalNSView] = []
        if let tv = view as? GhosttyTerminalNSView {
            results.append(tv)
        }
        for subview in view.subviews {
            results.append(contentsOf: findAllTerminalViews(in: subview))
        }
        return results
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        // Make ourselves first responder on click
        window?.makeFirstResponder(self)

        guard let surface = surface else { return }
        let mods = ghosttyMods(event.modifierFlags)

        ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_PRESS,
            GHOSTTY_MOUSE_LEFT,
            mods
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        let mods = ghosttyMods(event.modifierFlags)

        ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_LEFT,
            mods
        )
    }

    override func mouseDragged(with event: NSEvent) {
        // Delegate to mouseMoved (matches reference implementation)
        self.mouseMoved(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface = surface else { return }
        // Convert to view-local coordinates (bottom-left origin)
        let loc = self.convert(event.locationInWindow, from: nil)
        let mods = ghosttyMods(event.modifierFlags)
        // Ghostty expects unscaled, top-left origin coordinates.
        // The embedded runtime scales by content scale factor internally.
        ghostty_surface_mouse_pos(surface, loc.x, frame.height - loc.y, mods)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let surface = surface else { return }
        let loc = self.convert(event.locationInWindow, from: nil)
        let mods = ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, loc.x, frame.height - loc.y, mods)
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface = surface else { return }
        // Skip exit if mouse is pressed (dragging across view boundary)
        if NSEvent.pressedMouseButtons != 0 { return }
        let mods = ghosttyMods(event.modifierFlags)
        // Sentinel (-1, -1) tells ghostty the cursor has left the viewport
        ghostty_surface_mouse_pos(surface, -1, -1, mods)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = surface else { return }
        let mods = ghosttyMods(event.modifierFlags)

        ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_PRESS,
            GHOSTTY_MOUSE_RIGHT,
            mods
        )
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        let mods = ghosttyMods(event.modifierFlags)

        ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_RIGHT,
            mods
        )
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surface else { return }

        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas

        if precision {
            // 2x speed multiplier (matches reference impl)
            y *= 2
        }

        // Build the scroll mods packed int:
        // bit 0 = precision, bits 1-3 = momentum phase
        var scrollMods: Int32 = 0
        if precision {
            scrollMods |= 0b0000_0001
        }
        // Map momentum phase
        let momentumVal: Int32
        switch event.momentumPhase {
        case .began: momentumVal = 1
        case .stationary: momentumVal = 2
        case .changed: momentumVal = 3
        case .ended: momentumVal = 4
        case .cancelled: momentumVal = 5
        case .mayBegin: momentumVal = 6
        default: momentumVal = 0
        }
        scrollMods |= momentumVal << 1

        // Only send vertical scroll to ghostty; forward the full event
        // up the responder chain so the parent ScrollView handles
        // horizontal pane-to-pane scrolling.
        ghostty_surface_mouse_scroll(
            surface,
            0,
            y,
            scrollMods
        )

        // Forward to the next responder so SwiftUI's horizontal
        // ScrollView receives the horizontal scroll delta.
        self.nextResponder?.scrollWheel(with: event)
    }

    override func updateTrackingAreas() {
        // Remove old tracking areas
        for area in trackingAreas {
            removeTrackingArea(area)
        }

        // Add new tracking area for mouse moved events
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }
}
