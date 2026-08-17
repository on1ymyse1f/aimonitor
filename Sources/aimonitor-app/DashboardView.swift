import AIMonitorCore
import SwiftUI

/// One calm page: a serif headline number, supporting stats as quiet lines,
/// then usage / flow / quota. Hierarchy through type and spacing, not boxes.
struct DashboardView: View {
    @EnvironmentObject var model: MonitorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let d = model.dashboard {
                    hero(d)
                    if let a = d.activeNow.first {
                        ActiveNowRow(provider: a.provider, model: a.model, lastEventAt: a.lastEventAt)
                    }
                    usageSection(d)
                    flowSection(d)
                    quotaSection(d)
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .background(Theme.window)
    }

    // MARK: Hero — the one number that matters today

    private func hero(_ d: StoreReport.Dashboard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Theme.display(StoreReport.compact(d.todayTokens), size: 34)
                Text("tokens today")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }

            HStack(spacing: 18) {
                heroStat("time", StoreReport.duration(minutes: d.todayActiveMinutes))
                heroStat("cost", d.todayCostUSD.map { "$" + String(format: "%.2f", $0) } ?? "n/a")
                heroStat("requests", "\(d.todayRequests)")
            }
        }
    }

    private func heroStat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Theme.mono(value, size: 12, color: Theme.text)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
        }
    }

    // MARK: Usage — thin charcoal bars, no rainbow

    private func usageSection(_ d: StoreReport.Dashboard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("USAGE")
            if d.usageShares.isEmpty {
                EmptyNote(text: "No usage recorded today.")
            } else {
                ForEach(Array(d.usageShares.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 10) {
                        Text(s.provider)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 78, alignment: .leading)
                            .lineLimit(1)
                        TrackBar(fraction: s.fraction, color: i == 0 ? Theme.bar : Theme.bar.opacity(0.45))
                        Theme.mono("\(Int(s.fraction * 100))%", size: 11)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: Token flow

    private func flowSection(_ d: StoreReport.Dashboard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader("TOKEN FLOW")
                Spacer()
                RangePicker(selection: $model.flowRange)
            }
            if d.flow.isEmpty {
                EmptyNote(text: "No usage in this range.")
            } else {
                FlowChart(flow: d.flow, hourly: d.flowIsHourly)
            }
        }
    }

    // MARK: Quota — terracotta appears only when it means something

    private func quotaSection(_ d: StoreReport.Dashboard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("QUOTA")
            if d.quotas.isEmpty {
                EmptyNote(text: "No quota data — providers either don't report it or weren't used yet.")
            }
            ForEach(d.quotas, id: \.window.id) { q in
                QuotaRow(q: q)
            }
        }
    }
}

struct QuotaRow: View {
    let q: StoreReport.QuotaView

    var body: some View {
        let warn = q.window.usedPercent >= 90
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(q.provider) · \(q.window.label)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Theme.mono(
                    "\(Int(q.window.usedPercent.rounded()))% · \(StoreReport.resetDescription(q.window.resetsAt))",
                    size: 11,
                    color: warn ? Theme.accent : Theme.textMuted
                )
            }
            TrackBar(fraction: q.window.usedPercent / 100, color: warn ? Theme.accent : Theme.bar.opacity(0.45))
            if let p = q.projection {
                Text("At current pace, exhausted \(Self.pace(p.exhaustedAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    static func pace(_ date: Date) -> String {
        let t = date.timeIntervalSinceNow
        if t < 3600 { return "in \(max(1, Int(t / 60)))m" }
        if t < 86400 { return "in \(Int(t / 3600))h \(Int(t.truncatingRemainder(dividingBy: 3600) / 60))m" }
        return "in \(Int(t / 86400))d"
    }
}

/// Understated text tabs for the flow range.
struct RangePicker: View {
    @Binding var selection: StoreReport.FlowRange
    @EnvironmentObject var model: MonitorModel

    var body: some View {
        HStack(spacing: 12) {
            ForEach(StoreReport.FlowRange.allCases, id: \.self) { range in
                Button {
                    selection = range
                    model.refresh()
                } label: {
                    Text(range.rawValue)
                        .font(.system(size: 10, weight: selection == range ? .semibold : .regular))
                        .foregroundStyle(selection == range ? Theme.text : Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
