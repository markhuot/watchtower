# Browser History

## Summary

Track URLs visited in browser panes into a local SQLite database and surface them as searchable entries in the command palette. The database retains 30 days of history, logging the URL, page title, date accessed, and a handful of other useful fields (domain, visit count, referrer source). The command palette's fuzzy matcher includes history entries so that typing a partial URL fragment like `sst/opencode` matches `github.com/sst/opencode` and opens it in a browser pane.

## Motivation

Browser panes (see `specs/browser-panes.md`) let developers view web content inline, but there is no way to get back to a page once the pane is closed. The "Go to URL..." command requires the user to remember and type the full URL. Developers revisit the same handful of URLs constantly — localhost dev servers, GitHub repos, CI dashboards, documentation pages — and a history-backed fuzzy finder eliminates the friction of retyping them.

This also complements the existing "Go to URL..." and "Search the web..." palette commands. Instead of being the *only* way to navigate, they become the fallback for new URLs. For everything the user has visited before, the history surfaces it automatically.

## Detailed Design

### 1. Database Location and Schema

The database lives at `~/Library/Application Support/Watchtower/history.db`. This follows macOS conventions for per-user application data and is outside the app sandbox's container (Watchtower uses App Sandbox with file access, but `~/Library/Application Support/<bundle-id>/` is the standard writable location).

**Schema:**

```sql
CREATE TABLE IF NOT EXISTS visits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    url TEXT NOT NULL,
    domain TEXT NOT NULL,            -- extracted host (e.g., "github.com")
    title TEXT,                      -- page <title> at time of visit
    visited_at TEXT NOT NULL,        -- ISO 8601 timestamp (UTC)
    source TEXT NOT NULL DEFAULT 'navigation'  -- how the visit originated
);

CREATE INDEX IF NOT EXISTS idx_visits_visited_at ON visits(visited_at);
CREATE INDEX IF NOT EXISTS idx_visits_domain ON visits(domain);
CREATE INDEX IF NOT EXISTS idx_visits_url ON visits(url);
```

**Fields:**

| Column | Type | Purpose |
|---|---|---|
| `id` | INTEGER PK | Auto-incrementing row ID |
| `url` | TEXT | Full URL including scheme, path, query string, and fragment |
| `domain` | TEXT | Extracted host component (e.g., `github.com`, `localhost:3000`). Enables fast domain-level queries and deduplication in the palette |
| `title` | TEXT | The page's `<title>` at the time of the visit. Nullable because some pages have no title (e.g., `about:blank`, raw JSON endpoints) |
| `visited_at` | TEXT | ISO 8601 UTC timestamp. TEXT rather than INTEGER for human-readable debugging with `sqlite3` CLI |
| `source` | TEXT | How the navigation happened: `"navigation"` (link click or redirect within a page), `"palette"` (opened via command palette), `"address"` (typed via "Go to URL..."). Useful for understanding usage patterns and potentially ranking palette results by intentional visits |

**Why these extra fields:**

- **`domain`** — the palette's fuzzy matcher searches against the full URL, but grouping by domain is useful for deduplication (showing `github.com/sst/opencode` once instead of 47 times) and for potential future features like "most visited domains" or domain-level blocking.
- **`source`** — distinguishes intentional navigation ("I typed this URL") from incidental navigation ("the page redirected here"). Palette-originated and address-bar visits are stronger signals of intent than in-page redirects. This could inform ranking in the future (intentional visits score higher), though the initial implementation does not use it for ranking.

**Fields considered and excluded:**

- **Favicon URL** — would require downloading and caching favicon images, adding network requests and disk storage management. Not worth the complexity for a palette-driven UI where icons aren't displayed.
- **HTTP status code** — already tracked on `BrowserPaneModel` but not useful in history. A 404 page visited last week is irrelevant to whether the user wants to visit it again.
- **Page content / snippet** — far too heavy for a history database. The title is sufficient for identification.

### 2. Recording Visits

A visit is recorded when a page finishes loading (`WKNavigationDelegate.webView(_:didFinish:)`). This is the right hook because:

