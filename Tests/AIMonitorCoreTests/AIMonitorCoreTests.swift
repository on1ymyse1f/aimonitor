import XCTest
@testable import AIMonitorCore

/// Fixtures are written to disk at run time, shaped to the *real* log formats
/// verified against live logs on this machine — including the two traps that
/// make naive parsers over-report.
final class TempDir {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aimonitor-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ lines: [String], to relativePath: String) -> URL {
        let target = url.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? lines.joined(separator: "\n").write(to: target, atomically: true, encoding: .utf8)
        return target
    }
}

// MARK: - Codex: the cumulative-counter trap

final class CodexCollectorTests: XCTestCase {

    /// Codex's `total_token_usage` is cumulative per session. Summing the
    /// snapshots overcounts; the right answer is the final snapshot.
    func testCumulativeSnapshotsAreNotSummed() {
        let dir = TempDir()
        _ = dir.write([
            codexTokenCount(ts: "2026-08-10T10:00:00.000Z", input: 100, cached: 50, output: 10),
            codexTokenCount(ts: "2026-08-10T10:01:00.000Z", input: 300, cached: 150, output: 30),
            codexTokenCount(ts: "2026-08-10T10:02:00.000Z", input: 600, cached: 300, output: 60),
        ], to: "2026/08/10/rollout-a.jsonl")

        let report = CodexCollector(sessionsRoot: dir.url).collect()
        let tokens = report.tokens!

        // Final cumulative snapshot, NOT 10+30+60 == 100.
        XCTAssertEqual(tokens.output, 60, "summing cumulative snapshots would give 100")
        // input is inclusive of cached, so fresh input is 600 - 300.
        XCTAssertEqual(tokens.uncachedInput, 300)
        XCTAssertEqual(tokens.cachedInput, 300)
        XCTAssertEqual(report.tokenConfidence, .exact)
    }

    /// Duplicate `token_count` events repeat an identical cumulative value.
    /// Delta accumulation must therefore contribute zero for the duplicate.
    func testDuplicateTokenCountEventsContributeZero() {
        let dir = TempDir()
        _ = dir.write([
            codexTokenCount(ts: "2026-08-10T10:00:00.000Z", input: 100, cached: 0, output: 10),
            codexTokenCount(ts: "2026-08-10T10:00:01.000Z", input: 100, cached: 0, output: 10),
            codexTokenCount(ts: "2026-08-10T10:00:02.000Z", input: 100, cached: 0, output: 10),
            codexTokenCount(ts: "2026-08-10T10:01:00.000Z", input: 250, cached: 0, output: 25),
        ], to: "2026/08/10/rollout-a.jsonl")

        let tokens = CodexCollector(sessionsRoot: dir.url).collect().tokens!
        XCTAssertEqual(tokens.output, 25)
        XCTAssertEqual(tokens.uncachedInput, 250)
    }

    /// Summed deltas from a zero baseline must equal the final snapshot. This is
    /// the invariant that lets windowed queries share the whole-history path.
    func testDeltaSumEqualsFinalSnapshot() {
        let dir = TempDir()
        _ = dir.write([
            codexTokenCount(ts: "2026-08-10T10:00:00.000Z", input: 1000, cached: 400, output: 100),
            codexTokenCount(ts: "2026-08-10T11:00:00.000Z", input: 2500, cached: 900, output: 260),
            codexTokenCount(ts: "2026-08-10T12:00:00.000Z", input: 4000, cached: 1500, output: 410),
        ], to: "2026/08/10/rollout-a.jsonl")

        let whole = CodexCollector(sessionsRoot: dir.url).collect().tokens!
        let windowed = CodexCollector(sessionsRoot: dir.url)
            .collect(since: Timestamps.parse("2026-08-10T09:00:00.000Z")!).tokens!

        XCTAssertEqual(whole.output, 410)
        XCTAssertEqual(windowed, whole, "a window covering all events must equal the whole-history total")
    }

