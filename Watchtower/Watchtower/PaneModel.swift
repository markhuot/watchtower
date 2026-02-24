import Foundation
import SwiftUI

// MARK: - PaneStatus

/// Shared status enum used by all pane types.
enum PaneStatus {
    /// The pane has active work (terminal: foreground process; browser: page loading).
    case active
    /// The pane is idle (terminal: shell prompt; browser: page loaded with HTTP 2xx).
    case idle
    /// The pane encountered an error (terminal: non-zero exit; browser: navigation error or non-2xx HTTP).
    case failed
}

// MARK: - PaneProgress

/// Progress state for the universal header progress bar.
struct PaneProgress {
    enum State {
        case normal        // standard progress (accent color)
        case error         // error state (red)
        case paused        // paused state (orange)
        case indeterminate // bouncing animation, no percentage
    }

    let state: State
    let value: Double?    // 0.0-1.0, nil for indeterminate
}

// MARK: - PaneModel

/// Base class for all pane types (terminal, browser, etc.).
/// Holds shared properties and defines the interface that subclasses override.
class PaneModel: Identifiable, ObservableObject {
    let id: UUID
    @Published var paneWidth: CGFloat
    @Published var isFocused: Bool = false
    @Published var isDragging: Bool = false

    /// Weak reference to the parent view model, used by NSViews to check
    /// `pendingFocus` in `viewDidMoveToWindow`. Set when the pane is added
    /// to the view model's `panes` array.
    weak var viewModel: PaneContainerViewModel?

    /// Default pane width: 80 columns * 9px per char + 40px padding
    static let defaultPaneWidth: CGFloat = 80 * 9 + 40

    // Subclasses override these computed properties
    var title: String { "" }
    var subtitle: String? { nil }
    var status: PaneStatus { .idle }
    var progress: PaneProgress? { nil }
    var directory: String? { nil }

    /// Minimum width when this pane is the focus-mode target.
    /// Terminals use a column-based width for legibility; subclasses
    /// (e.g. browser) can override to fill more of the window.
    func focusModeMinWidth(windowWidth: CGFloat) -> CGFloat {
        // 150 columns * ~9px per char + 40px padding
        return 150 * 9 + 40
    }

    init(id: UUID, paneWidth: CGFloat = PaneModel.defaultPaneWidth) {
        self.id = id
        self.paneWidth = paneWidth
    }
}
