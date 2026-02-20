import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = TerminalContainerViewModel()
    @ObservedObject private var appManager = GhosttyAppManager.shared

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    ForEach(viewModel.terminals) { terminal in
                        TerminalPaneWithHandle(
                            terminal: terminal,
                            allTerminals: viewModel.terminals
                        )
                    }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(appManager.backgroundColor)
        .onReceive(NotificationCenter.default.publisher(for: .addTerminal)) { _ in
            viewModel.addTerminal()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusPreviousPane)) { _ in
            viewModel.focusPreviousPane()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusNextPane)) { _ in
            viewModel.focusNextPane()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttySurfaceClosed)) { notification in
            if let view = notification.object as? GhosttyTerminalNSView {
                viewModel.removeTerminal(byId: view.terminal.id)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { viewModel.addTerminal() }) {
                    Image(systemName: "plus")
                }
            }
        }
    }
}

/// A terminal pane with a draggable resize handle on its right edge.
struct TerminalPaneWithHandle: View {
    @ObservedObject var terminal: TerminalModel
    let allTerminals: [TerminalModel]

    /// Width at the moment the drag started.
    @State private var dragStartWidth: CGFloat? = nil

    /// Minimum pane width in points.
    private let minPaneWidth: CGFloat = 200

    /// Approximate cell width in points (matches TerminalModel.defaultPaneWidth calculation).
    private static let estimatedCellWidth: CGFloat = 9

    /// Snap a width to the nearest cell boundary to prevent sub-cell jitter.
    static func snapToGrid(_ width: CGFloat) -> CGFloat {
        let padding: CGFloat = 40 // matches TerminalModel default padding
        let cols = round((width - padding) / estimatedCellWidth)
        return cols * estimatedCellWidth + padding
    }

    var body: some View {
        HStack(spacing: 0) {
            TerminalPaneView(terminal: terminal)
                .frame(width: terminal.paneWidth)
                .animation(nil, value: terminal.paneWidth)

            // Resize handle: a thin draggable strip on the right edge
            Rectangle()
                .fill(Color.clear)
                .frame(width: 6)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragStartWidth == nil {
                                dragStartWidth = terminal.paneWidth
                            }

                            let rawWidth = max(
                                minPaneWidth,
                                (dragStartWidth ?? terminal.paneWidth) + value.translation.width
                            )

                            // Snap to cell grid to prevent jitter
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
                            dragStartWidth = nil
                        }
                )
        }
    }
}

class TerminalContainerViewModel: ObservableObject {
    @Published var terminals: [TerminalModel] = []

    init() {
        // Start with one terminal
        addTerminal()
    }

    func addTerminal() {
        let terminal = TerminalModel(
            id: UUID(),
            title: "Terminal \(terminals.count + 1)",
            status: .running,
            directory: NSHomeDirectory()
        )
        terminals.append(terminal)
    }

    func removeTerminal(_ terminal: TerminalModel) {
        removeTerminal(byId: terminal.id)
    }

    func removeTerminal(byId id: UUID) {
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

    private func makeFocused(index: Int) {
        let terminal = terminals[index]
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else { return }

        // Find all GhosttyTerminalNSViews in the window
        func findAllTerminalViews(in view: NSView) -> [GhosttyTerminalNSView] {
            var results: [GhosttyTerminalNSView] = []
            if let tv = view as? GhosttyTerminalNSView {
                results.append(tv)
            }
            for subview in view.subviews {
                results.append(contentsOf: findAllTerminalViews(in: subview))
            }
            return results
        }

        let allViews = findAllTerminalViews(in: contentView)

        // Match by terminal ID
        if let targetView = allViews.first(where: { $0.terminal.id == terminal.id }) {
            window.makeFirstResponder(targetView)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
