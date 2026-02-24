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

    /// Called when a drag starts from this pane's title bar.
    var onDragStarted: (() -> Void)? = nil

    /// Called when the title bar is clicked (to focus the pane).
    var onHeaderTapped: (() -> Void)? = nil
    
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
    private var highlightBorderColor: Color {
        if isHighlightActive {
            return appManager.highlightColor
        } else if isHighlightDimmed {
            return appManager.highlightColor.opacity(0.3)
        } else {
            return appManager.foregroundColor.opacity(0.08)
        }
    }

    /// The shadow color for the focus highlight glow.
    private var highlightShadowColor: Color {
        if isHighlightActive {
            return appManager.highlightColor.opacity(0.6)
        } else {
            return Color.clear
        }
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            // Existing pane content (header + content area)
            VStack(spacing: 0) {
                // Header — acts as drag handle with click-to-focus support
                PaneHeaderView(pane: pane)
                    .frame(height: 40)
                    .overlay(
                        DragSourceView(
                            pane: pane,
                            onDragStarted: onDragStarted,
                            onClicked: onHeaderTapped
                        )
                    )
                
                // Content area — switches on pane type
                if let terminal = pane as? TerminalPaneModel {
                    GeometryReader { geo in
                        GhosttyTerminalView(terminal: terminal, size: geo.size)
                    }
                } else if let browser = pane as? BrowserPaneModel {
                    BrowserWebView(browser: browser)
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

            // Command palette overlay (only on the pane it was opened from)
            if isPaletteOpenHere {
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
                    .padding(.top, 50)  // 40px header + 10px gap
                    .transition(.opacity)
            }
        }
        .opacity(pane.isDragging ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: pane.isFocused)
        .animation(.easeInOut(duration: 0.15), value: controlActiveState)
        .animation(.easeInOut(duration: 0.15), value: pane.isDragging)
        .animation(.easeOut(duration: 0.15), value: viewModel.commandPalettePaneId)
    }
}

struct PaneHeaderView: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject private var appManager = GhosttyAppManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Status indicator — glowing circle
                StatusCircle(status: pane.status)
                
                // Title (from terminal/browser)
                Text(pane.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                
                Spacer()

                // Subtitle (directory/branch for terminals, host for browsers)
                if let subtitle = pane.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
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
    
    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .shadow(color: statusColor.opacity(0.8), radius: 4, x: 0, y: 0)
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

    var body: some View {
        HStack(spacing: 8) {
            StatusCircle(status: pane.status)
            Text(pane.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.15))
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
    var onClicked: (() -> Void)?

    func makeNSView(context: Context) -> DragSourceNSView {
        let view = DragSourceNSView()
        view.pane = pane
        view.onDragStarted = onDragStarted
        view.onClicked = onClicked
        return view
    }

    func updateNSView(_ nsView: DragSourceNSView, context: Context) {
        nsView.pane = pane
        nsView.onDragStarted = onDragStarted
        nsView.onClicked = onClicked
    }
}

class DragSourceNSView: NSView, NSDraggingSource {
    var pane: PaneModel!
    var onDragStarted: (() -> Void)?
    var onClicked: (() -> Void)?

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
            onClicked?()
        }
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }
}
