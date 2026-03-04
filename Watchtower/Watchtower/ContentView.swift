import SwiftUI
import UniformTypeIdentifiers
import Combine
import WebKit
import AppKit

private let weblocUTType = UTType(importedAs: "com.apple.web-internet-location")

private struct PaneFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

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
    @ObservedObject private var config = WatchtowerConfig.shared
    @State private var showCLIInstallSheet = false
    @State private var paneFrames: [UUID: CGRect] = [:]

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
                                    .id(pane.id)
                                    .background(
                                        GeometryReader { paneGeo in
                                            Color.clear.preference(
                                                key: PaneFramePreferenceKey.self,
                                                value: [pane.id: paneGeo.frame(in: .named("WindowSpace"))]
                                            )
                                        }
                                    )
                                }
                            }
                            .padding(10)
                            .frame(minWidth: viewModel.isFullScreen ? geometry.size.width : nil)
                        }
                        .coordinateSpace(name: "WindowSpace")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onChange(of: viewModel.focusedPaneId) { targetId in
                            guard let targetId = targetId else { return }
                            DispatchQueue.main.async {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    scrollProxy.scrollTo(targetId)
                                }
                                DispatchQueue.main.async {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        scrollProxy.scrollTo(targetId)
                                    }
                                }
                                viewModel.focusedPaneId = nil
                            }
                        }
                        .onChange(of: viewModel.centeredPaneId) { targetId in
                            guard let targetId = targetId else { return }
                            DispatchQueue.main.async {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    scrollProxy.scrollTo(targetId, anchor: .center)
                                }
                                DispatchQueue.main.async {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        scrollProxy.scrollTo(targetId, anchor: .center)
                                    }
                                }
                                viewModel.centeredPaneId = nil
                            }
                        }
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
        .background(
            TitlebarStatusStripInstaller(viewModel: viewModel)
                .frame(width: 0, height: 0)
        )
        .contentShape(Rectangle())
        .coordinateSpace(name: "WindowSpace")
        .onPreferenceChange(PaneFramePreferenceKey.self) { paneFrames = $0 }
        .onDrop(of: [.text, .url, .fileURL, weblocUTType], delegate: WindowDropDelegate(
            viewModel: viewModel,
            paneFrames: paneFrames
        ))
        .focusedSceneValue(\.paneViewModel, viewModel)
        .onAppear {
            IPCServer.shared.register(viewModel)

            // Show CLI install prompt on first window only
            if !ContentView.hasShownCLIPrompt && CLIInstaller.shouldPrompt(dismissed: config.cliInstallDismissed) {
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

struct TitlebarPaneStatusStrip: View {
    @ObservedObject var viewModel: PaneContainerViewModel

    var body: some View {
        HStack(spacing: 10) {
            ForEach(viewModel.panes) { pane in
                TitlebarPaneStatusDot(
                    pane: pane,
                    isSelected: viewModel.focusedPaneId == pane.id || pane.isFocused,
                    onTap: {
                        viewModel.focusPane(id: pane.id)
                    }
                )
            }
        }
        .fixedSize()
        .background(Color.clear)
    }
}

struct TitlebarStatusStripInstaller: NSViewRepresentable {
    @ObservedObject var viewModel: PaneContainerViewModel

    func makeNSView(context: Context) -> TitlebarStatusInstallerNSView {
        let view = TitlebarStatusInstallerNSView()
        view.viewModel = viewModel
        return view
    }

    func updateNSView(_ nsView: TitlebarStatusInstallerNSView, context: Context) {
        nsView.viewModel = viewModel
        nsView.installOrUpdate()
    }
}

final class TitlebarStatusInstallerNSView: NSView {
    weak var viewModel: PaneContainerViewModel?
    private var hostingView: NSHostingView<TitlebarPaneStatusStrip>?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installOrUpdate()
    }

    func installOrUpdate() {
        guard let viewModel,
              let window,
              let container = window.contentView?.firstViewFromRoot(withClassName: "NSTitlebarContainerView") else {
            return
        }

        if let hostingView {
            hostingView.rootView = TitlebarPaneStatusStrip(viewModel: viewModel)
            if hostingView.superview !== container {
                hostingView.removeFromSuperview()
                container.addSubview(hostingView)
                activateConstraints(for: hostingView, in: container)
            }
            return
        }

        let host = NSHostingView(rootView: TitlebarPaneStatusStrip(viewModel: viewModel))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = false
        host.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(host)
        activateConstraints(for: host, in: container)
        hostingView = host
    }

    private func activateConstraints(for host: NSView, in container: NSView) {
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    deinit {
        hostingView?.removeFromSuperview()
    }
}

struct TitlebarPaneStatusDot: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject private var appManager = GhosttyAppManager.shared
    let isSelected: Bool
    let onTap: () -> Void

    @State private var bounceYOffset: CGFloat = 0

    private var helpText: String {
        if let subtitle = pane.subtitle, !subtitle.isEmpty {
            return "\(pane.title)\n\(subtitle)"
        }
        return pane.title
    }

    private var statusColor: Color {
        appManager.paneStatusColor(pane.status)
    }

    private var dotSize: CGFloat {
        isSelected ? 12 : 9
    }

    var body: some View {
        Button(action: onTap) {
            Circle()
                .fill(statusColor)
                .frame(width: dotSize, height: dotSize)
                .shadow(
                    color: statusColor.opacity(isSelected ? 1.0 : 0.4),
                    radius: isSelected ? 5 : 3,
                    x: 0,
                    y: isSelected ? 1 : 0
                )
                .offset(y: bounceYOffset)
                .animation(.spring(response: 0.34, dampingFraction: 0.7), value: isSelected)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
            .background(Color.clear)
        .onChange(of: isSelected) { selected in
            bounceYOffset = 0
            if selected {
                withAnimation(.easeOut(duration: 0.14)) {
                    bounceYOffset = -3
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.72)) {
                        bounceYOffset = 0
                    }
                }
            } else {
                withAnimation(.easeOut(duration: 0.14)) {
                    bounceYOffset = 3
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.72)) {
                        bounceYOffset = 0
                    }
                }
            }
        }
        .help(helpText)
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
            .opacity(pane.isClosing ? 0 : (pane.isAppearing ? 0 : 1))
            .animation(.easeIn(duration: min(0.12, pane.animationDuration * 0.45)), value: pane.isClosing)
            .offset(
                x: pane.isAppearing ? -50 : (pane.isClosing ? -20 : 0),
                y: 0
            )
            .animation(.easeOut(duration: pane.animationDuration), value: pane.isAppearing)
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
    @State private var closingFrozenContentWidth: CGFloat? = nil

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
    private var baseWidth: CGFloat {
        if pane.isCollapsed {
            return PaneModel.collapsedPaneWidth
        }
        let isFocusModeTarget = viewModel.isFocusMode && pane.id == viewModel.focusModePaneId
        if isFocusModeTarget {
            return max(pane.paneWidth, pane.focusModeMinWidth(windowWidth: windowWidth))
        }
        return pane.paneWidth
    }

    private var effectiveWidth: CGFloat {
        pane.isClosing ? 0 : baseWidth
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
        if pane.isClosing {
            return 0
        }
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
        guard let dropSlot = viewModel.dropTargetIndex else { return false }

        // External URL drag — always show if slot matches (never a no-op)
        if viewModel.showExternalDropIndicators {
            return index == 0 && dropSlot == 0
        }

        // Internal pane reorder
        guard let dragId = viewModel.draggedPaneId,
              let dragIndex = allPanes.firstIndex(where: { $0.id == dragId }) else {
            return false
        }
        // Show left indicator on the first pane only when the drop slot is 0
        // and it's not a no-op (dragged pane is already at index 0 or 1)
        return index == 0 && dropSlot == 0 && dragIndex != 0
    }

    /// Whether the right-edge drop indicator should be shown for this pane.
    private var showRightIndicator: Bool {
        guard let dropSlot = viewModel.dropTargetIndex else { return false }

        // External URL drag — always show if slot matches (never a no-op)
        if viewModel.showExternalDropIndicators {
            return dropSlot == index + 1
        }

        // Internal pane reorder
        guard let dragId = viewModel.draggedPaneId,
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

            PaneView(pane: pane, viewModel: viewModel, fixedContentWidth: closingFrozenContentWidth, onClose: {
                    viewModel.removePane(byId: pane.id)
                }, onDragStarted: {
                    viewModel.dragStarted(paneId: pane.id)
                }, onDragEnded: {
                    viewModel.cleanupDragState()
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
                .animation(.easeIn(duration: pane.animationDuration), value: pane.isClosing)
                .onDrop(of: [.text, .url, .fileURL, weblocUTType], delegate: PaneSplitDropDelegate(
                    paneIndex: index,
                    paneWidth: pane.paneWidth,
                    viewModel: viewModel
                ))
                .overlay {
                    // During internal pane reorder drags, install a top-most
                    // drop target so embedded NSViews (WKWebView/CEF) can't
                    // swallow drag events as the cursor moves across content.
                    if viewModel.draggedPaneId != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .onDrop(of: [.text, .url, .fileURL, weblocUTType], delegate: PaneSplitDropDelegate(
                                paneIndex: index,
                                paneWidth: pane.paneWidth,
                                viewModel: viewModel
                            ))
                    }
                }

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
            .animation(.easeInOut(duration: pane.isClosing ? pane.animationDuration : 0.2), value: rightGapWidth)
        }
        .onChange(of: pane.isClosing) { isClosing in
            if isClosing {
                closingFrozenContentWidth = baseWidth
            } else {
                closingFrozenContentWidth = nil
            }
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

/// Handles drag-and-drop for reordering panes and accepting external URL drops.
/// Each drop zone (left/right half of a pane) creates one of these with its target slot index.
struct PaneDropDelegate: DropDelegate {
    let targetSlot: Int
    let viewModel: PaneContainerViewModel

    func dropEntered(info: DropInfo) {
        guard !viewModel.isHandlingExternalDrop else { return }
        beginExternalDragIfNeeded(info, viewModel: viewModel)
        withAnimation(.easeInOut(duration: 0.15)) {
            viewModel.dropTargetIndex = targetSlot
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if viewModel.isHandlingExternalDrop { return externalAwareDropProposal(viewModel: viewModel) }
        beginExternalDragIfNeeded(info, viewModel: viewModel)
        viewModel.dropTargetIndex = targetSlot
        return externalAwareDropProposal(viewModel: viewModel)
    }

    func dropExited(info: DropInfo) {
        // Only clear if we're still pointing at this slot
        if viewModel.dropTargetIndex == targetSlot {
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.dropTargetIndex = nil
            }
        }
    }

    func dropEnded(info: DropInfo) {
        clearExternalDragUIIfNeeded(viewModel)
    }

    func performDrop(info: DropInfo) -> Bool {
        performPaneOrExternalDrop(info: info, targetSlot: targetSlot, viewModel: viewModel)
    }

    func validateDrop(info: DropInfo) -> Bool {
        return viewModel.draggedPaneId != nil || info.hasItemsConforming(to: [.url, .text, .fileURL, weblocUTType])
    }
}

/// Drop delegate placed on the full pane area.
/// Determines which half the cursor is in and routes to the correct slot.
/// Handles both internal pane reordering and external URL drops.
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
        guard !viewModel.isHandlingExternalDrop else { return }
        beginExternalDragIfNeeded(info, viewModel: viewModel)
        let slot = slotForLocation(info)
        withAnimation(.easeInOut(duration: 0.15)) {
            viewModel.dropTargetIndex = slot
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if viewModel.isHandlingExternalDrop { return externalAwareDropProposal(viewModel: viewModel) }
        beginExternalDragIfNeeded(info, viewModel: viewModel)
        let slot = slotForLocation(info)
        if viewModel.dropTargetIndex != slot {
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.dropTargetIndex = slot
            }
        }
        return externalAwareDropProposal(viewModel: viewModel)
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeInOut(duration: 0.15)) {
            viewModel.dropTargetIndex = nil
        }
    }

    func dropEnded(info: DropInfo) {
        clearExternalDragUIIfNeeded(viewModel)
    }

    func performDrop(info: DropInfo) -> Bool {
        let slot = slotForLocation(info)
        return performPaneOrExternalDrop(info: info, targetSlot: slot, viewModel: viewModel)
    }

    func validateDrop(info: DropInfo) -> Bool {
        return viewModel.draggedPaneId != nil || info.hasItemsConforming(to: [.url, .text, .fileURL, weblocUTType])
    }
}

