import AIMonitorCore
import SwiftUI

// MARK: - Timeline page

struct TimelineView: View {
    @EnvironmentObject var model: MonitorModel

    private var providers: [String] {
        Array(Set(model.timeline.map(\.provider))).sorted()
    }

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
                        Text(model.timelineProvider ?? "All providers").font(.system(size: 11))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            Hairline()

            if model.timeline.isEmpty {
                EmptyNote(text: "No events yet.").padding(20)
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
                                Theme.sectionLabel(Self.dayLabel(day).uppercased())
                                    .padding(.horizontal, 20).padding(.vertical, 6)
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
            Theme.mono({
                let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: e.timestamp)
            }(), size: 11, color: Theme.textMuted)
            .frame(width: 44, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.provider).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                    if let m = e.model {
                        Text(m).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    }
                }
                if let p = e.project {
                    Text(p).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                }
            }
            Spacer()
            Theme.mono(StoreReport.compact(e.billable), size: 11)
        }
        .padding(.horizontal, 20).padding(.vertical, 7)
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
                ForEach(model.models, id: \.model) { m in
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(m.model).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                                Spacer()
                                Theme.mono(StoreReport.compact(m.billable), size: 12, color: Theme.text)
                            }
                            HStack {
                                Text(m.provider).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                                Spacer()
                                Text("\(m.requests) requests · \(m.costUSD.map { "$" + String(format: "%.2f", $0) } ?? "unpriced")")
                                    .font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                            }
                            TrackBar(fraction: Double(m.billable) / Double(maxBillable), color: Theme.bar.opacity(0.45))
                        }
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        Hairline().padding(.leading, 20)
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
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("WHAT EACH COLLECTOR CAN ACCESS")
                    collectorNote("Claude Code", "Reads ~/.claude/projects transcripts. Stores token counts, model, timestamps, project slug, request ids. Prompt and response text is never parsed, let alone stored.")
                    collectorNote("Codex CLI", "Reads ~/.codex/sessions rollout logs and the quota data embedded in them. auth.json is never opened; no credential is ever refreshed.")
                    Text("Everything stays in ~/Library/Application Support/AIMonitor. No telemetry, no account, no network.")
                        .font(.system(size: 10)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("RETENTION")
                    HStack(spacing: 14) {
                        ForEach([("7 days", "7"), ("30 days", "30"), ("90 days", "90"), ("1 year", "365"), ("Forever", "0")], id: \.1) { label, value in
                            Button {
                                retention = value
                                try? model.store.setSetting("retention_days", value)
                                try? model.store.applyRetention()
                            } label: {
                                Text(label)
                                    .font(.system(size: 11, weight: retention == value ? .semibold : .regular))
                                    .foregroundStyle(retention == value ? Theme.accent : Theme.textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

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
                    .foregroundStyle(confirmDelete ? .white : Theme.accent)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(confirmDelete ? Theme.accent : Theme.accentFaint)
                    .clipShape(Capsule())
                    Text("Removes every event, quota snapshot, and checkpoint. The next sync re-reads the logs from scratch.")
                        .font(.system(size: 10)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
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