    /// A resume/fork restarts the counters mid-file. Prior usage still counts,
    /// and the reset is surfaced rather than silently flooring to zero.
    func testCounterResetIsHandledAndReported() {
        let dir = TempDir()
        _ = dir.write([
            codexTokenCount(ts: "2026-08-10T10:00:00.000Z", input: 500, cached: 0, output: 50),
            codexTokenCount(ts: "2026-08-10T10:01:00.000Z", input: 900, cached: 0, output: 90),
            // resume: counters restart
            codexTokenCount(ts: "2026-08-10T10:02:00.000Z", input: 200, cached: 0, output: 20),
            codexTokenCount(ts: "2026-08-10T10:03:00.000Z", input: 350, cached: 0, output: 35),
        ], to: "2026/08/10/rollout-a.jsonl")

        let report = CodexCollector(sessionsRoot: dir.url).collect()
        XCTAssertEqual(report.stats.counterResetsObserved, 1)
        // 900 pre-reset + 350 post-reset
        XCTAssertEqual(report.tokens!.output, 90 + 35)
        XCTAssertEqual(report.tokenConfidence, .estimated, "a reset makes the total an estimate")
    }

    /// Quota comes from the log itself — no credentials. `resets_at` is an
    /// absolute epoch, and the window label derives from `window_minutes`.
    func testQuotaParsedFromRateLimitsWithDerivedLabel() {
        let dir = TempDir()
        let line = """
        {"timestamp":"2026-08-13T05:44:36.693Z","type":"event_msg","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":0,\
        "output_tokens":5,"reasoning_output_tokens":1,"total_tokens":15}},\
        "rate_limits":{"limit_id":"codex","limit_name":null,\
        "primary":{"used_percent":100.0,"window_minutes":10080,"resets_at":1787196990},\
        "secondary":null,"plan_type":"plus"}}}
        """
        _ = dir.write([line], to: "2026/08/13/rollout-a.jsonl")

        let report = CodexCollector(sessionsRoot: dir.url).collect()
        XCTAssertEqual(report.quotaConfidence, .exact)
        XCTAssertEqual(report.quotas.count, 1, "secondary is null and must not produce a phantom window")

        let quota = report.quotas[0]
        XCTAssertEqual(quota.label, "weekly", "10080 minutes is a weekly window, not the assumed 5h")
        XCTAssertEqual(quota.usedPercent, 100.0)
        XCTAssertEqual(quota.planType, "plus")
        XCTAssertEqual(
            quota.resetsAt, Date(timeIntervalSince1970: 1_787_196_990),
            "resets_at is an absolute epoch, not an offset"
        )
    }

    func testWindowLabelsDeriveFromMinutes() {
        XCTAssertEqual(QuotaWindow.label(forWindowMinutes: 300), "5h")
        XCTAssertEqual(QuotaWindow.label(forWindowMinutes: 10080), "weekly")
        XCTAssertEqual(QuotaWindow.label(forWindowMinutes: 1440), "daily")
        XCTAssertEqual(QuotaWindow.label(forWindowMinutes: 180), "3h")
    }

    /// Codex ships no verified rate card, so cost must be absent, not guessed.
    func testCodexCostIsUnavailableNotZero() {
        let dir = TempDir()
        _ = dir.write([
            codexTokenCount(ts: "2026-08-10T10:00:00.000Z", input: 100, cached: 0, output: 10),
        ], to: "2026/08/10/rollout-a.jsonl")

        let report = CodexCollector(sessionsRoot: dir.url).collect()
        XCTAssertNil(report.apiEquivalentCostUSD)
        XCTAssertEqual(report.apiEquivalentCostConfidence, .unavailable)
    }

    /// An empty scan must not read as a quiet day.
    func testEmptyScanReportsUnavailableRatherThanZero() {
        let dir = TempDir()
        let report = CodexCollector(sessionsRoot: dir.url).collect()
        XCTAssertNil(report.tokens)
        XCTAssertEqual(report.tokenConfidence, .unavailable)
        XCTAssertTrue(report.notes.contains { $0.contains("not a quiet day") })
    }

    private func codexTokenCount(ts: String, input: Int, cached: Int, output: Int) -> String {
        """
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{\
        "total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
        "cache_write_input_tokens":0,"output_tokens":\(output),"reasoning_output_tokens":0,\
        "total_tokens":\(input + output)},\
        "last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"cache_write_input_tokens":0,\
        "output_tokens":0,"reasoning_output_tokens":0,"total_tokens":0},\
        "model_context_window":272000}}}
        """
    }
}

// MARK: - Claude Code: the duplicate-record trap

final class ClaudeCodeCollectorTests: XCTestCase {