private func beginExternalDragIfNeeded(_ info: DropInfo, viewModel: PaneContainerViewModel) {
    if viewModel.draggedPaneId == nil && info.hasItemsConforming(to: [.url, .text, .fileURL, weblocUTType]) {
        viewModel.isExternalURLDrag = true
        viewModel.showExternalDropIndicators = true
    }
}

private func clearExternalDragUIIfNeeded(_ viewModel: PaneContainerViewModel) {
    if viewModel.draggedPaneId == nil {
        viewModel.isExternalURLDrag = false
        viewModel.showExternalDropIndicators = false
        viewModel.dropTargetIndex = nil
        viewModel.isHandlingExternalDrop = false
    }
}

private func externalAwareDropProposal(viewModel: PaneContainerViewModel) -> DropProposal {
    DropProposal(operation: viewModel.draggedPaneId != nil ? .move : .copy)
}

private func performPaneOrExternalDrop(info: DropInfo, targetSlot: Int, viewModel: PaneContainerViewModel) -> Bool {
    if let draggedId = viewModel.draggedPaneId {
        viewModel.movePane(id: draggedId, toSlot: targetSlot)
        viewModel.cleanupDragState()
        return true
    }

    if loadURLFromDrop(info, completion: { url in
        viewModel.insertBrowser(url: url, atSlot: targetSlot)
    }) {
        markExternalDropAccepted(viewModel)
        return true
    }

    viewModel.cleanupDragState()
    return false
}

