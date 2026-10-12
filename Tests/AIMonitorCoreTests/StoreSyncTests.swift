import XCTest
@testable import AIMonitorCore

// MARK: - Store dedup

final class EventStoreTests: XCTestCase {

    private func event(id: String, billable: Int, provider: String = "Claude Code", model: String? = "claude-opus-5") -> AIEvent {
        AIEvent(
            id: id, timestamp: Date(timeIntervalSince1970: 1_787_000_000),
            provider: provider, model: model,
            tokens: TokenBreakdown(output: billable),   // billable == output here
            costUSD: nil, confidence: .estimated
        )
    }

    /// Claude Code's progressive snapshots share a requestId; the fold keeps the
    /// largest regardless of arrival order — the invariant the CLI collector
    /// proved in memory, now enforced by the schema.
    func testKeepLargestIsOrderIndependent() throws {
        let store = try EventStore.inMemory()
        try store.insert(usage: event(id: "req_1", billable: 800), keepLargest: true)
        try store.insert(usage: event(id: "req_1", billable: 2), keepLargest: true)
        try store.insert(usage: event(id: "req_1", billable: 410), keepLargest: true)
        let t = try XCTUnwrap(store.tokenBreakdown(provider: "Claude Code"))
        XCTAssertEqual(t.billableEquivalent, 800, "smaller snapshots must never overwrite the completed one")
        XCTAssertEqual(try store.eventCount(provider: "Claude Code"), 1)
    }

    /// Codex positional ids replay identically: re-syncing a file is a no-op.
    func testPositionalIdsIgnoreReplays() throws {
        let store = try EventStore.inMemory()
        try store.insert(usage: event(id: "codex:rollout-a@0", billable: 100, provider: "Codex CLI", model: nil), keepLargest: false)
        try store.insert(usage: event(id: "codex:rollout-a@0", billable: 100, provider: "Codex CLI", model: nil), keepLargest: false)
        let t = try XCTUnwrap(store.tokenBreakdown(provider: "Codex CLI"))
        XCTAssertEqual(t.billableEquivalent, 100)
    }

    func testRetentionDeletesOldEvents() throws {
        let store = try EventStore.inMemory()
        var old = event(id: "old", billable: 10)
        old.timestamp = Date(timeIntervalSince1970: 1_000_000)   // 1970
        try store.insert(usage: old, keepLargest: true)
        try store.insert(usage: event(id: "new", billable: 10), keepLargest: true)
        try store.applyRetention()   // default 90 days
        XCTAssertEqual(try store.eventCount(provider: "Claude Code"), 1)
        try store.setSetting("retention_days", "0")   // forever
        try store.applyRetention()
        XCTAssertEqual(try store.eventCount(provider: "Claude Code"), 1, "forever must delete nothing")
    }

    func testDeleteAllData() throws {
        let store = try EventStore.inMemory()
        try store.insert(usage: event(id: "a", billable: 10), keepLargest: true)
        try store.deleteAllData()
        XCTAssertEqual(try store.eventCount(provider: "Claude Code"), 0)
        XCTAssertNil(try store.tokenBreakdown(provider: "Claude Code"))
    }
}

// MARK: - Incremental sync

final class SyncEngineTests: XCTestCase {

    private func claudeRecord(requestID: String, ts: String, output: Int) -> String {
        """
        {"requestId":"\(requestID)","timestamp":"\(ts)","type":"assistant","sessionId":"s1",\
        "message":{"id":"msg_\(requestID)_\(output)","model":"claude-opus-5",\
        "usage":{"input_tokens":2,"cache_read_input_tokens":100,\
        "cache_creation":{"ephemeral_1h_input_tokens":50,"ephemeral_5m_input_tokens":0},\
        "output_tokens":\(output)}}}
        """
    }

    private func codexTokenCount(ts: String, input: Int, cached: Int, output: Int) -> String {
        """
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{\
        "total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
        "cache_write_input_tokens":0,"output_tokens":\(output),"reasoning_output_tokens":0,\
        "total_tokens":\(input + output)}}}}
        """
    }

