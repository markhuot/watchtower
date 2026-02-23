# AGENTS.md - Blog

Instructions for writing Watchtower development blog posts.

## What This Is

A technical development blog for the Watchtower project. Posts are written by reading through OpenCode session history and synthesizing it into a narrative about what was built and how. Each post covers a period of development, explains technical decisions, and documents the interesting problems encountered.

## How Posts Are Generated

### Step-by-step process

1. **Determine the time range.** Read the previous post's front matter to find which sessions it already covered. The new post should start from the first session *after* those.

2. **List all sessions.**
   ```bash
   opencode session list
   ```
   Sessions are listed newest-first. The oldest sessions are at the bottom.

3. **Export sessions to `.tmp/`.** Use the project-local `.tmp/` directory (NOT `/tmp`):
   ```bash
   mkdir -p .tmp
   opencode export <session_id> > .tmp/session_NN.json
   ```
   Export in chronological order. You can export many in parallel.

4. **Read each session JSON.** Session export files are large (50KB-30MB). Use the Task tool with a `general` subagent to read and summarize each one. Ask the subagent for:
   - The user's initial request (direct quotes)
   - What was built/changed (files, technical details)
   - Technical decisions and their rationale
   - Struggles, bugs, and non-obvious discoveries
   - The session ID and date

   You can dispatch 6-8 subagents in parallel to read sessions concurrently.

5. **Read supporting context.** In parallel with session reads:
   - `git log --oneline --reverse` for commit history
   - Key source files mentioned across sessions
   - The README, AGENTS.md, and any specs referenced

6. **Write the post.** Create a markdown file in `blog/` with the naming convention `YYYY-MM-DD-slug.md`. See the format section below.

### Session export JSON structure

Each exported session is a JSON object with:
- `id` — session ID (e.g., `ses_384d2cdd0ffe25LIq8cnXZ2sqJ`)
- `slug` — human-readable name (e.g., `silent-comet`)
- `created` / `updated` — Unix timestamps in milliseconds
- `messages` — array of user/assistant message objects, each containing `content` (text or tool calls/results)
- `summary` — object with `additions`, `deletions`, `files` counts and `patches` array

The `messages` array is where the real content lives. User messages contain the requests and intent. Assistant messages contain tool calls (file reads, edits, bash commands) and their results, plus the assistant's reasoning.

## Post Format

### Front matter

```yaml
---
title: "Short descriptive title"
date: YYYY-MM-DD
author: Mark Huot
sessions:
  - ses_XXXXX  # Brief description of what this session did
  - ses_YYYYY  # Another session
---
```

The `sessions` list should include every session that was referenced while writing the post. Add a `# comment` after each ID summarizing the session in a few words.

### Content guidelines

- **Technical and specific.** Describe what was built, how, and why. Include code patterns, API details, and architecture decisions. Avoid vague hand-waving.
- **Show the problems.** The interesting parts are usually the bugs, the wrong approaches, and what was learned. Don't just list features -- describe the journey.
- **Use the user's own words.** When the user explained their intent or described a problem in a session, quote them directly.
- **Reference actual code.** Include short code snippets, API signatures, or config fragments where they help explain a point.
- **No emojis.** Keep the tone straightforward and technical.
- **Images.** Reference images relative to the repo root with `../resources/filename.png` since blog posts are one level deep.

### Naming convention

`YYYY-MM-DD-slug.md` where the date is the primary date of the development work covered (not necessarily the date the post was written).

## Coverage So Far

### Post 1: `2026-02-20-its-alive.md`

**Covers:** The entire initial build of Watchtower from first commit through the first ~3 days.

**Date range:** Feb 20, 2026 (00:50 AM first commit) through Feb 22, 2026.

