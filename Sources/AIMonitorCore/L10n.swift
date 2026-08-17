import Foundation

/// Minimal two-language string table. Lives in the core so the menu bar and
/// the dashboard app share one source of truth.
public enum Language: String, CaseIterable, Sendable {
    case system, en, zh

    /// Effective concrete language for a configured value.
    public var resolved: Language {
        if self != .system { return self }
        return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .zh : .en
    }
}

public enum L10n {
    public enum Key: String, CaseIterable {
        // Root
        case appTitle, tabToday, tabTimeline, tabModels, tabSettings
        // Dashboard
        case tokensToday, time, cost, requests, activeNow
        case usage, tokenFlow, quota
        case noUsageToday, noUsageInRange, noQuotaData, exhaustedPrefix
        // Range picker
        case rangeToday, range7D, range30D, rangeAll
        // Timeline / models
        case allProviders, noEvents, requestsSuffix, unpriced
        // Settings
        case collectorsAccess, claudeCollectorNote, codexCollectorNote, kimiCollectorNote, storageNote
        case retention, retention7, retention30, retention90, retentionYear, retentionForever
        case notifications, notificationsDetail
        case claudeQuota, claudeQuotaDetail, kimiQuota, kimiQuotaDetail
        case exportCard, exportCardDone
        case appearance, appearanceSystem, appearanceLight, appearanceDark
        case language, languageSystem
        case deleteAll, deleteConfirm, deleteNote
        // Menu bar
        case openDashboard, syncNow, quit, today
        // Quota misc
        case resetUnknown
    }