/// Marks that an external URL drop has been accepted and immediately clears
/// all transient drag UI so indicators don't linger while async URL loading
/// finishes.
private func markExternalDropAccepted(_ viewModel: PaneContainerViewModel) {
    viewModel.isHandlingExternalDrop = true
    viewModel.isExternalURLDrag = false
    viewModel.showExternalDropIndicators = false
    viewModel.dropTargetIndex = nil
}

// MARK: - URL Drop Helper

/// Extract a URL from an external drop and invoke the completion on the main thread.
/// Returns `true` if a URL provider was found (the async load is in flight),
/// `false` if nothing usable was on the pasteboard.
private func loadURLFromDrop(_ info: DropInfo, completion: @escaping (URL) -> Void) -> Bool {
    let providerTypes = info.itemProviders(for: [.item]).map { $0.registeredTypeIdentifiers }

    let completionLock = NSLock()
    var didComplete = false
    let completeOnce: (URL) -> Void = { url in
        completionLock.lock()
        defer { completionLock.unlock() }
        guard !didComplete else { return }
        didComplete = true
        completion(url)
    }

    // Legacy webloc type (com.apple.web-internet-location)
    let weblocType = "com.apple.web-internet-location"
    if let provider = info.itemProviders(for: [.item]).first(where: {
        $0.hasItemConformingToTypeIdentifier(weblocType) || $0.registeredTypeIdentifiers.contains(weblocType)
    }) {
        provider.loadItem(forTypeIdentifier: weblocType, options: nil) { item, _ in
            if let fileUrl = item as? URL, fileUrl.isFileURL {
                if let extracted = extractWeblocURL(fromFile: fileUrl) {
                    DispatchQueue.main.async { completeOnce(extracted) }
                    return
                }
            }
            if let nsurl = item as? NSURL {
                let fileUrl = nsurl as URL
                if fileUrl.isFileURL, let extracted = extractWeblocURL(fromFile: fileUrl) {
                    DispatchQueue.main.async { completeOnce(extracted) }
                    return
                }
            }
            if let string = item as? String, let url = URL(string: string) {
                DispatchQueue.main.async { completeOnce(url) }
                return
            }
            if let data = item as? Data,
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                if let urlString = plist["URL"] as? String, let url = URL(string: urlString) {
                    DispatchQueue.main.async { completeOnce(url) }
                    return
                }
                if let urlString = plist["URLString"] as? String, let url = URL(string: urlString) {
                    DispatchQueue.main.async { completeOnce(url) }
                    return
                }
            }
        }
        provider.loadDataRepresentation(forTypeIdentifier: weblocType) { data, _ in
            guard let data else { return }
            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                if let urlString = plist["URL"] as? String, let url = URL(string: urlString) {
                    DispatchQueue.main.async { completeOnce(url) }
                    return
                }
                if let urlString = plist["URLString"] as? String, let url = URL(string: urlString) {
                    DispatchQueue.main.async { completeOnce(url) }
                    return
                }
            }
            if let string = String(data: data, encoding: .utf8), let url = URL(string: string) {
                DispatchQueue.main.async { completeOnce(url) }
                return
            }
        }
        return true
    }
    // Try .url type next (most browsers provide this)
    let urlProviders = info.itemProviders(for: [.url])
    if let provider = urlProviders.first {
        provider.loadObject(ofClass: NSURL.self) { object, _ in
            guard let nsurl = object as? NSURL else { return }
            DispatchQueue.main.async { completeOnce(nsurl as URL) }
        }
        return true
    }

    // Some drags provide file URLs instead of web URLs
    let fileProviders = info.itemProviders(for: [.fileURL])
    if let provider = fileProviders.first {
        provider.loadObject(ofClass: NSURL.self) { object, _ in
            guard let nsurl = object as? NSURL else { return }
            DispatchQueue.main.async { completeOnce(nsurl as URL) }
        }
        return true
    }

    // Fallback: plain text that parses as a URL
    let textProviders = info.itemProviders(for: [.text])
    if let provider = textProviders.first {
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String,
                  let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme != nil else { return }
            DispatchQueue.main.async { completeOnce(url) }
        }
        return true
    }

    return false
}

