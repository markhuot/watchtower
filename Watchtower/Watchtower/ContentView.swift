import SwiftUI
import UniformTypeIdentifiers
import Combine
import WebKit

// MARK: - PendingFocus

/// A one-shot focus token. Represents "focus this pane when its view appears."
/// Used to eliminate double-async timing heuristics for first-responder management.
class PendingFocus {
    let paneId: UUID
    private(set) var fulfilled = false

    init(paneId: UUID) {
        self.paneId = paneId
    }

    /// Called by the NSView when it enters the window hierarchy.
    /// Returns true if this was the first call (focus should be claimed).
    @discardableResult
    func fulfill() -> Bool {
        guard !fulfilled else { return false }
        fulfilled = true
        return true
    }

    /// Cancel the pending focus (e.g., another focus request superseded this one).
    func cancel() {
        fulfilled = true
    }
}

struct ContentView: View {
    @StateObject private var viewModel = PaneContainerViewModel()
    @ObservedObject private var appManager = GhosttyAppManager.shared
    @State private var showCLIInstallSheet = false

    /// Ensures the CLI install prompt only shows once per app launch,
    /// even if multiple windows are opened.
    private static var hasShownCLIPrompt = false

    var body: some View {
        Group {
            if viewModel.panes.isEmpty {
                EmptyStateView(
                    onNewTerminal: {
                        let terminal = viewModel.addTerminal()
                        viewModel.focusPane(terminal)
                    },
                    onNewBrowser: {
                        viewModel.openNewBrowser()
                    }
                )
            } else {
                GeometryReader { geometry in
                    ScrollViewReader { scrollProxy in
                        ScrollView(.horizontal, showsIndicators: !viewModel.isFocusMode) {
                            HStack(spacing: 0) {
                                ForEach(viewModel.panes) { pane in
                                    FocusModeWrapper(
                                        pane: pane,
                                        viewModel: viewModel
                                    ) {
                                        PaneWithHandle(
                                            pane: pane,
                                            allPanes: viewModel.panes,
                                            viewModel: viewModel,
                                            windowWidth: geometry.size.width
                                        )
                                    }
                                    .compositingGroup()
                                    .opacity(pane.isClosing ? 0 : 1)
                                    .offset(y: pane.isClosing ? 20 : 0)
                                    .animation(.easeIn(duration: 0.25), value: pane.isClosing)
                                    .id(pane.id)
                                }
                            }
                            .padding(10)
                            .frame(minWidth: viewModel.isFullScreen ? geometry.size.width : nil)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Scroll to the focused pane when entering focus mode
                        .onChange(of: viewModel.isFocusMode) { isFocused in
                            if isFocused, let targetId = viewModel.focusModePaneId {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    scrollProxy.scrollTo(targetId, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
        }
        .background(appManager.backgroundColor.ignoresSafeArea())
        .focusedSceneValue(\.paneViewModel, viewModel)
        .onAppear {
            IPCServer.shared.register(viewModel)

            // Show CLI install prompt on first window only
            if !ContentView.hasShownCLIPrompt && CLIInstaller.shouldPrompt {
                ContentView.hasShownCLIPrompt = true
                showCLIInstallSheet = true
            }
        }
        .onDisappear {
            IPCServer.shared.unregister(viewModel)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttySurfaceClosed)) { notification in
            if let view = notification.object as? GhosttyTerminalNSView {
                let termId = view.terminal.id
                NSLog("[CLOSE-DEBUG] .ghosttySurfaceClosed received for terminal %@, panes.count=%d, paneIds=%@",
                      termId.uuidString, viewModel.panes.count,
                      viewModel.panes.map { $0.id.uuidString }.joined(separator: ", "))
                viewModel.removePane(byId: termId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserPaneClosed)) { notification in
            if let paneId = notification.userInfo?["paneId"] as? UUID {
                viewModel.removePane(byId: paneId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cefBrowserDidClose)) { notification in
            if let paneId = notification.userInfo?["paneId"] as? UUID {
                NSLog("[CEF-CLOSE] onReceive cefBrowserDidClose for pane %@, panes.count=%d", paneId.uuidString, viewModel.panes.count)
                viewModel.finishRemovingCEFPane(byId: paneId)
            } else {
                NSLog("[CEF-CLOSE] onReceive cefBrowserDidClose but no paneId in userInfo!")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Terminal") {
                        let terminal = viewModel.addTerminal()
                        viewModel.focusPane(terminal)
                    }

                    Button("New Browser") {
                        viewModel.openNewBrowser()
                    }

                    Divider()

                    // Project actions
                    ForEach(viewModel.projectActions) { action in
                        actionMenuButton(action)
                    }

                    // Separator between project and global actions
                    if !viewModel.projectActions.isEmpty && !viewModel.globalActions.isEmpty {
                        Divider()
                    }

                    // Global actions
                    ForEach(viewModel.globalActions) { action in
                        actionMenuButton(action)
                    }
                } label: {
                    Image(systemName: "plus")
                } primaryAction: {
                    viewModel.addContextualPane()
                }
            }
        }
        .sheet(isPresented: $viewModel.showActionDialog) {
            if let action = viewModel.pendingAction {
                ActionDialogView(
                    isPresented: $viewModel.showActionDialog,
                    action: action,
                    workingDirectory: viewModel.focusedDirectory,
                    onRun: { fieldValues in
                        viewModel.executeAction(action, withValues: fieldValues)
                    }
                )
            }
        }
        .sheet(isPresented: $showCLIInstallSheet) {
            CLIInstallSheet(isPresented: $showCLIInstallSheet)
        }
    }

    @ViewBuilder
    private func actionMenuButton(_ action: Action) -> some View {
        Button(action: {
            viewModel.triggerAction(action)
        }) {
            VStack(alignment: .leading) {
                Text(action.menuLabel)
                if let desc = action.descriptionText {
                    Text(desc)
                        .font(.caption)
                }
            }
        }
    }
}

// MARK: - EmptyStateView

/// Shown when no panes are open. Presents two centered buttons for creating
/// a new terminal or browser, each with an icon, title, and dimmed keyboard
/// shortcut hint.
struct EmptyStateView: View {
    var onNewTerminal: () -> Void
    var onNewBrowser: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            EmptyStateButton(
                icon: "terminal",
                title: "New Terminal",
                shortcut: "\u{21E7}\u{2318}T",
                action: onNewTerminal
            )
            EmptyStateButton(
                icon: "globe",
                title: "New Browser",
                shortcut: "\u{21E7}\u{2318}B",
                action: onNewBrowser
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateButton: View {
    let icon: String
    let title: String
    let shortcut: String
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Text(shortcut)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .frame(width: 170, height: 140)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovering ? Color.white.opacity(0.08) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isFocused ? Color.accentColor : Color.white.opacity(0.12), lineWidth: isFocused ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .foregroundColor(.white)
        .focused($isFocused)
        .modifier(FocusEffectDisabledModifier())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

/// Conditionally applies `.focusEffectDisabled()` on macOS 14+.
struct FocusEffectDisabledModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

// MARK: - FocusModeWrapper

/// Wraps a pane with focus-mode visual treatment (dimming, shadow)
/// without bloating the main ContentView body.
struct FocusModeWrapper<Content: View>: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject var viewModel: PaneContainerViewModel
    @ObservedObject private var appManager = GhosttyAppManager.shared
    let content: Content

    init(pane: PaneModel,
         viewModel: PaneContainerViewModel,
         @ViewBuilder content: () -> Content) {
        self.pane = pane
        self.viewModel = viewModel
        self.content = content()
    }

    private var isFocusModeTarget: Bool {
        viewModel.isFocusMode && pane.id == viewModel.focusModePaneId
    }

    var body: some View {
        content
            .overlay(focusModeDimOverlay)
            .shadow(
                color: isFocusModeTarget ? .black.opacity(0.6) : .clear,
                radius: isFocusModeTarget ? 24 : 0,
                x: 0, y: 0
            )
            .compositingGroup()
            .opacity(pane.isClosing ? 0 : 1)
            .offset(y: pane.isClosing ? 20 : 0)
            .animation(.easeIn(duration: pane.closeAnimationDuration), value: pane.isClosing)
    }

    @ViewBuilder
    private var focusModeDimOverlay: some View {
        if viewModel.isFocusMode && !isFocusModeTarget {
            appManager.backgroundColor.opacity(0.8)
                .allowsHitTesting(false)
        }
    }
}

/// A pane with a draggable resize handle on its right edge,
/// and drop-target indicators on both edges for reordering.
struct PaneWithHandle: View {
    @ObservedObject var pane: PaneModel
    let allPanes: [PaneModel]
    @ObservedObject var viewModel: PaneContainerViewModel
    let windowWidth: CGFloat

    /// The absolute X position of the mouse in window coordinates when the drag started,
    /// along with the pane width at that moment. Using absolute coordinates avoids the
    /// feedback loop where snap-to-grid moves the handle, which changes translation, which
    /// causes jittery resizing.
    @State private var dragAnchor: (startX: CGFloat, startWidth: CGFloat)? = nil

    /// Minimum pane width in points.
    private let minPaneWidth: CGFloat = 200

    /// Approximate cell width in points (matches PaneModel.defaultPaneWidth calculation).
    static let estimatedCellWidth: CGFloat = 9

    /// The effective width of this pane, accounting for focus mode and collapse state.
    /// When collapsed, the pane shrinks to a narrow strip.
    /// When this pane is the focus-mode target the pane content itself
    /// expands to the focus-mode minimum (which varies by pane type).
    private var effectiveWidth: CGFloat {
        if pane.isCollapsed {
            return PaneModel.collapsedPaneWidth
        }
        let isFocusModeTarget = viewModel.isFocusMode && pane.id == viewModel.focusModePaneId
        if isFocusModeTarget {
            return max(pane.paneWidth, pane.focusModeMinWidth(windowWidth: windowWidth))
        }
        return pane.paneWidth
    }

    /// Standard gap width between panes (3px indicator + 12px padding each side).
    private static let standardGapWidth: CGFloat = 27

    /// Narrow gap width used between two neighboring collapsed panes.
    private static let collapsedGapWidth: CGFloat = 15

    /// The current index of this pane in the array.
    private var index: Int {
        allPanes.firstIndex(where: { $0.id == pane.id }) ?? 0
    }

    /// The width of the gap to the right of this pane.
    /// When both this pane and the next pane are collapsed, the gap narrows
    /// to reduce visual clutter. During a drag reorder the gaps expand back
    /// to full width so drop targets are easy to hit.
    private var rightGapWidth: CGFloat {
        let isDragging = viewModel.draggedPaneId != nil
        if !isDragging,
           pane.isCollapsed,
           index + 1 < allPanes.count,
           allPanes[index + 1].isCollapsed {
            return Self.collapsedGapWidth
        }
        return Self.standardGapWidth
    }

    /// Whether the left-edge drop indicator should be shown for this pane.
    private var showLeftIndicator: Bool {
        guard let dropSlot = viewModel.dropTargetIndex,
              let dragId = viewModel.draggedPaneId,
              let dragIndex = allPanes.firstIndex(where: { $0.id == dragId }) else {
            return false
        }
        // Show left indicator on the first pane only when the drop slot is 0
        // and it's not a no-op (dragged pane is already at index 0 or 1)
        return index == 0 && dropSlot == 0 && dragIndex != 0
    }

    /// Whether the right-edge drop indicator should be shown for this pane.
    private var showRightIndicator: Bool {
        guard let dropSlot = viewModel.dropTargetIndex,
              let dragId = viewModel.draggedPaneId,
              let dragIndex = allPanes.firstIndex(where: { $0.id == dragId }) else {
            return false
        }
        // Don't show if dropping here would be a no-op
        // (the slot is immediately before or after the dragged pane's current position)
        let isNoOp = (dropSlot == dragIndex || dropSlot == dragIndex + 1)
        return dropSlot == index + 1 && !isNoOp
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left drop indicator (only for the first pane)
            if index == 0 {
                DropIndicatorView(isActive: showLeftIndicator, targetSlot: 0, viewModel: viewModel)
            }

            PaneView(pane: pane, viewModel: viewModel, onClose: {
                    viewModel.removePane(byId: pane.id)
                }, onDragStarted: {
                    viewModel.dragStarted(paneId: pane.id)
                }, onHeaderTapped: {
                    viewModel.focusPane(id: pane.id)
                }, onHeaderDoubleTapped: {
                    if pane.isCollapsed {
                        viewModel.focusPane(id: pane.id)
                    }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        pane.isCollapsed.toggle()
                    }
                })
                .frame(width: effectiveWidth)
                .animation(nil, value: pane.paneWidth)
                .animation(.easeInOut(duration: 0.2), value: pane.isCollapsed)
                .onDrop(of: [.text], delegate: PaneSplitDropDelegate(
                    paneIndex: index,
                    paneWidth: pane.paneWidth,
                    viewModel: viewModel
                ))

            // Gap between panes: drop indicator overlaid with a full-width resize handle.
            // The resize handle's hit area covers the entire gap so dragging can start
            // right at the pane edge.
            ZStack {
                // Drop indicator (visual only — the resize gesture on top takes priority)
                DropIndicatorView(isActive: showRightIndicator, targetSlot: index + 1, viewModel: viewModel)

                // Resize handle: invisible but covers the full gap for hit testing.
                // macOS 15+ uses pointerStyle (system-level cursor API that
                // can't be overridden by WKWebView's cursor management).
                // Older macOS falls back to onHover + NSCursor push/pop.
                Color.clear
                    .contentShape(Rectangle())
                    .modifier(ResizeCursorModifier())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                // On first event, record the mouse's absolute X and the
                                // current pane width. All subsequent events compute the
                                // delta from this fixed anchor, so the handle shifting
                                // never feeds back into the calc.
                                if dragAnchor == nil {
                                    dragAnchor = (startX: value.startLocation.x, startWidth: pane.paneWidth)
                                }

                                let anchor = dragAnchor!
                                let delta = value.location.x - anchor.startX
                                let newWidth = max(minPaneWidth, anchor.startWidth + delta)

                                // Check if option key is held
                                let optionHeld = NSEvent.modifierFlags.contains(.option)

                                if optionHeld {
                                    // Resize ALL panes to the same width
                                    for p in allPanes {
                                        p.paneWidth = newWidth
                                    }
                                } else {
                                    // Resize only this pane
                                    pane.paneWidth = newWidth
                                }
                            }
                            .onEnded { _ in
                                dragAnchor = nil
                            }
                    )
            }
            .frame(width: rightGapWidth)
            .animation(.easeInOut(duration: 0.2), value: rightGapWidth)
        }
    }
}

// MARK: - Resize Cursor Modifier

/// Sets the east-west resize cursor on the view.
/// On macOS 15+ uses the system `pointerStyle` API which integrates at
/// the window-server level and can't be overridden by WKWebView's cursor
/// management. On older macOS falls back to `onHover` + `NSCursor.push/pop`.
struct ResizeCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .pointerStyle(.frameResize(position: .trailing))
        } else {
            content
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        }
    }
}

// MARK: - Drop Delegate

/// Handles drag-and-drop for reordering panes.
/// Each drop zone (left/right half of a pane) creates one of these with its target slot index.
struct PaneDropDelegate: DropDelegate {
    let targetSlot: Int
    let viewModel: PaneContainerViewModel

