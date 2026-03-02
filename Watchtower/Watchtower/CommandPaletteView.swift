import SwiftUI
import AppKit

// MARK: - Palette Mode

/// The current mode of the command palette.
enum PaletteMode {
    /// Normal command list.
    case commands
    /// Color picker sub-palette for "Set Pane Color".
    case colorPicker
}

// MARK: - Hex Color Parsing

/// Parse a hex color string into a SwiftUI Color.
/// Accepts formats: #RGB, #RRGGBB, RGB, RRGGBB (with or without # prefix).
func parseHexColor(_ text: String) -> Color? {
    var hex = text.trimmingCharacters(in: .whitespaces)
    if hex.hasPrefix("#") { hex.removeFirst() }

    // Handle 3-digit hex
    if hex.count == 3 && hex.allSatisfy({ $0.isHexDigit }) {
        let chars = Array(hex)
        hex = String(chars[0]) + String(chars[0])
            + String(chars[1]) + String(chars[1])
            + String(chars[2]) + String(chars[2])
    }

    guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
    guard let value = UInt64(hex, radix: 16) else { return nil }

    let r = Double((value >> 16) & 0xFF) / 255.0
    let g = Double((value >> 8) & 0xFF) / 255.0
    let b = Double(value & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
}

/// Normalize a hex color string to "#RRGGBB" format.
func normalizeHex(_ text: String) -> String {
    var hex = text.trimmingCharacters(in: .whitespaces)
    if hex.hasPrefix("#") { hex.removeFirst() }
    if hex.count == 3 {
        let chars = Array(hex)
        hex = String(chars[0]) + String(chars[0])
            + String(chars[1]) + String(chars[1])
            + String(chars[2]) + String(chars[2])
    }
    return "#\(hex.uppercased())"
}

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
    /// Optional color swatch to display next to the item name (used by color picker).
    let swatchColor: Color?
    /// If non-nil, selecting this item transitions the palette to the given mode
    /// instead of dismissing it.
    let transitionsToMode: PaletteMode?
    /// The action closure receives the view model and a `forceNewPane` flag.
    /// When `forceNewPane` is true (Cmd+Return), browser-navigation actions
    /// should always open a new pane instead of navigating in-place.
    let action: (PaneContainerViewModel, Bool) -> Void

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
            swatchColor: nil,
            transitionsToMode: nil,
            action: { vm, _ in action(vm) }
        )
    }

    /// Create a query action item (Go to URL, Search the web).
    static func queryAction(
        name: String,
        queryPreview: String? = nil,
        action: @escaping (PaneContainerViewModel, Bool) -> Void
    ) -> CommandPaletteItem {
        CommandPaletteItem(
            displayName: name,
            description: nil,
            shortcutText: nil,
            sourceTag: nil,
            isQueryAction: true,
            queryPreview: queryPreview,
            swatchColor: nil,
            transitionsToMode: nil,
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
            swatchColor: nil,
            transitionsToMode: nil,
            action: { viewModel, _ in
                viewModel.triggerAction(actionModel)
            }
        )
    }

    /// Create an item from a browser history entry.
    static func fromHistory(_ entry: HistoryEntry) -> CommandPaletteItem {
        CommandPaletteItem(
            displayName: entry.urlWithoutScheme,
            description: entry.title,
            shortcutText: nil,
            sourceTag: "History",
            isQueryAction: false,
            queryPreview: nil,
            swatchColor: nil,
            transitionsToMode: nil,
            action: { viewModel, forceNewPane in
                if !forceNewPane, let browser = viewModel.contextualPane as? BrowserPaneModel {
                    browser.navigationSource = "palette"
                    browser.navigate(to: entry.url)
                } else {
                    let browser = viewModel.addBrowser(url: entry.url)
                    browser.navigationSource = "palette"
                    viewModel.focusPane(browser)
                }
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
    /// Asynchronously computed filter results. Updated by a debounced background task.
    @State private var computedFilteredItems: [FilteredPaletteItem] = []
    /// The filter task handle, cancelled and replaced on each keystroke.
    @State private var filterTask: Task<Void, Never>?
    /// The current palette mode (commands vs color picker sub-palette).
    @State private var mode: PaletteMode = .commands

    private let maxVisibleItems = 10
    private let cornerRadius: CGFloat = 8

    /// Whether the focused pane is a browser.
    private var isBrowserFocused: Bool {
        viewModel.contextualPane is BrowserPaneModel
    }

    /// Build the full command list from built-in commands + discovered actions.
    /// In color picker mode, returns the color picker items instead.
    private var allItems: [CommandPaletteItem] {
        if mode == .colorPicker {
            return colorPickerItems
        }

        var items: [CommandPaletteItem] = []

        // Built-in commands (always visible)
        items.append(.builtIn(name: "New Terminal", shortcut: "\u{2318}\u{21E7}T") { vm in
            let terminal = vm.addTerminal()
            vm.focusPane(terminal)
        })
        items.append(.builtIn(name: "New Browser", shortcut: "\u{2318}\u{21E7}B") { vm in
            vm.openNewBrowser()
        })
        items.append(.builtIn(name: "Close Pane", shortcut: "\u{2318}W") { vm in
            vm.closeCurrentPane()
        })
        items.append(.builtIn(name: "Close Panes to the Right") { vm in
            vm.closePanesToTheRight()
        })
        items.append(.builtIn(name: "Close Other Panes") { vm in
            vm.closeOtherPanes()
        })
        items.append(.builtIn(name: "Close All Panes") { vm in
            vm.closeAllPanes()
        })

        // Collapse / Expand toggle — label reflects the focused pane's current state
        if let focusedPane = viewModel.contextualPane {
            let collapseLabel = focusedPane.isCollapsed ? "Expand Pane" : "Collapse Pane"
            items.append(.builtIn(name: collapseLabel) { vm in
                vm.toggleCollapsePane()
            })
        }
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
        items.append(.builtIn(name: "Focus Current Pane", shortcut: "\u{2318}\u{21E7}\u{21A9}") { vm in
            vm.toggleFocusMode()
        })
        items.append(.builtIn(name: "Move Pane Left", shortcut: "\u{2318}\u{2325}[") { vm in
            vm.movePaneLeft()
        })
        items.append(.builtIn(name: "Move Pane Right", shortcut: "\u{2318}\u{2325}]") { vm in
            vm.movePaneRight()
        })
        items.append(.builtIn(name: "Fit Panes to Window") { vm in
            vm.fitPanesToWindow()
        })
        items.append(.builtIn(name: "Center Pane") { vm in
            vm.centerPane()
        })
        items.append(CommandPaletteItem(
            displayName: "Set Pane Color",
            description: "Change the header color of the focused pane",
            shortcutText: nil,
            sourceTag: nil,
            isQueryAction: false,
            queryPreview: nil,
            swatchColor: nil,
            transitionsToMode: .colorPicker,
            action: { _, _ in }
        ))

        // Browser-specific commands (only when browser pane is focused)
        if isBrowserFocused {
            items.append(.builtIn(name: "Go Back", shortcut: "\u{2318}[") { vm in
                if let browser = vm.contextualPane as? BrowserPaneModel {
                    browser.goBack()
                }
            })
            items.append(.builtIn(name: "Go Forward", shortcut: "\u{2318}]") { vm in
                if let browser = vm.contextualPane as? BrowserPaneModel {
                    browser.goForward()
                }
            })
            items.append(.builtIn(name: "Reload Page", shortcut: "\u{2318}R") { vm in
                if let browser = vm.contextualPane as? BrowserPaneModel {
                    browser.reloadOrStop()
                }
            })

            // Engine switching — show option to switch to the OTHER engine
            if let browser = viewModel.contextualPane as? BrowserPaneModel {
                let currentEngine = browser.engine
                let targetEngine: BrowserEngine = currentEngine == .webkit ? .chromium : .webkit
                items.append(.builtIn(name: "Switch to \(targetEngine.displayName)") { vm in
                    if let browser = vm.contextualPane as? BrowserPaneModel {
                        browser.switchEngine(to: targetEngine)
                    }
                })
            }
        }

        // Project actions
        for action in viewModel.projectActions {
            items.append(.fromAction(action))
        }

        // Global actions
        for action in viewModel.globalActions {
            items.append(.fromAction(action))
        }

        // Clear Browsing History (always visible)
        items.append(.builtIn(name: "Clear Browsing History\u{2026}") { vm in
            guard let window = NSApp.keyWindow else { return }
            // Capture the pane that should regain focus after the sheet dismisses.
            // contextualPane resolves via commandPalettePaneId which is still set
            // at this point (executeSelected runs the action before dismissing).
            let paneToRefocus = vm.contextualPane
            let alert = NSAlert()
            alert.messageText = "Clear Browsing History?"
            alert.informativeText = "This will permanently delete all browsing history. This action cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Clear History")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    HistoryStore.shared.clearAll()
                }
                // The sheet steals focus from the pane; restore it on dismiss.
                if let pane = paneToRefocus {
                    vm.focusPane(pane)
                }
            }
        })

        return items
    }

    /// Build the color picker items: "Default" + 16 ANSI theme colors.
    private var colorPickerItems: [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        // "Default" resets to nil (theme background at 0.8 opacity)
        items.append(CommandPaletteItem(
            displayName: "Default",
            description: "Theme background color",
            shortcutText: nil,
            sourceTag: nil,
            isQueryAction: false,
            queryPreview: nil,
            swatchColor: appManager.backgroundColor.opacity(0.8),
            transitionsToMode: nil,
            action: { vm, _ in
                if let pane = vm.contextualPane {
                    pane.headerColor = nil
                }
            }
        ))

        // 16 ANSI colors from the ghostty theme
        for entry in appManager.themeColors {
            items.append(CommandPaletteItem(
                displayName: entry.name,
                description: nil,
                shortcutText: nil,
                sourceTag: nil,
                isQueryAction: false,
                queryPreview: nil,
                swatchColor: entry.color,
                transitionsToMode: nil,
                action: { [color = entry.color] vm, _ in
                    if let pane = vm.contextualPane {
                        pane.headerColor = color
                    }
                }
            ))
        }

        return items
    }

    /// Kick off an async filter computation. Debounces by cancelling any
    /// in-flight task; the SQLite query and fuzzy matching run off the main
    /// thread so the UI stays responsive during rapid typing.
    private func scheduleFilter() {
        filterTask?.cancel()

        let currentFilter = filterText
        let currentMode = mode
        let items = allItems

        // Empty query — synchronous, no work to offload
        if currentFilter.isEmpty {
            computedFilteredItems = items.enumerated().map { (index, item) in
                FilteredPaletteItem(
                    id: item.id,
                    item: item,
                    nameMatch: nil,
                    descriptionMatch: nil,
                    score: items.count - index
                )
            }
            return
        }

        filterTask = Task.detached(priority: .userInitiated) {
            // Debounce: wait 50ms so rapid keystrokes don't each trigger
            // a full filter pass. If the task is cancelled (next keystroke
            // arrived), we bail out before doing any real work.
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }

            // --- Heavy work (off main thread) ---

            // Fuzzy-match built-in commands & actions (or color picker items)
            var results: [FilteredPaletteItem] = []
            for item in items {
                if Task.isCancelled { return }
                let nameMatch = fuzzyMatch(query: currentFilter, candidate: item.displayName)
                let descMatch: FuzzyMatchResult?
                if let desc = item.description {
                    descMatch = fuzzyMatch(query: currentFilter, candidate: desc)
                } else {
                    descMatch = nil
                }

                if nameMatch != nil || descMatch != nil {
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

            // History and query actions only in commands mode
            if currentMode == .commands {
                // Fuzzy-match history entries
                let historyEntries = HistoryStore.shared.search(query: currentFilter, limit: 20)
                for entry in historyEntries {
                    if Task.isCancelled { return }
                    let displayURL = entry.urlWithoutScheme
                    let urlMatch = fuzzyMatch(query: currentFilter, candidate: displayURL)
                    let titleMatch: FuzzyMatchResult?
                    if let title = entry.title {
                        titleMatch = fuzzyMatch(query: currentFilter, candidate: title)
                    } else {
                        titleMatch = nil
                    }

                    if urlMatch != nil || titleMatch != nil {
                        let item = CommandPaletteItem.fromHistory(entry)
                        var score = urlMatch?.score ?? ((titleMatch?.score ?? 0) - 100)
                        score += HistoryStore.tiebreakerBonus(
                            lastVisitedAt: entry.lastVisitedAt,
                            visitCount: entry.visitCount
                        )
                        results.append(FilteredPaletteItem(
                            id: item.id,
                            item: item,
                            nameMatch: urlMatch,
                            descriptionMatch: titleMatch,
                            score: score
                        ))
                    }
                }

                if Task.isCancelled { return }

                // Sort
                results.sort {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.item.displayName.count < $1.item.displayName.count
                }

                // Append query actions (Go to URL / Search the web)
                let queryText = currentFilter.trimmingCharacters(in: .whitespaces)
                if !queryText.isEmpty {
                    let urlLike = isURLLike(queryText)

                    let goToURL = CommandPaletteItem.queryAction(
                        name: "Go to URL"
                    ) { vm, forceNewPane in
                        guard let url = normalizeURL(queryText) else { return }
                        if !forceNewPane, let browser = vm.contextualPane as? BrowserPaneModel {
                            browser.navigationSource = "address"
                            browser.navigate(to: url)
                        } else {
                            let browser = vm.addBrowser(url: url)
                            browser.navigationSource = "address"
                            vm.focusPane(browser)
                        }
                    }

                    let searchWeb = CommandPaletteItem.queryAction(
                        name: "Search the web"
                    ) { vm, forceNewPane in
                        guard let url = WatchtowerConfig.shared.searchURL(for: queryText) else { return }
                        if !forceNewPane, let browser = vm.contextualPane as? BrowserPaneModel {
                            browser.navigate(to: url)
                        } else {
                            let browser = vm.addBrowser(url: url)
                            vm.focusPane(browser)
                        }
                    }

                    let firstAction = urlLike ? goToURL : searchWeb
                    let secondAction = urlLike ? searchWeb : goToURL

                    results.append(FilteredPaletteItem(
                        id: firstAction.id,
                        item: firstAction,
                        nameMatch: nil,
                        descriptionMatch: nil,
                        score: -1000
                    ))
                    results.append(FilteredPaletteItem(
                        id: secondAction.id,
                        item: secondAction,
                        nameMatch: nil,
                        descriptionMatch: nil,
                        score: -1001
                    ))
                }
            } else if currentMode == .colorPicker {
                // Sort color picker results
                results.sort {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.item.displayName.count < $1.item.displayName.count
                }

                // In color picker mode, offer a custom hex color if the filter
                // text parses as a valid hex color
                let queryText = currentFilter.trimmingCharacters(in: .whitespaces)
                if let parsedColor = parseHexColor(queryText) {
                    let hexLabel = normalizeHex(queryText)
                    let hexItem = CommandPaletteItem(
                        displayName: "Custom: \(hexLabel)",
                        description: nil,
                        shortcutText: nil,
                        sourceTag: nil,
                        isQueryAction: true,
                        queryPreview: nil,
                        swatchColor: parsedColor,
                        transitionsToMode: nil,
                        action: { vm, _ in
                            if let pane = vm.contextualPane {
                                pane.headerColor = parsedColor
                            }
                        }
                    )
                    results.append(FilteredPaletteItem(
                        id: hexItem.id,
                        item: hexItem,
                        nameMatch: nil,
                        descriptionMatch: nil,
                        score: -1000
                    ))
                }
            }

            if Task.isCancelled { return }

            // --- Publish results on main thread ---
            let finalResults = results
            await MainActor.run {
                computedFilteredItems = finalResults
            }
        }
    }

    /// The visible items (capped at maxVisibleItems for regular items, with
    /// query actions always appended so "Go to URL" and "Search the web" are
    /// always reachable).
    private var visibleItems: [FilteredPaletteItem] {
        let regular = computedFilteredItems.filter { !$0.item.isQueryAction }
        let queryActions = computedFilteredItems.filter { $0.item.isQueryAction }
        return Array(regular.prefix(maxVisibleItems)) + queryActions
    }

    /// Whether there are more regular (non-query-action) items than what's shown.
    private var hasMore: Bool {
        let regularCount = computedFilteredItems.filter { !$0.item.isQueryAction }.count
        return regularCount > maxVisibleItems
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
                placeholder: mode == .colorPicker
                    ? "Pick a color or enter hex (#RRGGBB)\u{2026}"
                    : "Filter commands\u{2026}",
                selectAllOnAppear: viewModel.commandPaletteInitialText != nil,
                onArrowUp: { moveSelection(by: -1) },
                onArrowDown: { moveSelection(by: 1) },
                onJumpUp: { jumpSectionUp() },
                onJumpDown: { jumpSectionDown() },
                onSubmit: { forceNewPane in executeSelected(forceNewPane: forceNewPane) },
                onEscape: {
                    if mode == .colorPicker {
                        // Go back to commands mode instead of dismissing
                        mode = .commands
                        filterText = ""
                        selectedIndex = 0
                    } else {
                        viewModel.dismissCommandPalette()
                    }
                }
            )
            .padding(.horizontal, 22)
            .padding(.vertical, 10)

            Divider()
                .background(Color.white.opacity(0.1))

            // Results list
            if visibleItems.isEmpty {
                HStack {
                    Text(mode == .colorPicker ? "No matching colors" : "No matching commands")
                        .foregroundColor(.white.opacity(0.4))
                        .font(.system(size: 13))
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, filteredItem in
                        // Draw separator before query actions
                        if index == queryActionSeparatorIndex && index > 0 {
                            Divider()
                                .background(Color.white.opacity(0.1))
                                .padding(.horizontal, 8)
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
                            executeSelected(forceNewPane: NSEvent.modifierFlags.contains(.command))
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
                .padding(.vertical, 8)
            }
        }
        .background(.ultraThinMaterial)
        .background(
            GeometryReader { geo in
                let centerY = 300 / max(geo.size.height, 1)
                RadialGradient(
                    gradient: Gradient(colors: [
                        appManager.highlightColor.opacity(0.25),
                        appManager.highlightColor.opacity(0.0)
                    ]),
                    center: UnitPoint(x: 0.5, y: centerY),
                    startRadius: 0,
                    endRadius: 300
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(appManager.highlightColor, lineWidth: 2)
                .shadow(color: appManager.highlightColor.opacity(0.6), radius: 8)
        )
        .shadow(color: .black.opacity(0.5), radius: 40, x: 0, y: 15)
        .onAppear {
            // Pre-fill the filter text when opened with Cmd+L on a browser pane
            if let initial = viewModel.commandPaletteInitialText {
                filterText = initial
            }
            // Seed the initial results (synchronous for empty, async for pre-filled)
            scheduleFilter()
        }
        .onChange(of: filterText) { _ in
            // Reset selection and kick off a debounced filter pass
            selectedIndex = 0
            scheduleFilter()
        }
        .onChange(of: mode) { _ in
            // Re-compute items when switching between commands and color picker
            scheduleFilter()
        }
    }

    private func moveSelection(by offset: Int) {
        guard !visibleItems.isEmpty else { return }
        let count = visibleItems.count
        selectedIndex = (selectedIndex + offset + count) % count
    }

    /// Jump to the first item of the next section (Cmd+Down).
    private func jumpSectionDown() {
        guard !visibleItems.isEmpty else { return }
        if let sep = queryActionSeparatorIndex, selectedIndex < sep {
            // Currently in the top section -> jump to query actions
            selectedIndex = sep
        } else {
            // Already in the bottom section or no separator -> go to last item
            selectedIndex = visibleItems.count - 1
        }
    }

    /// Jump to the first item of the previous section (Cmd+Up).
    private func jumpSectionUp() {
        guard !visibleItems.isEmpty else { return }
        if let sep = queryActionSeparatorIndex, selectedIndex >= sep {
            // Currently in the query action section -> jump to top
            selectedIndex = 0
        } else {
            // Already in the top section -> go to first item
            selectedIndex = 0
        }
    }

    private func executeSelected(forceNewPane: Bool = false) {
        guard selectedIndex >= 0 && selectedIndex < visibleItems.count else { return }
        let item = visibleItems[selectedIndex].item

        // If this item transitions to a sub-palette mode, switch mode
        // and stay open instead of running the action and dismissing.
        if let targetMode = item.transitionsToMode {
            mode = targetMode
            filterText = ""
            selectedIndex = 0
            return
        }

        // Snapshot the focus generation before the action runs.
        // If the action calls focusPane(), the generation advances and
        // dismiss will preserve the action's focus target.
        let gen = viewModel.focusGeneration
        // Run the action BEFORE dismissing so that `contextualPane` can
        // still resolve via `commandPalettePaneId`. Actions that create
        // new panes call `focusPane()` which bumps `focusGeneration`.
        item.action(viewModel, forceNewPane)
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

    /// Maximum number of characters to display on a single line before truncating.
    private let maxDisplayChars = 65

    var body: some View {
        HStack(spacing: 0) {
            // Color swatch for color picker items
            if let swatch = item.item.swatchColor {
                Circle()
                    .fill(swatch)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                    )
                    .frame(width: 14, height: 14)
                    .padding(.trailing, 8)
            }

            VStack(alignment: .leading, spacing: 2) {
                // Name with highlighted matched characters, truncated to one line
                let nameTruncation = truncatedDisplayText(
                    item.item.displayName,
                    matchedIndices: item.nameMatch?.matchedIndices ?? [],
                    maxChars: maxDisplayChars
                )
                highlightedText(
                    nameTruncation.text,
                    matchedIndices: nameTruncation.adjustedIndices,
                    baseColor: .white.opacity(0.9),
                    matchColor: highlightColor
                )
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

                // Description subtitle
                if let desc = item.item.description {
                    let descTruncation = truncatedDisplayText(
                        desc,
                        matchedIndices: (item.nameMatch == nil) ? (item.descriptionMatch?.matchedIndices ?? []) : [],
                        maxChars: maxDisplayChars
                    )
                    highlightedText(
                        descTruncation.text,
                        matchedIndices: descTruncation.adjustedIndices,
                        baseColor: .white.opacity(0.4),
                        matchColor: highlightColor.opacity(0.8)
                    )
                    .font(.system(size: 11))
                    .lineLimit(1)
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
        .padding(.horizontal, 8)
    }

    /// Result of truncating a display string to fit on one line.
    private struct TruncatedText {
        let text: String
        let adjustedIndices: [Int]
    }

    /// Truncate `text` to fit within `maxChars`, centering the visible window
    /// on the last matched character when truncation is needed.
    ///
    /// - If the text fits within `maxChars`, returns it unchanged.
    /// - Otherwise, computes a window of `maxChars` characters centered on the
    ///   last matched index, prepending/appending "…" where text was clipped.
    private func truncatedDisplayText(
        _ text: String,
        matchedIndices: [Int],
        maxChars: Int
    ) -> TruncatedText {
        let chars = Array(text)
        guard chars.count > maxChars else {
            // Fits on one line — no truncation needed
            return TruncatedText(text: text, adjustedIndices: matchedIndices)
        }

        // Determine the anchor point: last matched character, or 0 if no matches
        let anchor = matchedIndices.max() ?? 0

        // Reserve space for ellipsis characters (each "…" is 1 char)
        // We'll compute the window, then decide which ellipses are needed
        let halfWindow = maxChars / 2

        // Center the window on the anchor
        var windowStart = max(0, anchor - halfWindow)
        var windowEnd = windowStart + maxChars

        // Clamp to string bounds
        if windowEnd > chars.count {
            windowEnd = chars.count
            windowStart = max(0, windowEnd - maxChars)
        }

        let needsLeadingEllipsis = windowStart > 0
        let needsTrailingEllipsis = windowEnd < chars.count

        // Shrink the window to make room for ellipsis characters
        if needsLeadingEllipsis { windowStart += 1 }
        if needsTrailingEllipsis { windowEnd -= 1 }

        // Build the truncated string
        var result = ""
        if needsLeadingEllipsis { result += "\u{2026}" }
        result += String(chars[windowStart..<windowEnd])
        if needsTrailingEllipsis { result += "\u{2026}" }

        // Remap matched indices into the new string's coordinate space
        let ellipsisOffset = needsLeadingEllipsis ? 1 : 0
        let adjustedIndices = matchedIndices.compactMap { idx -> Int? in
            guard idx >= windowStart && idx < windowEnd else { return nil }
            return idx - windowStart + ellipsisOffset
        }

        return TruncatedText(text: result, adjustedIndices: adjustedIndices)
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

// MARK: - NSTextView Wrapper

/// An NSViewRepresentable wrapping NSTextView for the command palette's
/// search field, with auto-growing height, direct first responder control,
/// and key event interception.
struct CommandPaletteTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Filter commands\u{2026}"
    var selectAllOnAppear: Bool = false
    var onArrowUp: () -> Void
    var onArrowDown: () -> Void
    var onJumpUp: () -> Void
    var onJumpDown: () -> Void
    var onSubmit: (Bool) -> Void  // Bool = forceNewPane (Cmd held)
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> PaletteTextView {
        let textView = PaletteTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .white
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isFieldEditor = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.allowsUndo = true

        // Placeholder support is handled via the custom subclass
        textView.placeholderString = placeholder

        // Pre-fill text if provided (e.g. browser URL from Cmd+L)
        if !text.isEmpty {
            textView.string = text
        }

        // Become first responder once when the palette appears.
        // This must be in makeNSView (not updateNSView) so it only
        // fires once — updateNSView runs during SwiftUI teardown and
        // would re-steal focus from the terminal after dismissal.
        DispatchQueue.main.async {
            if let window = textView.window {
                window.makeFirstResponder(textView)
                // Select all text so the user can type to replace or
                // press arrow keys to edit (matches browser Cmd+L UX).
                if self.selectAllOnAppear {
                    textView.selectAll(nil)
                }
            }
        }

        return textView
    }

    func updateNSView(_ nsView: PaletteTextView, context: Context) {
        if nsView.string != text {
            nsView.string = text
            nsView.invalidateIntrinsicContentSize()
        }
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
            nsView.needsDisplay = true
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        let parent: CommandPaletteTextField

        init(_ parent: CommandPaletteTextField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.invalidateIntrinsicContentSize()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onArrowUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onArrowDown()
                return true
            case #selector(NSResponder.moveToBeginningOfDocument(_:)):
                // Cmd+Up — jump to previous section
                parent.onJumpUp()
                return true
            case #selector(NSResponder.moveToEndOfDocument(_:)):
                // Cmd+Down — jump to next section
                parent.onJumpDown()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                let cmdHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
                parent.onSubmit(cmdHeld)
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // Cmd+Return sends insertNewlineIgnoringFieldEditor instead of
                // insertNewline — treat it as submit with forceNewPane.
                parent.onSubmit(true)
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

// MARK: - Palette Text View (NSTextView subclass)

/// Custom NSTextView subclass that provides intrinsic content size based on
/// text layout (for auto-growing height) and placeholder text rendering.
class PaletteTextView: NSTextView {
    var placeholderString: String? = nil

    override var intrinsicContentSize: NSSize {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let insets = textContainerInset
        let height = usedRect.height + insets.height * 2
        // Minimum height of one line (~20pt) so the field never collapses
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 20))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw placeholder when empty
        if string.isEmpty, let placeholder = placeholderString {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white.withAlphaComponent(0.4),
                .font: font ?? NSFont.systemFont(ofSize: 14)
            ]
            let insets = textContainerInset
            let padding = textContainer?.lineFragmentPadding ?? 0
            let rect = NSRect(
                x: insets.width + padding,
                y: insets.height,
                width: bounds.width - insets.width * 2 - padding * 2,
                height: bounds.height - insets.height * 2
            )
            NSString(string: placeholder).draw(in: rect, withAttributes: attrs)
        }
    }

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set { super.needsDisplay = newValue }
    }
}
