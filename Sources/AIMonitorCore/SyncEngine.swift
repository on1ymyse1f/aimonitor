import Foundation

/// Incremental log → store synchronization.
///
/// Restart-safety rules:
///   * Files are append-only. A checkpoint (size + offset + provider state) is
///     written per file **after** its events are committed, in one transaction
///     per file, so a crash mid-file re-parses that file and the dedup rules
///     (requestId keep-largest / positional INSERT OR IGNORE) make the replay
///     harmless.
///   * A file that shrank since its checkpoint was rotated or rewritten —
///     re-parse from zero; the same dedup rules keep events unique.
///   * Codex counters are cumulative per session; the last snapshot is stored
///     in the checkpoint so deltas stay correct across process restarts.
public struct SyncEngine: Sendable {
    public let store: EventStore
    public let claudeRoot: URL
    public let codexRoot: URL

    public init(store: EventStore, claudeRoot: URL? = nil, codexRoot: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.store = store
        self.claudeRoot = claudeRoot ?? home.appendingPathComponent(".claude/projects", isDirectory: true)
        self.codexRoot = codexRoot ?? home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public struct SyncSummary: Equatable {
        public var filesScanned = 0
        public var filesSkippedUnchanged = 0
        public var filesFailed = 0
        public var claudeEvents = 0
        public var codexEvents = 0
        public var quotaSnapshots = 0
    }

    /// stat-only change detection: total size of all known logs. Cheap enough to
    /// run on a timer; a sync only happens when this changes.
    public func logsFingerprint() -> Int {
        var total = 0
        for root in [claudeRoot, codexRoot] {
            guard let e = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in e {
                total &+= (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return total
    }

    public func sync() -> SyncSummary {
        var summary = SyncSummary()
        syncClaude(&summary)
        syncCodex(&summary)
        // Retention is deliberately NOT applied here: the sync engine's job is
        // to make the store faithful to the logs. Data lifecycle is a separate
        // decision, applied by the app layer via store.applyRetention().
        return summary
    }

    // MARK: - Claude Code

    private func syncClaude(_ summary: inout SyncSummary) {
        for file in ClaudeCodeCollector.transcriptFiles(under: claudeRoot) {
            do { try syncClaudeFile(file, &summary) } catch { summary.filesFailed += 1 }
        }
    }

    private func syncClaudeFile(_ file: URL, _ summary: inout SyncSummary) throws {
        let size = fileSize(file)
        let path = file.path
        let cp = try store.checkpoint(for: path)
        if let cp, cp.size == size { summary.filesSkippedUnchanged += 1; return }

        let offset = (cp != nil && cp!.offset <= size) ? cp!.offset : 0
        let project = Self.claudeProjectName(for: file, under: claudeRoot)
        var pending: [AIEvent] = []

        let end = try JSONL.forEachLine(at: file, from: UInt64(offset), needles: ["\"usage\""]) { object, lineStart, _ in
            guard let message = object.dict("message"),
                  let usage = message.dict("usage") else { return }
            if object.bool("isApiErrorMessage") == true { return }

            let timestamp = Timestamps.parse(object.str("timestamp"))
            let tokens = ClaudeCodeCollector.normalize(usage)
            let model = message.str("model") ?? "unknown"
            let speed = usage.str("speed")

            let id: String
            if let requestID = object.str("requestId"), !requestID.isEmpty {
                id = requestID
            } else if let messageID = message.str("id"), !messageID.isEmpty {
                id = "msg:" + messageID
            } else {
                // Positional id: byte offsets are stable because logs are append-only.
                id = "pos:\(file.lastPathComponent)@\(lineStart)"
            }

            let cost = PricingTable.cost(of: tokens, model: model, speed: speed, asOf: timestamp ?? Date())
            pending.append(AIEvent(
                id: id, timestamp: timestamp,
                provider: ClaudeCodeCollector.providerName,
                application: "Claude Code",
                model: model,
                sessionId: object.str("sessionId"),
                project: project,
                tokens: tokens, costUSD: cost, confidence: .estimated
            ))
        }

        try commitEvents(pending, keepLargest: true) { [store] in
            try store.setCheckpoint(.init(size: size, offset: Int(end), state: nil), for: path)
        }
        summary.filesScanned += 1
        summary.claudeEvents += pending.count
    }

    // MARK: - Codex

    private func syncCodex(_ summary: inout SyncSummary) {
        for file in CodexCollector.rolloutFiles(under: codexRoot) {
            do { try syncCodexFile(file, &summary) } catch { summary.filesFailed += 1 }
        }
    }

    private func syncCodexFile(_ file: URL, _ summary: inout SyncSummary) throws {
        let size = fileSize(file)
        let path = file.path
        let cp = try store.checkpoint(for: path)
        if let cp, cp.size == size { summary.filesSkippedUnchanged += 1; return }

        let offset = (cp != nil && cp!.offset <= size) ? cp!.offset : 0
        var previous: TokenBreakdown = {
            guard let cp, offset > 0, let state = cp.state,
                  let data = state.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: Int].self, from: data) else { return TokenBreakdown() }
            return TokenBreakdown(
                uncachedInput: dict["uncachedInput"] ?? 0, cachedInput: dict["cachedInput"] ?? 0,
                cacheWrite5m: dict["cacheWrite5m"] ?? 0, cacheWrite1h: dict["cacheWrite1h"] ?? 0,
                cacheWriteUnspecified: dict["cacheWriteUnspecified"] ?? 0,
                output: dict["output"] ?? 0, reasoning: dict["reasoning"] ?? 0
            )
        }()

        // Session meta lives in the first line, which the needle filter would
        // skip; read it directly. Cheap even on huge files.
        let meta = Self.codexSessionMeta(of: file)
        let project = meta.cwd?.split(separator: "/").last.map(String.init)

        var pending: [AIEvent] = []
        var quotas: [QuotaWindow] = []

        let end = try JSONL.forEachLine(at: file, from: UInt64(offset), needles: ["token_count", "rate_limits"]) { object, lineStart, _ in
            let payload = object.dict("payload") ?? object
            let eventDate = Timestamps.parse(object.str("timestamp"))

            if let rateLimits = payload.dict("rate_limits"), let observedAt = eventDate {
                quotas.append(contentsOf: CodexCollector.quotaWindows(from: rateLimits, observedAt: observedAt))
            }

            guard let info = payload.dict("info"),
                  let cumulative = info.dict("total_token_usage") else { return }

            let snapshot = CodexCollector.normalize(cumulative)
            let delta: TokenBreakdown
            if snapshot.indicatesResetFrom(previous) {
                delta = snapshot   // counters restarted (resume/fork): fresh run
            } else {
                delta = snapshot.delta(from: previous)
            }
            previous = snapshot
            guard delta.billableEquivalent > 0 else { return }

            pending.append(AIEvent(
                id: "codex:\(file.lastPathComponent)@\(lineStart)",
                timestamp: eventDate,
                provider: CodexCollector.providerName,
                application: "Codex",
                model: nil,
                sessionId: meta.sessionId,
                project: project,
                tokens: delta,
                costUSD: nil,   // no verified OpenAI rate card — never guessed
                confidence: .exact
            ))
        }

        let stateDict: [String: Int] = [
            "uncachedInput": previous.uncachedInput, "cachedInput": previous.cachedInput,
            "cacheWrite5m": previous.cacheWrite5m, "cacheWrite1h": previous.cacheWrite1h,
            "cacheWriteUnspecified": previous.cacheWriteUnspecified,
            "output": previous.output, "reasoning": previous.reasoning,
        ]
        let state = String(data: (try? JSONEncoder().encode(stateDict)) ?? Data(), encoding: .utf8)

        try commitEvents(pending, keepLargest: false) { [store] in
            for q in quotas { try store.insert(quota: q, provider: CodexCollector.providerName) }
            try store.setCheckpoint(.init(size: size, offset: Int(end), state: state), for: path)
        }
        summary.filesScanned += 1
        summary.codexEvents += pending.count
        summary.quotaSnapshots += quotas.count
    }

    // MARK: - Helpers

    /// Events and checkpoint commit atomically: a crash between them would
    /// replay the file, and dedup makes replays harmless — but atomicity makes
    /// even that unnecessary.
    private func commitEvents(_ events: [AIEvent], keepLargest: Bool, and extra: () throws -> Void) throws {
        guard !events.isEmpty else { try extra(); return }
        try store.transaction { storeDB in
            for e in events { try storeDB.insert(usage: e, keepLargest: keepLargest) }
            try extra()
        }
    }

    private func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// `-Users-chengwenbo-Claude-trotflow` → `Claude-trotflow`
    static func claudeProjectName(for file: URL, under root: URL) -> String? {
        let rel = file.path.dropFirst(root.path.count).split(separator: "/")
        guard var slug = rel.first.map(String.init) else { return nil }
        if slug.hasPrefix("-"), let range = slug.range(of: #"^-[^-]*-[^-]*-"#, options: .regularExpression) {
            slug.removeSubrange(range)
        }
        return slug.isEmpty ? nil : slug
    }

    static func codexSessionMeta(of file: URL) -> (sessionId: String?, cwd: String?) {
        guard let handle = try? FileHandle(forReadingFrom: file),
              let chunk = try? handle.read(upToCount: 1 << 16),
              let newline = chunk.firstIndex(of: 0x0A),
              let object = try? JSONSerialization.jsonObject(with: Data(chunk[..<newline])) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return (nil, nil) }
        try? handle.close()
        return (payload["id"] as? String, payload["cwd"] as? String)
    }
}
