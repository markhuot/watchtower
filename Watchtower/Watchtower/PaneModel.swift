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
    @Published var isCollapsed: Bool = false
    @Published var isClosing: Bool = false
    @Published var isAppearing: Bool = true

    /// Duration of the close/appear animation. Normally 0.2s, but 3s when
    /// Shift is held (standard macOS slow-motion convention).
    var animationDuration: TimeInterval = 0.2

    /// Whether the bell/alert has been rung and not yet acknowledged.
    /// Set to `true` when the terminal rings the bell. Cleared after
    /// the pane has been focused for 1 second.
    @Published var hasBell: Bool = false

    /// Monotonic token incremented for each bell event.
    /// Unlike `hasBell`, this changes on every bell so the UI can trigger
    /// transient effects (like a shake) even when the bell indicator is
    /// already visible.
    @Published var bellEventToken: UInt64 = 0

    /// Custom header background color for this pane. When `nil`, the
    /// default theme background is used. Set via the command palette's
    /// "Set Pane Color" action.
    @Published var headerColor: Color? = nil

    /// Weak reference to the parent view model, used by NSViews to check
    /// `pendingFocus` in `viewDidMoveToWindow`. Set when the pane is added
    /// to the view model's `panes` array.
    weak var viewModel: PaneContainerViewModel?

    /// Default pane width: 80 columns * 10px per char + 40px padding
    static let defaultPaneWidth: CGFloat = 80 * 10 + 40

    /// Width of a collapsed pane strip (status icon + rotated title).
    /// Sized so the status icon stays at the same horizontal position
    /// (12px leading + 8px center = 20px) as in the expanded header.
    static let collapsedPaneWidth: CGFloat = 40

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
