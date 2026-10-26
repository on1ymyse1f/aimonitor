import Foundation

/// Everything the menu bar and the dashboard show, as display-ready values, for
/// front ends that are not AppKit / SwiftUI (the Windows tray app renders this
/// from JSON). Text is formatted here with the same rules the macOS views use,
/// so every platform shows the same words and numbers for the same store.
///
/// Raw numbers appear only where a view draws geometry (bar fractions, flow
/// bars) or ticks on its own (the active-now age).
public struct UISnapshot: Codable, Equatable {
    public var generatedAt: Double
    public var settings: Settings
    /// Every `L10n.Key` in the configured language, keyed by its raw value.
    public var strings: [String: String]
    public var header: Header
    public var menu: Menu
    public var today: Today
    public var timeline: Timeline
    public var models: [ModelRow]
    public var providersPresent: [String]

    public struct Settings: Codable, Equatable {
        public var appearance: String        // system | light | dark
        public var language: String          // system | en | zh
        public var resolvedLanguage: String  // en | zh
        public var claudeQuota: Bool
        public var kimiQuota: Bool
        public var notifications: Bool
        public var retentionDays: String
        public var flowRange: String         // StoreReport.FlowRange raw value
        public var timelineProvider: String?
    }

    public struct Header: Codable, Equatable {
        public var title: String
        public var date: String
    }

    /// The macOS status item: its title and its menu, line for line.
    public struct Menu: Codable, Equatable {
        public var title: String
        public var items: [Item]

        public struct Item: Codable, Equatable {
            public var kind: String  // header | info | separator
            public var text: String
        }
    }

    public struct Today: Codable, Equatable {
        public var tokens: String
        public var time: String
        public var cost: String
        public var requests: String
        public var activeNow: Active?
        public var usage: [Share]
        public var flow: Flow
        public var quotas: [Quota]

        public struct Active: Codable, Equatable {
            public var provider: String
            public var model: String?
            public var lastEventAt: Double
        }

        public struct Share: Codable, Equatable {
            public var provider: String
            public var fraction: Double
            public var percent: String
        }

        public struct Flow: Codable, Equatable {
            public var values: [Int]
            public var firstLabel: String
            public var lastLabel: String
        }

        public struct Quota: Codable, Equatable {
            public var id: String
            public var title: String
            public var detail: String
            public var fraction: Double
            public var warn: Bool
            public var projection: String?
        }
    }

    public struct Timeline: Codable, Equatable {
        public var providers: [String]
        public var days: [Day]

        public struct Day: Codable, Equatable {
            public var label: String
            public var events: [Event]
        }

        public struct Event: Codable, Equatable {
            public var time: String
            public var provider: String
            public var model: String?
            public var project: String?
            public var tokens: String
        }
    }

    public struct ModelRow: Codable, Equatable {
        public var model: String
        public var provider: String
        public var tokens: String
        public var detail: String
        public var fraction: Double
    }
}

extension UISnapshot {
    public static func make(
        store: EventStore,
        flowRange: StoreReport.FlowRange = .today,
        timelineProvider: String? = nil,
        now: Date = Date()
    ) throws -> UISnapshot {
        let languageSetting = store.setting("language") ?? "system"
        let lang = Language(rawValue: languageSetting) ?? .system
        let dashboard = try StoreReport.dashboard(from: store, flowRange: flowRange)
        let events = try store.recentEvents(provider: timelineProvider)

        return UISnapshot(
            generatedAt: now.timeIntervalSince1970,
            settings: Settings(
                appearance: store.setting("appearance") ?? "system",
                language: languageSetting,
                resolvedLanguage: lang.resolved.rawValue,
                claudeQuota: store.setting("claude_quota_optin") == "true",
                kimiQuota: store.setting("kimi_quota_optin") == "true",
                notifications: store.setting("notifications_enabled") == "true",
                retentionDays: store.setting("retention_days") ?? "90",
                flowRange: flowRange.rawValue,
                timelineProvider: timelineProvider
            ),
            strings: Dictionary(uniqueKeysWithValues: L10n.Key.allCases.map { ($0.rawValue, L10n.text($0, lang)) }),
            header: Header(title: L10n.text(.appTitle, lang), date: headerDate(now)),
            menu: menu(dashboard, metric: store.setting("menubar_metric") ?? "quota", lang: lang, now: now),
            today: today(dashboard, lang: lang, now: now),
            timeline: timeline(events, lang: lang),
            models: models(try store.totalsByModel(), lang: lang),
            providersPresent: try store.providersPresent()
        )
    }

