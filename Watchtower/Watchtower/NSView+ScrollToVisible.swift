import AppKit

extension NSView {
    /// If this view is inside a scroll view and not fully visible,
    /// scroll just enough to bring it on screen with a 10px buffer.
    func scrollToVisibleInEnclosingScrollView() {
        // Walk up the view hierarchy to find the NSScrollView backing
        // SwiftUI's ScrollView.
        guard let scrollView = enclosingScrollView else { return }

        let clipView = scrollView.contentView

        // The pane's frame in the coordinate system of the scroll view's
        // document view (the content inside the scroll view).
        guard let documentView = scrollView.documentView else { return }
        let paneRect = self.convert(self.bounds, to: documentView)

        let buffer: CGFloat = 10
        let visibleRect = clipView.bounds

        // Determine if scrolling is needed and calculate the minimum
        // adjustment to bring the pane into view with the buffer.
        var newOrigin = visibleRect.origin

        if paneRect.minX - buffer < visibleRect.minX {
            // Pane is clipped on the left — scroll left
            newOrigin.x = paneRect.minX - buffer
        } else if paneRect.maxX + buffer > visibleRect.maxX {
            // Pane is clipped on the right — scroll right
            newOrigin.x = paneRect.maxX + buffer - visibleRect.width
        }

        // Clamp to valid scroll range
        let maxScrollX = max(0, documentView.frame.width - visibleRect.width)
        newOrigin.x = min(max(0, newOrigin.x), maxScrollX)

        if newOrigin != visibleRect.origin {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clipView.animator().setBoundsOrigin(newOrigin)
            }
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    /// Returns `true` if this view itself, or any ancestor (superview),
    /// is an instance of the given class (or a subclass of it).
    func isOrHasAncestor<T: NSView>(ofType type: T.Type) -> Bool {
        var current: NSView? = self
        while let v = current {
            if v is T { return true }
            current = v.superview
        }
        return false
    }
}