- The page title is available (it's set by the time `didFinish` fires).
- The URL is final (redirects have resolved).
- Failed navigations (`didFail`, `didFailProvisionalNavigation`) are not recorded — there's no useful page to revisit.

**What gets recorded:**

- Every successful top-level navigation (not subframes, not XHR/fetch requests).
- `about:blank` is excluded — it's the default empty state, not a meaningful visit.
- Duplicate consecutive visits to the same URL within the same pane are deduplicated — rapidly refreshing a page does not create 50 history entries. A new visit is recorded only if the URL differs from that pane's last recorded URL.

**Source tracking:** The `source` column is populated based on how the navigation was initiated:

- If the navigation was triggered by `addBrowser(url:)` called from the command palette's "Go to URL..." → `"address"`.
- If the navigation was triggered by selecting a history entry in the palette → `"palette"`.
- All other navigations (link clicks, redirects, form submissions, JavaScript `location.href` changes) → `"navigation"`.

This requires threading a `navigationSource` flag through `BrowserPaneModel`. The flag is set before initiating a navigation and consumed in `didFinish`. It defaults to `"navigation"` and is reset after each recording.

### 3. Retention and Cleanup

The database retains 30 days of history. Cleanup runs on app launch and once per hour while the app is running:

```swift
func pruneOldVisits() {
    let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30 * 24 * 60 * 60))
    try? db.execute("DELETE FROM visits WHERE visited_at < ?", [cutoff])
}
```

The hourly timer is a simple `Timer.scheduledTimer` on the main run loop. The DELETE operation is fast (indexed on `visited_at`) and runs on a background queue to avoid blocking the UI.

**No VACUUM:** SQLite reclaims space gradually without explicit `VACUUM`. The history database is small (30 days of URLs is likely under 1MB even for heavy users), so fragmentation is not a concern.

### 4. HistoryStore

A new `HistoryStore` class encapsulates all database access:

```swift
class HistoryStore {
    private let db: OpaquePointer?  // sqlite3*
    private let queue = DispatchQueue(label: "com.watchtower.history", qos: .utility)

    init() {
        // Open or create database at ~/Library/Application Support/Watchtower/history.db
        // Run CREATE TABLE IF NOT EXISTS and CREATE INDEX IF NOT EXISTS
        // Run initial prune
        // Schedule hourly prune timer
    }

    /// Record a visit. Called from the WKNavigationDelegate on didFinish.
    func recordVisit(url: URL, title: String?, source: String = "navigation") {
        queue.async {
            let domain = url.host ?? url.absoluteString
            let now = ISO8601DateFormatter().string(from: Date())
            // INSERT INTO visits (url, domain, title, visited_at, source) VALUES (?, ?, ?, ?, ?)
        }
    }

    /// Search history for command palette results. Returns unique URLs,
    /// most recently visited first, limited to `limit` results.
    func search(query: String, limit: Int = 20) -> [HistoryEntry] {
        // Runs on the calling queue (palette filtering is already on main).
        // Uses the in-memory fuzzy matcher, not SQL LIKE — see Section 5.
    }

    /// Prune visits older than 30 days.
    func pruneOldVisits() { ... }
}

struct HistoryEntry {
    let url: URL
    let domain: String
    let title: String?
    let lastVisitedAt: Date
    let visitCount: Int  // COUNT(*) grouped by URL
}
```

`HistoryStore` is a singleton, created once during app startup and passed to `PaneContainerViewModel`. All database writes happen on a serial background queue. Reads for palette search happen synchronously on the main thread (the dataset is small — under 10K rows for 30 days — and the query is a full-table scan followed by in-memory fuzzy matching, which completes in < 1ms for this scale).

### 5. Command Palette Integration

History entries appear in the command palette as a new category, below built-in commands and custom actions, but above the "Go to URL..." and "Search the web..." query actions.

**Ordering in the palette (when the query is non-empty):**

1. Built-in commands (fuzzy matched)
2. Custom actions (fuzzy matched)
3. **History entries** (fuzzy matched)
4. Separator
5. "Go to URL..." / "Search the web..." (query actions, not fuzzy matched)

When the query is empty, history entries are not shown — the palette shows only commands and actions. History entries only appear when the user is actively typing, which signals intent to navigate.

**Fuzzy matching for history:**

Each history entry is matched against the palette query using the existing `fuzzyMatch(query:candidate:)` function. The candidate string is the **URL with the scheme and `www.` prefix stripped** (e.g., `github.com/sst/opencode` rather than `https://www.github.com/sst/opencode`). Stripping the scheme and `www.` makes matches more natural — typing `github` should match immediately without needing to skip past `https://www.`. The same stripped form is used for the display text in the palette row.

The fuzzy matcher also runs against the **page title** as a secondary candidate (same dual-match pattern used for action descriptions — see `specs/command-palette.md`, Section 4). A match on either URL or title includes the entry. URL matches rank higher than title-only matches.

**Unified scoring — history competes directly with commands and actions:**

History entries, built-in commands, and custom actions all compete on the same fuzzy match score. There are no reserved slots or category-based ordering — the 10-result cap is filled by the highest-scoring matches regardless of type. The existing fuzzy matcher's scoring heuristics (see `specs/command-palette.md`, Section 4) already produce the right behavior:

1. **Consecutive character bonus** — matches where query characters are adjacent score higher. Typing `github` matches `github.com/sst/opencode` (6 consecutive characters) far above `alternative.to/github-mirror` (where the characters are scattered).
2. **Prefix bonus** — matching from the start of the string scores higher. `github` at position 0 in `github.com` beats `github` at position 16 in `alternative.to/github.com`.
3. **Word-boundary bonus** — matching at the start of a path segment or word scores higher. `opencode` matches the `/opencode` segment boundary in `github.com/sst/opencode`.

These three heuristics mean that `github` naturally ranks `github.com` above `alternative.to/github.com`, and `newterminal` ranks the "New Terminal" command above `dev.to/launching-a-new-terminal` in history — no special category weighting needed.

History entries get two small **tiebreaker bonuses** that only matter when fuzzy match scores are equal:

- **Recency tiebreaker** — entries visited in the last hour get a small additive bonus, tapering to zero at 30 days. Distinguishes between two history entries with identical match quality.
- **Visit count tiebreaker** — entries with more visits get a small additive bonus (capped). Helps `localhost:3000` surface above a one-off visit when both match equally well.

These tiebreakers are intentionally weak — they never override a better character match. A strong prefix match on a rarely visited URL always beats a weak scattered match on a frequently visited one.

**Deduplication:** The palette shows each URL at most once, even if the database contains many visits to that URL. `HistoryStore.search()` returns entries grouped by URL with the most recent title and a visit count. If the same URL has been visited with different titles (e.g., a GitHub PR page whose title changes), the most recent title is shown.

**Visual treatment of history rows:**

```
╔══════════════════════════════════════╗
║ sst/opencode                          ║
╠══════════════════════════════════════╣
║ ▸ github.com/sst/opencode            ║
║       OpenCode - Terminal AI       🕐 ║
║   localhost:3000/dashboard            ║
║       My App - Dashboard           🕐 ║
║ ─────────────────────────────────── ║
║   Go to URL       sst/opencode       ║
║   Search the web  sst/opencode       ║
╚══════════════════════════════════════╝
```

- The primary line shows the URL (without scheme or `www.` prefix), with fuzzy-matched characters highlighted.
- The subtitle shows the page title in a dimmer color, with matched characters highlighted if the match was on the title.
- A small clock icon (🕐) or timestamp indicator on the right distinguishes history entries from commands. Alternatively, a `[history]` tag similar to `[project]`/`[global]` — the exact visual treatment should match the app's existing style.
- No keyboard shortcut is shown (history entries are not bound to shortcuts).

**Result cap:** History entries share the palette's existing 10-result cap with commands and actions. All results are ranked by fuzzy match score regardless of category — the top 10 win. If 3 commands and 12 history entries match, the palette shows the best 10 by score (likely all 3 commands plus the 7 best-matching history entries, since commands tend to be short strings with strong prefix matches). The "More..." indicator appears when results exceed 10. No slots are reserved for any category.

### 6. Executing a History Entry

When a history entry is selected and executed:

- If the focused pane is a browser pane, navigate that pane to the URL.
- If the focused pane is a terminal pane (or any non-browser pane), create a new browser pane and navigate it to the URL.

This is the same behavior as "Go to URL..." (see `specs/browser-panes.md`, Section 8). The action closure on the `CommandPaletteItem` calls the same code path:

```swift
CommandPaletteItem(
    displayName: entry.urlWithoutScheme,
    description: entry.title,
    shortcutText: nil,
    sourceTag: "[history]",
    isQueryAction: false,
    queryPreview: nil,
    action: { viewModel in
        if let browser = viewModel.contextualPane as? BrowserPaneModel {
            browser.url = entry.url
        } else {
            let pane = viewModel.addBrowser(url: entry.url)
            viewModel.focusPane(pane)
        }
    }
)
```

The `source` for this navigation is recorded as `"palette"` in the history database (see Section 2).

### 7. SQLite Dependency

macOS ships with SQLite (`libsqlite3`) and the C API is available via `import SQLite3` in Swift. No third-party dependencies are needed. The `HistoryStore` uses the C API directly (`sqlite3_open`, `sqlite3_prepare_v2`, `sqlite3_step`, `sqlite3_finalize`, `sqlite3_close`) wrapped in a Swift class. This is verbose but avoids adding a dependency for what amounts to 5 SQL statements.

A thin wrapper around the C API (prepare, bind, step, column extraction) keeps the callsites readable without needing a full ORM:

```swift
/// Execute a SQL statement with optional bindings.
func execute(_ sql: String, _ bindings: [Any?] = []) throws { ... }

/// Query rows, mapping each to T via a closure.
func query<T>(_ sql: String, _ bindings: [Any?] = [], map: (OpaquePointer) -> T) throws -> [T] { ... }
```

### 8. App Lifecycle

**Startup:**
1. `HistoryStore` is initialized (opens or creates the database, runs migrations, prunes old entries).
2. The store is set on `PaneContainerViewModel` (or accessed as a singleton).

**Runtime:**
1. Every `didFinish` navigation in `BrowserWebView`'s coordinator calls `historyStore.recordVisit(url:title:source:)`.
2. Every command palette filter pass calls `historyStore.search(query:limit:)` to include history entries.
3. Hourly prune timer removes entries older than 30 days.

**Shutdown:**
1. `sqlite3_close` is called in `HistoryStore.deinit`. No explicit flush needed — writes are committed immediately (SQLite autocommit mode).

### 9. Clear Browsing History

A "Clear Browsing History..." built-in command in the command palette deletes all history entries. It shows a confirmation alert before proceeding:

```swift
let alert = NSAlert()
alert.messageText = "Clear Browsing History?"
alert.informativeText = "This will permanently delete all browsing history. This action cannot be undone."
alert.alertStyle = .warning
alert.addButton(withTitle: "Clear History")
alert.addButton(withTitle: "Cancel")
alert.beginSheetModal(for: window) { response in
    if response == .alertFirstButtonReturn {
        historyStore.clearAll()
    }
}
```

`HistoryStore.clearAll()` runs `DELETE FROM visits` on the background queue. The palette command is always visible (not gated on whether history entries exist) so it's discoverable.

The `...` suffix on the command name follows macOS conventions — it indicates the command will show a confirmation dialog before acting (same convention used for "New Workspace..." and other parameterized actions).

### 10. Privacy Considerations

Browser history is sensitive data. The database is stored in `~/Library/Application Support/Watchtower/` with default macOS file permissions (readable only by the user). No history data is transmitted over the network. No history data is shared between users on the same machine.

All browser pane navigations are recorded. There is no private browsing mode — the feature is not worth the complexity for the initial implementation. Users who want to clear their tracks can use the "Clear Browsing History..." palette command or delete `history.db` manually.

## Resolved Decisions

### 1. No Private Browsing Mode

All browser pane navigations are recorded. A private browsing mode is not worth the complexity for the initial implementation. Users can use "Clear Browsing History..." from the palette to remove all history.

### 2. History Mixed Into Main Palette

History entries appear in the same Cmd+K command palette alongside commands and actions. There is no dedicated history search mode (no separate shortcut, no `/history` prefix). One palette, one fuzzy finder, one place to find everything. If the palette becomes too noisy as features grow, a filtering mechanism can be added later.

### 3. Unified Score-Ranked Results

All results (commands, actions, history) compete on the same fuzzy match score. The existing consecutive-character, prefix, and word-boundary bonuses produce correct ranking without category-based slot reservations. See Section 5 for details.

### 4. Strip Scheme and `www.`

History URLs are displayed and matched with both the scheme (`https://`) and `www.` prefix stripped. `github.com/sst/opencode` instead of `https://www.github.com/sst/opencode`.

### 5. Always Navigate or Create

Selecting a history entry always navigates the focused browser pane (or creates a new one if focused on a terminal). The palette does not check whether the URL is already open in another pane. This keeps the behavior simple and predictable — the user always knows which pane will be affected.

## Implementation Plan

1. **HistoryStore** — create `HistoryStore.swift` with SQLite C API wrapper, database creation, schema migration, `recordVisit()`, `search()`, `clearAll()`, and `pruneOldVisits()`. Include the hourly prune timer. Unit-testable with an in-memory database (`:memory:`).
2. **Record visits** — in `BrowserWebView`'s navigation delegate coordinator, call `historyStore.recordVisit(url:title:source:)` on `didFinish`. Skip `about:blank`. Deduplicate consecutive same-URL visits per pane. Thread `navigationSource` through `BrowserPaneModel`.
3. **Search and deduplication** — implement `HistoryStore.search()`: load recent entries, deduplicate by URL (keeping the most recent title and summing visit counts), return `[HistoryEntry]`.
4. **Palette integration** — in `CommandPaletteView`'s filtered results computation, call `historyStore.search(query:)` when the query is non-empty. Convert `HistoryEntry` results to `CommandPaletteItem` instances with `[history]` tag and scheme/www-stripped URL as display name. All results (commands, actions, history) ranked by unified fuzzy match score. Apply recency and visit count tiebreaker bonuses to history items. Add "Clear Browsing History..." as a built-in palette command with confirmation alert.
5. **History entry execution** — implement the action closure: navigate existing browser pane or create a new one. Set `navigationSource = "palette"` before navigating.
6. **Wire HistoryStore into app lifecycle** — initialize in `GhosttyAppManager` or `WatchtowerApp` at startup. Pass to `PaneContainerViewModel`. Schedule prune timer.

## Files to Create or Modify

| File | Action | Description |
|---|---|---|
| `HistoryStore.swift` | Create | SQLite database manager: open/create database, schema with `visits` table and indexes, `recordVisit()` on background queue, `search()` with deduplication and visit count, `clearAll()` for history clearing, `pruneOldVisits()` with 30-day cutoff, hourly prune timer. Thin C API wrapper (`execute`, `query`). `HistoryEntry` struct. URL stripping utility (remove scheme and `www.` prefix). |
| `BrowserWebView.swift` | Modify | In the navigation delegate coordinator's `didFinish`, call `historyStore.recordVisit()`. Skip `about:blank`. Deduplicate consecutive same-URL visits per pane. Read `navigationSource` from `BrowserPaneModel`. |
| `BrowserPaneModel.swift` | Modify | Add `var navigationSource: String = "navigation"` flag, reset to `"navigation"` after each visit is recorded. |
| `CommandPaletteView.swift` | Modify | In the filtered results computation, call `historyStore.search(query:)` when query is non-empty. Convert `HistoryEntry` to `CommandPaletteItem` with `[history]` tag and scheme/www-stripped URL as display name. All results ranked by unified fuzzy match score with recency/visit-count tiebreakers on history items. Add "Clear Browsing History..." built-in command with confirmation alert calling `historyStore.clearAll()`. |
| `ContentView.swift` | Modify | Pass `HistoryStore` reference to palette (either via `PaneContainerViewModel` property or environment object). |
| `WatchtowerApp.swift` | Modify | Initialize `HistoryStore` at app startup. |
| `GhosttyAppManager.swift` | No change | History is independent of Ghostty's C API |
| `FuzzyMatch.swift` | No change | Existing `fuzzyMatch(query:candidate:)` is reused as-is |
| `PaneModel.swift` | No change | No changes to the pane model hierarchy |
| `Action.swift` | No change | Actions are unrelated to history |
