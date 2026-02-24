import SwiftUI
import AppKit

// MARK: - Command Palette Item

/// A single entry in the command palette's list.
struct CommandPaletteItem: Identifiable {
    let id = UUID()
    let displayName: String
    let description: String?
    let shortcutText: String?
    let sourceTag: String?  // "[project]" or "[global]", nil for built-in
    /// Whether this item is a "query action" (Go to URL, Search the web)
    /// that uses the palette text as input rather than matching against it.
    let isQueryAction: Bool
    /// Preview text shown on the right side for query actions.
    let queryPreview: String?
    let action: (PaneContainerViewModel) -> Void

    /// Create a built-in command item.
    static func builtIn(
        name: String,
        shortcut: String? = nil,
        action: @escaping (PaneContainerViewModel) -> Void
    ) -> CommandPaletteItem {
        CommandPaletteItem(
            displayName: name,
            description: nil,
            shortcutText: shortcut,
            sourceTag: nil,
            isQueryAction: false,
            queryPreview: nil,
            action: action
        )
    }

    /// Create a query action item (Go to URL, Search the web).
    static func queryAction(
        name: String,
        queryPreview: String,
        action: @escaping (PaneContainerViewModel) -> Void
    ) -> CommandPaletteItem {
        CommandPaletteItem(
            displayName: name,
            description: nil,
            shortcutText: nil,
            sourceTag: nil,
            isQueryAction: true,
            queryPreview: queryPreview,
            action: action
        )
    }

    /// Create an item from a discovered Action.
    /// Actions that trigger a new terminal pane manage focus themselves
    /// via `focusPane()` inside `triggerAction`.
    static func fromAction(_ actionModel: Action) -> CommandPaletteItem {
        CommandPaletteItem(
            displayName: actionModel.displayName,
            description: actionModel.descriptionText,
            shortcutText: nil,
            sourceTag: actionModel.isGlobal ? "[global]" : "[project]",
            isQueryAction: false,
            queryPreview: nil,
            action: { viewModel in
                viewModel.triggerAction(actionModel)
            }
        )
    }
}

// MARK: - Filtered Result

/// A command palette item paired with its fuzzy match result for display.
struct FilteredPaletteItem: Identifiable {
    let id: UUID
    let item: CommandPaletteItem
    let nameMatch: FuzzyMatchResult?
    let descriptionMatch: FuzzyMatchResult?
    let score: Int
}

// MARK: - URL Detection

/// Determine if a string looks like a URL rather than a search query.
func isURLLike(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return false }

    // Contains a scheme
    if trimmed.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) != nil {
        return true
    }

    // Starts with localhost
    if trimmed.hasPrefix("localhost") {
        return true
    }

    // Looks like a domain: no spaces, contains a dot, ends with TLD-like suffix
    if !trimmed.contains(" ") && trimmed.contains(".") {
        return true
    }

    return false
}

/// Normalize a URL string by adding a scheme if missing.
func normalizeURL(_ text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    // Already has a scheme
    if trimmed.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) != nil {
        return URL(string: trimmed)
    }

    // localhost or IP addresses get http://
    if trimmed.hasPrefix("localhost") || trimmed.range(of: "^\\d{1,3}\\.\\d{1,3}", options: .regularExpression) != nil {
        return URL(string: "http://\(trimmed)")
    }

    // Everything else gets https://
    return URL(string: "https://\(trimmed)")
}

// MARK: - Command Palette View

struct CommandPaletteView: View {
    @ObservedObject var viewModel: PaneContainerViewModel
    @ObservedObject private var appManager = GhosttyAppManager.shared

    @State private var filterText: String = ""
    @State private var selectedIndex: Int = 0

    private let maxVisibleItems = 10
    private let cornerRadius: CGFloat = 8

    /// Whether the focused pane is a browser.
    private var isBrowserFocused: Bool {
        viewModel.contextualPane is BrowserPaneModel
    }

