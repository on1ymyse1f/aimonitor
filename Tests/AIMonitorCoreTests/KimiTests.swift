import XCTest
@testable import AIMonitorCore

// MARK: - Kimi Code: wire-log parsing

final class KimiCollectorTests: XCTestCase {

    private func usageRecord(model: String = "kimi-code/kimi-for-coding", input: Int = 2119,
                             cached: Int = 17920, cacheWrite: Int = 0, output: Int = 47,
                             timeMs: Int = 1_786_973_716_746, scope: String? = "turn") -> String {
        let scopePart = scope.map { ",\"usageScope\":\"\($0)\"" } ?? ""
        return """
        {"type":"usage.record","model":"\(model)","usage":{"inputOther":\(input),"output":\(output),\
        "inputCacheRead":\(cached),"inputCacheCreation":\(cacheWrite)}\(scopePart),"time":\(timeMs)}
        """
    }

    /// The field mapping verified against live logs: inputOther is fresh input,
    /// inputCacheRead is cached, inputCacheCreation has no TTL.
    func testNormalizeTurnRecord() throws {
        let dir = TempDir()
        _ = dir.write([usageRecord()], to: "wd_proj_a1b2c3/session_s1/agents/main/wire.jsonl")
        let report = KimiCollector(sessionsRoot: dir.url).collect()
        let t = try XCTUnwrap(report.tokens)
        XCTAssertEqual(t.uncachedInput, 2119)
        XCTAssertEqual(t.cachedInput, 17920)
        XCTAssertEqual(t.cacheWriteUnspecified, 0)
        XCTAssertEqual(t.output, 47)
        XCTAssertEqual(report.tokenConfidence, .exact)
    }

    /// A non-turn scope (should one ever appear) must not be summed next to
    /// turn records — it would double-count.
    func testNonTurnScopeIsSkipped() throws {
        let dir = TempDir()
        _ = dir.write([
            usageRecord(output: 10),
            usageRecord(output: 999, scope: "session"),
        ], to: "wd_proj_a1b2c3/session_s1/agents/main/wire.jsonl")
        let report = KimiCollector(sessionsRoot: dir.url).collect()
        XCTAssertEqual(report.tokens?.output, 10)
    }

    /// `time` is epoch milliseconds: 1_786_973_716_746 → 2026, not 1970 + ms-as-seconds.
    func testTimestampIsMilliseconds() throws {
        let object: [String: Any] = ["time": 1_786_973_716_746]
        let d = try XCTUnwrap(KimiCollector.timestamp(of: object))
        XCTAssertEqual(d.timeIntervalSince1970, 1_786_973_716.746, accuracy: 0.001)
    }

    func testPerModelBreakdown() throws {
        let dir = TempDir()
        _ = dir.write([
            usageRecord(model: "kimi-code/k3", output: 10),
            usageRecord(model: "kimi-code/k3", output: 20),
            usageRecord(model: "kimi-code/kimi-for-coding", output: 5),
        ], to: "wd_proj_a1b2c3/session_s1/agents/main/wire.jsonl")
        let report = KimiCollector(sessionsRoot: dir.url).collect()
        XCTAssertEqual(report.perModel.count, 2)
        XCTAssertEqual(report.perModel.first?.model, "kimi-code/k3")
        XCTAssertEqual(report.perModel.first?.requests, 2)
    }

    /// Empty directory reports unavailable, never a quiet zero.
    func testNoLogsIsUnavailableNotZero() {
        let report = KimiCollector(sessionsRoot: TempDir().url).collect()
        XCTAssertEqual(report.tokenConfidence, .unavailable)
        XCTAssertNil(report.tokens)
    }

    /// Project attribution: session_index workDir wins; the workspace slug is
    /// the fallback when a session is not indexed.
    func testProjectAttribution() throws {
        let dir = TempDir()
        _ = dir.write(
            ["{\"sessionId\":\"session_s1\",\"sessionDir\":\"/x\",\"workDir\":\"/Users/me/my-project\"}"],
            to: "session_index.jsonl"
        )
        let sessions = dir.url.appendingPathComponent("sessions", isDirectory: true)
        let indexed = dir.write([usageRecord()], to: "sessions/wd_me_deadbeef/session_s1/agents/main/wire.jsonl")
        let unindexed = dir.write([usageRecord()], to: "sessions/wd_fallback_1a2b3c4d/session_s2/agents/main/wire.jsonl")

        let index = KimiCollector.sessionIndex(under: sessions)
        XCTAssertEqual(index["session_s1"], "/Users/me/my-project")
        XCTAssertEqual(KimiCollector.projectName(for: indexed, under: sessions, index: index), "my-project")
        XCTAssertEqual(KimiCollector.projectName(for: unindexed, under: sessions, index: index), "fallback")
    }

