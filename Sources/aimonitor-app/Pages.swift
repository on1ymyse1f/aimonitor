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
                    Button(L10n.text(.allProviders, model.language)) { model.timelineProvider = nil; model.refresh() }
                    Divider()
                    ForEach(providers, id: \.self) { p in
                        Button(p) { model.timelineProvider = p; model.refresh() }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.timelineProvider ?? L10n.text(.allProviders, model.language)).font(.system(size: 11))
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
                EmptyNote(text: L10n.text(.noEvents, model.language)).padding(20)
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
                                Theme.sectionLabel(Self.dayLabel(day, lang: model.language))
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
                                Text("\(m.requests) \(L10n.text(.requestsSuffix, model.language)) · \(m.costUSD.map { "$" + String(format: "%.2f", $0) } ?? L10n.text(.unpriced, model.language))")
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

// MARK: - Settings page

struct SettingsView: View {
    @EnvironmentObject var model: MonitorModel
    @State private var retention = "90"
    @State private var notifications = false
    @State private var confirmDelete = false
    @State private var exportedPath: String?

    private var lang: Language { model.language }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Appearance
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(L10n.text(.appearance, lang))
                    HStack(spacing: 14) {
                        ForEach([("system", L10n.text(.appearanceSystem, lang)),
                                 ("light", L10n.text(.appearanceLight, lang)),
                                 ("dark", L10n.text(.appearanceDark, lang))], id: \.0) { value, label in
                            choiceButton(label, selected: model.appearance == value) { model.setAppearance(value) }
                        }
                    }
                }

                // Language
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(L10n.text(.language, lang))
                    HStack(spacing: 14) {
                        choiceButton(L10n.text(.languageSystem, lang), selected: model.language == .system) { model.setLanguage(.system) }
                        choiceButton("English", selected: model.language == .en) { model.setLanguage(.en) }
                        choiceButton("中文", selected: model.language == .zh) { model.setLanguage(.zh) }
                    }
                }

                Hairline()

                // Claude live quota — opt-in
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(L10n.text(.claudeQuota, lang).uppercased())
                    Toggle(isOn: Binding(
                        get: { model.claudeQuotaEnabled },
                        set: { model.setClaudeQuotaEnabled($0) }
                    )) {
                        Text(L10n.text(.claudeQuota, lang))
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                    Text(L10n.text(.claudeQuotaDetail, lang))
                        .font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Kimi live quota — opt-in
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(L10n.text(.kimiQuota, lang).uppercased())
                    Toggle(isOn: Binding(
                        get: { model.kimiQuotaEnabled },
                        set: { model.setKimiQuotaEnabled($0) }
                    )) {
                        Text(L10n.text(.kimiQuota, lang))
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                    Text(L10n.text(.kimiQuotaDetail, lang))
                        .font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Profile card export
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(L10n.text(.exportCard, lang).uppercased())
                    HStack(spacing: 14) {
                        ForEach((try? model.store.providersPresent()) ?? [], id: \.self) { p in
                            choiceButton(p, selected: false) {
                                exportedPath = model.exportCard(provider: p)?.path
                            }
                        }
                    }
                    if let exportedPath {
                        Text("\(L10n.text(.exportCardDone, lang))\(exportedPath)")
                            .font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Hairline()

                // Collectors
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(L10n.text(.collectorsAccess, lang))
                    collectorNote("Claude Code", L10n.text(.claudeCollectorNote, lang))
                    collectorNote("Codex CLI", L10n.text(.codexCollectorNote, lang))
                    collectorNote("Kimi Code", L10n.text(.kimiCollectorNote, lang))
                    Text(L10n.text(.storageNote, lang))
                        .font(.system(size: 10)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }

                // Retention
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(L10n.text(.retention, lang))
                    HStack(spacing: 14) {
                        ForEach([("7", L10n.text(.retention7, lang)), ("30", L10n.text(.retention30, lang)),
                                 ("90", L10n.text(.retention90, lang)), ("365", L10n.text(.retentionYear, lang)),
                                 ("0", L10n.text(.retentionForever, lang))], id: \.0) { value, label in
                            choiceButton(label, selected: retention == value) {
                                retention = value
                                try? model.store.setSetting("retention_days", value)
                                try? model.store.applyRetention()
                            }
                        }
                    }
                }

                // Notifications
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(L10n.text(.notifications, lang))
                    Toggle(isOn: $notifications) {
                        Text(L10n.text(.notificationsDetail, lang))
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                    .onChange(of: notifications) {
                        try? model.store.setSetting("notifications_enabled", notifications ? "true" : "false")
                    }
                }

                // Delete
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("DELETE")
                    Button(confirmDelete ? L10n.text(.deleteConfirm, lang) : L10n.text(.deleteAll, lang)) {
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
                    Text(L10n.text(.deleteNote, lang))
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

    private func choiceButton(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accent : Theme.textMuted)
        }
        .buttonStyle(.plain)
    }

    private func collectorNote(_ name: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
            Text(body).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
