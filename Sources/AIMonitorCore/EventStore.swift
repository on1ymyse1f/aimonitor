import Foundation

/// Persistent analytics store. SQLite, local-only, WAL mode.
///
/// Dedup rules are enforced by the schema, not by callers remembering:
///   * Claude Code events upsert by requestId and keep the **largest**
///     snapshot (progressive streaming duplicates never double-count, and the
///     fold stays order-independent).
///   * Codex delta events carry positional ids and INSERT OR IGNORE — replaying
///     a log is a no-op.
public final class EventStore: @unchecked Sendable {
    // SQLite runs in serialized mode; the connection is safe to share.
    // Callers still serialize their own writes by design (single sync engine).
    private let db: Database

    /// Applied migrations, in order. Never edit an applied entry; append.
    private static let migrations: [(String, String)] = [
        ("001_core", """
            CREATE TABLE events(
              id TEXT PRIMARY KEY,
              ts REAL,
              source TEXT NOT NULL,
              provider TEXT NOT NULL,
              application TEXT,
              model TEXT,
              session_id TEXT,
              project TEXT,
              event_type TEXT NOT NULL DEFAULT 'usage',
              uncached_input INTEGER NOT NULL DEFAULT 0,
              cached_input INTEGER NOT NULL DEFAULT 0,
              cache_write_5m INTEGER NOT NULL DEFAULT 0,
              cache_write_1h INTEGER NOT NULL DEFAULT 0,
              cache_write_unspecified INTEGER NOT NULL DEFAULT 0,
              output INTEGER NOT NULL DEFAULT 0,
              reasoning INTEGER NOT NULL DEFAULT 0,
              billable INTEGER NOT NULL DEFAULT 0,
              cost_usd REAL,
              confidence TEXT NOT NULL
            );
            CREATE TABLE quota_snapshots(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              observed_at REAL NOT NULL,
              provider TEXT NOT NULL,
              window_id TEXT NOT NULL,
              label TEXT NOT NULL,
              used_percent REAL NOT NULL,
              window_minutes INTEGER NOT NULL,
              resets_at REAL,
              plan_type TEXT
            );
            CREATE TABLE checkpoints(
              path TEXT PRIMARY KEY,
              size INTEGER NOT NULL,
              offset INTEGER NOT NULL,
              state TEXT
            );
            CREATE TABLE settings(
              key TEXT PRIMARY KEY,
              value TEXT
            );
            """),
        ("002_indexes", """
            CREATE INDEX idx_events_ts ON events(ts);
            CREATE INDEX idx_events_provider_ts ON events(provider, ts);
            CREATE INDEX idx_events_model ON events(model);
            CREATE INDEX idx_events_project ON events(project);
            CREATE INDEX idx_events_session ON events(session_id);
            CREATE INDEX idx_quota_window_obs ON quota_snapshots(window_id, observed_at);
            """),
    ]

    public init(path: String) throws {
        db = try Database(path: path)
        try migrate()
    }

    /// In-memory store, for tests.
    public static func inMemory() throws -> EventStore { try EventStore(path: "file:aimonitor-test-\(UUID().uuidString)?mode=memory&cache=shared") }

