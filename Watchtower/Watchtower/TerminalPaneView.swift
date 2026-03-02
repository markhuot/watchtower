import SwiftUI
import UniformTypeIdentifiers

struct PaneView: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject var viewModel: PaneContainerViewModel
    @ObservedObject private var appManager = GhosttyAppManager.shared

    /// Per-window active state. `.key` means this window is the key window,
    /// `.active` means it's active but not key, `.inactive` means background.
    /// Using this instead of `appManager.isWindowActive` so that only the
    /// frontmost window shows the full-intensity focus highlight.
    @Environment(\.controlActiveState) private var controlActiveState

    /// Called when the close button is clicked.
    var onClose: (() -> Void)? = nil

    /// Called when a drag starts from this pane's title bar.
    var onDragStarted: (() -> Void)? = nil

    /// Called when a drag session ends (drop or cancel).
    var onDragEnded: (() -> Void)? = nil

    /// Called when the title bar is clicked (to focus the pane).
    var onHeaderTapped: (() -> Void)? = nil

    /// Called when the title bar is double-clicked (to expand a collapsed pane).
    var onHeaderDoubleTapped: (() -> Void)? = nil

    private let cornerRadius: CGFloat = 6

    /// Whether this window is the key (frontmost) window.
    private var isWindowKey: Bool {
        controlActiveState == .key
    }

    /// Whether the command palette is open on this pane.
    private var isPaletteOpenHere: Bool {
        viewModel.commandPalettePaneId == pane.id
    }

    /// Whether the highlight should be shown at full intensity.
    /// True only when the pane is focused AND the window is the key window
    /// AND the command palette is NOT open (palette draws its own outline).
    private var isHighlightActive: Bool {
        pane.isFocused && isWindowKey && !isPaletteOpenHere
    }

    /// A dimmed version of the highlight for when the pane is focused
    /// but the window is not the key window.
    private var isHighlightDimmed: Bool {
        pane.isFocused && !isWindowKey && !isPaletteOpenHere
    }

    /// The border color for the focus highlight, accounting for window activation state.
    /// When `hasBell` is true, the border uses the theme's bright red (palette 9).
    /// When `pane.headerColor` is set, that color replaces the default highlight color.
    /// The `.animation` modifier on the parent handles the smooth transition.
    private var highlightBorderColor: Color {
        if pane.hasBell {
            return appManager.bellColor
        } else if let custom = pane.headerColor {
            if isHighlightActive {
                return custom
            } else if isHighlightDimmed {
                return custom.opacity(0.3)
            } else {
                return custom.opacity(0.3)
            }
        } else if isHighlightActive {
            return appManager.highlightColor
        } else if isHighlightDimmed {
            return appManager.highlightColor.opacity(0.3)
        } else {
            return appManager.foregroundColor.opacity(0.08)
        }
    }

    /// The shadow color for the focus highlight glow.
    private var highlightShadowColor: Color {
        if pane.isCollapsed {
            return Color.clear  // no glow on collapsed panes — too narrow
        }
        if pane.hasBell {
            return appManager.bellColor.opacity(0.6)
        }
        if let custom = pane.headerColor {
            if isHighlightActive {
                return custom.opacity(0.6)
            } else {
                return Color.clear
            }
        }
        if isHighlightActive {
            return appManager.highlightColor.opacity(0.6)
        } else {
            return Color.clear
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Normal pane content — always in the hierarchy so terminals
            // and browsers keep running. Hidden visually when collapsed.
            // When collapsed, we clamp the content to the collapsed width
            // and clip overflow so it doesn't influence the ZStack's size.
            VStack(spacing: 0) {
                // Header — acts as drag handle with click-to-focus support
                ZStack(alignment: .leading) {
                    PaneHeaderView(pane: pane, onClose: onClose)
                        .overlay(
                            DragSourceView(
                                pane: pane,
                                onDragStarted: onDragStarted,
                                onDragEnded: onDragEnded,
                                onClicked: onHeaderTapped,
                                onDoubleClicked: onHeaderDoubleTapped
                            )
                        )

                    // Status circle sits above the drag overlay so hover/click works
                    StatusCircle(status: pane.status, onClose: onClose)
                        .padding(.leading, 12)

                    // Back / Forward buttons for browser panes — above the drag
                    // overlay so click events reach them.
                    if let browser = pane as? BrowserPaneModel {
                        HStack(spacing: 8) {
                            Button(action: { browser.goBack() }) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(appManager.headerTextColor.opacity(browser.canGoBack ? 0.9 : 0.25))
                            .disabled(!browser.canGoBack)
                            .frame(width: 16, height: 16)

                            Button(action: { browser.reloadOrStop() }) {
                                Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(appManager.headerTextColor.opacity(0.9))
                            .frame(width: 16, height: 16)

                            Button(action: { browser.goForward() }) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(appManager.headerTextColor.opacity(browser.canGoForward ? 0.9 : 0.25))
                            .disabled(!browser.canGoForward)
                            .frame(width: 16, height: 16)
                        }
                        // Position: 12px leading + 16px status circle + 8px gap
                        .padding(.leading, 36)
                    }
                }
                .frame(height: 44)

                // Content area — switches on pane type
                if let terminal = pane as? TerminalPaneModel {
                    GeometryReader { geo in
                        GhosttyTerminalView(terminal: terminal, size: geo.size)
                    }
                } else if let browser = pane as? BrowserPaneModel {
                    ZStack {
                        switch browser.engine {
                        case .webkit:
                            WebKitBrowserView(browser: browser)
                        case .chromium:
                            ChromiumBrowserRepresentable(browser: browser)
                        }
                    }
                    // During pane drag reorder or external URL drag, block the
                    // browser from intercepting the drag session. WKWebView and CEF
                    // register as NSDraggingDestination which steals the drag,
                    // preventing drops on neighboring panes.
                    .allowsHitTesting(viewModel.draggedPaneId == nil && !viewModel.isExternalURLDrag)
                }
            }
            .frame(width: pane.isCollapsed ? PaneModel.collapsedPaneWidth : nil)
            .clipped()
            .opacity(pane.isCollapsed ? 0 : 1)
            .allowsHitTesting(!pane.isCollapsed)

            // Collapsed overlay — sits on top when collapsed
            if pane.isCollapsed {
                CollapsedPaneContent(
                    pane: pane,
                    onClose: onClose,
                    onDragStarted: onDragStarted,
                    onDragEnded: onDragEnded,
                    onHeaderTapped: onHeaderTapped,
                    onHeaderDoubleTapped: onHeaderDoubleTapped
                )
            }

            // Command palette overlay (only on the pane it was opened from, never when collapsed)
            if isPaletteOpenHere && !pane.isCollapsed {
                // Dismiss layer — covers the pane area behind the palette
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.dismissCommandPalette()
                    }

                // Palette itself — positioned below the header, centered
                CommandPaletteView(viewModel: viewModel)
                    .frame(maxWidth: min(500, pane.paneWidth - 20))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 54)  // 44px header + 10px gap
                    .transition(.opacity)
            }
        }
        .background(appManager.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    highlightBorderColor,
                    lineWidth: 2
                )
                .shadow(
                    color: highlightShadowColor,
                    radius: 8
                )
                .allowsHitTesting(false)
        )
        .opacity(pane.isDragging ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: pane.isFocused)
        .animation(.easeInOut(duration: 0.15), value: controlActiveState)
        .animation(.easeInOut(duration: 0.15), value: pane.isDragging)
        .animation(.easeInOut(duration: 0.15), value: pane.hasBell)
        .animation(.easeInOut(duration: 0.15), value: pane.headerColor)
        .animation(.easeOut(duration: 0.15), value: viewModel.commandPalettePaneId)
        .animation(.easeInOut(duration: 0.2), value: pane.isCollapsed)
        .accessibilityIdentifier("pane")
    }
}