    /// The core invariant: incremental sync (sync, append, sync again) must land
    /// on exactly the same store contents as one full sync of the final file.
    func testIncrementalEqualsFullSyncClaude() throws {
        let incrementalDir = TempDir(), fullDir = TempDir()
        let lines1 = [claudeRecord(requestID: "r1", ts: "2026-08-10T10:00:00.000Z", output: 100)]
        let lines2 = lines1 + [claudeRecord(requestID: "r2", ts: "2026-08-10T10:01:00.000Z", output: 200)]

        let incStore = try EventStore.inMemory()
        let incEngine = SyncEngine(store: incStore, claudeRoot: incrementalDir.url, codexRoot: TempDir().url, kimiRoot: TempDir().url)
        _ = incrementalDir.write(lines1, to: "proj/session.jsonl")
        _ = incEngine.sync()
        _ = incrementalDir.write(lines2, to: "proj/session.jsonl")   // append (rewrite with more lines)
        _ = incEngine.sync()

        let fullStore = try EventStore.inMemory()
        let fullEngine = SyncEngine(store: fullStore, claudeRoot: fullDir.url, codexRoot: TempDir().url, kimiRoot: TempDir().url)
        _ = fullDir.write(lines2, to: "proj/session.jsonl")
        _ = fullEngine.sync()

        XCTAssertEqual(
            try incStore.tokenBreakdown(provider: ClaudeCodeCollector.providerName),
            try fullStore.tokenBreakdown(provider: ClaudeCodeCollector.providerName)
        )
    }

    /// Codex deltas must resume from the checkpoint's saved cumulative snapshot,
    /// not from zero — otherwise the second sync double-counts.
    func testIncrementalEqualsFullSyncCodex() throws {
        let incrementalDir = TempDir(), fullDir = TempDir()
        let lines1 = [codexTokenCount(ts: "2026-08-10T10:00:00.000Z", input: 100, cached: 50, output: 10)]
        let lines2 = lines1 + [codexTokenCount(ts: "2026-08-10T10:01:00.000Z", input: 300, cached: 150, output: 30)]

        let incStore = try EventStore.inMemory()
        let incEngine = SyncEngine(store: incStore, claudeRoot: TempDir().url, codexRoot: incrementalDir.url, kimiRoot: TempDir().url)
        _ = incrementalDir.write(lines1, to: "2026/08/10/rollout-a.jsonl")
        _ = incEngine.sync()
        _ = incrementalDir.write(lines2, to: "2026/08/10/rollout-a.jsonl")
        _ = incEngine.sync()

        let fullStore = try EventStore.inMemory()
        let fullEngine = SyncEngine(store: fullStore, claudeRoot: TempDir().url, codexRoot: fullDir.url, kimiRoot: TempDir().url)
        _ = fullDir.write(lines2, to: "2026/08/10/rollout-a.jsonl")
        _ = fullEngine.sync()

        let inc = try XCTUnwrap(try incStore.tokenBreakdown(provider: CodexCollector.providerName))
        let full = try XCTUnwrap(try fullStore.tokenBreakdown(provider: CodexCollector.providerName))
        XCTAssertEqual(inc, full)
        XCTAssertEqual(full.billableEquivalent, 330, "final snapshot: 150 fresh + 150 cached + 30 output")
    }

