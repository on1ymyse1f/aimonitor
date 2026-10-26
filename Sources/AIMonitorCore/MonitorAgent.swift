import Foundation

/// The loop behind the macOS menu bar and dashboard, without AppKit / SwiftUI:
/// stat-gated sync, the opt-in live quota fetches, quota notifications, and
/// the dashboard's commands. Same rules as `aimonitor-menubar` and
/// `aimonitor-app`; the Windows tray app drives it through `aimonitor agent`,
/// one JSON object per line each way.
///
/// Not thread-safe: callers serialize `handle` / `tick` (the CLI uses one
/// queue). The quota fetches run detached and only insert into the store,
/// exactly as on macOS.
public final class MonitorAgent: @unchecked Sendable {
    public let store: EventStore
    public let engine: SyncEngine

    private var flowRange: StoreReport.FlowRange = .today
    private var timelineProvider: String?
    private var fingerprint = -1
    /// Quota thresholds already notified, per window id.
    private var notifiedThresholds: [String: Int] = [:]
    private var lastClaudeQuotaFetch = Date.distantPast
    private var lastKimiQuotaFetch = Date.distantPast
    private let claudeQuota = ClaudeQuotaProvider()
    private let kimiQuota = KimiQuotaProvider()
    private let fetchesQuotas: Bool

    /// - Parameter fetchesQuotas: false keeps tests off the network even with
    ///   the opt-in settings on.
    public init(store: EventStore, engine: SyncEngine, fetchesQuotas: Bool = true) {
        self.store = store
        self.engine = engine
        self.fetchesQuotas = fetchesQuotas
    }

    public struct Notification: Codable, Equatable {
        public var title: String
        public var body: String
    }

    // MARK: - Protocol

    /// One message to the front end: `{"type": …, "data": …}`.
    enum Message: Encodable {
        case snapshot(UISnapshot)
        case notification(Notification)
        case cardExported(path: String?)
        case error(String)

