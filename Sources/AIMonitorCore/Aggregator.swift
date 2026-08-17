import Foundation

/// Cursor is deliberately out of scope for this phase.
///
/// Cursor does not write per-request token accounting locally in a form
/// comparable to Codex's and Claude Code's; its usage data sits behind a
/// team-oriented admin API, and the local store holds a session token rather
/// than per-request counts. A Cursor row built from a different kind of number
/// would sit next to its neighbours implying comparability it does not have, so
/// this reports `unavailable` with the reason instead.
public struct CursorCollector: Sendable {
    public init() {}
    public static let providerName = "Cursor"

    public func collect(since: Date? = nil) -> ProviderReport {
        ProviderReport(
            provider: Self.providerName,
            tokenConfidence: .unavailable,
            billedCostConfidence: .unavailable,
            quotaConfidence: .unavailable,
            notes: [
                "No local per-request token accounting comparable to the other providers.",
                "Cursor's usage history is exposed through a team admin API, not the local store; a row here would not mean what its neighbours mean.",
            ]
        )
    }
}

public struct Aggregator: Sendable {
    public let codex: CodexCollector
    public let claudeCode: ClaudeCodeCollector
    public let kimi: KimiCollector
    public let cursor: CursorCollector

    public init(
        codex: CodexCollector = CodexCollector(),
        claudeCode: ClaudeCodeCollector = ClaudeCodeCollector(),
        kimi: KimiCollector = KimiCollector(),
        cursor: CursorCollector = CursorCollector()
    ) {
        self.codex = codex
        self.claudeCode = claudeCode
        self.kimi = kimi
        self.cursor = cursor
    }

    public func report(since: Date? = nil, now: Date = Date()) -> UsageReport {
        UsageReport(
            generatedAt: now,
            since: since,
            providers: [
                claudeCode.collect(since: since),
                codex.collect(since: since),
                kimi.collect(since: since),
                cursor.collect(since: since),
            ]
        )
    }
}