    /// Live logs repeat one request across several assistant records with
    /// identical usage. Summing lines over-reports; folding by requestId does not.
    func testDuplicateRequestIdsAreFoldedNotSummed() {
        let dir = TempDir()
        let record = claudeRecord(requestID: "req_1", model: "claude-opus-5", input: 2, output: 410, cacheRead: 48357, cacheWrite1h: 225)
        _ = dir.write([record, record, record], to: "proj/session.jsonl")

        let report = ClaudeCodeCollector(projectsRoot: dir.url).collect()
        let tokens = report.tokens!

        XCTAssertEqual(tokens.output, 410, "summing three identical records would give 1230")
        XCTAssertEqual(report.stats.duplicatesDropped, 2)
        XCTAssertEqual(report.stats.recordsWithUsage, 3)
    }

    /// Claude Code totals depend on `input_tokens`, whose meaning is disputed
    /// upstream, so they must never be presented as exact — not even on a clean
    /// scan where every record carried a requestId.
    func testClaudeCodeTokensAreNeverExact() {
        let dir = TempDir()
        _ = dir.write([
            claudeRecord(requestID: "req_1", model: "claude-opus-5", input: 2, output: 500, cacheRead: 400_000, cacheWrite1h: 2451),
        ], to: "proj/session.jsonl")

        let report = ClaudeCodeCollector(projectsRoot: dir.url).collect()
        XCTAssertEqual(report.stats.syntheticallyKeyed, 0, "clean scan")
        XCTAssertEqual(report.tokenConfidence, .estimated)
        XCTAssertTrue(report.notes.contains { $0.contains("Fresh input reads low") })
    }

    /// Records sharing a requestId are progressive snapshots of one streaming
    /// message: output grows while input holds steady. The completed snapshot is
    /// the largest, and picking the largest rather than the last makes the fold
    /// independent of the order files happen to be traversed in.
    func testProgressiveStreamingSnapshotsKeepTheCompletedOne() {
        let dir = TempDir()
        // Same requestId, output growing 2 -> 783, deliberately written so the
        // completed snapshot is NOT last in traversal order.
        _ = dir.write([
            claudeRecord(requestID: "req_1", model: "claude-opus-5", input: 5103, output: 2),
            claudeRecord(requestID: "req_1", model: "claude-opus-5", input: 5103, output: 783),
            claudeRecord(requestID: "req_1", model: "claude-opus-5", input: 5103, output: 2),
        ], to: "proj/session.jsonl")

        let report = ClaudeCodeCollector(projectsRoot: dir.url).collect()
        XCTAssertEqual(report.tokens!.output, 783, "a later partial snapshot must not overwrite the completed one")
        XCTAssertEqual(report.stats.duplicatesDropped, 2)
    }

    /// The same records in any order must produce the same total.
    func testFoldIsIndependentOfTraversalOrder() {
        let records = [
            ("req_1", 2), ("req_1", 783), ("req_2", 5), ("req_2", 489), ("req_3", 256),
        ]
        func total(_ ordered: [(String, Int)]) -> Int {
            let dir = TempDir()
            _ = dir.write(
                ordered.map { claudeRecord(requestID: $0.0, model: "claude-opus-5", input: 10, output: $0.1) },
                to: "proj/session.jsonl"
            )
            return ClaudeCodeCollector(projectsRoot: dir.url).collect().tokens!.output
        }
        XCTAssertEqual(total(records), 783 + 489 + 256)
        XCTAssertEqual(total(records.reversed()), 783 + 489 + 256)
        XCTAssertEqual(total(records.shuffled()), 783 + 489 + 256)
    }

    /// A record with no provider-assigned identity can hide a duplicate, so the
    /// total must degrade to an estimate and say why.
    func testMissingRequestIdDegradesConfidence() {
        let dir = TempDir()
        _ = dir.write([
            claudeRecord(requestID: nil, messageID: nil, model: "claude-opus-5", input: 10, output: 20),
        ], to: "proj/session.jsonl")

        let report = ClaudeCodeCollector(projectsRoot: dir.url).collect()
        XCTAssertEqual(report.stats.syntheticallyKeyed, 1)
        XCTAssertEqual(report.tokenConfidence, .estimated)
        XCTAssertTrue(report.notes.contains { $0.contains("keyed by file+line") })
    }