    func dropEntered(info: DropInfo) {
        withAnimation(.easeInOut(duration: 0.15)) {
            viewModel.dropTargetIndex = targetSlot
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        viewModel.dropTargetIndex = targetSlot
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // Only clear if we're still pointing at this slot
        if viewModel.dropTargetIndex == targetSlot {
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.dropTargetIndex = nil
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedId = viewModel.draggedPaneId else { return false }

        viewModel.movePane(id: draggedId, toSlot: targetSlot)
        viewModel.cleanupDragState()

        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        return viewModel.draggedPaneId != nil
    }
}

/// Drop delegate placed on the full pane area.
/// Determines which half the cursor is in and routes to the correct slot.
struct PaneSplitDropDelegate: DropDelegate {
    let paneIndex: Int
    let paneWidth: CGFloat
    let viewModel: PaneContainerViewModel

    private func slotForLocation(_ info: DropInfo) -> Int {
        // info.location is in the coordinate space of the view the delegate is on.
        // Left half → slot before this pane, right half → slot after.
        if info.location.x < paneWidth / 2 {
            return paneIndex
        } else {
            return paneIndex + 1
        }
    }

    func dropEntered(info: DropInfo) {
        let slot = slotForLocation(info)
        withAnimation(.easeInOut(duration: 0.15)) {
            viewModel.dropTargetIndex = slot
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let slot = slotForLocation(info)
        if viewModel.dropTargetIndex != slot {
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.dropTargetIndex = slot
            }
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeInOut(duration: 0.15)) {
            viewModel.dropTargetIndex = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let slot = slotForLocation(info)
        guard let draggedId = viewModel.draggedPaneId else { return false }

        viewModel.movePane(id: draggedId, toSlot: slot)
        viewModel.cleanupDragState()

        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        return viewModel.draggedPaneId != nil
    }
}

// MARK: - Drop Indicator

/// A vertical indicator between panes that doubles as a drop target.
/// Always occupies the same space to prevent layout shift when dragging starts.
struct DropIndicatorView: View {
    let isActive: Bool
    let targetSlot: Int
    @ObservedObject var viewModel: PaneContainerViewModel

    @ObservedObject private var appManager = GhosttyAppManager.shared

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(isActive ? appManager.highlightColor : Color.clear)
            .frame(width: 3)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onDrop(of: [.text], delegate: PaneDropDelegate(
                targetSlot: targetSlot,
                viewModel: viewModel
            ))
            .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}

class PaneContainerViewModel: ObservableObject {
    @Published var panes: [PaneModel] = []

    /// The index of the slot where a dragged pane would be inserted.
    /// `nil` when no drag is active. 0 = before first pane, 1 = between first and second, etc.
    @Published var dropTargetIndex: Int? = nil

    /// The ID of the pane currently being dragged.
    @Published var draggedPaneId: UUID? = nil

    /// Whether focus mode is active. In focus mode the currently focused pane
    /// floats above all other panes as a centered overlay.
    @Published var isFocusMode: Bool = false

    /// The ID of the pane that was focused when focus mode was entered.
    /// Stored so that switching focus exits focus mode cleanly.
    @Published var focusModePaneId: UUID? = nil

    /// The git repo root for the currently focused terminal's directory.
    /// `nil` when not in a git repo.
    @Published var gitRepoRoot: String? = nil

    /// Discovered actions for the focused terminal's project.
    @Published var actions: [Action] = []

    /// The ID of the pane that the command palette is open on,
    /// or `nil` when the palette is closed. Stored explicitly so the
    /// palette stays visible even when the NSTextField steals first
    /// responder from the terminal's NSView (which clears isFocused).
    @Published var commandPalettePaneId: UUID? = nil

    /// When non-nil, the command palette's text field is pre-filled with
    /// this string on next open (e.g. the current browser URL for Cmd+L).
    /// Cleared by `dismissCommandPalette`.
    @Published var commandPaletteInitialText: String? = nil

    /// When set, the next NSView matching this pane ID to enter the window
    /// hierarchy will claim first responder. Setting a new value automatically
    /// cancels the previous one via `didSet`, preventing races.
    var pendingFocus: PendingFocus? {
        didSet { oldValue?.cancel() }
    }

    /// Monotonically increasing counter bumped every time `focusPane` is
    /// called. Used by `dismissCommandPalette` to detect whether an action
    /// explicitly requested focus (in which case dismiss should not override it).
    private(set) var focusGeneration: UInt = 0

    /// Convenience: whether the command palette is currently visible.
    var isCommandPalettePresented: Bool {
        commandPalettePaneId != nil
    }

    /// Whether the window is in macOS native fullscreen mode.
    @Published var isFullScreen: Bool = false

    /// Whether the action dialog is shown.
    @Published var showActionDialog: Bool = false

    /// The action pending user input (shown in the dialog).
    @Published var pendingAction: Action? = nil

    /// Project-specific actions (non-global).
    var projectActions: [Action] {
        actions.filter { !$0.isGlobal }
    }

    /// Global actions.
    var globalActions: [Action] {
        actions.filter { $0.isGlobal }
    }

    /// The pane that should provide context for actions and other operations.
    /// Checks the command palette's pane first (since its NSTextField steals
    /// first responder, no pane has `isFocused == true` while the palette is
    /// open), then falls back to the actually focused pane.
    var contextualPane: PaneModel? {
        if let paletteId = commandPalettePaneId,
           let p = panes.first(where: { $0.id == paletteId }) {
            return p
        }
        return panes.first(where: { $0.isFocused })
    }

    /// The contextual pane's current working directory.
    /// Returns the home directory when no pane is focused or
    /// when the focused pane has no directory (e.g. browser panes).
    var focusedDirectory: String {
        contextualPane?.directory ?? NSHomeDirectory()
    }

    /// Event monitor for detecting when a drag session ends (mouse up).
    private var dragEndMonitor: Any? = nil

    /// Event monitor that forwards horizontal scroll events from browser
    /// panes to the parent horizontal ScrollView. WKWebView captures all
    /// scroll events (breaking pane-to-pane scrolling), so we use a local
    /// event monitor to programmatically scroll the parent when we see
    /// horizontal delta over a browser pane. The monitor does NOT consume
    /// the event — WKWebView still sees it for vertical scrolling.
    private var browserScrollMonitor: Any? = nil

    /// Subject that emits the currently focused pane. Used to drive
    /// the `switchToLatest` pipeline that tracks the focused pane's
    /// directory for git detection and action discovery.
    private let focusedPaneSubject = CurrentValueSubject<PaneModel?, Never>(nil)

    /// Bag holding the Combine pipeline subscriptions.
    private var cancellables = Set<AnyCancellable>()

    /// In-flight git detection task, cancelled when focus/directory changes.
    private var gitDetectionTask: Task<Void, Never>? = nil

    /// In-flight action discovery task, cancelled when focus/directory changes.
    private var actionDiscoveryTask: Task<Void, Never>? = nil

    init() {
        // Set up a Combine pipeline that:
        // 1. Watches which pane is focused (via focusedPaneSubject)
        // 2. For terminal panes, switchToLatest subscribes to $terminalDirectory
        // 3. On each new directory, runs git detection and action discovery
        // 4. For non-terminal panes (e.g. browser), emits nil to clear state
        focusedPaneSubject
            .compactMap { $0 }
            .map { pane -> AnyPublisher<String?, Never> in
                if let terminal = pane as? TerminalPaneModel {
                    return terminal.$terminalDirectory
                        .removeDuplicates()
                        .map { Optional($0) }
                        .eraseToAnyPublisher()
                } else {
                    // Non-terminal panes have no directory
                    return Just(nil as String?).eraseToAnyPublisher()
                }
            }
            .switchToLatest()
            .sink { [weak self] directory in
                if let directory = directory {
                    self?.detectGitRepo(for: directory)
                    self?.discoverActions(for: directory)
                } else {
                    // Browser pane or no directory — clear git/actions
                    self?.gitDetectionTask?.cancel()
                    self?.gitRepoRoot = nil
                    self?.actionDiscoveryTask?.cancel()
                    self?.actions = []
                }
            }
            .store(in: &cancellables)

        // Also handle the nil case (no focused pane) to clear state
        focusedPaneSubject
            .filter { $0 == nil }
            .sink { [weak self] _ in
                self?.gitDetectionTask?.cancel()
                self?.gitRepoRoot = nil
                self?.actionDiscoveryTask?.cancel()
                self?.actions = []
            }
            .store(in: &cancellables)

        // App starts empty — the EmptyStateView offers buttons to create panes.

        // Install a local event monitor that watches scroll wheel events.
        // When the mouse is over a WKWebView (browser pane), WKWebView
        // captures all scroll events — the horizontal component never
        // reaches the parent horizontal ScrollView that manages
        // pane-to-pane scrolling. This monitor detects that situation and
        // programmatically scrolls the parent NSScrollView.
        browserScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleBrowserHorizontalScroll(event)
            return event  // always pass through — don't break WKWebView's vertical scrolling
        }

        // Track macOS native fullscreen state
        NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)
            .sink { [weak self] _ in self?.isFullScreen = true }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)
            .sink { [weak self] _ in self?.isFullScreen = false }
            .store(in: &cancellables)
    }