private func extractWeblocURL(fromFile fileUrl: URL) -> URL? {
    guard fileUrl.isFileURL else { return nil }
    if let data = try? Data(contentsOf: fileUrl),
       let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
        if let urlString = plist["URL"] as? String, let url = URL(string: urlString) {
            return url
        }
        if let urlString = plist["URLString"] as? String, let url = URL(string: urlString) {
            return url
        }
    }
    return nil
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
            .onDrop(of: [.text, .url, .fileURL, weblocUTType], delegate: PaneDropDelegate(
                targetSlot: targetSlot,
                viewModel: viewModel
            ))
            .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}

// MARK: - Window Edge Drop Target

/// A trailing-edge drop target that accepts URLs when there's empty window space.
struct WindowDropDelegate: DropDelegate {
    let viewModel: PaneContainerViewModel
    let paneFrames: [UUID: CGRect]

    private var isExternalDrag: Bool {
        viewModel.draggedPaneId == nil
    }

    private func paneRange() -> (minX: CGFloat, maxX: CGFloat)? {
        let frames = paneFrames.values
        guard !frames.isEmpty else { return nil }
        let minX = frames.map { $0.minX }.min() ?? 0
        let maxX = frames.map { $0.maxX }.max() ?? 0
        return (minX, maxX)
    }

