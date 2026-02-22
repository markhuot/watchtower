import SwiftUI
import UniformTypeIdentifiers
import Combine

struct ContentView: View {
    @StateObject private var viewModel = TerminalContainerViewModel()
    @ObservedObject private var appManager = GhosttyAppManager.shared

    /// Minimum width for focus mode: 150 columns using the same cell-width math.
    private static let focusModeMinWidth: CGFloat = 150 * TerminalPaneWithHandle.estimatedCellWidth + 40

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: !viewModel.isFocusMode) {
                    HStack(spacing: 0) {
                        ForEach(viewModel.terminals) { terminal in
                            FocusModeWrapper(
                                terminal: terminal,
                                viewModel: viewModel,
                                focusModeMinWidth: ContentView.focusModeMinWidth
                            ) {
                                TerminalPaneWithHandle(
                                    terminal: terminal,
                                    allTerminals: viewModel.terminals,
                                    viewModel: viewModel
                                )
                            }
                            .id(terminal.id)
                        }
                    }
                    .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Scroll to the focused pane when entering focus mode
                .onChange(of: viewModel.isFocusMode) { isFocused in
                    if isFocused, let targetId = viewModel.focusModeTerminalId {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            scrollProxy.scrollTo(targetId, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(appManager.backgroundColor.ignoresSafeArea())
        .focusedValue(\.terminalViewModel, viewModel)
        .onReceive(NotificationCenter.default.publisher(for: .ghosttySurfaceClosed)) { notification in
            if let view = notification.object as? GhosttyTerminalNSView {
                viewModel.removeTerminal(byId: view.terminal.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .closePaneRequested)) { notification in
            if let terminalId = notification.userInfo?["terminalId"] as? UUID {
                viewModel.removeTerminal(byId: terminalId)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if viewModel.gitRepoRoot != nil {
                    Menu {
                        Button("New Terminal") {
                            viewModel.addTerminal()
                        }
                        Button("New Workspace...") {
                            viewModel.showWorkspaceDialog = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    } primaryAction: {
                        viewModel.addTerminal()
                    }
                } else {
                    Button(action: { viewModel.addTerminal() }) {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.showWorkspaceDialog) {
            if let repoRoot = viewModel.gitRepoRoot {
                WorkspaceDialogView(
                    isPresented: $viewModel.showWorkspaceDialog,
                    repoRoot: repoRoot,
                    onSubmit: { name, branch in
                        viewModel.createWorkspace(name: name, baseBranch: branch)
                    }
                )
            }
        }
    }
}

/// Wraps a terminal pane with focus-mode visual treatment (width override,
/// dimming, shadow) without bloating the main ContentView body.
struct FocusModeWrapper<Content: View>: View {
    @ObservedObject var terminal: TerminalModel
    @ObservedObject var viewModel: TerminalContainerViewModel
    @ObservedObject private var appManager = GhosttyAppManager.shared
    let focusModeMinWidth: CGFloat
    let content: Content

    init(terminal: TerminalModel,
         viewModel: TerminalContainerViewModel,
         focusModeMinWidth: CGFloat,
         @ViewBuilder content: () -> Content) {
        self.terminal = terminal
        self.viewModel = viewModel
        self.focusModeMinWidth = focusModeMinWidth
        self.content = content()
    }

    private var isFocusModeTarget: Bool {
        viewModel.isFocusMode && terminal.id == viewModel.focusModeTerminalId
    }

    var body: some View {
        content
            .frame(width: isFocusModeTarget
                ? max(terminal.paneWidth, focusModeMinWidth)
                : nil)
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

/// A terminal pane with a draggable resize handle on its right edge,
/// and drop-target indicators on both edges for reordering.
struct TerminalPaneWithHandle: View {
    @ObservedObject var terminal: TerminalModel
    let allTerminals: [TerminalModel]
    @ObservedObject var viewModel: TerminalContainerViewModel

    /// The absolute X position of the mouse in window coordinates when the drag started,
    /// along with the pane width at that moment. Using absolute coordinates avoids the
    /// feedback loop where snap-to-grid moves the handle, which changes translation, which
    /// causes jittery resizing.
    @State private var dragAnchor: (startX: CGFloat, startWidth: CGFloat)? = nil

    /// Minimum pane width in points.
    private let minPaneWidth: CGFloat = 200

    /// Approximate cell width in points (matches TerminalModel.defaultPaneWidth calculation).
    static let estimatedCellWidth: CGFloat = 9

    /// Snap a width to the nearest cell boundary to prevent sub-cell jitter.
    static func snapToGrid(_ width: CGFloat) -> CGFloat {
        let padding: CGFloat = 40 // matches TerminalModel default padding
        let cols = round((width - padding) / estimatedCellWidth)
        return cols * estimatedCellWidth + padding
    }

    /// The current index of this terminal in the array.
    private var index: Int {
        allTerminals.firstIndex(where: { $0.id == terminal.id }) ?? 0
    }

    /// Whether the left-edge drop indicator should be shown for this pane.
    private var showLeftIndicator: Bool {
        guard let dropSlot = viewModel.dropTargetIndex,
              let dragId = viewModel.draggedTerminalId,
              let dragIndex = allTerminals.firstIndex(where: { $0.id == dragId }) else {
            return false
        }
        // Show left indicator on the first pane only when the drop slot is 0
        // and it's not a no-op (dragged pane is already at index 0 or 1)
        return index == 0 && dropSlot == 0 && dragIndex != 0
    }

    /// Whether the right-edge drop indicator should be shown for this pane.
    private var showRightIndicator: Bool {
        guard let dropSlot = viewModel.dropTargetIndex,
              let dragId = viewModel.draggedTerminalId,
              let dragIndex = allTerminals.firstIndex(where: { $0.id == dragId }) else {
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

            TerminalPaneView(terminal: terminal, onDragStarted: {
                    viewModel.dragStarted(terminalId: terminal.id)
                }, onHeaderTapped: {
                    viewModel.focusTerminal(id: terminal.id)
                })
                .frame(width: terminal.paneWidth)
                .animation(nil, value: terminal.paneWidth)
                .onDrop(of: [.text], delegate: PaneSplitDropDelegate(
                    paneIndex: index,
                    paneWidth: terminal.paneWidth,
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
                                // due to snap-to-grid never feeds back into the calc.
                                if dragAnchor == nil {
                                    dragAnchor = (startX: value.startLocation.x, startWidth: terminal.paneWidth)
                                }

                                let anchor = dragAnchor!
                                let delta = value.location.x - anchor.startX
                                let rawWidth = max(minPaneWidth, anchor.startWidth + delta)

                                // Snap to cell grid to prevent sub-cell jitter
                                let newWidth = TerminalPaneWithHandle.snapToGrid(rawWidth)

                                // Check if option key is held
                                let optionHeld = NSEvent.modifierFlags.contains(.option)

                                if optionHeld {
                                    // Resize ALL terminals to the same width
                                    for t in allTerminals {
                                        t.paneWidth = newWidth
                                    }
                                } else {
                                    // Resize only this terminal
                                    terminal.paneWidth = newWidth
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
    let viewModel: TerminalContainerViewModel

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
        guard let draggedId = viewModel.draggedTerminalId else { return false }

        viewModel.moveTerminal(id: draggedId, toSlot: targetSlot)
        viewModel.cleanupDragState()

        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        return viewModel.draggedTerminalId != nil
    }
}

/// Drop delegate placed on the full pane area.
/// Determines which half the cursor is in and routes to the correct slot.
struct PaneSplitDropDelegate: DropDelegate {
    let paneIndex: Int
    let paneWidth: CGFloat
    let viewModel: TerminalContainerViewModel

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
        guard let draggedId = viewModel.draggedTerminalId else { return false }

        viewModel.moveTerminal(id: draggedId, toSlot: slot)
        viewModel.cleanupDragState()

        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        return viewModel.draggedTerminalId != nil
    }
}

// MARK: - Drop Indicator

/// A vertical indicator between panes that doubles as a drop target.
/// Always occupies the same space to prevent layout shift when dragging starts.
struct DropIndicatorView: View {
    let isActive: Bool
    let targetSlot: Int
    @ObservedObject var viewModel: TerminalContainerViewModel

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

class TerminalContainerViewModel: ObservableObject {
    @Published var terminals: [TerminalModel] = []

    /// The index of the slot where a dragged pane would be inserted.
    /// `nil` when no drag is active. 0 = before first pane, 1 = between first and second, etc.
    @Published var dropTargetIndex: Int? = nil

    /// The ID of the terminal currently being dragged.
    @Published var draggedTerminalId: UUID? = nil

    /// Whether focus mode is active. In focus mode the currently focused pane
    /// floats above all other panes as a centered overlay.
    @Published var isFocusMode: Bool = false

    /// The ID of the terminal that was focused when focus mode was entered.
    /// Stored so that switching focus exits focus mode cleanly.
    @Published var focusModeTerminalId: UUID? = nil

    /// The git repo root for the currently focused terminal's directory.
    /// `nil` when not in a git repo.
    @Published var gitRepoRoot: String? = nil

    /// Whether the workspace creation dialog is shown.
    @Published var showWorkspaceDialog: Bool = false

    /// Event monitor for detecting when a drag session ends (mouse up).
    private var dragEndMonitor: Any? = nil

    /// Subject that emits the currently focused terminal. Used to drive
    /// the `switchToLatest` pipeline that tracks the focused terminal's
    /// directory for git detection.
    private let focusedTerminalSubject = CurrentValueSubject<TerminalModel?, Never>(nil)

    /// Bag holding the Combine pipeline subscriptions.
    private var cancellables = Set<AnyCancellable>()

    /// In-flight git detection task, cancelled when focus/directory changes.
    private var gitDetectionTask: Task<Void, Never>? = nil

    init() {
        // Set up a Combine pipeline that:
        // 1. Watches which terminal is focused (via focusedTerminalSubject)
        // 2. switchToLatest subscribes to the focused terminal's $directory
        // 3. On each new directory, runs git detection
        focusedTerminalSubject
            .compactMap { $0 }
            .map { terminal in
                terminal.$directory
                    .removeDuplicates()
            }
            .switchToLatest()
            .sink { [weak self] directory in
                self?.detectGitRepo(for: directory)
            }
            .store(in: &cancellables)

        // Also handle the nil case (no focused terminal) to clear gitRepoRoot
        focusedTerminalSubject
            .filter { $0 == nil }
            .sink { [weak self] _ in
                self?.gitDetectionTask?.cancel()
                self?.gitRepoRoot = nil
            }
            .store(in: &cancellables)

        // Start with one terminal
        addTerminal()
    }

    deinit {
        if let monitor = dragEndMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Call when a drag session begins to install cleanup monitoring.
    func dragStarted(terminalId: UUID) {
        draggedTerminalId = terminalId

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
        draggedTerminalId = nil
        for terminal in terminals {
            terminal.isDragging = false
        }
        if let monitor = dragEndMonitor {
            NSEvent.removeMonitor(monitor)
            dragEndMonitor = nil
        }
    }

    /// Toggle focus mode on the currently focused terminal.
    /// If focus mode is already active, it is deactivated.
    func toggleFocusMode() {
        if isFocusMode {
            withAnimation(.easeInOut(duration: 0.2)) {
                isFocusMode = false
                focusModeTerminalId = nil
            }
        } else {
            guard let focused = terminals.first(where: { $0.isFocused }) else { return }
            focusModeTerminalId = focused.id
            withAnimation(.easeInOut(duration: 0.2)) {
                isFocusMode = true
            }
        }
    }

    /// Exit focus mode if it is currently active.
    func exitFocusMode() {
        guard isFocusMode else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isFocusMode = false
            focusModeTerminalId = nil
        }
    }

    func addTerminal() {
        // Inherit the working directory and pane width from the currently
        // focused terminal, falling back to defaults when nothing is focused.
        let focusedTerminal = terminals.first(where: { $0.isFocused })
        let directory = focusedTerminal?.directory ?? NSHomeDirectory()
        let paneWidth = focusedTerminal?.paneWidth ?? TerminalModel.defaultPaneWidth

        let terminal = TerminalModel(
            id: UUID(),
            title: "Terminal \(terminals.count + 1)",
            status: .active,
            directory: directory,
            paneWidth: paneWidth
        )

        // Insert after the currently focused pane, or append at the end if none is focused
        if let focusedIndex = terminals.firstIndex(where: { $0.isFocused }) {
            terminals.insert(terminal, at: focusedIndex + 1)
        } else {
            terminals.append(terminal)
        }

        // Focus the new terminal after SwiftUI has time to create the view
        let newId = terminal.id
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let idx = self.terminals.firstIndex(where: { $0.id == newId }) else { return }
            self.makeFocused(index: idx)
        }
    }

    func removeTerminal(_ terminal: TerminalModel) {
        removeTerminal(byId: terminal.id)
    }

    /// Move a terminal from its current position to a new slot index.
    /// `toSlot` is in pre-removal coordinates (0 = before first, count = after last).
    func moveTerminal(id: UUID, toSlot slot: Int) {
        guard let fromIndex = terminals.firstIndex(where: { $0.id == id }) else { return }

        // Determine the actual destination index after removal
        var destIndex = slot
        if slot > fromIndex {
            // Account for the item being removed before insertion
            destIndex -= 1
        }
        destIndex = max(0, min(destIndex, terminals.count - 1))

        guard destIndex != fromIndex else { return }

        let terminal = terminals.remove(at: fromIndex)
        terminals.insert(terminal, at: destIndex)
    }

    func removeTerminal(byId id: UUID) {
        // Exit focus mode if the removed terminal was the focus-mode target
        if id == focusModeTerminalId {
            exitFocusMode()
        }

        guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }

        // Determine which terminal to focus after removal.
        let focusIndex: Int?
        if terminals.count <= 1 {
            // Last terminal — we'll create a new one and focus it.
            focusIndex = nil
        } else if index > 0 {
            // Prefer the terminal immediately to the left.
            focusIndex = index - 1
        } else {
            // Leftmost terminal removed — focus the one to the right
            // (which will shift into index 0 after removal).
            focusIndex = 0
        }

        terminals.remove(at: index)

        if let focusIndex = focusIndex {
            // Focus the neighbor after a brief delay so SwiftUI has
            // time to reconcile the view hierarchy.
            let targetId = terminals[focusIndex].id
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      let idx = self.terminals.firstIndex(where: { $0.id == targetId }) else { return }
                self.makeFocused(index: idx)
            }
        } else {
            // Was the last terminal — re-create one and focus it.
            addTerminal()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.makeFocused(index: self.terminals.count - 1)
            }
        }
    }

    func focusPreviousPane() {
        guard terminals.count > 1 else { return }
        let currentIndex = terminals.firstIndex(where: { $0.isFocused }) ?? 0
        let newIndex = (currentIndex - 1 + terminals.count) % terminals.count
        makeFocused(index: newIndex)
    }

    func focusNextPane() {
        guard terminals.count > 1 else { return }
        let currentIndex = terminals.firstIndex(where: { $0.isFocused }) ?? 0
        let newIndex = (currentIndex + 1) % terminals.count
        makeFocused(index: newIndex)
    }

    /// Focus a terminal by its ID (e.g. when the header is clicked).
    func focusTerminal(id: UUID) {
        guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }
        makeFocused(index: index)
    }

    private func makeFocused(index: Int) {
        let terminal = terminals[index]

        // Push the focused terminal into the subject so the Combine pipeline
        // picks up its $directory publisher (and re-runs git detection).
        focusedTerminalSubject.send(terminal)

        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else { return }

        let allViews = GhosttyTerminalNSView.findAllTerminalViews(in: contentView)

        // Match by terminal ID
        if let targetView = allViews.first(where: { $0.terminal.id == terminal.id }) {
            window.makeFirstResponder(targetView)
        }
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

    // MARK: - Workspace Creation

    /// Create a new workspace terminal with the given name and base branch.
    func createWorkspace(name: String, baseBranch: String) {
        guard let repoRoot = gitRepoRoot else { return }

        let command = WorkspaceManager.buildCommand(
            workspaceName: name,
            baseBranch: baseBranch,
            repoRoot: repoRoot
        )
        let env = WorkspaceManager.buildEnvVars(
            workspaceName: name,
            baseBranch: baseBranch,
            repoRoot: repoRoot
        )

        let focusedTerminal = terminals.first(where: { $0.isFocused })
        let paneWidth = focusedTerminal?.paneWidth ?? TerminalModel.defaultPaneWidth

        // Determine if this is a custom script (sets wait_after_command)
        let hasCustomScript = WorkspaceManager.findWorkspaceScript(repoRoot: repoRoot) != nil

        let terminal = TerminalModel(
            id: UUID(),
            title: name,
            status: .active,
            directory: repoRoot,
            paneWidth: paneWidth,
            command: command,
            env: env,
            waitAfterCommand: hasCustomScript
        )

        // Insert after the currently focused pane
        if let focusedIndex = terminals.firstIndex(where: { $0.isFocused }) {
            terminals.insert(terminal, at: focusedIndex + 1)
        } else {
            terminals.append(terminal)
        }

        // Focus the new terminal
        let newId = terminal.id
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let idx = self.terminals.firstIndex(where: { $0.id == newId }) else { return }
            self.makeFocused(index: idx)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
