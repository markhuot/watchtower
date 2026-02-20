import SwiftUI
import UniformTypeIdentifiers

struct TerminalPaneView: View {
    @ObservedObject var terminal: TerminalModel
    @ObservedObject private var appManager = GhosttyAppManager.shared

    /// Called when a drag starts from this pane's title bar.
    var onDragStarted: (() -> Void)? = nil

    /// Called when the title bar is clicked (to focus the pane).
    var onHeaderTapped: (() -> Void)? = nil
    
    private let cornerRadius: CGFloat = 6

    /// Whether the highlight should be shown at full intensity.
    /// True only when the pane is focused AND the window is active.
    private var isHighlightActive: Bool {
        terminal.isFocused && appManager.isWindowActive
    }

    /// A dimmed version of the highlight for when the pane is focused
    /// but the window is inactive.
    private var isHighlightDimmed: Bool {
        terminal.isFocused && !appManager.isWindowActive
    }

    /// The border color for the focus highlight, accounting for window activation state.
    private var highlightBorderColor: Color {
        if isHighlightActive {
            return appManager.highlightColor
        } else if isHighlightDimmed {
            return appManager.highlightColor.opacity(0.3)
        } else {
            return Color.clear
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
        VStack(spacing: 0) {
            // Header — acts as drag handle with click-to-focus support
            TerminalHeaderView(terminal: terminal)
                .frame(height: 40)
                .overlay(
                    DragSourceView(
                        terminal: terminal,
                        onDragStarted: onDragStarted,
                        onClicked: onHeaderTapped
                    )
                )
            
            // Terminal content area - use GeometryReader to get accurate size
            GeometryReader { geo in
                GhosttyTerminalView(terminal: terminal, size: geo.size)
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
        .opacity(terminal.isDragging ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: terminal.isFocused)
        .animation(.easeInOut(duration: 0.15), value: appManager.isWindowActive)
        .animation(.easeInOut(duration: 0.15), value: terminal.isDragging)
    }
}

struct TerminalHeaderView: View {
    @ObservedObject var terminal: TerminalModel
    @ObservedObject private var appManager = GhosttyAppManager.shared
    
    var body: some View {
        HStack(spacing: 8) {
            // Status indicator — glowing circle
            StatusCircle(status: terminal.status)
            
            // Title (from terminal/running program)
            Text(terminal.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
            
            Spacer()

            // Current working directory (flush right)
            Text(terminal.abbreviatedDirectory)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .background(appManager.backgroundColor.opacity(0.8))
    }
}

struct StatusCircle: View {
    let status: TerminalStatus
    
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

struct TerminalPaneView_Previews: PreviewProvider {
    static var previews: some View {
        TerminalPaneView(terminal: TerminalModel(
            id: UUID(),
            title: "vim",
            status: .active,
            directory: "/Users/username/projects"
        ))
        .frame(width: 760, height: 600)
    }
}

/// The drag preview shown while dragging a pane by its title bar.
/// Shows the status circle and the terminal title in a compact pill.
struct DragPreviewView: View {
    @ObservedObject var terminal: TerminalModel

    var body: some View {
        HStack(spacing: 8) {
            StatusCircle(status: terminal.status)
            Text(terminal.title)
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
    let terminal: TerminalModel
    var onDragStarted: (() -> Void)?
    var onClicked: (() -> Void)?

    func makeNSView(context: Context) -> DragSourceNSView {
        let view = DragSourceNSView()
        view.terminal = terminal
        view.onDragStarted = onDragStarted
        view.onClicked = onClicked
        return view
    }

    func updateNSView(_ nsView: DragSourceNSView, context: Context) {
        nsView.terminal = terminal
        nsView.onDragStarted = onDragStarted
        nsView.onClicked = onClicked
    }
}

class DragSourceNSView: NSView, NSDraggingSource {
    var terminal: TerminalModel!
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

        terminal.isDragging = true
        onDragStarted?()

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(terminal.id.uuidString, forType: .string)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

        // Create the drag preview image from DragPreviewView
        let previewView = DragPreviewView(terminal: terminal)
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