    /// Build the full command list from built-in commands + discovered actions.
    private var allItems: [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        // Built-in commands (always visible)
        items.append(.builtIn(name: "New Terminal", shortcut: "\u{2318}T") { vm in
            let terminal = vm.addTerminal()
            vm.focusPane(terminal)
        })
        items.append(.builtIn(name: "New Browser") { vm in
            let browser = vm.addBrowser()
            vm.focusPane(browser)
        })
        items.append(.builtIn(name: "Close Pane", shortcut: "\u{2318}W") { vm in
            vm.closeCurrentPane()
        })
        items.append(.builtIn(name: "Toggle Full Screen", shortcut: "\u{2303}\u{2318}F") { vm in
            NSApp.keyWindow?.toggleFullScreen(nil)
        })
        items.append(.builtIn(name: "Minimize", shortcut: "\u{2318}M") { vm in
            NSApp.keyWindow?.miniaturize(nil)
        })
        items.append(.builtIn(name: "Zoom") { vm in
            NSApp.keyWindow?.zoom(nil)
        })
        items.append(.builtIn(name: "Focus Previous Pane", shortcut: "\u{2318}\u{21E7}[") { vm in
            vm.focusPreviousPane()
        })
        items.append(.builtIn(name: "Focus Next Pane", shortcut: "\u{2318}\u{21E7}]") { vm in
            vm.focusNextPane()
        })
        items.append(.builtIn(name: "Toggle Focus Mode", shortcut: "\u{2318}\u{21E7}\u{21A9}") { vm in
            vm.toggleFocusMode()
        })
        items.append(.builtIn(name: "Move Pane Left", shortcut: "\u{2318}\u{2325}[") { vm in
            vm.movePaneLeft()
        })
        items.append(.builtIn(name: "Move Pane Right", shortcut: "\u{2318}\u{2325}]") { vm in
            vm.movePaneRight()
        })

        // Browser-specific commands (only when browser pane is focused)
        if isBrowserFocused {
            items.append(.builtIn(name: "Go Back", shortcut: "\u{2318}[") { vm in
                if let browser = vm.contextualPane as? BrowserPaneModel,
                   let window = NSApp.keyWindow,
                   let contentView = window.contentView,
                   let webView = findWebView(for: browser.id, in: contentView) {
                    webView.goBack()
                }
            })
            items.append(.builtIn(name: "Go Forward", shortcut: "\u{2318}]") { vm in
                if let browser = vm.contextualPane as? BrowserPaneModel,
                   let window = NSApp.keyWindow,
                   let contentView = window.contentView,
                   let webView = findWebView(for: browser.id, in: contentView) {
                    webView.goForward()
                }
            })
            items.append(.builtIn(name: "Reload Page", shortcut: "\u{2318}R") { vm in
                if let browser = vm.contextualPane as? BrowserPaneModel,
                   let window = NSApp.keyWindow,
                   let contentView = window.contentView,
                   let webView = findWebView(for: browser.id, in: contentView) {
                    webView.reload()
                }
            })
        }

        // Project actions
        for action in viewModel.projectActions {
            items.append(.fromAction(action))
        }

        // Global actions
        for action in viewModel.globalActions {
            items.append(.fromAction(action))
        }

        return items
    }