    /// Falls back to message.id when requestId is absent but the message has one.
    func testFallsBackToMessageIdBeforeGoingPositional() {
        let dir = TempDir()
        let record = claudeRecord(requestID: nil, messageID: "msg_abc", model: "claude-opus-5", input: 10, output: 20)
        _ = dir.write([record, record], to: "proj/session.jsonl")

        let report = ClaudeCodeCollector(projectsRoot: dir.url).collect()
        XCTAssertEqual(report.stats.syntheticallyKeyed, 0)
        XCTAssertEqual(report.stats.duplicatesDropped, 1)
        XCTAssertEqual(report.tokens!.output, 20)
    }

    /// 1h and 5m cache writes bill at different rates and must stay separate.
    func testCacheWriteTTLSplitIsPreservedAndPricedCorrectly() {
        let dir = TempDir()
        _ = dir.write([
            claudeRecord(
                requestID: "req_1", model: "claude-opus-5",
                input: 1000, output: 500, cacheRead: 10000,
                cacheWrite1h: 2000, cacheWrite5m: 1000
            ),
        ], to: "proj/session.jsonl")

        let report = ClaudeCodeCollector(projectsRoot: dir.url).collect()
        let tokens = report.tokens!
        XCTAssertEqual(tokens.cacheWrite1h, 2000)
        XCTAssertEqual(tokens.cacheWrite5m, 1000)
        XCTAssertEqual(tokens.cacheWriteUnspecified, 0)

        // Golden value cross-checked independently: 1h at 2x, 5m at 1.25x.
        let cost = NSDecimalNumber(decimal: report.apiEquivalentCostUSD!).doubleValue
        XCTAssertEqual(cost, 0.048750, accuracy: 1e-9)

        // The wrong answer a flat 1.25x on all writes would produce.
        let flatWrong = 0.041250
        XCTAssertNotEqual(cost, flatWrong, accuracy: 1e-9)
    }

    /// A flat `cache_creation_input_tokens` with no TTL breakdown must be
    /// carried as unspecified rather than silently filed under one TTL.
    func testFlatCacheCreationBecomesUnspecified() {
        let dir = TempDir()
        let line = """
        {"requestId":"req_1","timestamp":"2026-08-10T10:00:00.000Z","type":"assistant",\
        "message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":10,\
        "cache_read_input_tokens":0,"cache_creation_input_tokens":800,"output_tokens":20}}}
        """
        _ = dir.write([line], to: "proj/session.jsonl")

        let tokens = ClaudeCodeCollector(projectsRoot: dir.url).collect().tokens!
        XCTAssertEqual(tokens.cacheWriteUnspecified, 800)
        XCTAssertEqual(tokens.cacheWrite1h, 0)
        XCTAssertEqual(tokens.cacheWrite5m, 0)
    }

    /// Error envelopes carry usage for a request that never completed.
    func testApiErrorRecordsAreExcluded() {
        let dir = TempDir()
        let good = claudeRecord(requestID: "req_ok", model: "claude-opus-5", input: 10, output: 20)
        let bad = """
        {"requestId":"req_err","timestamp":"2026-08-10T10:00:00.000Z","type":"assistant",\
        "isApiErrorMessage":true,"message":{"id":"msg_e","model":"claude-opus-5",\
        "usage":{"input_tokens":9999,"output_tokens":9999}}}
        """
        _ = dir.write([good, bad], to: "proj/session.jsonl")

        let report = ClaudeCodeCollector(projectsRoot: dir.url).collect()
        XCTAssertEqual(report.tokens!.output, 20)
        XCTAssertTrue(report.notes.contains { $0.contains("API-error record") })
    }

    /// Thinking tokens are a subset of output and must not be added again.
    func testThinkingTokensAreNotDoubleCounted() {
        let dir = TempDir()
        let line = """
        {"requestId":"req_1","timestamp":"2026-08-10T10:00:00.000Z","type":"assistant",\
        "message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":0,\
        "output_tokens":410,"output_tokens_details":{"thinking_tokens":99}}}}
        """
        _ = dir.write([line], to: "proj/session.jsonl")

        let tokens = ClaudeCodeCollector(projectsRoot: dir.url).collect().tokens!
        XCTAssertEqual(tokens.reasoning, 99)
        XCTAssertEqual(tokens.output, 410)
        XCTAssertEqual(tokens.billableEquivalent, 410, "reasoning is inside output, not additional to it")
    }