    public static func text(_ key: Key, _ lang: Language) -> String {
        let zh = lang.resolved == .zh
        switch key {
        case .appTitle: return "AI Monitor"
        case .tabToday: return zh ? "今日" : "Today"
        case .tabTimeline: return zh ? "时间线" : "Timeline"
        case .tabModels: return zh ? "模型" : "Models"
        case .tabSettings: return zh ? "设置" : "Settings"
        case .tokensToday: return zh ? "今日 token" : "tokens today"
        case .time: return zh ? "时长" : "time"
        case .cost: return zh ? "费用" : "cost"
        case .requests: return zh ? "请求" : "requests"
        case .activeNow: return zh ? "当前活跃" : "ACTIVE NOW"
        case .usage: return zh ? "用量分布" : "USAGE"
        case .tokenFlow: return zh ? "流量" : "TOKEN FLOW"
        case .quota: return zh ? "额度" : "QUOTA"
        case .noUsageToday: return zh ? "今天还没有记录到用量。" : "No usage recorded today."
        case .noUsageInRange: return zh ? "该时间范围内没有用量。" : "No usage in this range."
        case .noQuotaData: return zh ? "暂无额度数据——提供商未上报或尚未使用。" : "No quota data — providers either don't report it or weren't used yet."
        case .exhaustedPrefix: return zh ? "按当前速度，将耗尽" : "At current pace, exhausted"
        case .rangeToday: return zh ? "今日" : "Today"
        case .range7D: return "7D"
        case .range30D: return "30D"
        case .rangeAll: return zh ? "全部" : "All"
        case .allProviders: return zh ? "全部提供商" : "All providers"
        case .noEvents: return zh ? "暂无事件。" : "No events yet."
        case .requestsSuffix: return zh ? "次请求" : "requests"
        case .unpriced: return zh ? "未定价" : "unpriced"
        case .collectorsAccess: return zh ? "各采集器的访问范围" : "WHAT EACH COLLECTOR CAN ACCESS"
        case .claudeCollectorNote: return zh
            ? "读取 ~/.claude/projects 下的会话记录。只存储 token 数、模型、时间戳、项目名、请求 ID。从不解析、更不会存储 prompt 或回复内容。"
            : "Reads ~/.claude/projects transcripts. Stores token counts, model, timestamps, project slug, request ids. Prompt and response text is never parsed, let alone stored."
        case .codexCollectorNote: return zh
            ? "读取 ~/.codex/sessions 下的 rollout 日志及其中内嵌的额度数据。auth.json 从不打开，凭证从不触碰。"
            : "Reads ~/.codex/sessions rollout logs and the quota data embedded in them. auth.json is never opened; no credential is ever refreshed."
        case .kimiCollectorNote: return zh
            ? "读取 ~/.kimi-code/sessions 下的 wire 日志中的 usage 记录。会话内容行在解析前就被跳过。credentials 目录从不读取。"
            : "Reads usage records from wire logs under ~/.kimi-code/sessions. Conversation lines are skipped before parsing. The credentials directory is never read."
        case .kimiQuota: return zh ? "Kimi 在线额度" : "Kimi live quota"
        case .kimiQuotaDetail: return zh
            ? "只读 Kimi Code 本地凭证文件中的访问令牌，向官方额度端点发一个 GET。每 15 分钟最多一次；令牌不落盘、不刷新。关闭则不产生任何网络请求。"
            : "Reads the access token from Kimi Code's local credential file and issues one GET to the official usage endpoint. At most once every 15 minutes; the token is never stored or refreshed. Off means zero network requests."
        case .exportCard: return zh ? "导出使用名片" : "Export profile card"
        case .exportCardDone: return zh ? "名片已导出：" : "Card exported:"
        case .storageNote: return zh
            ? "一切数据只存在 ~/Library/Application Support/AIMonitor。无遥测、无账号、除可选的在线额度查询（默认关闭）外无任何网络请求。"
            : "Everything stays in ~/Library/Application Support/AIMonitor. No telemetry, no account, no network except the optional live quota queries (off by default)."
        case .retention: return zh ? "保留时长" : "RETENTION"
        case .retention7: return zh ? "7 天" : "7 days"
        case .retention30: return zh ? "30 天" : "30 days"
        case .retention90: return zh ? "90 天" : "90 days"
        case .retentionYear: return zh ? "1 年" : "1 year"
        case .retentionForever: return zh ? "永久" : "Forever"
        case .notifications: return zh ? "通知" : "NOTIFICATIONS"
        case .notificationsDetail: return zh ? "额度达到 80% / 90% / 100% 时提醒" : "Quota alerts at 80% / 90% / 100%"
        case .claudeQuota: return zh ? "Claude 在线额度" : "Claude live quota"
        case .claudeQuotaDetail: return zh
            ? "从钥匙串只读 Claude Code 的 OAuth 令牌，向官方端点发一个 GET。每 15 分钟最多一次；令牌不落盘、不刷新。关闭则不产生任何网络请求。"
            : "Reads the Claude Code OAuth token from your Keychain and issues one GET to the official usage endpoint. At most once every 15 minutes; the token is never stored or refreshed. Off means zero network requests."
        case .appearance: return zh ? "外观" : "APPEARANCE"
        case .appearanceSystem: return zh ? "跟随系统" : "System"
        case .appearanceLight: return zh ? "浅色" : "Light"
        case .appearanceDark: return zh ? "深色" : "Dark"
        case .language: return zh ? "语言" : "LANGUAGE"
        case .languageSystem: return zh ? "跟随系统" : "System"
        case .deleteAll: return zh ? "删除全部分析数据" : "Delete all analytics data"
        case .deleteConfirm: return zh ? "再点一次确认" : "Click again to confirm"
        case .deleteNote: return zh
            ? "删除所有事件、额度快照和检查点。下次同步将从头重新读取日志。"
            : "Removes every event, quota snapshot, and checkpoint. The next sync re-reads the logs from scratch."
        case .openDashboard: return zh ? "打开仪表盘" : "Open Dashboard"
        case .syncNow: return zh ? "立即同步" : "Sync now"
        case .quit: return zh ? "退出" : "Quit"
        case .today: return zh ? "今日" : "Today"
        case .resetUnknown: return zh ? "重置时间未知" : "reset unknown"
        }
    }
}