    /// Filter and score items against the current query.
    private var filteredItems: [FilteredPaletteItem] {
        let items = allItems

        if filterText.isEmpty {
            return items.enumerated().map { (index, item) in
                FilteredPaletteItem(
                    id: item.id,
                    item: item,
                    nameMatch: nil,
                    descriptionMatch: nil,
                    score: items.count - index  // preserve original order
                )
            }
        }

        // Fuzzy-match regular items
        var results: [FilteredPaletteItem] = []
        for item in items {
            let nameMatch = fuzzyMatch(query: filterText, candidate: item.displayName)
            let descMatch: FuzzyMatchResult?
            if let desc = item.description {
                descMatch = fuzzyMatch(query: filterText, candidate: desc)
            } else {
                descMatch = nil
            }

            if nameMatch != nil || descMatch != nil {
                // Name matches rank higher than description-only matches
                let score = nameMatch?.score ?? ((descMatch?.score ?? 0) - 100)
                results.append(FilteredPaletteItem(
                    id: item.id,
                    item: item,
                    nameMatch: nameMatch,
                    descriptionMatch: descMatch,
                    score: score
                ))
            }
        }

        // Sort by score descending
        results.sort { $0.score > $1.score }

        // Add query action items (Go to URL, Search the web) — always shown
        // when query is non-empty, exempt from fuzzy matching
        let queryText = filterText.trimmingCharacters(in: .whitespaces)
        if !queryText.isEmpty {
            let urlLike = isURLLike(queryText)

            let goToURL = CommandPaletteItem.queryAction(
                name: "Go to URL",
                queryPreview: queryText
            ) { vm in
                guard let url = normalizeURL(queryText) else { return }
                if let browser = vm.contextualPane as? BrowserPaneModel {
                    browser.navigate(to: url)
                } else {
                    let browser = vm.addBrowser(url: url)
                    vm.focusPane(browser)
                }
            }

            let searchWeb = CommandPaletteItem.queryAction(
                name: "Search the web",
                queryPreview: queryText
            ) { vm in
                let encoded = queryText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? queryText
                guard let url = URL(string: "https://duckduckgo.com/?q=\(encoded)") else { return }
                if let browser = vm.contextualPane as? BrowserPaneModel {
                    browser.navigate(to: url)
                } else {
                    let browser = vm.addBrowser(url: url)
                    vm.focusPane(browser)
                }
            }

            // URL-like queries: Go to URL first; non-URL: Search first
            let firstAction = urlLike ? goToURL : searchWeb
            let secondAction = urlLike ? searchWeb : goToURL

            results.append(FilteredPaletteItem(
                id: firstAction.id,
                item: firstAction,
                nameMatch: nil,
                descriptionMatch: nil,
                score: -1000  // below fuzzy matches
            ))
            results.append(FilteredPaletteItem(
                id: secondAction.id,
                item: secondAction,
                nameMatch: nil,
                descriptionMatch: nil,
                score: -1001  // below first query action
            ))
        }

        return results
    }

    /// The visible items (capped at maxVisibleItems).
    private var visibleItems: [FilteredPaletteItem] {
        Array(filteredItems.prefix(maxVisibleItems))
    }

    /// Whether there are more items than what's shown.
    private var hasMore: Bool {
        filteredItems.count > maxVisibleItems
    }

    /// Index of the first query action in visibleItems, for separator drawing.
    private var queryActionSeparatorIndex: Int? {
        visibleItems.firstIndex(where: { $0.item.isQueryAction })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            CommandPaletteTextField(
                text: $filterText,
                onArrowUp: { moveSelection(by: -1) },
                onArrowDown: { moveSelection(by: 1) },
                onSubmit: { executeSelected() },
                onEscape: { viewModel.dismissCommandPalette() }
            )
            .frame(height: 36)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()
                .background(Color.white.opacity(0.1))

            // Results list
            if visibleItems.isEmpty {
                HStack {
                    Text("No matching commands")
                        .foregroundColor(.white.opacity(0.4))
                        .font(.system(size: 13))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, filteredItem in
                        // Draw separator before query actions
                        if index == queryActionSeparatorIndex && index > 0 {
                            Divider()
                                .background(Color.white.opacity(0.1))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 4)
                        }

                        CommandPaletteRow(
                            item: filteredItem,
                            isSelected: index == selectedIndex,
                            highlightColor: appManager.highlightColor
                        )
                        .id(filteredItem.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedIndex = index
                            executeSelected()
                        }
                    }

                    if hasMore {
                        HStack {
                            Spacer()
                            Text("More...")
                                .foregroundColor(.white.opacity(0.3))
                                .font(.system(size: 12))
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(appManager.highlightColor, lineWidth: 2)
                .shadow(color: appManager.highlightColor.opacity(0.6), radius: 8)
        )
        .shadow(color: .black.opacity(0.5), radius: 40, x: 0, y: 15)
        .onChange(of: filterText) { _ in
            // Reset selection when filter changes
            selectedIndex = 0
        }
    }

    private func moveSelection(by offset: Int) {
        guard !visibleItems.isEmpty else { return }
        let count = visibleItems.count
        selectedIndex = (selectedIndex + offset + count) % count
    }

    private func executeSelected() {
        guard selectedIndex >= 0 && selectedIndex < visibleItems.count else { return }
        let item = visibleItems[selectedIndex].item
        // Snapshot the focus generation before the action runs.
        // If the action calls focusPane(), the generation advances and
        // dismiss will preserve the action's focus target.
        let gen = viewModel.focusGeneration
        // Run the action BEFORE dismissing so that `contextualPane` can
        // still resolve via `commandPalettePaneId`. Actions that create
        // new panes call `focusPane()` which bumps `focusGeneration`.
        item.action(viewModel)
        // Dismiss tears down the palette UI. If the generation hasn't
        // changed (action didn't call focusPane), dismiss restores focus
        // to the original pane. Otherwise, the action's focus is preserved.
        viewModel.dismissCommandPalette(beforeGeneration: gen)
    }
}

// MARK: - Command Palette Row

struct CommandPaletteRow: View {
    let item: FilteredPaletteItem
    let isSelected: Bool
    let highlightColor: Color

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                // Name with highlighted matched characters
                highlightedText(
                    item.item.displayName,
                    matchedIndices: item.nameMatch?.matchedIndices ?? [],
                    baseColor: .white.opacity(0.9),
                    matchColor: highlightColor
                )
                .font(.system(size: 13, weight: .medium))