// MARK: - Collapsed Pane Content

/// The content shown when a pane is collapsed: a narrow vertical strip
/// with the status icon at the top and the title rotated 90 degrees.
/// The underlying terminal/browser continues running — only the view is hidden.
struct CollapsedPaneContent: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject private var appManager = GhosttyAppManager.shared
    var onClose: (() -> Void)? = nil
    var onDragStarted: (() -> Void)? = nil
    var onDragEnded: (() -> Void)? = nil
    var onHeaderTapped: (() -> Void)? = nil
    var onHeaderDoubleTapped: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Status circle at the top — left-aligned with the same 12px
            // leading padding as the expanded header so the icon doesn't
            // shift horizontally when collapsing/expanding.
            HStack {
                StatusCircle(status: pane.status, onClose: onClose)
                    .padding(.leading, 12)
                Spacer()
            }
            .padding(.top, 14)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Rotated title — placed in an overlay on the full-size VStack
        // so the text's natural (pre-rotation) width never influences the
        // collapsed pane's layout. rotationEffect is purely visual; SwiftUI
        // still uses the pre-rotation frame for sizing, so without this
        // technique long titles would push the pane wider than 30px.
        .overlay(alignment: .topLeading) {
            Text(pane.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(appManager.headerTextColor.opacity(0.7))
                .lineLimit(1)
                .fixedSize()
                .rotationEffect(.degrees(90), anchor: .topLeading)
                // After 90° rotation around topLeading the text extends
                // rightward (old width is now height) and its visual top
                // sits at the anchor. Offset down past the status circle
                // (14pt padding + 16pt circle + 12pt gap = 42pt) and right
                // to center it horizontally in the ~40px strip.
                .offset(x: 27, y: 42)
        }
        .background(appManager.backgroundColor.opacity(0.8))
        .overlay(
            DragSourceView(
                pane: pane,
                onDragStarted: onDragStarted,
                onDragEnded: onDragEnded,
                onClicked: onHeaderTapped,
                onDoubleClicked: onHeaderDoubleTapped
            )
        )
    }
}

