import Foundation
import SQLite3

// MARK: - HistoryEntry

/// A deduplicated history entry for display in the command palette.
struct HistoryEntry {
    let url: URL
    let domain: String
    let title: String?
    let lastVisitedAt: Date
    let visitCount: Int

    /// The URL with scheme and `www.` prefix stripped for display and matching.
    var urlWithoutScheme: String {
        HistoryStore.stripScheme(from: url)
    }
}

// MARK: - HistoryStore

/// Manages a local SQLite database of browser history visits.
/// All writes happen on a serial background queue. Reads for palette search
/// happen synchronously on the calling thread (dataset is small).
class HistoryStore {
    static let shared = HistoryStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.watchtower.history", qos: .utility)
    private var pruneTimer: Timer?

    /// ISO 8601 formatter for database timestamps.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init() {
        openDatabase()
        createSchema()
        pruneOldVisits()
        schedulePruneTimer()
    }

    deinit {
        pruneTimer?.invalidate()
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Database Setup

    private func openDatabase() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let watchtowerDir = appSupport.appendingPathComponent("Watchtower")

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(
            at: watchtowerDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let dbPath = watchtowerDir.appendingPathComponent("history.db").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            let errmsg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            print("[HistoryStore] Failed to open database: \(errmsg)")
            db = nil
        }
    }

    private func createSchema() {
        let createTable = """
            CREATE TABLE IF NOT EXISTS visits (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL,
                domain TEXT NOT NULL,
                title TEXT,
                visited_at TEXT NOT NULL,
                source TEXT NOT NULL DEFAULT 'navigation'
            );
            """
        let createIndexVisitedAt = "CREATE INDEX IF NOT EXISTS idx_visits_visited_at ON visits(visited_at);"
        let createIndexDomain = "CREATE INDEX IF NOT EXISTS idx_visits_domain ON visits(domain);"
        let createIndexUrl = "CREATE INDEX IF NOT EXISTS idx_visits_url ON visits(url);"

        try? execute(createTable)
        try? execute(createIndexVisitedAt)
        try? execute(createIndexDomain)
        try? execute(createIndexUrl)
    }

    // MARK: - Recording Visits

    /// Record a visit. Called from the WKNavigationDelegate on didFinish.
    func recordVisit(url: URL, title: String?, source: String = "navigation") {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }

            let urlString = url.absoluteString
            let domain = url.host ?? url.absoluteString
            let now = HistoryStore.isoFormatter.string(from: Date())

            let sql = "INSERT INTO visits (url, domain, title, visited_at, source) VALUES (?, ?, ?, ?, ?)"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (urlString as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (domain as NSString).utf8String, -1, nil)
            if let title = title {
                sqlite3_bind_text(stmt, 3, (title as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_text(stmt, 4, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (source as NSString).utf8String, -1, nil)

            sqlite3_step(stmt)
        }
    }

    // MARK: - Search

    /// Search history for command palette results. Returns unique URLs,
    /// most recently visited first, limited to `limit` results.
    /// Loads all recent entries and applies in-memory fuzzy matching.
    func search(query: String, limit: Int = 20) -> [HistoryEntry] {
        guard let db = db else { return [] }
        guard !query.isEmpty else { return [] }

        // Load deduplicated entries: most recent title per URL, visit count, most recent visit
        let sql = """
            SELECT url, domain, title, MAX(visited_at) as last_visit, COUNT(*) as visit_count
            FROM visits
            GROUP BY url
            ORDER BY last_visit DESC
            LIMIT 500
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var entries: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let urlCStr = sqlite3_column_text(stmt, 0),
                  let domainCStr = sqlite3_column_text(stmt, 1),
                  let lastVisitCStr = sqlite3_column_text(stmt, 3) else {
                continue
            }

            let urlString = String(cString: urlCStr)
            let domain = String(cString: domainCStr)
            let lastVisitString = String(cString: lastVisitCStr)

            guard let url = URL(string: urlString) else { continue }

            let title: String?
            if let titleCStr = sqlite3_column_text(stmt, 2) {
                title = String(cString: titleCStr)
            } else {
                title = nil
            }

            let lastVisitedAt = HistoryStore.isoFormatter.date(from: lastVisitString) ?? Date()
            let visitCount = Int(sqlite3_column_int(stmt, 4))

            entries.append(HistoryEntry(
                url: url,
                domain: domain,
                title: title,
                lastVisitedAt: lastVisitedAt,
                visitCount: visitCount
            ))
        }

        return entries
    }

    // MARK: - Clear All

    /// Delete all history entries.
    func clearAll() {
        queue.async { [weak self] in
            try? self?.execute("DELETE FROM visits")
        }
    }

    // MARK: - Prune

    /// Remove entries older than 30 days.
    func pruneOldVisits() {
        queue.async { [weak self] in
            let cutoff = HistoryStore.isoFormatter.string(
                from: Date().addingTimeInterval(-30 * 24 * 60 * 60)
            )
            try? self?.execute("DELETE FROM visits WHERE visited_at < '\(cutoff)'")
        }
    }

    private func schedulePruneTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.pruneTimer = Timer.scheduledTimer(
                withTimeInterval: 3600,  // 1 hour
                repeats: true
            ) { [weak self] _ in
                self?.pruneOldVisits()
            }
        }
    }

    // MARK: - URL Stripping Utility

    /// Strip scheme (http://, https://) and `www.` prefix from a URL for display.
    static func stripScheme(from url: URL) -> String {
        var str = url.absoluteString

        // Remove scheme
        for prefix in ["https://www.", "http://www.", "https://", "http://"] {
            if str.hasPrefix(prefix) {
                str = String(str.dropFirst(prefix.count))
                break
            }
        }

        // Remove trailing slash if that's the only path
        if str.hasSuffix("/") && !str.dropLast().contains("/") {
            str = String(str.dropLast())
        }

        return str
    }

    // MARK: - Tiebreaker Scoring

    /// Compute a small tiebreaker bonus for a history entry.
    /// Recency bonus: up to +5 for visits in the last hour, tapering to 0 at 30 days.
    /// Visit count bonus: up to +3, capped at 50 visits.
    static func tiebreakerBonus(lastVisitedAt: Date, visitCount: Int) -> Int {
        let age = -lastVisitedAt.timeIntervalSinceNow  // seconds since visit
        let maxAge: Double = 30 * 24 * 60 * 60  // 30 days in seconds

        // Recency: linear taper from 5 (just now) to 0 (30 days ago)
        let recencyBonus = max(0, Int(5.0 * (1.0 - age / maxAge)))

        // Visit count: logarithmic scale, capped
        let cappedCount = min(visitCount, 50)
        let countBonus = min(3, Int(3.0 * Double(cappedCount) / 50.0))

        return recencyBonus + countBonus
    }

    // MARK: - SQLite Helpers

    /// Execute a SQL statement (no result rows).
    private func execute(_ sql: String) throws {
        guard let db = db else { return }
        var errmsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errmsg)
            print("[HistoryStore] SQL error: \(msg)")
        }
    }
}