    deinit {
        if let monitor = dragEndMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = browserScrollMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Browser horizontal scroll forwarding

    /// Called by the local scroll-wheel event monitor. Detects when the
    /// mouse is over a WKWebView and programmatically scrolls the parent
    /// horizontal NSScrollView by the event's horizontal delta.
    ///
    /// WKWebView captures all scroll events internally, so horizontal
    /// trackpad gestures never reach the parent ScrollView. This method
    /// reads the horizontal delta from each event and applies it to the
    /// parent's clip view, giving the user pane-to-pane scrolling even
    /// when the mouse is over a browser pane. The event itself is NOT
    /// consumed — WKWebView still receives it for vertical scrolling.
    private func handleBrowserHorizontalScroll(_ event: NSEvent) {
        // Only care about events with a horizontal component.
        guard event.scrollingDeltaX != 0 else { return }

        // Determine the window and the view under the mouse.
        guard let window = event.window else { return }
        let locationInWindow = event.locationInWindow
        guard let hitView = window.contentView?.hitTest(locationInWindow) else { return }

        // Check if the hit view is (or is inside) a WKWebView or
        // ChromiumBrowserView. If not, the parent horizontal ScrollView
        // handles scrolling natively.
        guard hitView.isOrHasAncestor(ofType: WKWebView.self) ||
              hitView.isOrHasAncestor(ofType: ChromiumBrowserView.self) else { return }

        // Find the parent horizontal NSScrollView (the one backing
        // SwiftUI's ScrollView(.horizontal)).
        guard let parentScrollView = findHorizontalScrollView(from: hitView) else { return }

        let clipView = parentScrollView.contentView
        guard let documentView = parentScrollView.documentView else { return }

        var dx = event.scrollingDeltaX
        if event.hasPreciseScrollingDeltas {
            // Trackpad: delta is already in points. Negate because positive
            // deltaX = "scroll content left" but we need to increase origin.x.
            dx = -dx
        } else {
            // Mouse wheel: delta is in "lines", scale up.
            dx = -dx * 10
        }

        var newOrigin = clipView.bounds.origin
        newOrigin.x += dx

        // Clamp to valid range.
        let maxScrollX = max(0, documentView.frame.width - clipView.bounds.width)
        newOrigin.x = min(max(0, newOrigin.x), maxScrollX)

        clipView.setBoundsOrigin(newOrigin)
        parentScrollView.reflectScrolledClipView(clipView)
    }

    /// Walk up the view hierarchy from `view` to find the horizontal
    /// NSScrollView that backs SwiftUI's `ScrollView(.horizontal)`.
    /// Skips any NSScrollView that belongs to WKWebView's internals.
    private func findHorizontalScrollView(from view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let v = current {
            if let sv = v as? NSScrollView {
                // WKWebView and ChromiumBrowserView contain internal
                // NSScrollViews — skip those. The parent horizontal scroll
                // view is the one whose documentView is wider than the clip
                // view (SwiftUI sets this up).
                let isWebKitInternal = sv.isOrHasAncestor(ofType: WKWebView.self)
                let isChromiumInternal = sv.isOrHasAncestor(ofType: ChromiumBrowserView.self)
                if !isWebKitInternal && !isChromiumInternal {
                    return sv
                }
            }
            current = v.superview
        }
        return nil
    }

    /// Call when a drag session begins to install cleanup monitoring.
    func dragStarted(paneId: UUID) {
        draggedPaneId = paneId

        // Install a one-shot local event monitor that cleans up drag state
        // when the mouse button is released (drag session ends).
        if dragEndMonitor == nil {
            dragEndMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                // Delay cleanup slightly so performDrop can fire first
                DispatchQueue.main.async {
                    self?.cleanupDragState()
                }
                return event
            }
        }
    }