    // MARK: - Menu bar (aimonitor-menubar)

    static func menu(_ data: StoreReport.Dashboard, metric: String, lang: Language, now: Date) -> Menu {
        var title = "AI"
        switch metric {
        case "tokens": title = StoreReport.compact(data.todayTokens)
        case "time": title = StoreReport.duration(minutes: data.todayActiveMinutes)
        case "cost":
            title = data.todayCostUSD.map { "~" + ReportFormatter.money(Decimal($0)) } ?? "n/a"
        case "none": title = "AI"
        default:
            if let q = StoreReport.tightestQuota(data.quotas) {
                title = "\(Int(q.window.usedPercent.rounded()))%"
            } else {
                title = StoreReport.compact(data.todayTokens)
            }
        }

        let separator = Menu.Item(kind: "separator", text: "")
        func info(_ s: String) -> Menu.Item { Menu.Item(kind: "info", text: s) }

        var items = [Menu.Item(kind: "header", text: "AI Monitor")]
        if let active = data.activeNow.first {
            let ago = Int(now.timeIntervalSince(active.lastEventAt))
            items.append(info("● \(active.provider)\(active.model.map { " · \($0)" } ?? "") · \(ago)s ago"))
        }

        items.append(separator)
        let costText = data.todayCostUSD.map { "~" + ReportFormatter.money(Decimal($0)) + " eq." } ?? "n/a"
        items.append(info("\(L10n.text(.today, lang)): \(StoreReport.compact(data.todayTokens)) tokens · \(StoreReport.duration(minutes: data.todayActiveMinutes)) · \(costText)"))

        if !data.usageShares.isEmpty {
            items.append(separator)
            for share in data.usageShares.prefix(6) {
                // The macOS menu formats this with "%-14@ %3.0f%%  %@"; `%@`
                // padding is not portable, so the column is padded by hand.
                let name = share.provider.count < 14
                    ? share.provider + String(repeating: " ", count: 14 - share.provider.count)
                    : share.provider
                items.append(info("\(name) \(String(format: "%3.0f", share.fraction * 100))%  \(StoreReport.compact(share.billable))"))
            }
        }

        if !data.quotas.isEmpty {
            items.append(separator)
            for q in data.quotas {
                var line = "\(q.provider) \(q.window.label) — \(String(format: "%.0f", q.window.usedPercent))% · \(StoreReport.resetDescription(q.window.resetsAt, lang: lang))"
                if let p = q.projection {
                    let hours = p.exhaustedAt.timeIntervalSince(now) / 3600
                    line += String(format: lang.resolved == .zh ? " · 按当前速度 %.1f 小时后耗尽" : " · exhausted in %.1fh at current pace", hours)
                }
                items.append(info(line))
            }
        }
        return Menu(title: title, items: items)
    }

    // MARK: - Dashboard: Today page (DashboardView)

    static func today(_ d: StoreReport.Dashboard, lang: Language, now: Date) -> Today {
        let hourly = d.flowIsHourly
        func flowLabel(_ date: Date) -> String {
            let f = DateFormatter()
            f.dateFormat = hourly ? "HH:mm" : "MMM d"
            return f.string(from: date)
        }

        return Today(
            tokens: StoreReport.compact(d.todayTokens),
            time: StoreReport.duration(minutes: d.todayActiveMinutes),
            cost: d.todayCostUSD.map { "$" + String(format: "%.2f", $0) } ?? "n/a",
            requests: "\(d.todayRequests)",
            activeNow: d.activeNow.first.map {
                Today.Active(provider: $0.provider, model: $0.model, lastEventAt: $0.lastEventAt.timeIntervalSince1970)
            },
            usage: d.usageShares.map {
                Today.Share(provider: $0.provider, fraction: $0.fraction, percent: "\(Int($0.fraction * 100))%")
            },
            flow: Today.Flow(
                values: d.flow.map(\.billable),
                firstLabel: d.flow.first.map { flowLabel($0.bucket) } ?? "",
                lastLabel: d.flow.last.map { flowLabel($0.bucket) } ?? ""
            ),
            quotas: d.quotas.map { q in
                Today.Quota(
                    id: q.window.id,
                    title: "\(q.provider) · \(q.window.label)",
                    detail: "\(Int(q.window.usedPercent.rounded()))% · \(StoreReport.resetDescription(q.window.resetsAt, lang: lang))",
                    fraction: q.window.usedPercent / 100,
                    warn: q.window.usedPercent >= 90,
                    projection: q.projection.map { "\(L10n.text(.exhaustedPrefix, lang)) \(pace($0.exhaustedAt, lang: lang, now: now))" }
                )
            }
        )
    }