    private func resolveEdgeSlot(for location: CGPoint) -> Int? {
        guard let range = paneRange() else { return 0 }
        if location.x < range.minX {
            return 0
        }
        if location.x > range.maxX {
            return viewModel.panes.count
        }
        return nil
    }

    func dropEntered(info: DropInfo) {
        guard !viewModel.isHandlingExternalDrop else { return }
        guard isExternalDrag else { return }
        if let slot = resolveEdgeSlot(for: info.location) {
            viewModel.dropTargetIndex = slot
            viewModel.showExternalDropIndicators = true
            viewModel.isExternalURLDrag = true
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if viewModel.isHandlingExternalDrop {
            return DropProposal(operation: .copy)
        }
        guard isExternalDrag else { return DropProposal(operation: .move) }
        if let slot = resolveEdgeSlot(for: info.location) {
            if viewModel.dropTargetIndex != slot {
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewModel.dropTargetIndex = slot
                }
            }
            viewModel.showExternalDropIndicators = true
            viewModel.isExternalURLDrag = true
        }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        if isExternalDrag {
            viewModel.showExternalDropIndicators = false
            viewModel.isExternalURLDrag = false
            viewModel.dropTargetIndex = nil
            viewModel.isHandlingExternalDrop = false
        }
    }

    func dropEnded(info: DropInfo) {
        if isExternalDrag {
            viewModel.showExternalDropIndicators = false
            viewModel.isExternalURLDrag = false
            viewModel.dropTargetIndex = nil
            viewModel.isHandlingExternalDrop = false
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard isExternalDrag else { return false }
        guard let slot = resolveEdgeSlot(for: info.location) else { return false }

        if loadURLFromDrop(info, completion: { url in
            viewModel.insertBrowser(url: url, atSlot: slot)
        }) {
            markExternalDropAccepted(viewModel)
            return true
        }

        viewModel.cleanupDragState()
        return false
    }
}

class PaneContainerViewModel: ObservableObject {
    @Published var panes: [PaneModel] = []

    /// The index of the slot where a dragged pane would be inserted.
    /// `nil` when no drag is active. 0 = before first pane, 1 = between first and second, etc.
    @Published var dropTargetIndex: Int? = nil

    /// The ID of the pane currently being dragged.
    @Published var draggedPaneId: UUID? = nil

    /// The ID of the pane that should be minimally scrolled into view.
    /// Used by keyboard focus navigation and pane creation.
    @Published var focusedPaneId: UUID? = nil

    /// The ID of the pane that should be centered in the viewport.
    /// Used only for explicit "Center Pane" actions.
    @Published var centeredPaneId: UUID? = nil

    /// Whether an external URL drag (from another app) is active over this window.
    @Published var isExternalURLDrag: Bool = false

    /// Prevents duplicate pane creation during external drop callbacks.
    @Published var isHandlingExternalDrop: Bool = false

    /// When true, the drop indicators are visible for an external URL drag.
    @Published var showExternalDropIndicators: Bool = false

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

    /// The browser pane ID hosting the floating find bar, or `nil` when hidden.
    @Published var browserFindPaneId: UUID? = nil

    /// Current query text in the floating browser find bar.
    @Published var browserFindQuery: String = ""

    /// Incremented each time find is explicitly opened so the bar can
    /// re-focus the text field on repeated Cmd+F presses.
    @Published var browserFindFocusToken: UInt = 0

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

