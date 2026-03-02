import AppKit

extension NSView {
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

    /// Recursively finds the first descendant whose class name matches exactly.
    /// Useful for locating private AppKit views like NSTitlebarContainerView.
    func firstDescendant(withClassName name: String) -> NSView? {
        for subview in subviews {
            if String(describing: type(of: subview)) == name {
                return subview
            } else if let found = subview.firstDescendant(withClassName: name) {
                return found
            }
        }
        return nil
    }

    /// Walks up to the root of the view hierarchy and then searches downward
    /// for the first view whose class name matches. This finds private views
    /// (e.g. titlebar views) that are siblings of the contentView, not children.
    func firstViewFromRoot(withClassName name: String) -> NSView? {
        var root: NSView = self
        while let parent = root.superview { root = parent }
        if String(describing: type(of: root)) == name {
            return root
        }
        return root.firstDescendant(withClassName: name)
    }
}
