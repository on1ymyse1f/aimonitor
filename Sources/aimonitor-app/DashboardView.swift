import AIMonitorCore
import SwiftUI

/// The main page, mirroring the approved mockup:
/// ACTIVE NOW · TODAY (time/tokens/cost) · USAGE · TOKEN FLOW · QUOTA.
struct DashboardView: View {
    @EnvironmentObject var model: MonitorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let d = model.dashboard {
                    if let a = d.activeNow.first {
                        ActiveNowCard(provider: a.provider, model: a.model, lastEventAt: a.lastEventAt)
                    }

                    todayGrid(d).card(padding: 14)

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader("USAGE")
                        if d.usageShares.isEmpty {
                            EmptyNote(text: "No usage recorded today.")
                        } else {
                            ForEach(Array(d.usageShares.enumerated()), id: \.offset) { i, s in
                                HStack(spacing: 8) {
                                    Text(s.provider)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textSecondary)
                                        .frame(width: 80, alignment: .leading)
                                        .lineLimit(1)
                                    TrackBar(fraction: s.fraction,
                                             color: Theme.providerColors[i % Theme.providerColors.count])
                                    Text("\(Int(s.fraction * 100))%")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Theme.textSecondary)
                                        .frame(width: 34, alignment: .trailing)
                                }
                            }
                        }
                    }
                    .card(padding: 14)

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
                    .card(padding: 14)

                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader("QUOTA")
                        if d.quotas.isEmpty {
                            EmptyNote(text: "No quota data — providers either don't report it or weren't used yet.")
                        }
                        ForEach(d.quotas, id: \.window.id) { q in
                            QuotaRow(q: q)
                        }
                    }
                    .card(padding: 14)
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(16)
        }
        .background(Theme.window)
    }

    private func todayGrid(_ d: StoreReport.Dashboard) -> some View {
        HStack(spacing: 0) {
            stat("TIME", StoreReport.duration(minutes: d.todayActiveMinutes))
            Spacer()
            stat("TOKENS", StoreReport.compact(d.todayTokens))
            Spacer()
            stat("COST", d.todayCostUSD.map { "$" + String(format: "%.2f", $0) } ?? "n/a")
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Theme.sectionLabel(label)
            Theme.number(value)
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
                Text("\(Int(q.window.usedPercent.rounded()))% · \(StoreReport.resetDescription(q.window.resetsAt))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(warn ? Theme.amberText : Theme.textMuted)
            }
            TrackBar(fraction: q.window.usedPercent / 100, color: warn ? Theme.amber : Theme.gray)
            if let p = q.projection {
                Text("At current pace, exhausted \(Self.pace(p.exhaustedAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.amberText)
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

/// Compact Today/7D/30D/All switch styled to sit inside a card header.
struct RangePicker: View {
    @Binding var selection: StoreReport.FlowRange
    @EnvironmentObject var model: MonitorModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(StoreReport.FlowRange.allCases, id: \.self) { range in
                Button {
                    selection = range
                    model.refresh()
                } label: {
                    Text(range.rawValue)
                        .font(.system(size: 10, weight: selection == range ? .semibold : .regular))
                        .foregroundStyle(selection == range ? Theme.text : Theme.textMuted)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(selection == range ? Theme.trackFill : .clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