        private enum Keys: String, CodingKey { case type, data }
        private struct Path: Encodable { var path: String? }
        private struct Text: Encodable { var message: String }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .snapshot(let s): try c.encode("snapshot", forKey: .type); try c.encode(s, forKey: .data)
            case .notification(let n): try c.encode("notification", forKey: .type); try c.encode(n, forKey: .data)
            case .cardExported(let p): try c.encode("cardExported", forKey: .type); try c.encode(Path(path: p), forKey: .data)
            case .error(let m): try c.encode("error", forKey: .type); try c.encode(Text(message: m), forKey: .data)
            }
        }
    }

    /// The periodic tick: what the menu bar does every 15 s.
    public func tick() -> [String] { handle(line: #"{"cmd":"refresh"}"#) }

    /// An error message line, for failures before an agent exists.
    public static func errorLine(_ message: String) -> String {
        let data = (try? JSONEncoder().encode(Message.error(message))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Handles one command line from the front end and returns the lines to
    /// send back. Commands:
    ///
    ///     {"cmd":"refresh"}                          stat-gated sync, snapshot
    ///     {"cmd":"sync"}                             forced sync, snapshot
    ///     {"cmd":"setFlowRange","value":"7D"}
    ///     {"cmd":"setTimelineProvider","value":null}
    ///     {"cmd":"setSetting","key":"language","value":"zh"}
    ///     {"cmd":"setRetention","value":"30"}
    ///     {"cmd":"deleteAll"}
    ///     {"cmd":"exportCard","provider":"Codex","directory":"…"}
    public func handle(line: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let cmd = object["cmd"] as? String
        else { return encode([.error("unreadable command")]) }

        var out: [Message] = []
        switch cmd {
        case "refresh":
            out += refresh(forceSync: false).map(Message.notification)
        case "sync":
            out += refresh(forceSync: true).map(Message.notification)
        case "setFlowRange":
            guard let raw = object["value"] as? String, let range = StoreReport.FlowRange(rawValue: raw) else {
                return encode([.error("bad flow range")])
            }
            flowRange = range
            out += refresh(forceSync: false).map(Message.notification)
        case "setTimelineProvider":
            timelineProvider = object["value"] as? String
            out += refresh(forceSync: false).map(Message.notification)
        case "setSetting":
            guard let key = object["key"] as? String, let value = object["value"] as? String,
                  let allowed = Self.settableValues[key], allowed.contains(value)
            else { return encode([.error("setting not allowed")]) }
            try? store.setSetting(key, value)
            // Turning a live quota on fetches right away, as the macOS toggle does.
            if value == "true", key.hasSuffix("_quota_optin") {
                out += refresh(forceSync: false).map(Message.notification)
            }
        case "setRetention":
            guard let value = object["value"] as? String, ["7", "30", "90", "365", "0"].contains(value) else {
                return encode([.error("bad retention")])
            }
            try? store.setSetting("retention_days", value)
            try? store.applyRetention()
        case "deleteAll":
            try? store.deleteAllData()
            out += refresh(forceSync: false).map(Message.notification)
        case "exportCard":
            guard let provider = object["provider"] as? String, let directory = object["directory"] as? String else {
                return encode([.error("exportCard needs provider and directory")])
            }
            return encode([.cardExported(path: exportCard(provider: provider, directory: URL(fileURLWithPath: directory, isDirectory: true))?.path)])
        default:
            return encode([.error("unknown command \(cmd)")])
        }

        do {
            out.append(.snapshot(try UISnapshot.make(store: store, flowRange: flowRange, timelineProvider: timelineProvider)))
        } catch {
            out.append(.error("\(error)"))
        }
        return encode(out)
    }

    /// The settings the dashboard may change, and their legal values.
    static let settableValues: [String: Set<String>] = [
        "appearance": ["system", "light", "dark"],
        "language": ["system", "en", "zh"],
        "claude_quota_optin": ["true", "false"],
        "kimi_quota_optin": ["true", "false"],
        "notifications_enabled": ["true", "false"],
    ]

    private func encode(_ messages: [Message]) -> [String] {
        let encoder = JSONEncoder()
        return messages.compactMap { (try? encoder.encode($0)).map { String(decoding: $0, as: UTF8.self) } }
    }

    // MARK: - The loop

    /// Opt-in quota fetches, then a sync if the logs changed (or always when
    /// forced). Returns the quota notifications that became due — checked only
    /// after a sync, like the menu bar.
    func refresh(forceSync: Bool) -> [Notification] {
        let current = engine.logsFingerprint()
        maybeFetchQuotas()
        guard forceSync || current != fingerprint else { return [] }
        _ = engine.sync()
        fingerprint = current
        return dueNotifications()
    }

    private func maybeFetchQuotas() {
        guard fetchesQuotas else { return }
        let store = self.store
        if store.setting("claude_quota_optin") == "true",
           Date().timeIntervalSince(lastClaudeQuotaFetch) >= ClaudeQuotaProvider.minimumInterval {
            lastClaudeQuotaFetch = Date()
            let provider = claudeQuota
            Task.detached {
                if case .success(let windows) = await provider.fetch() {
                    for w in windows { try? store.insert(quota: w, provider: ClaudeQuotaProvider.providerName) }
                }
            }
        }
        if store.setting("kimi_quota_optin") == "true",
           Date().timeIntervalSince(lastKimiQuotaFetch) >= KimiQuotaProvider.minimumInterval {
            lastKimiQuotaFetch = Date()
            let provider = kimiQuota
            Task.detached {
                if case .success(let windows) = await provider.fetch() {
                    for w in windows { try? store.insert(quota: w, provider: KimiQuotaProvider.providerName) }
                }
            }
        }
    }

    /// Off by default; fires once per threshold (80/90/100) per window per
    /// process, with the same wording as the macOS notifications.
    func dueNotifications() -> [Notification] {
        guard store.setting("notifications_enabled") == "true",
              let quotas = try? store.latestQuotas() else { return [] }
        var due: [Notification] = []
        for (window, provider) in quotas {
            let crossed = [100, 90, 80].filter { window.usedPercent >= Double($0) }.max()
            guard let threshold = crossed, (notifiedThresholds[window.id] ?? 0) < threshold else { continue }
            notifiedThresholds[window.id] = threshold

            var body = "\(window.label) quota reached \(Int(window.usedPercent))%."
            if let history = try? store.quotaHistory(windowId: window.id),
               let p = BurnRate.project(history: history, windowMinutes: window.windowMinutes, resetsAt: window.resetsAt),
               p.exhaustedAt.timeIntervalSinceNow < (window.resetsAt?.timeIntervalSinceNow ?? 0) {
                body += String(format: " At current pace it runs out in %.0fh %02.0fm.",
                               floor(p.exhaustedAt.timeIntervalSinceNow / 3600),
                               (p.exhaustedAt.timeIntervalSinceNow.truncatingRemainder(dividingBy: 3600)) / 60)
            }
            due.append(Notification(title: "AI Monitor — \(provider)", body: body))
        }
        return due
    }

    /// The dashboard's profile-card export, written to `directory` (the
    /// front end passes the user's real Desktop, which may be redirected).
    func exportCard(provider: String, directory: URL) -> URL? {
        guard let days = try? store.dailyBillable(provider: provider) else { return nil }
        let stats = CardReport.stats(from: days)
        let name = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
        let lang = Language(rawValue: store.setting("language") ?? "system") ?? .system
        let html = CardReport.html(provider: provider, stats: stats, name: name, handle: NSUserName(), lang: lang)
        let slug = provider.replacingOccurrences(of: " ", with: "-").lowercased()
        let url = directory.appendingPathComponent("aimonitor-card-\(slug).html")
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