**Sessions covered:** 32 sessions total (all listed in the post's front matter). These span:
- First commit and initial app structure
- Ghostty C API integration (surfaces, keyboard, mouse, clipboard)
- Drag-and-drop pane reordering
- Pane resizing with snap-to-grid
- Transparent titlebar and dark mode
- Mouse coordinate bugs (Y-flip, double-scaling)
- Terminal status unification on `ghostty_surface_needs_confirm_quit()`
- CI pipeline (GitHub Actions, Zig build, code signing, notarization, caching)
- Auto-release with `YYYY.MM.NN` versioning
- UX polish (CWD inheritance, pane width inheritance, focus mode, keyboard shortcuts, close confirmation, window dimming)
- New Workspace feature (git worktrees via surface config `command` field)
- Beginning of User Actions spec

**Last session covered:** `ses_37a908e8effeZr7Reg1tcla9mv` (Cmd+W close pane, Feb 22, 2026)

**Where the next post should start:** Any sessions created after the ones listed in the first post's front matter. Run `opencode session list` and compare against the IDs in `blog/2026-02-20-its-alive.md`.

### Post 2: `2026-02-22-exec-not-found.md`

**Covers:** The user actions system implementation and the Ghostty command execution bug (`exec: not found` + missing user shell config).

**Date range:** Feb 22, 2026.

**Sessions covered:** 6 sessions (listed in front matter):
- User actions spec refinement (reactive discovery, per-terminal independence, removing WATCHTOWER_PROJECT_ROOT)
- Full user actions implementation (Action.swift, ActionParser.swift, ActionDiscovery.swift, ActionDialogView.swift)
- The `exec: not found` bug from double-exec wrapping
- The `TERM=xterm-ghostty` bug from Ghostty's non-interactive `bash --noprofile --norc` wrapper
- The `$SHELL -lic` fix to restore user shell config
- AGENTS.md learnings extraction, smoke test, command palette spec, titlebar redesign

**Key sessions:** `ses_37a767744ffeI3fR2EheNUZCV3` (implementation), `ses_37a86c0bcffe6lPu2Jkh9j79m4` (spec refinement)

**All sessions from this period (10 total):** Several were meta-sessions (blog writing attempts, AGENTS.md updates), one was a trivial Q&A, one was a smoke test. The post focuses on the implementation sessions.

**Where the next post should start:** Any sessions created after the ones listed in both post 1 and post 2 front matter. Run `opencode session list` and compare against all IDs in both posts.

### Post 3: `2026-02-22-command-palette.md`

**Covers:** The command palette feature (Cmd+K) from spec design through implementation, plus git branch display in pane headers and default window sizing.

**Date range:** Feb 22, 2026.

**Sessions covered:** 4 sessions (listed in front matter):
- Command palette spec refinement (per-pane overlay design, fuzzy matching requirements, focus outline transfer)
- Command palette implementation (FuzzyMatch.swift, CommandPaletteView.swift, 733 additions across 6 files)
- Git branch display in pane headers (reactive Combine chain from OSC 7 through to SwiftUI)
- Default window size (2.5 panes calculation, one-line change)

**Key sessions:** `ses_37953b84bffetfzG6w2CcMj01W` (implementation), `ses_3796b4a54ffeIrRrUYShXs7MRe` (spec refinement)

**Key technical topics:** Fuzzy matching algorithm with scoring heuristics, the focus-stealing bug (NSTextField taking first responder kills palette visibility), double-dispatch DispatchQueue.main.async for focus restoration, managesFocus flag for actions that control their own focus, ZStack layering outside clipShape.

**Uncovered sessions from this period (8 total):** 4 were included in the post. The remaining 4 were: a meta-session writing blog post 2 (`ses_37a4996b8ffeGIefOzAmSTKpx0`), the session that wrote blog post 1 (`ses_37a7118a8ffekR9cJpGPeI8kmz`), a trivial SSH+tmux Q&A (`ses_37a660a3dffeztmG31qT3C5791`, 8 seconds), and an aborted blog writing attempt (`ses_37a7421bfffeERgP3oKs0GWiQU`).

**Where the next post should start:** Any sessions created after the ones listed in posts 1, 2, and 3. Run `opencode session list` and compare against all IDs in all three posts.

## Tips

- **Subagent parallelism is critical.** Each session JSON can be 500KB-30MB. Dispatching 6-8 `general` subagents in parallel to summarize sessions keeps the process from taking forever.
- **Not every session is interesting.** "Build and run the app" sessions, pure commit-and-push sessions, and trivial one-line fixes can be mentioned in passing or skipped. Focus on sessions where problems were solved, architecture decisions were made, or the user expressed intent.
- **Watch for multi-session arcs.** Features often span 2-4 sessions (initial attempt, bug fix, polish). The blog narrative should weave these together rather than presenting them as isolated events.
- **The `.tmp/` directory is ephemeral.** It's in `.gitignore` (or should be). Use it freely for exported session data. Don't assume it persists between agent sessions.
- **Check git log for context between sessions.** Sometimes the user makes changes outside of OpenCode. `git log` fills in the gaps.
- **Read the specs.** The `specs/` directory contains design documents that explain the "why" behind features better than any individual session does.