    /// Convenience: whether the browser find bar is currently visible.
    var isBrowserFindPresented: Bool {
        browserFindPaneId != nil
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
            guard let self = self else { return event }
            guard self.isScrollEventOverBrowserPane(event) else { return event }

            // Option held: webview receives native scrolling in any direction,
            // and Watchtower pane-strip scrolling is disabled.
            if event.modifierFlags.contains(.option) {
                return event
            }

            // No modifiers: forward only horizontal motion to Watchtower's
            // pane strip, while allowing vertical scrolling in the webview.
            self.handleBrowserHorizontalScroll(event)
            return self.zeroedScrollEvent(event, zeroX: true, zeroY: false)
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

    /// Returns a copy of `event` with selected scroll axes zeroed out.
    private func zeroedScrollEvent(_ event: NSEvent, zeroX: Bool, zeroY: Bool) -> NSEvent {
        guard event.type == .scrollWheel else { return event }
        guard let cgEvent = event.cgEvent else { return event }

        if zeroX {
            cgEvent.setIntegerValueField(CGEventField.scrollWheelEventDeltaAxis2, value: 0)
            cgEvent.setIntegerValueField(CGEventField.scrollWheelEventPointDeltaAxis2, value: 0)
            cgEvent.setIntegerValueField(CGEventField.scrollWheelEventFixedPtDeltaAxis2, value: 0)
        }

        if zeroY {
            cgEvent.setIntegerValueField(CGEventField.scrollWheelEventDeltaAxis1, value: 0)
            cgEvent.setIntegerValueField(CGEventField.scrollWheelEventPointDeltaAxis1, value: 0)
            cgEvent.setIntegerValueField(CGEventField.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        }

        return NSEvent(cgEvent: cgEvent) ?? event
    }

    /// Returns true when the scroll event occurred over a browser pane
    /// (WKWebView or ChromiumBrowserView).
    private func isScrollEventOverBrowserPane(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        let locationInWindow = event.locationInWindow
        guard let hitView = window.contentView?.hitTest(locationInWindow) else { return false }

        return hitView.isOrHasAncestor(ofType: WKWebView.self)
            || hitView.isOrHasAncestor(ofType: ChromiumBrowserView.self)
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
    }

    /// Reset all drag-related state.
    func cleanupDragState() {
        dropTargetIndex = nil
        draggedPaneId = nil
        isExternalURLDrag = false
        isHandlingExternalDrop = false
        showExternalDropIndicators = false
        for pane in panes {
            pane.isDragging = false
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
    /// Unlike `toggleCommandPalette()`, this never dismisses — pressing
    /// Cmd+L while the palette is already open is a no-op.
    /// Auto-expands the pane if it is collapsed.
    func focusCommandPalette() {
        if isCommandPalettePresented {
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

    /// Open the web inspector for the focused browser pane.
    func openWebInspector() {
        guard let browser = contextualPane as? BrowserPaneModel else { return }
        let paneId = browser.id
        browser.openWebInspector()

        // Opening inspector can steal first responder (especially WebKit).
        // Re-assert focus so pane-scoped shortcuts (Cmd+Shift+P, Cmd+L, etc.)
        // continue to work without an extra click.
        DispatchQueue.main.async { [weak self] in
            self?.focusPaneById(paneId)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.focusPaneById(paneId)
        }
    }

    /// Show the browser find bar (Cmd+F) on the focused browser pane and
    /// focus its text field for immediate typing.
    func openBrowserFind() {
        guard let browser = contextualPane as? BrowserPaneModel else { return }

        if browser.isCollapsed {
            withAnimation(.easeInOut(duration: 0.2)) {
                browser.isCollapsed = false
            }
        }

        if browserFindPaneId != browser.id {
            browserFindPaneId = browser.id
            browserFindQuery = ""
        }
        browserFindFocusToken &+= 1
        focusPane(browser)
    }

    /// Update active browser find query and trigger a native find.
    func updateBrowserFindQuery(_ query: String) {
        browserFindQuery = query
        guard let paneId = browserFindPaneId,
              let browser = panes.first(where: { $0.id == paneId }) as? BrowserPaneModel else {
            return
        }

        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            browser.clearFindInPage()
        } else {
            browser.findInPage(query)
        }
    }

    /// Jump to the next browser find match for the current query (Cmd+G).
    func findNextInBrowser() {
        if !isBrowserFindPresented {
            openBrowserFind()
            return
        }

        guard let paneId = browserFindPaneId,
              let browser = panes.first(where: { $0.id == paneId }) as? BrowserPaneModel else {
            return
        }
        guard !browserFindQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            browserFindFocusToken &+= 1
            return
        }

        browser.findNextInPage()
    }

    /// Jump to the previous browser find match for the current query (Shift+Cmd+G).
    func findPreviousInBrowser() {
        if !isBrowserFindPresented {
            openBrowserFind()
            return
        }

        guard let paneId = browserFindPaneId,
              let browser = panes.first(where: { $0.id == paneId }) as? BrowserPaneModel else {
            return
        }
        guard !browserFindQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            browserFindFocusToken &+= 1
            return
        }

        browser.findPreviousInPage()
    }

    /// Hide the browser find bar and clear active find highlights.
    func dismissBrowserFind() {
        if let paneId = browserFindPaneId,
           let browser = panes.first(where: { $0.id == paneId }) as? BrowserPaneModel {
            browser.clearFindInPage()
        }
        browserFindPaneId = nil
        browserFindQuery = ""
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
        let shiftHeld = NSEvent.modifierFlags.contains(.option)
        let duration: TimeInterval = shiftHeld ? 3.0 : 0.2

        // Start close animation on all right panes
        withAnimation(.easeIn(duration: duration)) {
            for pane in rightPanes {
                pane.animationDuration = duration
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

    /// Close all panes except the currently focused one.
    /// Does nothing if there is only one pane.
    func closeOtherPanes() {
        guard let focusedPane = contextualPane,
              let currentIndex = panes.firstIndex(where: { $0.id == focusedPane.id }) else { return }

        let otherPanes = panes.enumerated().filter { $0.offset != currentIndex }.map { $0.element }
        guard !otherPanes.isEmpty else { return }

        // Exit focus mode if the focus-mode target is one of the panes being removed
        if let fmId = focusModePaneId,
           otherPanes.contains(where: { $0.id == fmId }) {
            exitFocusMode()
        }

        // Determine animation duration (hold Shift for slow-motion)
        let shiftHeld = NSEvent.modifierFlags.contains(.option)
        let duration: TimeInterval = shiftHeld ? 3.0 : 0.2

        // Start close animation on all other panes
        withAnimation(.easeIn(duration: duration)) {
            for pane in otherPanes {
                pane.animationDuration = duration
                pane.isClosing = true
            }
        }

        // Ensure the current pane is focused
        focusPane(focusedPane)

        // Initiate CEF close for any Chromium browser panes.
        var chromiumPaneIds = Set<UUID>()
        for pane in otherPanes {
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
        let nonChromiumIds = otherPanes.filter { !chromiumPaneIds.contains($0.id) }.map { $0.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self else { return }
            for id in nonChromiumIds {
                if let index = self.panes.firstIndex(where: { $0.id == id }) {
                    self.panes.remove(at: index)
                }
            }
        }
    }

    /// Close all panes. A new empty terminal will be created automatically
    /// by removePane when the last pane is removed.
    func closeAllPanes() {
        let allPanes = Array(panes)
        guard !allPanes.isEmpty else { return }

        // Exit focus mode
        if focusModePaneId != nil {
            exitFocusMode()
        }

        // Determine animation duration (hold Shift for slow-motion)
        let shiftHeld = NSEvent.modifierFlags.contains(.option)
        let duration: TimeInterval = shiftHeld ? 3.0 : 0.2

        // Start close animation on all panes
        withAnimation(.easeIn(duration: duration)) {
            for pane in allPanes {
                pane.animationDuration = duration
                pane.isClosing = true
            }
        }

        // Initiate CEF close for any Chromium browser panes.
        var chromiumPaneIds = Set<UUID>()
        for pane in allPanes {
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
        let nonChromiumIds = allPanes.filter { !chromiumPaneIds.contains($0.id) }.map { $0.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self else { return }
            for id in nonChromiumIds {
                if let index = self.panes.firstIndex(where: { $0.id == id }) {
                    self.panes.remove(at: index)
                }
            }
        }
    }

    /// Scroll the container so the currently focused pane (or the
    /// specified pane) is centered in the window.
    func centerPane(_ pane: PaneModel? = nil) {
        let target = pane ?? contextualPane
        guard let target = target else { return }

        requestCenteredScroll(to: target.id)
    }

    /// Triggers minimal scrolling so a pane is brought into view.
    /// If the pane is already the active target, toggles through nil so
    /// `onChange` still fires.
    private func requestRevealScroll(to paneId: UUID) {
        if focusedPaneId == paneId {
            focusedPaneId = nil
            DispatchQueue.main.async { [weak self] in
                self?.focusedPaneId = paneId
            }
        } else {
            focusedPaneId = paneId
        }
    }

    /// Triggers centered scrolling for a pane via `centeredPaneId`.
    /// If the pane is already the active target, toggles through nil so
    /// `onChange` still fires and re-centers.
    private func requestCenteredScroll(to paneId: UUID) {
        if centeredPaneId == paneId {
            centeredPaneId = nil
            DispatchQueue.main.async { [weak self] in
                self?.centeredPaneId = paneId
            }
        } else {
            centeredPaneId = paneId
        }
    }

    /// Resolve the initial width for a newly created terminal pane.
    /// Inherit width only when the contextual pane is also a terminal.
    private func terminalPaneWidthForNewPane(sourcePane: PaneModel?) -> CGFloat {
        guard let terminal = sourcePane as? TerminalPaneModel else {
            return PaneModel.defaultPaneWidth
        }
        return terminal.paneWidth
    }

    /// Resolve the initial width for a newly created browser pane.
    /// Inherit width only when the contextual pane is also a browser.
    private func browserPaneWidthForNewPane(sourcePane: PaneModel?) -> CGFloat {
        guard let browser = sourcePane as? BrowserPaneModel else {
            return PaneModel.defaultPaneWidth
        }
        return browser.paneWidth
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
        // Inherit the working directory from the contextual pane.
        // Width is inherited only when the contextual pane is also a terminal.
        let sourcePane = contextualPane
        let resolvedDirectory = directory
            ?? sourcePane?.directory
            ?? NSHomeDirectory()
        let paneWidth = terminalPaneWidthForNewPane(sourcePane: sourcePane)

        // Determine animation duration (hold Shift for slow-motion)
        let shiftHeld = NSEvent.modifierFlags.contains(.option)
        let duration: TimeInterval = shiftHeld ? 3.0 : 0.2

        let terminal = TerminalPaneModel(
            id: UUID(),
            title: "Terminal \(panes.count + 1)",
            status: .active,
            directory: resolvedDirectory,
            paneWidth: paneWidth,
            initialInput: initialInput
        )
        terminal.viewModel = self
        terminal.animationDuration = duration

        // Insert after the contextual pane, or append at the end if none is focused
        if let source = sourcePane,
           let sourceIndex = panes.firstIndex(where: { $0.id == source.id }) {
            panes.insert(terminal, at: sourceIndex + 1)
        } else {
            panes.append(terminal)
        }

        // Animate the pane in on the next run loop (after SwiftUI renders the initial frame)
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: duration)) {
                terminal.isAppearing = false
            }
        }

        return terminal
    }

    @discardableResult
    func addBrowser(url: URL = URL(string: "about:blank")!, engine: BrowserEngine? = nil) -> BrowserPaneModel {
        let sourcePane = contextualPane
        let paneWidth = browserPaneWidthForNewPane(sourcePane: sourcePane)

        // Determine animation duration (hold Shift for slow-motion)
        let shiftHeld = NSEvent.modifierFlags.contains(.option)
        let duration: TimeInterval = shiftHeld ? 3.0 : 0.2

        let browser = BrowserPaneModel(url: url, paneWidth: paneWidth, engine: engine ?? WatchtowerConfig.shared.browserEngine)
        browser.viewModel = self
        browser.animationDuration = duration

        // Insert after the contextual pane, or append at the end if none is focused
        if let source = sourcePane,
           let sourceIndex = panes.firstIndex(where: { $0.id == source.id }) {
            panes.insert(browser, at: sourceIndex + 1)
        } else {
            panes.append(browser)
        }

        // Animate the pane in on the next run loop (after SwiftUI renders the initial frame)
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: duration)) {
                browser.isAppearing = false
            }
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

    /// Insert a new browser pane at a specific slot index (used for external URL drops).
    /// `atSlot` is in the same coordinate system as `dropTargetIndex`:
    /// 0 = before first pane, panes.count = after last pane.
    @discardableResult
    func insertBrowser(url: URL, atSlot slot: Int) -> BrowserPaneModel {
        let paneWidth = browserPaneWidthForNewPane(sourcePane: contextualPane)

        let shiftHeld = NSEvent.modifierFlags.contains(.option)
        let duration: TimeInterval = shiftHeld ? 3.0 : 0.2

        let browser = BrowserPaneModel(url: url, paneWidth: paneWidth, engine: WatchtowerConfig.shared.browserEngine)
        browser.viewModel = self
        browser.animationDuration = duration

        let insertIndex = max(0, min(slot, panes.count))
        panes.insert(browser, at: insertIndex)

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: duration)) {
                browser.isAppearing = false
            }
        }

        focusPane(browser)
        return browser
    }

    func removePane(byId id: UUID) {
        let backtrace = Thread.callStackSymbols.joined(separator: "\n")
        NSLog("[CEF-CLOSE] removePane(byId: %@) called, panes.count=%d\n  backtrace:\n%@",
              id.uuidString, panes.count, backtrace)

        // Exit focus mode if the removed pane was the focus-mode target
        if id == focusModePaneId {
            exitFocusMode()
        }

        if browserFindPaneId == id {
            browserFindPaneId = nil
            browserFindQuery = ""
        }

        guard let index = panes.firstIndex(where: { $0.id == id }) else {
            NSLog("[CEF-CLOSE] removePane: pane %@ not found in array!", id.uuidString)
            return
        }

        // Don't re-trigger if already closing
        guard !panes[index].isClosing else { return }

        // Determine animation duration (hold Shift for slow-motion)
        let shiftHeld = NSEvent.modifierFlags.contains(.option)
        let duration: TimeInterval = shiftHeld ? 3.0 : 0.2
        panes[index].animationDuration = duration

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
            withAnimation(.easeInOut(duration: duration)) {
                self.panes.remove(at: removeIndex)
            }
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

        let duration = panes[index].animationDuration

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
            withAnimation(.easeInOut(duration: duration)) {
                panes.remove(at: index)
            }
            focusPaneById(neighborId)
        } else {
            NSLog("[CEF-CLOSE] finishRemovingCEFPane: removing last pane at index %d", index)
            withAnimation(.easeInOut(duration: duration)) {
                panes.remove(at: index)
            }
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
        // Ensure focused pane is visible (minimal scroll, no centering).
        // This must happen before any early returns below.
        requestRevealScroll(to: pane.id)

        // Auto-dismiss the command palette when focus moves to a different pane.
        if let paletteId = commandPalettePaneId, paletteId != pane.id {
            commandPalettePaneId = nil
        }

        if let findPaneId = browserFindPaneId, findPaneId != pane.id {
            dismissBrowserFind()
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
        let paneWidth = terminalPaneWidthForNewPane(sourcePane: sourcePane)

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