    /// Retrying a partial record after reopening the database must preserve both
    /// per-turn events and Codex's cumulative-counter resume state.
    func testPartialWriteSurvivesStoreReopenForEveryProvider() throws {
        let fixtures: [(provider: String, path: String, records: [String])] = [
            (ClaudeCodeCollector.providerName, "proj/session.jsonl", (1...3).map {
                claudeRecord(requestID: "r\($0)", ts: "2026-08-10T10:0\($0):00.000Z", output: $0 * 100)
            }),
            (CodexCollector.providerName, "2026/08/10/rollout-a.jsonl", (1...3).map {
                codexTokenCount(ts: "2026-08-10T10:0\($0):00.000Z", input: $0 * 100, cached: $0 * 50, output: $0 * 10)
            }),
            (KimiCollector.providerName, "sessions/wd_p_a1b2c3/session_s1/agents/main/wire.jsonl", (1...3).map {
                "{\"type\":\"usage.record\",\"usageScope\":\"turn\",\"usage\":{\"inputOther\":10,\"output\":\($0 * 100)},\"time\":1786973716746}"
            }),
        ]

        for fixture in fixtures {
            let dir = TempDir(), empty = TempDir(), databaseDir = TempDir()
            let databasePath = databaseDir.url.appendingPathComponent("events.sqlite").path
            func engine(_ store: EventStore) -> SyncEngine {
                SyncEngine(store: store,
                           claudeRoot: fixture.provider == ClaudeCodeCollector.providerName ? dir.url : empty.url,
                           codexRoot: fixture.provider == CodexCollector.providerName ? dir.url : empty.url,
                           kimiRoot: fixture.provider == KimiCollector.providerName ? dir.url : empty.url)
            }
            let prefix = fixture.records[0] + "\n"
            let second = Data(fixture.records[1].utf8)
            let split = second.count / 2
            let file = dir.write([prefix], to: fixture.path)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: second.prefix(split))
            let discoveredFiles: [URL]
            switch fixture.provider {
            case ClaudeCodeCollector.providerName: discoveredFiles = ClaudeCodeCollector.transcriptFiles(under: dir.url)
            case CodexCollector.providerName: discoveredFiles = CodexCollector.rolloutFiles(under: dir.url)
            default: discoveredFiles = KimiCollector.wireFiles(under: dir.url)
            }
            let checkpointPath = try XCTUnwrap(discoveredFiles.first).path
            do {
                let store = try EventStore(path: databasePath)
                XCTAssertEqual(engine(store).sync().filesFailed, 0, fixture.provider)
                XCTAssertEqual(try store.checkpoint(for: checkpointPath)?.offset, prefix.utf8.count, fixture.provider)
                XCTAssertEqual(try store.eventCount(provider: fixture.provider), 1, fixture.provider)
            }
            try handle.write(contentsOf: second.dropFirst(split))
            try handle.write(contentsOf: Data(("\n" + fixture.records[2]).utf8))

            let resumedStore = try EventStore(path: databasePath)
            XCTAssertEqual(engine(resumedStore).sync().filesFailed, 0, fixture.provider)
            let fullStore = try EventStore.inMemory()
            XCTAssertEqual(engine(fullStore).sync().filesFailed, 0, fixture.provider)
            XCTAssertEqual(try resumedStore.tokenBreakdown(provider: fixture.provider),
                           try fullStore.tokenBreakdown(provider: fixture.provider), fixture.provider)
            XCTAssertEqual(try resumedStore.eventCount(provider: fixture.provider), 3, fixture.provider)
            XCTAssertEqual(engine(resumedStore).sync().filesSkippedUnchanged, 1, fixture.provider)
        }
    }

    /// An unchanged file must be skipped — this is what makes the menu-bar timer cheap.
    func testUnchangedFilesAreSkipped() throws {
        let dir = TempDir()
        _ = dir.write([claudeRecord(requestID: "r1", ts: "2026-08-10T10:00:00.000Z", output: 100)], to: "proj/session.jsonl")
        let store = try EventStore.inMemory()
        let engine = SyncEngine(store: store, claudeRoot: dir.url, codexRoot: TempDir().url, kimiRoot: TempDir().url)
        var s = engine.sync()
        XCTAssertEqual(s.filesScanned, 1)
        s = engine.sync()
        XCTAssertEqual(s.filesScanned, 0)
        XCTAssertEqual(s.filesSkippedUnchanged, 1)
    }

    /// A truncated file (rotated) must be re-parsed from zero without duplicates.
    func testTruncatedFileReparsesCleanly() throws {
        let dir = TempDir()
        let lines = [claudeRecord(requestID: "r1", ts: "2026-08-10T10:00:00.000Z", output: 100),
                     claudeRecord(requestID: "r2", ts: "2026-08-10T10:01:00.000Z", output: 200)]
        _ = dir.write(lines, to: "proj/session.jsonl")
        let store = try EventStore.inMemory()
        let engine = SyncEngine(store: store, claudeRoot: dir.url, codexRoot: TempDir().url, kimiRoot: TempDir().url)
        _ = engine.sync()
        _ = dir.write([lines[0]], to: "proj/session.jsonl")   // truncated: smaller than checkpoint
        let s = engine.sync()
        XCTAssertEqual(s.filesScanned, 1, "size shrink must force re-parse")
        // r2's event stays in the store (history is history), r1 replays harmlessly.
        XCTAssertEqual(try store.eventCount(provider: ClaudeCodeCollector.providerName), 2)
    }

    /// Sync makes the store faithful to the logs; it must never silently apply
    /// retention — old events survive a sync and are only deleted by an
    /// explicit applyRetention() call.
    func testSyncNeverDeletesOldEvents() throws {
        let dir = TempDir()
        _ = dir.write([claudeRecord(requestID: "ancient", ts: "2020-01-01T00:00:00.000Z", output: 100)], to: "proj/session.jsonl")
        let store = try EventStore.inMemory()
        let engine = SyncEngine(store: store, claudeRoot: dir.url, codexRoot: TempDir().url, kimiRoot: TempDir().url)
        _ = engine.sync()
        XCTAssertEqual(try store.eventCount(provider: ClaudeCodeCollector.providerName), 1)
    }

    func testQuotaSnapshotsDeduplicateConsecutiveRepeats() throws {
        let store = try EventStore.inMemory()
        let q = QuotaWindow(id: "codex", label: "Weekly", usedPercent: 42, windowMinutes: 10080,
                            resetsAt: Date(timeIntervalSince1970: 1_787_500_000),
                            observedAt: Date(timeIntervalSince1970: 1_787_000_000), planType: nil)
        try store.insert(quota: q, provider: "Codex CLI")
        try store.insert(quota: q, provider: "Codex CLI")
        XCTAssertEqual(try store.quotaHistory(windowId: "codex").count, 1, "identical consecutive snapshots are noise")
    }
}