    /// Default on-disk location: ~/Library/Application Support/AIMonitor/aimonitor.db
    public static func defaultPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AIMonitor/aimonitor.db").path
    }

    private func migrate() throws {
        var applied = db.schemaVersion
        while applied < Self.migrations.count {
            let (_, sql) = Self.migrations[applied]
            try db.transaction { try db.exec(sql) }
            applied += 1
            db.schemaVersion = applied
        }
    }

    // MARK: - Transactions

    /// Atomic multi-write. Used by the sync engine so a file's events and its
    /// checkpoint commit together or not at all.
    public func transaction(_ body: (EventStore) throws -> Void) throws {
        try db.transaction { try body(self) }
    }

    // MARK: - Events

    /// Inserts a usage event. Claude-style ids (requestId) keep the largest
    /// snapshot on conflict; Codex-style positional ids ignore duplicates.
    public func insert(usage event: AIEvent, keepLargest: Bool) throws {
        let sql: String
        if keepLargest {
            sql = """
                INSERT INTO events(id,ts,source,provider,application,model,session_id,project,
                  uncached_input,cached_input,cache_write_5m,cache_write_1h,cache_write_unspecified,
                  output,reasoning,billable,cost_usd,confidence)
                VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)
                ON CONFLICT(id) DO UPDATE SET
                  ts=excluded.ts, model=excluded.model,
                  uncached_input=excluded.uncached_input, cached_input=excluded.cached_input,
                  cache_write_5m=excluded.cache_write_5m, cache_write_1h=excluded.cache_write_1h,
                  cache_write_unspecified=excluded.cache_write_unspecified,
                  output=excluded.output, reasoning=excluded.reasoning,
                  billable=excluded.billable, cost_usd=excluded.cost_usd
                WHERE excluded.billable > events.billable
                """
        } else {
            sql = """
                INSERT OR IGNORE INTO events(id,ts,source,provider,application,model,session_id,project,
                  uncached_input,cached_input,cache_write_5m,cache_write_1h,cache_write_unspecified,
                  output,reasoning,billable,cost_usd,confidence)
                VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)
                """
        }
        let stmt = try db.prepare(sql)
        let t = event.tokens
        stmt.bind(event.id, 1)
        stmt.bind(event.timestamp?.timeIntervalSince1970, 2)
        stmt.bind(event.source, 3)
        stmt.bind(event.provider, 4)
        stmt.bind(event.application, 5)
        stmt.bind(event.model, 6)
        stmt.bind(event.sessionId, 7)
        stmt.bind(event.project, 8)
        stmt.bind(t.uncachedInput, 9)
        stmt.bind(t.cachedInput, 10)
        stmt.bind(t.cacheWrite5m, 11)
        stmt.bind(t.cacheWrite1h, 12)
        stmt.bind(t.cacheWriteUnspecified, 13)
        stmt.bind(t.output, 14)
        stmt.bind(t.reasoning, 15)
        stmt.bind(t.billableEquivalent, 16)
        stmt.bind(event.costUSD.map { ($0 as NSDecimalNumber).doubleValue }, 17)
        stmt.bind(event.confidence.rawValue, 18)
        _ = try stmt.step()
    }

    // MARK: - Checkpoints

    public struct Checkpoint: Equatable {
        public var size: Int
        public var offset: Int
        /// Provider-specific resume state, JSON. Codex stores its last
        /// cumulative snapshot here so deltas survive restarts.
        public var state: String?
    }

    public func checkpoint(for path: String) throws -> Checkpoint? {
        let stmt = try db.prepare("SELECT size, offset, state FROM checkpoints WHERE path=?1")
        stmt.bind(path, 1)
        guard try stmt.step() else { return nil }
        return Checkpoint(size: stmt.int(0), offset: stmt.int(1), state: stmt.str(2))
    }

    public func setCheckpoint(_ cp: Checkpoint, for path: String) throws {
        let stmt = try db.prepare("""
            INSERT INTO checkpoints(path,size,offset,state) VALUES(?1,?2,?3,?4)
            ON CONFLICT(path) DO UPDATE SET size=excluded.size, offset=excluded.offset, state=excluded.state
            """)
        stmt.bind(path, 1); stmt.bind(cp.size, 2); stmt.bind(cp.offset, 3); stmt.bind(cp.state, 4)
        _ = try stmt.step()
    }

    // MARK: - Quota snapshots

    public func insert(quota q: QuotaWindow, provider: String) throws {
        // Skip consecutive duplicates: quota snapshots repeat every event.
        let latest = try db.prepare("""
            SELECT used_percent FROM quota_snapshots
            WHERE window_id=?1 ORDER BY observed_at DESC LIMIT 1
            """)
        latest.bind(q.id, 1)
        if try latest.step(), abs(latest.double(0) - q.usedPercent) < 0.001 { return }

        let stmt = try db.prepare("""
            INSERT INTO quota_snapshots(observed_at,provider,window_id,label,used_percent,window_minutes,resets_at,plan_type)
            VALUES(?1,?2,?3,?4,?5,?6,?7,?8)
            """)
        stmt.bind(q.observedAt.timeIntervalSince1970, 1)
        stmt.bind(provider, 2)
        stmt.bind(q.id, 3)
        stmt.bind(q.label, 4)
        stmt.bind(q.usedPercent, 5)
        stmt.bind(q.windowMinutes, 6)
        stmt.bind(q.resetsAt?.timeIntervalSince1970, 7)
        stmt.bind(q.planType, 8)
        _ = try stmt.step()
    }

    public struct QuotaPoint: Equatable {
        public var observedAt: Date
        public var usedPercent: Double
        public var resetsAt: Date?
    }

    /// Newest snapshot per window.
    public func latestQuotas() throws -> [(window: QuotaWindow, provider: String)] {
        let stmt = try db.prepare("""
            SELECT q.provider, q.window_id, q.label, q.used_percent, q.window_minutes, q.resets_at, q.observed_at, q.plan_type
            FROM quota_snapshots q
            JOIN (SELECT window_id, MAX(observed_at) m FROM quota_snapshots GROUP BY window_id) t
              ON t.window_id=q.window_id AND t.m=q.observed_at
            """)
        var out: [(QuotaWindow, String)] = []
        while try stmt.step() {
            let w = QuotaWindow(
                id: stmt.str(1) ?? "?",
                label: stmt.str(2) ?? "?",
                usedPercent: stmt.double(3),
                windowMinutes: stmt.int(4),
                resetsAt: stmt.isNull(5) ? nil : Date(timeIntervalSince1970: stmt.double(5)),
                observedAt: Date(timeIntervalSince1970: stmt.double(6)),
                planType: stmt.str(7)
            )
            out.append((w, stmt.str(0) ?? "?"))
        }
        return out
    }

    /// History of one window, oldest first. Feeds the burn-rate engine.
    public func quotaHistory(windowId: String) throws -> [QuotaPoint] {
        let stmt = try db.prepare("""
            SELECT observed_at, used_percent, resets_at FROM quota_snapshots
            WHERE window_id=?1 ORDER BY observed_at
            """)
        stmt.bind(windowId, 1)
        var out: [QuotaPoint] = []
        while try stmt.step() {
            out.append(QuotaPoint(
                observedAt: Date(timeIntervalSince1970: stmt.double(0)),
                usedPercent: stmt.double(1),
                resetsAt: stmt.isNull(2) ? nil : Date(timeIntervalSince1970: stmt.double(2))
            ))
        }
        return out
    }

    // MARK: - Settings

    public func setting(_ key: String) -> String? {
        guard let stmt = try? db.prepare("SELECT value FROM settings WHERE key=?1") else { return nil }
        stmt.bind(key, 1)
        guard let row = try? stmt.step(), row else { return nil }
        return stmt.str(0)
    }

    public func setSetting(_ key: String, _ value: String?) throws {
        let stmt = try db.prepare("""
            INSERT INTO settings(key,value) VALUES(?1,?2)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """)
        stmt.bind(key, 1); stmt.bind(value, 2)
        _ = try stmt.step()
    }

    /// Retention: delete events older than the configured window. Default 90 days;
    /// "forever" deletes nothing.
    public func applyRetention() throws {
        let days = Int(setting("retention_days") ?? "90") ?? 90
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        let stmt = try db.prepare("DELETE FROM events WHERE ts IS NOT NULL AND ts < ?1")
        stmt.bind(cutoff, 1)
        _ = try stmt.step()
    }

    /// One-click privacy: every stored byte of analytics, gone.
    public func deleteAllData() throws {
        try db.transaction {
            try db.exec("DELETE FROM events")
            try db.exec("DELETE FROM quota_snapshots")
            try db.exec("DELETE FROM checkpoints")
        }
    }

    // MARK: - Analytics

    public struct ProviderTotals: Equatable {
        public var provider: String
        public var billable: Int
        public var requests: Int
        public var costUSD: Double?
        public var sessions: Int
    }

    /// Totals per provider. `since`/`until` are inclusive lower / exclusive upper bounds.
    public func totalsByProvider(since: Date? = nil, until: Date? = nil) throws -> [ProviderTotals] {
        var whereClauses: [String] = []
        if since != nil { whereClauses.append("ts >= ?1") }
        if until != nil { whereClauses.append("ts < ?2") }
        let whereSQL = whereClauses.isEmpty ? "" : "WHERE ts IS NOT NULL AND " + whereClauses.joined(separator: " AND ")
        let stmt = try db.prepare("""
            SELECT provider, SUM(billable), COUNT(*), SUM(cost_usd), COUNT(DISTINCT session_id)
            FROM events \(whereSQL) GROUP BY provider ORDER BY SUM(billable) DESC
            """)
        if let since { stmt.bind(since.timeIntervalSince1970, 1) }
        if let until { stmt.bind(until.timeIntervalSince1970, 2) }
        var out: [ProviderTotals] = []
        while try stmt.step() {
            out.append(ProviderTotals(
                provider: stmt.str(0) ?? "?",
                billable: stmt.int(1),
                requests: stmt.int(2),
                costUSD: stmt.isNull(3) ? nil : stmt.double(3),
                sessions: stmt.int(4)
            ))
        }
        return out
    }

    public struct ModelTotals: Equatable {
        public var model: String
        public var provider: String
        public var billable: Int
        public var requests: Int
        public var costUSD: Double?
        public var sessions: Int
    }

    public func totalsByModel(since: Date? = nil) throws -> [ModelTotals] {
        let stmt = try db.prepare("""
            SELECT model, provider, SUM(billable), COUNT(*), SUM(cost_usd), COUNT(DISTINCT session_id)
            FROM events WHERE ts IS NOT NULL \(since != nil ? "AND ts >= ?1" : "")
            GROUP BY model, provider ORDER BY SUM(billable) DESC
            """)
        if let since { stmt.bind(since.timeIntervalSince1970, 1) }
        var out: [ModelTotals] = []
        while try stmt.step() {
            out.append(ModelTotals(
                model: stmt.str(0) ?? "unknown",
                provider: stmt.str(1) ?? "?",
                billable: stmt.int(2),
                requests: stmt.int(3),
                costUSD: stmt.isNull(4) ? nil : stmt.double(4),
                sessions: stmt.int(5)
            ))
        }
        return out
    }

    public struct ProjectTotals: Equatable {
        public var project: String
        public var provider: String
        public var billable: Int
        public var requests: Int
    }

    public func totalsByProject(since: Date? = nil) throws -> [ProjectTotals] {
        let stmt = try db.prepare("""
            SELECT project, provider, SUM(billable), COUNT(*)
            FROM events WHERE ts IS NOT NULL AND project IS NOT NULL
            \(since != nil ? "AND ts >= ?1" : "")
            GROUP BY project, provider ORDER BY SUM(billable) DESC
            """)
        if let since { stmt.bind(since.timeIntervalSince1970, 1) }
        var out: [ProjectTotals] = []
        while try stmt.step() {
            out.append(ProjectTotals(
                project: stmt.str(0) ?? "?",
                provider: stmt.str(1) ?? "?",
                billable: stmt.int(2),
                requests: stmt.int(3)
            ))
        }
        return out
    }

    /// Token flow buckets: per hour for a 1-day range, per day otherwise.
    /// Returns (bucketStart, billable) ascending.
    public func tokenFlow(since: Date, until: Date? = nil) throws -> [(Date, Int)] {
        let hourly = (until ?? Date()).timeIntervalSince(since) <= 36 * 3600
        let expr = hourly
            ? "strftime('%Y-%m-%d %H:00:00', ts, 'unixepoch', 'localtime')"
            : "date(ts, 'unixepoch', 'localtime')"
        let stmt = try db.prepare("""
            SELECT \(expr) b, SUM(billable) FROM events
            WHERE ts IS NOT NULL AND ts >= ?1 \(until != nil ? "AND ts < ?2" : "")
            GROUP BY b ORDER BY b
            """)
        stmt.bind(since.timeIntervalSince1970, 1)
        if let until { stmt.bind(until.timeIntervalSince1970, 2) }
        let fmt = DateFormatter()
        fmt.dateFormat = hourly ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
        var out: [(Date, Int)] = []
        while try stmt.step() {
            if let s = stmt.str(0), let d = fmt.parse(s) {
                out.append((d, stmt.int(1)))
            }
        }
        return out
    }

    /// Distinct minutes containing at least one event — the honest version of
    /// "AI active time" derivable from logs: activity corroborated by requests.
    public func activeMinutes(since: Date, until: Date? = nil) throws -> Int {
        let stmt = try db.prepare("""
            SELECT COUNT(DISTINCT strftime('%Y-%m-%d %H:%M', ts, 'unixepoch', 'localtime'))
            FROM events WHERE ts IS NOT NULL AND ts >= ?1 \(until != nil ? "AND ts < ?2" : "")
            """)
        stmt.bind(since.timeIntervalSince1970, 1)
        if let until { stmt.bind(until.timeIntervalSince1970, 2) }
        guard try stmt.step() else { return 0 }
        return stmt.int(0)
    }

    public struct ActiveSession: Equatable {
        public var provider: String
        public var model: String?
        public var lastEventAt: Date
    }

    /// Providers with an event in the last `withinSeconds` — "active now".
    public func activeNow(withinSeconds: TimeInterval = 300) throws -> [ActiveSession] {
        let cutoff = Date().addingTimeInterval(-withinSeconds).timeIntervalSince1970
        let stmt = try db.prepare("""
            SELECT provider, model, MAX(ts) FROM events
            WHERE ts IS NOT NULL AND ts >= ?1
            GROUP BY provider ORDER BY MAX(ts) DESC
            """)
        stmt.bind(cutoff, 1)
        var out: [ActiveSession] = []
        while try stmt.step() {
            out.append(ActiveSession(
                provider: stmt.str(0) ?? "?",
                model: stmt.str(1),
                lastEventAt: Date(timeIntervalSince1970: stmt.double(2))
            ))
        }
        return out
    }

    public struct DayTotals: Equatable {
        public var billable: Int
        public var requests: Int
        public var costUSD: Double?
        public var sessions: Int
    }

    public func totals(since: Date, until: Date? = nil) throws -> DayTotals {
        let stmt = try db.prepare("""
            SELECT SUM(billable), COUNT(*), SUM(cost_usd), COUNT(DISTINCT session_id)
            FROM events WHERE ts IS NOT NULL AND ts >= ?1 \(until != nil ? "AND ts < ?2" : "")
            """)
        stmt.bind(since.timeIntervalSince1970, 1)
        if let until { stmt.bind(until.timeIntervalSince1970, 2) }
        guard try stmt.step() else { return DayTotals(billable: 0, requests: 0, costUSD: nil, sessions: 0) }
        return DayTotals(
            billable: stmt.isNull(0) ? 0 : stmt.int(0),
            requests: stmt.int(1),
            costUSD: stmt.isNull(2) ? nil : stmt.double(2),
            sessions: stmt.int(3)
        )
    }

    /// Whole-history token breakdown per provider — the number the CLI report
    /// cross-checks against. SUM of billable components, not just billable.
    public func tokenBreakdown(provider: String) throws -> TokenBreakdown? {
        let stmt = try db.prepare("""
            SELECT SUM(uncached_input), SUM(cached_input), SUM(cache_write_5m), SUM(cache_write_1h),
                   SUM(cache_write_unspecified), SUM(output), SUM(reasoning)
            FROM events WHERE provider=?1
            """)
        stmt.bind(provider, 1)
        guard try stmt.step(), !stmt.isNull(0) else { return nil }
        return TokenBreakdown(
            uncachedInput: stmt.int(0), cachedInput: stmt.int(1),
            cacheWrite5m: stmt.int(2), cacheWrite1h: stmt.int(3),
            cacheWriteUnspecified: stmt.int(4),
            output: stmt.int(5), reasoning: stmt.int(6)
        )
    }

    public func eventCount(provider: String) throws -> Int {
        let stmt = try db.prepare("SELECT COUNT(*) FROM events WHERE provider=?1")
        stmt.bind(provider, 1)
        guard try stmt.step() else { return 0 }
        return stmt.int(0)
    }
}

private extension DateFormatter {
    func parse(_ s: String) -> Date? { date(from: s) }
}
