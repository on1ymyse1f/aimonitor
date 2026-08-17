import Foundation

/// Assembles everything the menu bar and the dashboard show, from the store.
/// Read-only; the SyncEngine owns writes.
public enum StoreReport {

    public struct QuotaView: Equatable {
        public var window: QuotaWindow
        public var provider: String
        public var projection: BurnRate.Projection?
    }

    public struct Dashboard {
        public var activeNow: [EventStore.ActiveSession]
        public var todayTokens: Int
        public var todayCostUSD: Double?     // nil = unpriced, not zero
        public var todayActiveMinutes: Int
        public var todayRequests: Int
        public var usageShares: [(provider: String, billable: Int, fraction: Double)]
        public var flow: [(bucket: Date, billable: Int)]
        public var flowIsHourly: Bool
        public var quotas: [QuotaView]
        public var generatedAt: Date
    }

    public enum FlowRange: String, CaseIterable {
        case today = "Today", week = "7D", month = "30D", all = "All"

        public var since: Date {
            let cal = Calendar.current
            switch self {
            case .today: return cal.startOfDay(for: Date())
            case .week: return cal.date(byAdding: .day, value: -7, to: Date())!
            case .month: return cal.date(byAdding: .day, value: -30, to: Date())!
            case .all: return Date(timeIntervalSince1970: 0)
            }
        }
    }

    public static func dashboard(from store: EventStore, flowRange: FlowRange = .today) throws -> Dashboard {
        let dayStart = Calendar.current.startOfDay(for: Date())
        let today = try store.totals(since: dayStart)
        let minutes = try store.activeMinutes(since: dayStart)

        let providerTotals = try store.totalsByProvider(since: dayStart)
        let totalBillable = providerTotals.reduce(0) { $0 + $1.billable }
        let shares = providerTotals.map {
            ($0.provider, $0.billable, totalBillable > 0 ? Double($0.billable) / Double(totalBillable) : 0)
        }

        let flow = try store.tokenFlow(since: flowRange.since)
        let hourly = flowRange == .today

        var quotas: [QuotaView] = []
        for (window, provider) in try store.latestQuotas() {
            let history = try store.quotaHistory(windowId: window.id)
            let projection = BurnRate.project(
                history: history, windowMinutes: window.windowMinutes, resetsAt: window.resetsAt
            )
            quotas.append(QuotaView(window: window, provider: provider, projection: projection))
        }
        quotas.sort { $0.window.usedPercent > $1.window.usedPercent }

        return Dashboard(
            activeNow: try store.activeNow(),
            todayTokens: today.billable,
            todayCostUSD: today.costUSD,
            todayActiveMinutes: minutes,
            todayRequests: today.requests,
            usageShares: shares,
            flow: flow,
            flowIsHourly: hourly,
            quotas: quotas,
            generatedAt: Date()
        )
    }

    /// Tightest quota across providers — the menu bar's headline number.
    public static func tightestQuota(_ quotas: [QuotaView]) -> QuotaView? {
        quotas.max { $0.window.usedPercent < $1.window.usedPercent }
    }

    // MARK: - Formatting shared by menu bar and dashboard

    /// 4.81M / 182k / 940
    public static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.2fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fk", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    /// 3h 42m / 41m
    public static func duration(minutes: Int) -> String {
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    /// "resets in 2h 14m" / "resets Fri"
    public static func resetDescription(_ date: Date?) -> String {
        guard let date else { return "reset unknown" }
        let interval = date.timeIntervalSinceNow
        if interval < 0 { return "reset due" }
        if interval < 24 * 3600 {
            let h = Int(interval) / 3600, m = (Int(interval) % 3600) / 60
            return h > 0 ? "resets in \(h)h \(m)m" : "resets in \(m)m"
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        return "resets \(fmt.string(from: date))"
    }
}