    /// Reset all drag-related state.
    func cleanupDragState() {
        dropTargetIndex = nil
        draggedPaneId = nil
        for pane in panes {
            pane.isDragging = false
        }
        if let monitor = dragEndMonitor {
            NSEvent.removeMonitor(monitor)
            dragEndMonitor = nil
        }
    }

    /// Toggle focus mode on the currently focused pane.
    /// If focus mode is already active, it is deactivated.
    func toggleFocusMode() {
        if isFocusMode {
            withAnimation(.easeInOut(duration: 0.2)) {
                isFocusMode = false
                focusModePaneId = nil
            }
        } else {
            guard let focused = contextualPane else { return }
            focusModePaneId = focused.id
            withAnimation(.easeInOut(duration: 0.2)) {
                isFocusMode = true
            }
        }
    }

    // MARK: - Command Palette

    /// Toggle the command palette on/off.
    /// If the focused pane is collapsed, auto-expand it first so the
    /// palette has enough room to render.
    func toggleCommandPalette() {
        if isCommandPalettePresented {
            dismissCommandPalette()
        } else {
            // Open the palette on the currently focused pane
            if let focused = panes.first(where: { $0.isFocused }) {
                if focused.isCollapsed {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        focused.isCollapsed = false
                    }
                }
                commandPalettePaneId = focused.id
            }
        }
    }