// MARK: - Burn rate

final class BurnRateTests: XCTestCase {

    private func point(_ hoursAgo: Double, _ pct: Double, resetsInHours: Double = 24) -> EventStore.QuotaPoint {
        EventStore.QuotaPoint(
            observedAt: Date().addingTimeInterval(-hoursAgo * 3600),
            usedPercent: pct,
            resetsAt: Date().addingTimeInterval(resetsInHours * 3600)
        )
    }

    func testProjectionWithSufficientData() throws {
        let reset = Date().addingTimeInterval(24 * 3600)
        let history = [point(6, 20), point(3, 50), point(0, 80)]
        let p = try XCTUnwrap(BurnRate.project(history: history, windowMinutes: 10080, resetsAt: reset))
        XCTAssertEqual(p.percentPerHour, 10, accuracy: 0.01)
        // 20% remaining at 10%/h → 2 hours
        XCTAssertEqual(p.exhaustedAt.timeIntervalSinceNow, 2 * 3600, accuracy: 60)
    }

    func testNoPredictionWithOnePoint() {
        XCTAssertNil(BurnRate.project(history: [point(0, 60)], windowMinutes: 300, resetsAt: Date().addingTimeInterval(3600)))
    }

    func testNoPredictionWhenSpanTooShort() {
        // Two points 30 seconds apart on a weekly window: nothing to project from.
        let history = [
            EventStore.QuotaPoint(observedAt: Date().addingTimeInterval(-30), usedPercent: 40, resetsAt: nil),
            EventStore.QuotaPoint(observedAt: Date(), usedPercent: 41, resetsAt: nil),
        ]
        XCTAssertNil(BurnRate.project(history: history, windowMinutes: 10080, resetsAt: Date().addingTimeInterval(24 * 3600)))
    }

    func testNoPredictionWhenBurnIsZero() {
        let history = [point(2, 60), point(1, 60), point(0, 60)]
        XCTAssertNil(BurnRate.project(history: history, windowMinutes: 10080, resetsAt: Date().addingTimeInterval(24 * 3600)))
    }

    func testNoPredictionWhenQuotaSurvivesTheWindow() {
        // Burning ~0.33%/hour with 24h to reset → nowhere near exhaustion.
        let history = [point(6, 40), point(3, 41), point(0, 42)]
        XCTAssertNil(BurnRate.project(history: history, windowMinutes: 10080, resetsAt: Date().addingTimeInterval(24 * 3600)))
    }

    func testResetDiscardsOldHistory() throws {
        let reset = Date().addingTimeInterval(24 * 3600)
        // Usage drops between 6h and 4h ago — a reset. Only post-reset points count.
        let history = [point(8, 95), point(6, 97), point(4, 5), point(0, 45)]
        let p = try XCTUnwrap(BurnRate.project(history: history, windowMinutes: 10080, resetsAt: reset))
        XCTAssertEqual(p.percentPerHour, 10, accuracy: 0.01, "rate must come from post-reset points only")
    }
}
