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


    var body: some View {
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
                            .id(pane.id)
                        }
                    }
                    .padding(10)
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
        .background(appManager.backgroundColor.ignoresSafeArea())
        .focusedSceneValue(\.paneViewModel, viewModel)
        .onReceive(NotificationCenter.default.publisher(for: .ghosttySurfaceClosed)) { notification in
            if let view = notification.object as? GhosttyTerminalNSView {
                viewModel.removePane(byId: view.terminal.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserPaneClosed)) { notification in
            if let paneId = notification.userInfo?["paneId"] as? UUID {
                viewModel.removePane(byId: paneId)
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
                        let browser = viewModel.addBrowser()
                        viewModel.focusPane(browser)
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
                    let terminal = viewModel.addTerminal()
                    viewModel.focusPane(terminal)
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

    /// The effective width of this pane, accounting for focus mode.
    /// When this pane is the focus-mode target the pane content itself
    /// expands to the focus-mode minimum (which varies by pane type).
    private var effectiveWidth: CGFloat {
        let isFocusModeTarget = viewModel.isFocusMode && pane.id == viewModel.focusModePaneId
        if isFocusModeTarget {
            return max(pane.paneWidth, pane.focusModeMinWidth(windowWidth: windowWidth))
        }
        return pane.paneWidth
    }

    /// The current index of this pane in the array.
    private var index: Int {
        allPanes.firstIndex(where: { $0.id == pane.id }) ?? 0
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

            PaneView(pane: pane, viewModel: viewModel, onDragStarted: {
                    viewModel.dragStarted(paneId: pane.id)
                }, onHeaderTapped: {
                    viewModel.focusPane(id: pane.id)
                })
                .frame(width: effectiveWidth)
                .animation(nil, value: pane.paneWidth)
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
                Color.clear
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
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
            .frame(width: 27) // 3px indicator + 12px padding each side
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

        // Start with one terminal
        let initial = addTerminal()
        focusPane(initial)
    }

    deinit {
        if let monitor = dragEndMonitor {
            NSEvent.removeMonitor(monitor)
        }
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
    func toggleCommandPalette() {
        if isCommandPalettePresented {
            dismissCommandPalette()
        } else {
            // Open the palette on the currently focused pane
            if let focused = panes.first(where: { $0.isFocused }) {
                commandPalettePaneId = focused.id
            }
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
        // Restore focus unless an action explicitly called focusPane()
        if beforeGeneration == nil || focusGeneration == beforeGeneration {
            focusPaneById(paneId)
        }
    }

    /// Close the currently focused pane.
    /// If multiple panes exist, closes just the focused one (with confirmation
    /// if an active session is running). If it's the only pane, closes the window.
    func closeCurrentPane() {
        guard let focusedPane = contextualPane else { return }
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else { return }

        if panes.count > 1 {
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
        } else {
            // Single pane — close the window.
            window.performClose(nil)
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

        // Remove all panes to the right
        panes.removeSubrange((currentIndex + 1)...)

        // Ensure the current pane is focused
        focusPane(focusedPane)
    }

    /// Exit focus mode if it is currently active.
    func exitFocusMode() {
        guard isFocusMode else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isFocusMode = false
            focusModePaneId = nil
        }
    }

    @discardableResult
    func addTerminal() -> TerminalPaneModel {
        // Inherit the working directory and pane width from the contextual
        // pane, falling back to defaults when nothing is focused.
        let sourcePane = contextualPane
        let directory = sourcePane?.directory ?? NSHomeDirectory()
        let paneWidth = sourcePane?.paneWidth ?? PaneModel.defaultPaneWidth

        let terminal = TerminalPaneModel(
            id: UUID(),
            title: "Terminal \(panes.count + 1)",
            status: .active,
            directory: directory,
            paneWidth: paneWidth
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
    func addBrowser(url: URL = URL(string: "about:blank")!) -> BrowserPaneModel {
        let sourcePane = contextualPane
        let paneWidth = sourcePane?.paneWidth ?? PaneModel.defaultPaneWidth

        let browser = BrowserPaneModel(url: url, paneWidth: paneWidth)
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
        // Exit focus mode if the removed pane was the focus-mode target
        if id == focusModePaneId {
            exitFocusMode()
        }

        guard let index = panes.firstIndex(where: { $0.id == id }) else { return }

        // Determine which pane to focus after removal.
        let neighborId: UUID
        if panes.count > 1 {
            let focusIndex = index > 0 ? index - 1 : 1
            neighborId = panes[focusIndex].id
        } else {
            // Last pane — create a new one and use its ID.
            let newTerminal = addTerminal()
            neighborId = newTerminal.id
        }

        panes.remove(at: index)
        focusPaneById(neighborId)
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
            if let webView = findWebView(for: pane.id, in: contentView) {
                window.makeFirstResponder(webView)
                return true
            }
        }
        return false
    }

    /// Walk the view hierarchy to find a WatchtowerWebView associated with a pane ID.
    private func findWebView(for paneId: UUID, in view: NSView) -> WatchtowerWebView? {
        if let webView = view as? WatchtowerWebView,
           webView.browser?.id == paneId {
            return webView
        }
        for subview in view.subviews {
            if let found = findWebView(for: paneId, in: subview) {
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