    /// Open the command palette pre-filled with the focused browser's URL.
    /// If the focused pane is not a browser the palette opens normally.
    /// If the palette is already open, it is dismissed instead (toggle).
    /// Auto-expands the pane if it is collapsed.
    func focusCommandPalette() {
        if isCommandPalettePresented {
            dismissCommandPalette()
            return
        }
        if let browser = panes.first(where: { $0.isFocused }) as? BrowserPaneModel {
            commandPaletteInitialText = browser.url.absoluteString
        }
        if let focused = panes.first(where: { $0.isFocused }) {
            if focused.isCollapsed {
                withAnimation(.easeInOut(duration: 0.2)) {
                    focused.isCollapsed = false
                }
            }
            commandPalettePaneId = focused.id
        }
    }

    /// Dismiss the command palette. If no `focusPane` call was made since
    /// `beforeGeneration` was captured, focus is restored to the pane that
    /// had the palette. If an action called `focusPane()` (bumping the
    /// generation), the action's focus request is preserved.
    ///
    /// When called without a generation (e.g. Esc, click-to-dismiss),
    /// focus is always restored to the original pane.
    func dismissCommandPalette(beforeGeneration: UInt? = nil) {
        guard let paneId = commandPalettePaneId else { return }
        commandPalettePaneId = nil  // tear down the palette UI
        commandPaletteInitialText = nil  // clear any pre-filled text
        // Restore focus unless an action explicitly called focusPane()
        if beforeGeneration == nil || focusGeneration == beforeGeneration {
            focusPaneById(paneId)
        }
    }

    /// Close the currently focused pane.
    /// If an active session is running, shows a confirmation alert first.
    /// When the last pane is closed, the empty state is shown.
    func closeCurrentPane() {
        guard let focusedPane = contextualPane else { return }
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else { return }

        if let terminal = focusedPane as? TerminalPaneModel {
            // Terminal pane — check for active session
            let terminalViews = GhosttyTerminalNSView.findAllTerminalViews(in: contentView)
            if let targetView = terminalViews.first(where: { $0.terminal.id == terminal.id }),
               let surface = targetView.surface,
               ghostty_surface_needs_confirm_quit(surface) {
                let alert = NSAlert()
                alert.messageText = "Close Terminal?"
                alert.informativeText = "This terminal has an active session. Closing it will terminate the session."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Close")
                alert.addButton(withTitle: "Cancel")
                alert.beginSheetModal(for: window) { [weak self] response in
                    if response == .alertFirstButtonReturn {
                        self?.removePane(byId: focusedPane.id)
                    }
                }
            } else {
                removePane(byId: focusedPane.id)
            }
        } else if let browser = focusedPane as? BrowserPaneModel {
            // Browser pane — check for form interaction
            if browser.hasInteractedForms {
                let alert = NSAlert()
                alert.messageText = "Close Browser Pane?"
                alert.informativeText = "There are unsaved changes on this page that will be lost."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Close")
                alert.addButton(withTitle: "Cancel")
                alert.beginSheetModal(for: window) { [weak self] response in
                    if response == .alertFirstButtonReturn {
                        self?.removePane(byId: focusedPane.id)
                    }
                }
            } else {
                removePane(byId: focusedPane.id)
            }
        } else {
            removePane(byId: focusedPane.id)
        }
    }