    /// A synthetic model is locally generated and unpriced; its tokens still
    /// count, but it must not silently contribute a guessed cost.
    func testUnpricedModelCountsTokensButNotCost() {
        let dir = TempDir()
        _ = dir.write([
            claudeRecord(requestID: "req_1", model: "<synthetic>", input: 100, output: 200),
        ], to: "proj/session.jsonl")

        let report = ClaudeCodeCollector(projectsRoot: dir.url).collect()
        XCTAssertEqual(report.tokens!.output, 200)
        XCTAssertTrue(report.stats.unpricedModels.contains("<synthetic>"))
        XCTAssertEqual(report.apiEquivalentCostUSD, 0, "no guessed price contributed")
        XCTAssertEqual(report.apiEquivalentCostConfidence, .estimated)
    }

    /// Billed cost is never derivable from local logs — a subscription does not
    /// bill per token, so API-equivalent and billed are different questions.
    func testBilledCostIsAlwaysUnavailable() {
        let dir = TempDir()
        _ = dir.write([
            claudeRecord(requestID: "req_1", model: "claude-opus-5", input: 10, output: 20),
        ], to: "proj/session.jsonl")

        let report = ClaudeCodeCollector(projectsRoot: dir.url).collect()
        XCTAssertEqual(report.billedCostConfidence, .unavailable)
        XCTAssertTrue(report.notes.contains { $0.contains("not an invoice") })
    }

    func testSinceWindowFiltersByRecordTimestamp() {
        let dir = TempDir()
        _ = dir.write([
            claudeRecord(requestID: "old", ts: "2026-08-01T10:00:00.000Z", model: "claude-opus-5", input: 1, output: 100),
            claudeRecord(requestID: "new", ts: "2026-08-16T10:00:00.000Z", model: "claude-opus-5", input: 1, output: 7),
        ], to: "proj/session.jsonl")

        let since = Timestamps.parse("2026-08-10T00:00:00.000Z")!
        let tokens = ClaudeCodeCollector(projectsRoot: dir.url).collect(since: since).tokens!
        XCTAssertEqual(tokens.output, 7)
    }

    func testEmptyScanReportsUnavailableRatherThanZero() {
        let dir = TempDir()
        let report = ClaudeCodeCollector(projectsRoot: dir.url).collect()
        XCTAssertNil(report.tokens)
        XCTAssertEqual(report.tokenConfidence, .unavailable)
    }

    private func claudeRecord(
        requestID: String?,
        messageID: String? = "msg_default",
        ts: String = "2026-08-10T10:00:00.000Z",
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite1h: Int = 0,
        cacheWrite5m: Int = 0
    ) -> String {
        var fields: [String] = []
        if let requestID { fields.append("\"requestId\":\"\(requestID)\"") }
        fields.append("\"timestamp\":\"\(ts)\"")
        fields.append("\"type\":\"assistant\"")

        var messageFields: [String] = []
        if let messageID { messageFields.append("\"id\":\"\(messageID)\"") }
        messageFields.append("\"model\":\"\(model)\"")
        messageFields.append("""
        "usage":{"input_tokens":\(input),"cache_read_input_tokens":\(cacheRead),\
        "cache_creation_input_tokens":\(cacheWrite1h + cacheWrite5m),\
        "cache_creation":{"ephemeral_1h_input_tokens":\(cacheWrite1h),"ephemeral_5m_input_tokens":\(cacheWrite5m)},\
        "output_tokens":\(output)}
        """)

        fields.append("\"message\":{\(messageFields.joined(separator: ","))}")
        return "{\(fields.joined(separator: ","))}"
    }
}

// MARK: - Pricing

final class PricingTests: XCTestCase {

    func testCacheMultipliersMatchPublishedRates() {
        XCTAssertEqual(PricingTable.cacheReadMultiplier, Decimal(string: "0.1")!)
        XCTAssertEqual(PricingTable.cacheWrite5mMultiplier, Decimal(string: "1.25")!)
        XCTAssertEqual(PricingTable.cacheWrite1hMultiplier, Decimal(string: "2.0")!)
    }