struct PaneHeaderView: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject private var appManager = GhosttyAppManager.shared
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Invisible spacer matching the status circle's interactive size.
                // The actual StatusCircle is rendered above the drag overlay in PaneView
                // so that hover/click events reach it.
                Color.clear
                    .frame(width: 16, height: 16)

                // Reserve space for back/reload/forward buttons on browser panes.
                // The actual buttons are rendered above the drag overlay in PaneView
                // so that click events reach them.
                if pane is BrowserPaneModel {
                    Color.clear.frame(width: 16, height: 16)
                    Color.clear.frame(width: 16, height: 16)
                    Color.clear.frame(width: 16, height: 16)
                }

                // Title (from terminal/browser)
                Text(pane.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(appManager.headerTextColor.opacity(0.9))
                    .lineLimit(1)

                Spacer()

                // Subtitle (directory/branch for terminals, host for browsers)
                if let subtitle = pane.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(appManager.headerTextColor.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4) // nudge content down to visually center (compensate for descender space)
            .frame(maxHeight: .infinity)

            // Progress bar — 4px bottom border
            ProgressBarView(progress: pane.progress)
                .frame(height: 4)
        }
        .background(appManager.backgroundColor.opacity(0.8))
    }
}

// MARK: - Progress Bar

struct ProgressBarView: View {
    let progress: PaneProgress?

    @State private var indeterminateOffset: CGFloat = -0.3

    private var progressColor: Color {
        guard let progress = progress else { return .clear }
        switch progress.state {
        case .normal: return .accentColor
        case .error: return .red
        case .paused: return .orange
        case .indeterminate: return .accentColor
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background — always clear
                Color.clear

                if let progress = progress {
                    if progress.state == .indeterminate || (progress.state != .indeterminate && progress.value == nil) {
                        // Indeterminate bouncing bar
                        RoundedRectangle(cornerRadius: 2)
                            .fill(progressColor)
                            .frame(width: geo.size.width * 0.3)
                            .offset(x: indeterminateOffset * geo.size.width)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                                    indeterminateOffset = 1.0
                                }
                            }
                    } else if let value = progress.value {
                        // Determinate progress bar
                        Rectangle()
                            .fill(progressColor)
                            .frame(width: geo.size.width * CGFloat(max(0, min(1, value))))
                            .animation(.linear(duration: 0.2), value: value)
                    }
                }
            }
        }
    }
}

struct StatusCircle: View {
    let status: PaneStatus
    var onClose: (() -> Void)? = nil
    @ObservedObject private var appManager = GhosttyAppManager.shared

