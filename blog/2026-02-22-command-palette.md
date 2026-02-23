---
title: "Cmd+K: Designing and Building a Command Palette"
date: 2026-02-22
author: Mark Huot
sessions:
  - ses_3796b4a54ffeIrRrUYShXs7MRe  # Command palette spec refinement
  - ses_37953b84bffetfzG6w2CcMj01W  # Command palette implementation
  - ses_379596ae8ffetngZmblafrqypQ  # Git branch display in pane headers
  - ses_3795e27bbffeAvqMCIBDHL1XRu  # Default window size
---

# Cmd+K: Designing and Building a Command Palette

Watchtower already had a toolbar dropdown for running user actions. But a dropdown menu doesn't scale -- once you have ten built-in commands, a handful of project-specific scripts, and some global actions, you need filtering. The command palette feature (Cmd+K) went from spec refinement through implementation across two sessions, producing 733 lines of new code across 6 files. Along the way it surfaced a focus management bug that required understanding the exact order in which SwiftUI tears down NSView hierarchies.

## Designing the palette

The spec refinement session was a back-and-forth about what the palette should look and behave like. Several decisions came from strong opinions about what *not* to do.

**No section dividers.** The original design grouped commands into sections (Built-in, Project, Global) with visual separators. The user rejected this: instead, each action row gets a subtle `[project]` or `[global]` tag on the right side. Built-in commands show their keyboard shortcut instead. This keeps the list flat and scannable.

**Fuzzy filtering, not substring matching.** The user gave concrete examples: "'mysql' should match 'new mysql terminal' and 'newt' should match all 'new...terminal' actions." That second case -- `newt` matching `new terminal` by splitting across a word boundary -- requires actual fuzzy matching with scoring, not a simple `contains()` check.

**Per-pane overlay, not window-level.** This was the most consequential design choice. The palette renders as an overlay on top of whichever pane is focused, not as a centered window-level sheet. The user's rationale: "the UI should be 'overlaid' on top of the currently active pane... the reason for putting the pallet over the pane is so that it is clear what it's acting on. if you select 'close pane' it's obvious what pane is closing."

**Focus outline transfer.** When the palette opens, the pane's focus outline (a colored border with glow) disappears, and the palette draws its own matching outline. The user cut through an over-complicated animation discussion: "is the problem that we're animating the outline? Because that's not the intent. we just need to hide one focus outline and use the same visual style for the new pallet's outline."

The spec session also flagged implementation concerns that turned out to be prescient. `.clipShape()` on the pane view would clip the palette overlay -- it needed to be a ZStack sibling outside the clip region. Focus changes while the palette is open (clicking other panes) should dismiss it. And an NSTextField was needed for the search field because SwiftUI's `@FocusState` is unreliable for first responder control on macOS.

## The fuzzy matcher

`FuzzyMatch.swift` (102 lines) implements a two-phase approach:

1. **Quick reject**: a linear scan verifying all query characters exist in order in the candidate string. This is O(n) and rejects most non-matches immediately.

2. **Recursive best-match search**: for candidates that pass the quick check, a recursive function tries every possible alignment of query characters against the candidate, scoring each with heuristics:

```swift
// Consecutive bonus: if this match is right after the previous one
if let lastIdx = currentIndices.last, idx == lastIdx + 1 {
    bonus += 8
}

// Word-boundary bonus: match at start of a word
if idx == 0 {
    bonus += 10 // prefix bonus (start of string)
} else {
    let prevChar = candidateOriginal[idx - 1]
    if prevChar == " " || prevChar == "-" || prevChar == "_" || prevChar == "/" {
        bonus += 6 // word boundary
    } else if prevChar.isLowercase && candidateOriginal[idx].isUppercase {
        bonus += 6 // camelCase boundary
    }
}
```

The scoring means `newt` matching `New Terminal` scores high (prefix bonus on `N`, word-boundary bonus on `T`, consecutive bonus on `e` and `w`) while `newt` matching something like `known extra width` would score much lower. For command palette scale -- tens of items, short strings -- the recursive search is fast enough that memoization isn't needed.

The filtered results list also matches against action descriptions, not just names, but name matches rank 100 points higher than description-only matches. Results are capped at 10 with a "More..." indicator.

## The focus bug

This was the critical implementation problem. Here's the sequence of events that caused it:

1. User presses Cmd+K. The palette opens on the focused pane.
2. The palette's `CommandPaletteTextField` (an `NSViewRepresentable` wrapping `NSTextField`) becomes first responder.
3. The terminal's `GhosttyTerminalNSView.resignFirstResponder()` fires, setting `terminal.isFocused = false`.
4. The palette overlay was originally gated on `terminal.isFocused` -- so it immediately disappeared.

The palette opened and closed in the same frame. The fix was to decouple palette visibility from terminal focus entirely:

```swift
@Published var commandPaletteTerminalId: UUID? = nil

var isCommandPalettePresented: Bool {
    commandPaletteTerminalId != nil
}
```

And in `TerminalPaneView`:

```swift
private var isPaletteOpenHere: Bool {
    viewModel.commandPaletteTerminalId == terminal.id
}
```