    /// Close all panes to the right of the currently focused pane.
    /// Does nothing if the focused pane is already the last pane.
    func closePanesToTheRight() {
        guard let focusedPane = contextualPane,
              let currentIndex = panes.firstIndex(where: { $0.id == focusedPane.id }) else { return }

        let rightPanes = Array(panes.suffix(from: currentIndex + 1))
        guard !rightPanes.isEmpty else { return }

        // Exit focus mode if the focus-mode target is one of the panes being removed
        if let fmId = focusModePaneId,
           rightPanes.contains(where: { $0.id == fmId }) {
            exitFocusMode()
        }

        // Determine animation duration (hold Shift for slow-motion)
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        let duration: TimeInterval = shiftHeld ? 3.0 : 0.2

        // Start close animation on all right panes
        withAnimation(.easeIn(duration: duration)) {
            for pane in rightPanes {
                pane.closeAnimationDuration = duration
                pane.isClosing = true
            }
        }

        // Ensure the current pane is focused
        focusPane(focusedPane)

        // Initiate CEF close for any Chromium browser panes.
        // They will be removed asynchronously when on_before_close fires.
        var chromiumPaneIds = Set<UUID>()
        for pane in rightPanes {
            if let browser = pane as? BrowserPaneModel,
               browser.engine == .chromium,
               !browser.isClosingCEF {
                browser.isClosingCEF = true
                if let chromiumView = browser.engineView as? ChromiumBrowserView {
                    chromiumView.closeCEFBrowser()
                }
                chromiumPaneIds.insert(pane.id)
            }
        }

        // Remove non-Chromium panes after the animation finishes.
        // Chromium panes stay until finishRemovingCEFPane is called.
        let nonChromiumIds = rightPanes.filter { !chromiumPaneIds.contains($0.id) }.map { $0.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self else { return }
            for id in nonChromiumIds {
                if let index = self.panes.firstIndex(where: { $0.id == id }) {
                    self.panes.remove(at: index)
                }
            }
        }
    }