    @State private var isHovered = false

    var body: some View {
        ZStack {
            if isHovered && onClose != nil {
                // Close button on hover
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(appManager.headerTextColor.opacity(0.7))
                    .frame(width: 16, height: 16)
                    .background(appManager.headerTextColor.opacity(0.15))
                    .clipShape(Circle())
                    .onTapGesture {
                        onClose?()
                    }
            } else {
                // Normal status circle
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.8), radius: 4, x: 0, y: 0)
            }
        }
        .frame(width: 16, height: 16)
        .contentShape(Circle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var statusColor: Color {
        switch status {
        case .active:
            return .yellow
        case .idle:
            return .green
        case .failed:
            return .red
        }
    }
}

struct PaneView_Previews: PreviewProvider {
    static var previews: some View {
        PaneView(
            pane: TerminalPaneModel(
                id: UUID(),
                title: "vim",
                status: .active,
                directory: "/Users/username/projects"
            ),
            viewModel: PaneContainerViewModel()
        )
        .frame(width: 760, height: 600)
    }
}

/// The drag preview shown while dragging a pane by its title bar.
/// Shows the status circle and the pane title in a compact pill.
struct DragPreviewView: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject private var appManager = GhosttyAppManager.shared

    var body: some View {
        HStack(spacing: 8) {
            StatusCircle(status: pane.status)
            Text(pane.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(appManager.headerTextColor.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(appManager.backgroundColor.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Custom Drag Source

/// An NSView-based drag source overlay for the header.
/// Handles click-to-focus with a minimum drag distance threshold before
/// starting an NSDraggingSession.
struct DragSourceView: NSViewRepresentable {
    let pane: PaneModel
    var onDragStarted: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onClicked: (() -> Void)?
    var onDoubleClicked: (() -> Void)?

    func makeNSView(context: Context) -> DragSourceNSView {
        let view = DragSourceNSView()
        view.pane = pane
        view.onDragStarted = onDragStarted
        view.onDragEnded = onDragEnded
        view.onClicked = onClicked
        view.onDoubleClicked = onDoubleClicked
        return view
    }

    func updateNSView(_ nsView: DragSourceNSView, context: Context) {
        nsView.pane = pane
        nsView.onDragStarted = onDragStarted
        nsView.onDragEnded = onDragEnded
        nsView.onClicked = onClicked
        nsView.onDoubleClicked = onDoubleClicked
    }
}

class DragSourceNSView: NSView, NSDraggingSource {
    var pane: PaneModel!
    var onDragStarted: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onClicked: (() -> Void)?
    var onDoubleClicked: (() -> Void)?

    /// Minimum distance in points before a drag begins.
    private let dragThreshold: CGFloat = 5.0
    private var mouseDownLocation: NSPoint?

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLocation = mouseDownLocation else { return }
        let currentLocation = event.locationInWindow
        let dx = currentLocation.x - startLocation.x
        let dy = currentLocation.y - startLocation.y
        let distance = sqrt(dx * dx + dy * dy)

        guard distance >= dragThreshold else { return }

        // Past threshold — begin a drag session
        mouseDownLocation = nil // prevent re-triggering

        pane.isDragging = true
        onDragStarted?()

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(pane.id.uuidString, forType: .string)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

        // Create the drag preview image from DragPreviewView
        let previewView = DragPreviewView(pane: pane)
        let renderer = ImageRenderer(content: previewView)
        renderer.scale = window?.backingScaleFactor ?? 2.0

        if let image = renderer.nsImage {
            let draggingFrame = NSRect(
                origin: convert(event.locationInWindow, from: nil),
                size: image.size
            )
            // Center the image on the cursor
            let centeredFrame = NSRect(
                x: draggingFrame.origin.x - image.size.width / 2,
                y: draggingFrame.origin.y - image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            )
            draggingItem.setDraggingFrame(centeredFrame, contents: image)
        }

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        // If we get a mouseUp without having started a drag, it's a click
        if mouseDownLocation != nil {
            mouseDownLocation = nil
            if event.clickCount == 2 {
                onDoubleClicked?()
            } else {
                onClicked?()
            }
        }
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded?()
    }
}