The palette's visibility is now tracked by the ID of the terminal it was opened on, not by whether that terminal is focused. The focus outline suppression uses the same flag -- `isHighlightActive` checks `!isPaletteOpenHere` so the pane's border disappears while the palette draws its own.

## Double-dispatch dismissal

Restoring focus to the terminal after closing the palette required a double-nested `DispatchQueue.main.async`:

```swift
func dismissCommandPalette(restoreFocus: Bool = true) {
    guard let terminalId = commandPaletteTerminalId else { return }
    commandPaletteTerminalId = nil

    guard restoreFocus else { return }

    DispatchQueue.main.async { [weak self] in
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let index = self.terminals.firstIndex(where: { $0.id == terminalId }) else { return }
            self.makeFocused(index: index)
        }
    }
}
```

One async isn't enough. Setting `commandPaletteTerminalId = nil` triggers a SwiftUI state change. The first `DispatchQueue.main.async` lets SwiftUI process that change and begin tearing down the palette's NSTextField. The second ensures the text field has fully resigned first responder before `makeFocused` calls `window.makeFirstResponder(targetView)` on the terminal's NSView. Without the second async, the terminal's NSView and the dying text field fight over first responder, and the terminal loses.

## The managesFocus flag

Some commands manage their own focus. "New Terminal" creates a pane and focuses it. If the palette restores focus to the *original* terminal after executing "New Terminal", the new terminal never gets focused -- the restoration clobbers the action's own focus logic.

The fix is a `managesFocus: Bool` flag on `CommandPaletteItem`:

```swift
items.append(.builtIn(name: "New Terminal", shortcut: "\u{2318}T", managesFocus: true) { vm in
    vm.addTerminal()
})
```

When `managesFocus` is true, `dismissCommandPalette(restoreFocus: false)` is called and the double-async restoration is skipped entirely.

## Built-in commands

The palette ships with ten built-in commands: New Terminal (Cmd+T), Close Terminal (Cmd+W), Toggle Full Screen (Ctrl+Cmd+F), Minimize (Cmd+M), Zoom, Focus Previous/Next Pane (Cmd+Shift+[/]), Toggle Focus Mode (Cmd+Shift+Enter), Move Pane Left/Right (Cmd+Option+[/]). The user specifically requested: "lets implement all five actions. make sure to give move pane left/right a keyboard shortcut too."

User-defined actions from `.watchtower/actions/` and `~/.config/watchtower/actions/` are appended after the built-ins, tagged with `[project]` or `[global]` respectively. The palette's `allItems` computed property merges both sources.

## Git branch in pane headers

A separate session added git branch display to each pane's header bar. The reactive chain is the interesting part:

Shell reports CWD via OSC 7 -> Ghostty fires `GHOSTTY_ACTION_PWD` -> `terminal.directory` is set -> Combine `$directory` subscription fires -> async git branch detection -> `terminal.gitBranch` updates -> SwiftUI re-renders the header.

The implementation lives entirely in `TerminalModel`:

```swift
$directory
    .removeDuplicates()
    .sink { [weak self] dir in
        self?.detectGitBranch(for: dir)
    }
    .store(in: &cancellables)
```

The header renders it as `~/Sites/foo:main` -- the abbreviated directory followed by a colon and the branch name. Simple, but it means every terminal pane independently tracks its own git context, which is useful when you have panes open in different repositories.

## Default window size

A 4-minute session to set the window's default size to fit "2.5 panes wide and ~1000px tall." The calculation: 2.5 panes at 760pt each, plus 1.5 inter-pane gaps at 27pt, plus 2 side padding at 10pt. That's `2.5 * 760 + 1.5 * 27 + 2 * 10 = 1960.5`, rounded to 1960. One line:

```swift
.defaultSize(width: 1960, height: 1000)
```

The half-pane is deliberate. Showing 2.5 panes signals that the view scrolls horizontally -- a common iOS pattern applied to a macOS window.

## What the palette looks like in code

The ZStack layering in `TerminalPaneView` ended up clean. The pane content (header + terminal surface) is clipped to a rounded rectangle. The palette sits *outside* that clip as a ZStack sibling, with a transparent dismiss layer behind it:

```swift
ZStack(alignment: .top) {
    // Pane content
    VStack(spacing: 0) { ... }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(/* focus border */)

    // Command palette overlay
    if isPaletteOpenHere {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { viewModel.dismissCommandPalette() }

        CommandPaletteView(viewModel: viewModel)
            .frame(maxWidth: min(500, terminal.paneWidth - 20))
            .padding(.top, 50)  // 40px header + 10px gap
    }
}
```

The palette is capped at 500pt wide (or 20pt less than the pane width, whichever is smaller). It uses `.ultraThinMaterial` for the background and draws its own highlight-colored border that matches the pane's focus outline style. The NSTextField search field intercepts arrow keys, Enter, Escape, and Tab via `doCommandBy:` to keep all keyboard interaction contained within the palette.

## The pattern

Three of these four sessions follow the same pattern: a design review that surfaces implementation concerns before any code is written, a large implementation session that hits exactly the bugs the review predicted, and small focused sessions for adjacent features. The focus bug was the only surprise -- and even that was foreseeable, since the spec session had flagged first responder management as a risk. The difference between "we know this could be a problem" and "here's the exact workaround" is always the implementation.