    /// Exit focus mode if it is currently active.
    func exitFocusMode() {
        guard isFocusMode else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isFocusMode = false
            focusModePaneId = nil
        }
    }

    /// Toggle the collapsed state of the currently focused pane.
    func toggleCollapsePane() {
        guard let pane = contextualPane else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            pane.isCollapsed.toggle()
        }
    }

    /// Collapse the currently focused pane (no-op if already collapsed).
    func collapsePane() {
        guard let pane = contextualPane, !pane.isCollapsed else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            pane.isCollapsed = true
        }
    }

    /// Expand the currently focused pane (no-op if already expanded).
    func expandPane() {
        guard let pane = contextualPane, pane.isCollapsed else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            pane.isCollapsed = false
        }
    }

    @discardableResult
    func addTerminal(directory: String? = nil, initialInput: String? = nil) -> TerminalPaneModel {
        // Inherit the working directory and pane width from the contextual
        // pane, falling back to defaults when nothing is focused.
        let sourcePane = contextualPane
        let resolvedDirectory = directory
            ?? sourcePane?.directory
            ?? NSHomeDirectory()
        let paneWidth = sourcePane?.paneWidth ?? PaneModel.defaultPaneWidth

        let terminal = TerminalPaneModel(
            id: UUID(),
            title: "Terminal \(panes.count + 1)",
            status: .active,
            directory: resolvedDirectory,
            paneWidth: paneWidth,
            initialInput: initialInput
        )
        terminal.viewModel = self

        // Insert after the contextual pane, or append at the end if none is focused
        if let source = sourcePane,
           let sourceIndex = panes.firstIndex(where: { $0.id == source.id }) {
            panes.insert(terminal, at: sourceIndex + 1)
        } else {
            panes.append(terminal)
        }

        return terminal
    }

    @discardableResult
    func addBrowser(url: URL = URL(string: "about:blank")!, engine: BrowserEngine? = nil) -> BrowserPaneModel {
        let sourcePane = contextualPane
        let paneWidth = sourcePane?.paneWidth ?? PaneModel.defaultPaneWidth

        let browser = BrowserPaneModel(url: url, paneWidth: paneWidth, engine: engine ?? WatchtowerConfig.shared.browserEngine)
        browser.viewModel = self

        // Insert after the contextual pane, or append at the end if none is focused
        if let source = sourcePane,
           let sourceIndex = panes.firstIndex(where: { $0.id == source.id }) {
            panes.insert(browser, at: sourceIndex + 1)
        } else {
            panes.append(browser)
        }

        return browser
    }

    /// Create a new blank browser pane, focus it, and immediately open
    /// the command palette so the user can type a URL right away.
    @discardableResult
    func openNewBrowser(engine: BrowserEngine? = nil) -> BrowserPaneModel {
        let browser = addBrowser(engine: engine)
        focusPane(browser)
        commandPalettePaneId = browser.id
        // Cancel the pending focus so the browser NSView doesn't steal
        // first responder from the command palette's text field.
        pendingFocus = nil
        return browser
    }

    /// Create a new pane matching the type of the currently focused pane.
    /// If a browser is focused a new browser is created; otherwise a new
    /// terminal is created. The new pane is automatically focused.
    func addContextualPane() {
        if contextualPane is BrowserPaneModel {
            openNewBrowser()
        } else {
            let terminal = addTerminal()
            focusPane(terminal)
        }
    }

    /// Move a pane from its current position to a new slot index.
    /// `toSlot` is in pre-removal coordinates (0 = before first, count = after last).
    func movePane(id: UUID, toSlot slot: Int) {
        guard let fromIndex = panes.firstIndex(where: { $0.id == id }) else { return }

        // Determine the actual destination index after removal
        var destIndex = slot
        if slot > fromIndex {
            // Account for the item being removed before insertion
            destIndex -= 1
        }
        destIndex = max(0, min(destIndex, panes.count - 1))

        guard destIndex != fromIndex else { return }

        let pane = panes.remove(at: fromIndex)
        panes.insert(pane, at: destIndex)
    }

    func removePane(byId id: UUID) {
        let backtrace = Thread.callStackSymbols.joined(separator: "\n")
        NSLog("[CEF-CLOSE] removePane(byId: %@) called, panes.count=%d\n  backtrace:\n%@",
              id.uuidString, panes.count, backtrace)

        // Exit focus mode if the removed pane was the focus-mode target
        if id == focusModePaneId {
            exitFocusMode()
        }

        guard let index = panes.firstIndex(where: { $0.id == id }) else {
            NSLog("[CEF-CLOSE] removePane: pane %@ not found in array!", id.uuidString)
            return
        }

        // Don't re-trigger if already closing
        guard !panes[index].isClosing else { return }

        // Determine animation duration (hold Shift for slow-motion)
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        let duration: TimeInterval = shiftHeld ? 3.0 : 0.2
        panes[index].closeAnimationDuration = duration

        // For Chromium browser panes, we must let CEF finish its async close
        // sequence before removing the pane from the array. Removing the pane
        // immediately tears down the NSView hierarchy while the CrBrowserMain
        // thread is still using it, causing EXC_BREAKPOINT.
        if let browser = panes[index] as? BrowserPaneModel,
           browser.engine == .chromium,
           !browser.isClosingCEF {
            NSLog("[CEF-CLOSE] removePane: initiating two-phase close for Chromium pane %@", id.uuidString)
            browser.isClosingCEF = true
            // Start close animation alongside CEF shutdown
            withAnimation(.easeIn(duration: duration)) {
                panes[index].isClosing = true
            }
            // Focus neighbor immediately so the user isn't left on the dying pane
            if panes.count > 1 {
                let focusIndex = index > 0 ? index - 1 : 1
                focusPaneById(panes[focusIndex].id)
            }
            // Initiate CEF's close sequence. The pane stays in the array
            // (and the view stays in the hierarchy) until on_before_close
            // fires and posts .cefBrowserDidClose, which calls
            // finishRemovingCEFPane(byId:).
            if let chromiumView = browser.engineView as? ChromiumBrowserView {
                chromiumView.closeCEFBrowser()
            } else {
                NSLog("[CEF-CLOSE] removePane: WARNING engineView is not ChromiumBrowserView!")
            }
            return
        }

        NSLog("[CEF-CLOSE] removePane: removing non-Chromium pane %@ at index %d", id.uuidString, index)

        // Start close animation, then remove after it completes
        withAnimation(.easeIn(duration: duration)) {
            panes[index].isClosing = true
        }

        // Focus neighbor immediately so the user isn't left on the dying pane
        if panes.count > 1 {
            let focusIndex = index > 0 ? index - 1 : 1
            focusPaneById(panes[focusIndex].id)
        }

        // Remove the pane from the array after the animation finishes
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self else { return }
            guard let removeIndex = self.panes.firstIndex(where: { $0.id == id }) else { return }
            self.panes.remove(at: removeIndex)
        }
    }

    /// Called when CEF's `on_before_close` fires, signaling the browser is
    /// fully shut down. Now it is safe to remove the pane from the array,
    /// which will trigger SwiftUI to dismantle the NSView.
    func finishRemovingCEFPane(byId id: UUID) {
        let backtrace = Thread.callStackSymbols.joined(separator: "\n")
        NSLog("[CEF-CLOSE] finishRemovingCEFPane(byId: %@) called, panes.count=%d\n  backtrace:\n%@",
              id.uuidString, panes.count, backtrace)

        guard let index = panes.firstIndex(where: { $0.id == id }) else {
            NSLog("[CEF-CLOSE] finishRemovingCEFPane: pane %@ not found in array!", id.uuidString)
            return
        }

        // Exit focus mode if the removed pane was the focus-mode target
        if id == focusModePaneId {
            exitFocusMode()
        }

        // The close animation was already started in removePane(byId:).
        // If CEF closed faster than 250ms the animation may still be in
        // flight — that's fine, removing the view mid-animation is smooth.

        // Focus neighbor and remove from array
        if panes.count > 1 {
            let focusIndex = index > 0 ? index - 1 : 1
            let neighborId = panes[focusIndex].id
            NSLog("[CEF-CLOSE] finishRemovingCEFPane: removing pane at index %d, focusing %@", index, neighborId.uuidString)
            panes.remove(at: index)
            focusPaneById(neighborId)
        } else {
            NSLog("[CEF-CLOSE] finishRemovingCEFPane: removing last pane at index %d", index)
            panes.remove(at: index)
        }
        NSLog("[CEF-CLOSE] finishRemovingCEFPane: done, panes.count=%d", panes.count)
    }

    func focusPreviousPane() {
        let currentPane = contextualPane
        guard panes.count > 1 else { return }
        let currentIndex: Int
        if let p = currentPane, let idx = panes.firstIndex(where: { $0.id == p.id }) {
            currentIndex = idx
        } else {
            currentIndex = 0
        }
        let newIndex = (currentIndex - 1 + panes.count) % panes.count
        focusPane(panes[newIndex])
    }

    func focusNextPane() {
        let currentPane = contextualPane
        guard panes.count > 1 else { return }
        let currentIndex: Int
        if let p = currentPane, let idx = panes.firstIndex(where: { $0.id == p.id }) {
            currentIndex = idx
        } else {
            currentIndex = 0
        }
        let newIndex = (currentIndex + 1) % panes.count
        focusPane(panes[newIndex])
    }

    /// Swap the focused pane one position to the left (wrapping around).
    func movePaneLeft() {
        guard panes.count > 1 else { return }
        guard let pane = contextualPane,
              let currentIndex = panes.firstIndex(where: { $0.id == pane.id }) else { return }
        let destIndex = (currentIndex - 1 + panes.count) % panes.count
        guard destIndex != currentIndex else { return }
        panes.swapAt(currentIndex, destIndex)
        focusPane(pane)
    }

    /// Resize all panes so they fit side-by-side within the window width.
    /// Accounts for outer padding, drop indicators, inter-pane gaps,
    /// and collapsed panes (which occupy a fixed narrow width).
    func fitPanesToWindow() {
        guard !panes.isEmpty else { return }
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else { return }

        let windowWidth = contentView.frame.width

        // Compute the total gap/chrome budget by walking the pane list.
        //   outer padding: 10 left + 10 right = 20
        //   first-pane left drop indicator: 27 (standardGapWidth)
        //   each pane's right gap: 27 normally, but 15 when both this
        //   pane and the next pane are collapsed.
        let standardGap: CGFloat = 27
        let collapsedGap: CGFloat = 15
        var chrome: CGFloat = 20 + standardGap  // outer padding + left indicator
        for (i, pane) in panes.enumerated() {
            // Each pane contributes a right-side gap
            if pane.isCollapsed,
               i + 1 < panes.count,
               panes[i + 1].isCollapsed {
                chrome += collapsedGap
            } else {
                chrome += standardGap
            }
        }

        // Subtract the fixed width of collapsed panes from the available space.
        let collapsedWidth = CGFloat(panes.filter { $0.isCollapsed }.count) * PaneModel.collapsedPaneWidth
        let expandedPanes = panes.filter { !$0.isCollapsed }
        let available = windowWidth - chrome - collapsedWidth

        if expandedPanes.isEmpty {
            // All panes are collapsed — nothing to resize.
            return
        }

        let perPane = max(200, available / CGFloat(expandedPanes.count))

        for pane in expandedPanes {
            pane.paneWidth = perPane
        }
    }

    /// Swap the focused pane one position to the right (wrapping around).
    func movePaneRight() {
        guard panes.count > 1 else { return }
        guard let pane = contextualPane,
              let currentIndex = panes.firstIndex(where: { $0.id == pane.id }) else { return }
        let destIndex = (currentIndex + 1) % panes.count
        guard destIndex != currentIndex else { return }
        panes.swapAt(currentIndex, destIndex)
        focusPane(pane)
    }

    /// Focus a pane by its ID (e.g. when the header is clicked).
    func focusPane(id: UUID) {
        guard let pane = panes.first(where: { $0.id == id }) else { return }
        focusPane(pane)
    }

    /// Focus a pane. If the NSView is already in the hierarchy, focus it
    /// immediately and fulfill the token. If not (just created), the token
    /// remains pending and viewDidMoveToWindow will pick it up.
    func focusPane(_ pane: PaneModel) {
        // Auto-dismiss the command palette when focus moves to a different pane.
        if let paletteId = commandPalettePaneId, paletteId != pane.id {
            commandPalettePaneId = nil
        }

        // Explicitly clear isFocused on all other panes. Normally this is
        // handled by resignFirstResponder on the NSView, but when a pane is
        // collapsed its NSView has been removed from the hierarchy and
        // resignFirstResponder will never fire, leaving stale isFocused state.
        for p in panes where p.id != pane.id {
            p.isFocused = false
        }

        // Reactive focus-mode update: when focus mode is active, the spotlight
        // follows the focused pane so it never drifts out of sync.
        if isFocusMode {
            focusModePaneId = pane.id
        }

        // Update the Combine pipeline for git detection / action discovery
        focusedPaneSubject.send(pane)

        // Bump the generation so dismissCommandPalette can detect that
        // an action explicitly requested focus.
        focusGeneration &+= 1

        // Set pendingFocus — cancels any prior pending focus via didSet
        pendingFocus = PendingFocus(paneId: pane.id)

        // Try immediate focus (view already in hierarchy)
        if makeFocusedImmediate(pane: pane) {
            pendingFocus?.fulfill()
            pendingFocus = nil
            return
        }

        // View doesn't exist yet (just added to panes array).
        // viewDidMoveToWindow on the NSView will check pendingFocus
        // and claim first responder when it enters the window.
        //
        // Single-async fallback for the case where the view IS in the
        // hierarchy but the command palette's NSTextField hasn't resigned
        // first responder yet (its teardown is asynchronous).
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let pending = self.pendingFocus,
                  pending.paneId == pane.id,
                   !pending.fulfilled else {
                return
            }
            if self.makeFocusedImmediate(pane: pane) {
                pending.fulfill()
                self.pendingFocus = nil
            }
        }
    }

    /// Convenience for focusing by ID (used by dismissCommandPalette).
    func focusPaneById(_ id: UUID) {
        guard let pane = panes.first(where: { $0.id == id }) else { return }
        focusPane(pane)
    }

    /// Try to find the pane's NSView in the hierarchy and make it first
    /// responder. Returns true if successful.
    @discardableResult
    private func makeFocusedImmediate(pane: PaneModel) -> Bool {
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else {
            return false
        }

        if pane is TerminalPaneModel {
            let allViews = GhosttyTerminalNSView.findAllTerminalViews(in: contentView)
            if let targetView = allViews.first(where: { $0.terminal.id == pane.id }) {
                window.makeFirstResponder(targetView)
                return true
            }
        } else if pane is BrowserPaneModel {
            if let engineView = findBrowserEngineView(for: pane.id, in: contentView) {
                window.makeFirstResponder(engineView)
                return true
            }
        }
        return false
    }

    /// Walk the view hierarchy to find a BrowserEngineView associated with a pane ID.
    private func findBrowserEngineView(for paneId: UUID, in view: NSView) -> (any BrowserEngineView)? {
        if let webView = view as? WatchtowerWebView,
           webView.browser?.id == paneId {
            return webView
        }
        if let chromiumView = view as? ChromiumBrowserView,
           chromiumView.browser?.id == paneId {
            return chromiumView
        }
        for subview in view.subviews {
            if let found = findBrowserEngineView(for: paneId, in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Git Detection

    /// Run git detection for the given directory.
    private func detectGitRepo(for directory: String) {
        gitDetectionTask?.cancel()
        gitDetectionTask = Task { @MainActor in
            let root = await WorkspaceManager.detectGitRepoRoot(for: directory)
            if !Task.isCancelled {
                self.gitRepoRoot = root
            }
        }
    }

    // MARK: - Action Discovery

    /// Discover actions for the given directory.
    private func discoverActions(for directory: String) {
        actionDiscoveryTask?.cancel()
        actionDiscoveryTask = Task { @MainActor in
            let discovered = await Task.detached {
                ActionDiscovery.discoverActions(for: directory)
            }.value
            if !Task.isCancelled {
                self.actions = discovered
            }
        }
    }

    // MARK: - Action Execution

    /// Trigger an action. If it has arguments, show the dialog; otherwise execute immediately.
    func triggerAction(_ action: Action) {
        if action.hasArguments {
            pendingAction = action
            showActionDialog = true
        } else {
            executeAction(action, withValues: [:])
        }
    }

    /// Execute an action with the given field values.
    func executeAction(_ action: Action, withValues values: [String: String]) {
        guard let command = ActionInterpreter.buildCommand(for: action) else { return }

        let sourcePane = contextualPane
        let directory = sourcePane?.directory ?? NSHomeDirectory()
        let paneWidth = sourcePane?.paneWidth ?? PaneModel.defaultPaneWidth

        // Build environment variables
        var env: [String: String] = values
        env["WATCHTOWER_GIT_ROOT"] = gitRepoRoot ?? ""
        env["WATCHTOWER_ACTION"] = action.id  // filename

        let terminal = TerminalPaneModel(
            id: UUID(),
            title: action.displayName,
            status: .active,
            directory: directory,
            paneWidth: paneWidth,
            command: command,
            env: env,
            waitAfterCommand: true
        )
        terminal.viewModel = self

        // Insert after the contextual pane
        if let source = sourcePane,
           let sourceIndex = panes.firstIndex(where: { $0.id == source.id }) {
            panes.insert(terminal, at: sourceIndex + 1)
        } else {
            panes.append(terminal)
        }

        // Focus the new terminal
        focusPane(terminal)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