    func testUnknownModelYieldsNoPriceRatherThanZero() {
        XCTAssertNil(PricingTable.rate(forModel: "gpt-5-codex", speed: nil))
        XCTAssertNil(PricingTable.rate(forModel: "<synthetic>", speed: nil))
        XCTAssertNil(
            PricingTable.cost(of: TokenBreakdown(output: 1000), model: "some-future-model", speed: nil, asOf: Date())
        )
    }

    func testDatedSnapshotResolvesToBaseAlias() {
        let rate = PricingTable.rate(forModel: "claude-haiku-4-5-20251001", speed: nil)
        XCTAssertEqual(rate?.inputPerMTok, 1)
        XCTAssertEqual(rate?.outputPerMTok, 5)
    }

    func testBedrockPrefixResolves() {
        let rate = PricingTable.rate(forModel: "anthropic.claude-opus-5", speed: nil)
        XCTAssertEqual(rate?.inputPerMTok, 5)
    }

    /// Claude Code logs carry `usage.speed`, so fast mode is detected, not assumed.
    func testFastModeUsesPremiumRates() {
        let standard = PricingTable.rate(forModel: "claude-opus-5", speed: nil)
        let fast = PricingTable.rate(forModel: "claude-opus-5", speed: "fast")
        XCTAssertEqual(standard?.inputPerMTok, 5)
        XCTAssertEqual(fast?.inputPerMTok, 10)
        XCTAssertEqual(fast?.outputPerMTok, 50)
    }

    func testSonnet5IntroPricingAppliesBeforeCutoff() {
        let rate = PricingTable.rate(forModel: "claude-sonnet-5", speed: nil)!
        let during = rate.rates(asOf: Timestamps.parse("2026-08-17T00:00:00Z")!)
        let after = rate.rates(asOf: Timestamps.parse("2026-09-15T00:00:00Z")!)
        XCTAssertEqual(during.input, 2)
        XCTAssertEqual(during.output, 10)
        XCTAssertEqual(after.input, 3)
        XCTAssertEqual(after.output, 15)
    }

    func testOpusCostArithmetic() {
        let tokens = TokenBreakdown(
            uncachedInput: 1000, cachedInput: 10000,
            cacheWrite5m: 1000, cacheWrite1h: 2000, output: 500
        )
        let cost = PricingTable.cost(of: tokens, model: "claude-opus-5", speed: nil, asOf: Date())!
        XCTAssertEqual(NSDecimalNumber(decimal: cost).doubleValue, 0.048750, accuracy: 1e-9)
    }
}

// MARK: - Confidence and provider-neutral shape

final class ConfidenceTests: XCTestCase {

    func testCombineIsWorstWins() {
        XCTAssertEqual(Confidence.combine([.exact, .exact]), .exact)
        XCTAssertEqual(Confidence.combine([.exact, .estimated]), .estimated)
        XCTAssertEqual(Confidence.combine([.exact, .estimated, .unavailable]), .unavailable)
        XCTAssertEqual(Confidence.combine([]), .unavailable)
    }

    /// The normalization that makes cross-provider sums meaningful: Codex's
    /// inclusive `input_tokens` and Claude Code's exclusive one must land on the
    /// same field meaning the same thing.
    func testProvidersNormalizeToTheSameInputConvention() {
        let codex = CodexCollector.normalize([
            "input_tokens": 1000, "cached_input_tokens": 800,
            "cache_write_input_tokens": 0, "output_tokens": 50, "reasoning_output_tokens": 10,
        ])
        let claude = ClaudeCodeCollector.normalize([
            "input_tokens": 200, "cache_read_input_tokens": 800,
            "output_tokens": 50,
            "output_tokens_details": ["thinking_tokens": 10],
        ])

        XCTAssertEqual(codex.uncachedInput, 200, "Codex input is inclusive of cached; the cached part is subtracted")
        XCTAssertEqual(claude.uncachedInput, 200, "Claude Code input is already exclusive")
        XCTAssertEqual(codex.cachedInput, claude.cachedInput)
        XCTAssertEqual(codex.billableEquivalent, claude.billableEquivalent)
    }

    func testCursorReportsUnavailableWithAReason() {
        let report = CursorCollector().collect()
        XCTAssertNil(report.tokens)
        XCTAssertEqual(report.tokenConfidence, .unavailable)
        XCTAssertFalse(report.notes.isEmpty, "an unavailable row must say why")
    }
}