                // Description subtitle
                if let desc = item.item.description {
                    highlightedText(
                        desc,
                        matchedIndices: (item.nameMatch == nil) ? (item.descriptionMatch?.matchedIndices ?? []) : [],
                        baseColor: .white.opacity(0.4),
                        matchColor: highlightColor.opacity(0.8)
                    )
                    .font(.system(size: 11))
                }
            }

            Spacer()

            // Right-side: query preview for query actions, shortcut for built-in, source tag for actions
            if let preview = item.item.queryPreview {
                Text(preview)
                    .foregroundColor(.white.opacity(0.4))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 200, alignment: .trailing)
            } else if let shortcut = item.item.shortcutText {
                Text(shortcut)
                    .foregroundColor(.white.opacity(0.4))
                    .font(.system(size: 12, design: .monospaced))
            } else if let tag = item.item.sourceTag {
                Text(tag)
                    .foregroundColor(.white.opacity(0.3))
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            isSelected
                ? highlightColor.opacity(0.2)
                : Color.clear
        )
        .cornerRadius(4)
        .padding(.horizontal, 4)
    }

    /// Build an attributed text view with certain character indices highlighted.
    @ViewBuilder
    private func highlightedText(
        _ text: String,
        matchedIndices: [Int],
        baseColor: Color,
        matchColor: Color
    ) -> some View {
        if matchedIndices.isEmpty {
            Text(text)
                .foregroundColor(baseColor)
        } else {
            let chars = Array(text)
            let indexSet = Set(matchedIndices)
            // Build attributed text using Text concatenation
            chars.enumerated().reduce(Text("")) { result, pair in
                let (i, char) = pair
                if indexSet.contains(i) {
                    return result + Text(String(char))
                        .foregroundColor(matchColor)
                        .bold()
                } else {
                    return result + Text(String(char))
                        .foregroundColor(baseColor)
                }
            }
        }
    }
}

// MARK: - NSTextField Wrapper

/// An NSViewRepresentable wrapping NSTextField for the command palette's
/// search field, with direct first responder control and key event interception.
struct CommandPaletteTextField: NSViewRepresentable {
    @Binding var text: String
    var onArrowUp: () -> Void
    var onArrowDown: () -> Void
    var onSubmit: () -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.placeholderString = "Filter commands\u{2026}"
        field.font = .systemFont(ofSize: 14)
        field.textColor = .white
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.cell?.sendsActionOnEndEditing = false

        // Become first responder once when the palette appears.
        // This must be in makeNSView (not updateNSView) so it only
        // fires once — updateNSView runs during SwiftUI teardown and
        // would re-steal focus from the terminal after dismissal.
        DispatchQueue.main.async {
            if let window = field.window {
                window.makeFirstResponder(field)
            }
        }

        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: CommandPaletteTextField

        init(_ parent: CommandPaletteTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onArrowUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onArrowDown()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            case #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.insertBacktab(_:)):
                // Consume Tab/Shift-Tab to prevent focus from leaving the palette
                return true
            default:
                return false
            }
        }
    }
}