    /// Incremental sync (sync, append, sync again) must equal one full sync,
    /// and a repeat sync must be a no-op — per-turn records summed twice would
    /// show up immediately.
    func testIncrementalEqualsFullSyncKimi() throws {
        let incrementalDir = TempDir(), fullDir = TempDir()
        let rel = "sessions/wd_p_a1b2c3/session_s1/agents/main/wire.jsonl"
        let lines1 = [usageRecord(output: 100)]
        let lines2 = lines1 + [usageRecord(output: 200)]

        let incStore = try EventStore.inMemory()
        let incEngine = SyncEngine(store: incStore, claudeRoot: TempDir().url, codexRoot: TempDir().url, kimiRoot: incrementalDir.url)
        _ = incrementalDir.write(lines1, to: rel)
        _ = incEngine.sync()
        _ = incrementalDir.write(lines2, to: rel)
        _ = incEngine.sync()
        let s = incEngine.sync()   // replay: must be a no-op
        XCTAssertEqual(s.kimiEvents, 0)

        let fullStore = try EventStore.inMemory()
        let fullEngine = SyncEngine(store: fullStore, claudeRoot: TempDir().url, codexRoot: TempDir().url, kimiRoot: fullDir.url)
        _ = fullDir.write(lines2, to: rel)
        _ = fullEngine.sync()

        XCTAssertEqual(
            try incStore.tokenBreakdown(provider: KimiCollector.providerName),
            try fullStore.tokenBreakdown(provider: KimiCollector.providerName)
        )
        XCTAssertEqual(try fullStore.tokenBreakdown(provider: KimiCollector.providerName)?.output, 300)
    }
}

// MARK: - Kimi online quota: defensive parsing

final class KimiQuotaProviderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    func testParsesDataEnvelopeShape() {
        let root: [String: Any] = ["data": [
            "five_hour": ["utilization": 37.5, "resets_at": "2026-08-18T04:00:00Z"],
            "weekly": ["utilization": 12.0, "resets_at": 1_787_600_000],
        ]]
        let windows = KimiQuotaProvider.parseWindows(from: root, now: now)
        XCTAssertEqual(windows.count, 2)
        let fiveHour = windows.first { $0.id == "kimi-five-hour" }
        XCTAssertEqual(fiveHour?.usedPercent, 37.5)
        XCTAssertEqual(fiveHour?.windowMinutes, 300)
        XCTAssertNotNil(fiveHour?.resetsAt)
        let weekly = windows.first { $0.id == "kimi-weekly" }
        XCTAssertEqual(weekly?.resetsAt, Date(timeIntervalSince1970: 1_787_600_000))
    }

    func testParsesFlatShape() {
        let root: [String: Any] = ["weekly": ["used_percent": 55.0]]
        let windows = KimiQuotaProvider.parseWindows(from: root, now: now)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.usedPercent, 55.0)
    }

    /// A window without a recognizable percent must not be emitted — a partial
    /// parse is no data, never a guessed window.
    func testWindowWithoutPercentIsDropped() {
        let root: [String: Any] = ["weekly": ["resets_at": 1_787_600_000]]
        XCTAssertTrue(KimiQuotaProvider.parseWindows(from: root, now: now).isEmpty)
    }

    func testUnknownShapeYieldsNothing() {
        XCTAssertTrue(KimiQuotaProvider.parseWindows(from: ["hello": "world"], now: now).isEmpty)
    }
}

// MARK: - Profile card: streaks and formatting

final class CardReportTests: XCTestCase {

    private func day(_ offset: Int, from base: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: base))!
    }

    func testCurrentStreakIsZeroWhenTodayIsQuiet() {
        let today = Date()
        let days = [(day: day(-2, from: today), billable: 100), (day: day(-1, from: today), billable: 100)]
        let s = CardReport.stats(from: days, today: today)
        XCTAssertEqual(s.currentStreak, 0, "a streak you are not still on today is over")
        XCTAssertEqual(s.longestStreak, 2)
    }

    func testCurrentStreakCountsBackFromToday() {
        let today = Date()
        let days = [
            (day: day(-5, from: today), billable: 10),   // island
            (day: day(-2, from: today), billable: 10),
            (day: day(-1, from: today), billable: 10),
            (day: day(0, from: today), billable: 10),
        ]
        let s = CardReport.stats(from: days, today: today)
        XCTAssertEqual(s.currentStreak, 3)
        XCTAssertEqual(s.longestStreak, 3)
    }

    func testPeakAndTotal() {
        let today = Date()
        let days = [(day: day(-1, from: today), billable: 300), (day: day(0, from: today), billable: 900)]
        let s = CardReport.stats(from: days, today: today)
        XCTAssertEqual(s.totalBillable, 1200)
        XCTAssertEqual(s.peakDay?.billable, 900)
    }

    func testCompactFormatting() {
        XCTAssertEqual(CardReport.compact(2_090_000_000, lang: .zh), "20.9亿")
        XCTAssertEqual(CardReport.compact(300_000_000, lang: .zh), "3亿")
        XCTAssertEqual(CardReport.compact(45_000, lang: .zh), "4.5万")
        XCTAssertEqual(CardReport.compact(940, lang: .zh), "940")
        XCTAssertEqual(CardReport.compact(2_090_000_000, lang: .en), "2.1B")
        XCTAssertEqual(CardReport.compact(4_810_000, lang: .en), "4.8M")
        XCTAssertEqual(CardReport.compact(940, lang: .en), "940")
    }

    /// The card HTML must escape free text and carry all four stats.
    func testCardHTMLEscapesAndRenders() {
        let today = Date()
        let s = CardReport.stats(from: [(day: today, billable: 1000)], today: today)
        let html = CardReport.html(
            provider: "Kimi <Code>", stats: s, name: "A & B", handle: "a\"b", lang: .zh
        )
        XCTAssertFalse(html.contains("Kimi <Code>"))
        XCTAssertTrue(html.contains("Kimi &lt;Code&gt;"))
        XCTAssertTrue(html.contains("A &amp; B"))
        XCTAssertTrue(html.contains("累计 Token"))
        XCTAssertTrue(html.contains("最长连续使用"))
    }
}