    /// "in 3h 12m" / "3h 12m内" — the dashboard's exhaustion pace.
    static func pace(_ date: Date, lang: Language, now: Date) -> String {
        let zh = lang.resolved == .zh
        let t = date.timeIntervalSince(now)
        if t < 3600 { return zh ? "\(max(1, Int(t / 60))) 分钟内" : "in \(max(1, Int(t / 60)))m" }
        if t < 86400 {
            let v = "\(Int(t / 3600))h \(Int(t.truncatingRemainder(dividingBy: 3600) / 60))m"
            return zh ? "\(v)内" : "in \(v)"
        }
        return zh ? "\(Int(t / 86400)) 天内" : "in \(Int(t / 86400))d"
    }

    /// The header's date, in the system locale: "Sun, Oct 26".
    static func headerDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f.string(from: date)
    }

    // MARK: - Dashboard: Timeline page

    static func timeline(_ events: [EventStore.TimelineEvent], lang: Language) -> Timeline {
        let dayKey = DateFormatter()
        dayKey.dateFormat = "yyyy-MM-dd"
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"

        let grouped = Dictionary(grouping: events) { dayKey.string(from: $0.timestamp) }
        return Timeline(
            providers: Array(Set(events.map(\.provider))).sorted(),
            days: grouped.sorted { $0.key > $1.key }.map { day, events in
                Timeline.Day(
                    label: dayLabel(day, lang: lang),
                    events: events.map {
                        Timeline.Event(
                            time: clock.string(from: $0.timestamp),
                            provider: $0.provider,
                            model: $0.model,
                            project: $0.project,
                            tokens: StoreReport.compact($0.billable)
                        )
                    }
                )
            }
        )
    }

    /// TODAY / YESTERDAY / "MONDAY, OCT 20" (zh: 今天 / 昨天 / "10月20日 星期一").
    static func dayLabel(_ yyyyMMdd: String, lang: Language) -> String {
        let inFmt = DateFormatter(); inFmt.dateFormat = "yyyy-MM-dd"
        guard let d = inFmt.date(from: yyyyMMdd) else { return yyyyMMdd }
        let zh = lang.resolved == .zh
        if Calendar.current.isDateInToday(d) { return zh ? "今天" : "TODAY" }
        if Calendar.current.isDateInYesterday(d) { return zh ? "昨天" : "YESTERDAY" }
        let outFmt = DateFormatter()
        outFmt.locale = zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        outFmt.dateFormat = zh ? "M月d日 EEEE" : "EEEE, MMM d"
        return outFmt.string(from: d).uppercased()
    }

    // MARK: - Dashboard: Models page

    static func models(_ totals: [EventStore.ModelTotals], lang: Language) -> [ModelRow] {
        let maxBillable = totals.map(\.billable).max() ?? 1
        return totals.map { m in
            ModelRow(
                model: m.model,
                provider: m.provider,
                tokens: StoreReport.compact(m.billable),
                detail: "\(m.requests) \(L10n.text(.requestsSuffix, lang)) · \(m.costUSD.map { "$" + String(format: "%.2f", $0) } ?? L10n.text(.unpriced, lang))",
                // A store of zero-token rows would divide by zero; JSON has no NaN.
                fraction: maxBillable > 0 ? Double(m.billable) / Double(maxBillable) : 0
            )
        }
    }
}
