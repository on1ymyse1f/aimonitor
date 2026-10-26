import XCTest
@testable import AIMonitorCore

// MARK: - The headless agent and the snapshot it sends to the Windows app

final class AgentTests: XCTestCase {
    /// Fixture directories live as long as the test: `TempDir` deletes on deinit.
    private var fixtures: [TempDir] = []

    private func claudeRecord(requestID: String, at date: Date, output: Int) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return """
        {"requestId":"\(requestID)","timestamp":"\(f.string(from: date))","type":"assistant","sessionId":"s1",\
        "message":{"id":"msg_\(requestID)","model":"claude-opus-5",\
        "usage":{"input_tokens":2,"cache_read_input_tokens":100,\
        "cache_creation":{"ephemeral_1h_input_tokens":50,"ephemeral_5m_input_tokens":0},\
        "output_tokens":\(output)}}}
        """
    }

    /// An agent over one Claude Code request made a second ago.
    private func agentWithUsage() throws -> (MonitorAgent, EventStore, TempDir) {
        let logs = TempDir()
        fixtures.append(logs)
        _ = logs.write([claudeRecord(requestID: "r1", at: Date().addingTimeInterval(-1), output: 1_500)],
                       to: "-Users-me-demo/s1.jsonl")
        let store = try EventStore.inMemory()
        let engine = SyncEngine(store: store, claudeRoot: logs.url, codexRoot: TempDir().url, kimiRoot: TempDir().url)
        return (MonitorAgent(store: store, engine: engine, fetchesQuotas: false), store, logs)
    }

    private func messages(_ lines: [String]) -> [(type: String, data: Data)] {
        lines.compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String, let data = obj["data"],
                  let raw = try? JSONSerialization.data(withJSONObject: data) else { return nil }
            return (type, raw)
        }
    }

    private func snapshot(_ lines: [String]) throws -> UISnapshot {
        let raw = try XCTUnwrap(messages(lines).last { $0.type == "snapshot" }?.data)
        return try JSONDecoder().decode(UISnapshot.self, from: raw)
    }

    private func notifications(_ lines: [String]) throws -> [MonitorAgent.Notification] {
        try messages(lines).filter { $0.type == "notification" }.map {
            try JSONDecoder().decode(MonitorAgent.Notification.self, from: $0.data)
        }
    }

    /// The snapshot carries the same text the macOS views format themselves.
    func testSnapshotUsesTheDashboardFormatting() throws {
        let (agent, store, _) = try agentWithUsage()
        _ = agent.handle(line: #"{"cmd":"setSetting","key":"language","value":"en"}"#)
        let snap = try snapshot(agent.handle(line: #"{"cmd":"sync"}"#))
        let d = try StoreReport.dashboard(from: store)

        XCTAssertEqual(snap.today.tokens, StoreReport.compact(d.todayTokens))
        XCTAssertEqual(snap.today.time, StoreReport.duration(minutes: d.todayActiveMinutes))
        XCTAssertEqual(snap.today.requests, "1")
        XCTAssertEqual(snap.today.usage.map(\.percent), ["100%"])
        XCTAssertEqual(snap.today.activeNow?.provider, ClaudeCodeCollector.providerName)
        XCTAssertNotEqual(snap.today.flow.values, [])

        // No quotas: the menu bar falls back to today's tokens.
        XCTAssertEqual(snap.menu.title, StoreReport.compact(d.todayTokens))
        XCTAssertEqual(snap.menu.items.first, .init(kind: "header", text: "AI Monitor"))
        XCTAssertTrue(snap.menu.items.contains { $0.text.hasPrefix("Today: \(snap.today.tokens) tokens · ") })

        XCTAssertEqual(snap.timeline.days.first?.label, "TODAY")
        XCTAssertEqual(snap.timeline.days.first?.events.first?.project, "demo")
        XCTAssertEqual(snap.models.first?.model, "claude-opus-5")
        XCTAssertTrue(snap.models.first?.detail.hasPrefix("1 requests · ") == true)
        XCTAssertEqual(snap.models.first?.fraction, 1)
        XCTAssertEqual(snap.providersPresent, [ClaudeCodeCollector.providerName])
        XCTAssertEqual(snap.strings.count, L10n.Key.allCases.count)
        XCTAssertEqual(snap.settings.retentionDays, "90")
        XCTAssertEqual(snap.settings.flowRange, "Today")
    }

    /// Quota at 92%: warning colour, menu bar title, and exactly one
    /// notification per threshold however many syncs follow.
    func testQuotaWarningAndNotificationsFireOncePerThreshold() throws {
        let (agent, store, logs) = try agentWithUsage()
        let now = Date()
        try store.insert(quota: QuotaWindow(id: "codex-5h", label: "5h", usedPercent: 92, windowMinutes: 300,
                                            resetsAt: now.addingTimeInterval(3_600), observedAt: now), provider: "Codex")
        _ = agent.handle(line: #"{"cmd":"setSetting","key":"notifications_enabled","value":"true"}"#)

        let first = agent.handle(line: #"{"cmd":"sync"}"#)
        let fired = try notifications(first)
        XCTAssertEqual(fired.map(\.title), ["AI Monitor — Codex"])
        XCTAssertTrue(fired.first?.body.hasPrefix("5h quota reached 92%.") == true)

        let snap = try snapshot(first)
        XCTAssertEqual(snap.menu.title, "92%")
        XCTAssertEqual(snap.today.quotas.first?.warn, true)
        XCTAssertTrue(snap.today.quotas.first?.detail.hasPrefix("92% · resets in ") == true)
        XCTAssertEqual(snap.today.quotas.first?.title, "Codex · 5h")

        XCTAssertEqual(try notifications(agent.handle(line: #"{"cmd":"sync"}"#)), [])

        try store.insert(quota: QuotaWindow(id: "codex-5h", label: "5h", usedPercent: 100, windowMinutes: 300,
                                            resetsAt: now.addingTimeInterval(3_600), observedAt: now.addingTimeInterval(60)), provider: "Codex")
        // A plain refresh only notifies after a sync, and syncs only when the logs changed.
        XCTAssertEqual(try notifications(agent.handle(line: #"{"cmd":"refresh"}"#)), [])
        _ = logs.write([claudeRecord(requestID: "r2", at: now, output: 10)], to: "-Users-me-demo/s2.jsonl")
        XCTAssertEqual(try notifications(agent.handle(line: #"{"cmd":"refresh"}"#)).map { String($0.body.prefix(20)) },
                       ["5h quota reached 100"])
    }

    /// Only the settings the dashboard exposes, with their legal values.
    func testCommandsValidateTheirInput() throws {
        let (agent, _, _) = try agentWithUsage()

        let zh = try snapshot(agent.handle(line: #"{"cmd":"setSetting","key":"language","value":"zh"}"#))
        XCTAssertEqual(zh.settings.resolvedLanguage, "zh")
        XCTAssertEqual(zh.strings["tabToday"], "今日")

        XCTAssertEqual(try snapshot(agent.handle(line: #"{"cmd":"setFlowRange","value":"7D"}"#)).settings.flowRange, "7D")
        XCTAssertEqual(try snapshot(agent.handle(line: #"{"cmd":"setRetention","value":"30"}"#)).settings.retentionDays, "30")
        XCTAssertEqual(try snapshot(agent.handle(line: #"{"cmd":"setTimelineProvider","value":"Codex"}"#)).settings.timelineProvider, "Codex")

        for bad in [
            #"{"cmd":"setSetting","key":"retention_days","value":"1"}"#,
            #"{"cmd":"setSetting","key":"appearance","value":"purple"}"#,
            #"{"cmd":"setRetention","value":"12"}"#,
            #"{"cmd":"setFlowRange","value":"1Y"}"#,
            #"{"cmd":"launch"}"#,
            "not json",
        ] {
            XCTAssertEqual(messages(agent.handle(line: bad)).map(\.type), ["error"], bad)
        }
    }

    func testExportCardAndDeleteAll() throws {
        let (agent, _, _) = try agentWithUsage()
        _ = agent.handle(line: #"{"cmd":"sync"}"#)

        let out = TempDir()
        fixtures.append(out)
        let line = try XCTUnwrap(agent.handle(line: """
            {"cmd":"exportCard","provider":"Claude Code","directory":\(String(decoding: try JSONEncoder().encode(out.url.path), as: UTF8.self))}
            """).first)
        let exported = try XCTUnwrap(messages([line]).first)
        XCTAssertEqual(exported.type, "cardExported")
        let path = try XCTUnwrap((try JSONSerialization.jsonObject(with: exported.data) as? [String: Any])?["path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(path.hasSuffix("aimonitor-card-claude-code.html"))

        let empty = try snapshot(agent.handle(line: #"{"cmd":"deleteAll"}"#))
        XCTAssertEqual(empty.models, [])
        XCTAssertEqual(empty.today.tokens, "0")
    }

    func testErrorLineIsJSON() throws {
        let line = MonitorAgent.errorLine(#"could not open "x""#)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "error")
    }
}
