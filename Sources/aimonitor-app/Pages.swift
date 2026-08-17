import AIMonitorCore
import SwiftUI

// MARK: - Timeline page

struct TimelineView: View {
    @EnvironmentObject var model: MonitorModel

    private var providers: [String] {
        Array(Set(model.timeline.map(\.provider))).sorted()
    }

    /// Group by calendar day, newest first.
    private var days: [(String, [EventStore.TimelineEvent])] {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let grouped = Dictionary(grouping: model.timeline) { fmt.string(from: $0.timestamp) }
        return grouped.sorted { $0.key > $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    Button("All providers") { model.timelineProvider = nil; model.refresh() }
                    Divider()
                    ForEach(providers, id: \.self) { p in
                        Button(p) { model.timelineProvider = p; model.refresh() }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.timelineProvider ?? "All providers")
                            .font(.system(size: 11))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.card)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
                }
                .menuStyle(.borderlessButton)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Hairline()

            if model.timeline.isEmpty {
                EmptyNote(text: "No events yet.").padding(16)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(days, id: \.0) { day, events in
                            Section {
                                ForEach(events, id: \.timestamp) { e in
                                    TimelineRow(e: e)
                                }
                            } header: {
                                Text(Self.dayLabel(day))
                                    .font(.system(size: 10, weight: .medium)).tracking(1)
                                    .foregroundStyle(Theme.textMuted)
                                    .padding(.horizontal, 16).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.window)
                            }
                        }
                    }
                }
                .background(Theme.window)
            }
        }
    }

    static func dayLabel(_ yyyyMMdd: String) -> String {
        let inFmt = DateFormatter(); inFmt.dateFormat = "yyyy-MM-dd"
        let outFmt = DateFormatter(); outFmt.dateFormat = "EEEE, MMM d"
        guard let d = inFmt.date(from: yyyyMMdd) else { return yyyyMMdd }
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return outFmt.string(from: d)
    }
}

struct TimelineRow: View {
    let e: EventStore.TimelineEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(e.timestamp, format: .dateTime.hour().minute())
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.provider).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                    if let m = e.model {
                        Text(m).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                }
                if let p = e.project {
                    Text(p).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                }
            }
            Spacer()
            Text(StoreReport.compact(e.billable))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .overlay(alignment: .bottom) { Hairline().padding(.leading, 76) }
    }
}

// MARK: - Models page

struct ModelsView: View {
    @EnvironmentObject var model: MonitorModel

    private var maxBillable: Int { model.models.map(\.billable).max() ?? 1 }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.models.enumerated()), id: \.offset) { i, m in
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(m.model).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                                Spacer()
                                Theme.number(StoreReport.compact(m.billable), size: 12)
                            }
                            HStack {
                                Text(m.provider).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                                Spacer()
                                Text("\(m.requests) requests · \(m.costUSD.map { "$" + String(format: "%.2f", $0) } ?? "unpriced")")
                                    .font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                            }
                            TrackBar(fraction: Double(m.billable) / Double(maxBillable),
                                     color: Theme.providerColors[i % Theme.providerColors.count])
                        }
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        Hairline().padding(.leading, 16)
                    }
                }
            }
        }
        .background(Theme.window)
    }
}

// MARK: - Privacy page

struct PrivacyView: View {
    @EnvironmentObject var model: MonitorModel
    @State private var retention = "90"
    @State private var notifications = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("WHAT EACH COLLECTOR CAN ACCESS")
                    collectorNote("Claude Code", "Reads ~/.claude/projects transcripts. Stores token counts, model, timestamps, project slug, request ids. Prompt and response text is never parsed, let alone stored.")
                    Hairline()
                    collectorNote("Codex CLI", "Reads ~/.codex/sessions rollout logs and the quota data embedded in them. auth.json is never opened; no credential is ever refreshed.")
                    Hairline()
                    Text("Everything stays in ~/Library/Application Support/AIMonitor. No telemetry, no account, no network.")
                        .font(.system(size: 10)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                .card(padding: 14)

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("RETENTION")
                    HStack(spacing: 2) {
                        ForEach([("7d", "7"), ("30d", "30"), ("90d", "90"), ("1y", "365"), ("∞", "0")], id: \.1) { label, value in
                            Button {
                                retention = value
                                try? model.store.setSetting("retention_days", value)
                                try? model.store.applyRetention()
                            } label: {
                                Text(label)
                                    .font(.system(size: 10, weight: retention == value ? .semibold : .regular))
                                    .foregroundStyle(retention == value ? Theme.text : Theme.textMuted)
                                    .frame(maxWidth: .infinity).padding(.vertical, 4)
                                    .background(retention == value ? Theme.trackFill : .clear)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .card(padding: 14)

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("NOTIFICATIONS")
                    Toggle(isOn: $notifications) {
                        Text("Quota alerts at 80% / 90% / 100%")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                    .onChange(of: notifications) {
                        try? model.store.setSetting("notifications_enabled", notifications ? "true" : "false")
                    }
                }
                .card(padding: 14)

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("DELETE")
                    Button(confirmDelete ? "Click again to confirm" : "Delete all analytics data") {
                        if confirmDelete {
                            try? model.store.deleteAllData()
                            confirmDelete = false
                            model.refresh()
                        } else {
                            confirmDelete = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmDelete = false }
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(confirmDelete ? .white : Theme.coral)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(confirmDelete ? Theme.coral : Theme.coral.opacity(0.12))
                    .clipShape(Capsule())
                    Text("Removes every event, quota snapshot, and checkpoint. The next sync re-reads the logs from scratch.")
                        .font(.system(size: 10)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                .card(padding: 14)
            }
            .padding(16)
        }
        .background(Theme.window)
        .onAppear {
            retention = model.store.setting("retention_days") ?? "90"
            notifications = model.store.setting("notifications_enabled") == "true"
        }
    }

    private func collectorNote(_ name: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
            Text(body).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
