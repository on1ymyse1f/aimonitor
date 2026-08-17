import AIMonitorCore
import SwiftUI

// MARK: - View model

@MainActor
final class MonitorModel: ObservableObject {
    @Published var dashboard: StoreReport.Dashboard?
    @Published var flowRange: StoreReport.FlowRange = .today
    @Published var timeline: [EventStore.TimelineEvent] = []
    @Published var models: [EventStore.ModelTotals] = []
    @Published var timelineProvider: String? = nil
    @Published var language: Language
    @Published var appearance: String   // "system" | "light" | "dark"
    @Published var claudeQuotaEnabled: Bool

    let store: EventStore
    let engine: SyncEngine
    private var fingerprint = -1
    private var lastClaudeQuotaFetch = Date.distantPast
    private let claudeQuota = ClaudeQuotaProvider()

    init() {
        let s = try! EventStore(path: EventStore.defaultPath())
        store = s
        engine = SyncEngine(store: s)
        language = Language(rawValue: s.setting("language") ?? "system") ?? .system
        appearance = s.setting("appearance") ?? "system"
        claudeQuotaEnabled = s.setting("claude_quota_optin") == "true"
    }

    func setLanguage(_ l: Language) {
        language = l
        try? store.setSetting("language", l.rawValue)
    }

    func setAppearance(_ a: String) {
        appearance = a
        try? store.setSetting("appearance", a)
    }

    func setClaudeQuotaEnabled(_ on: Bool) {
        claudeQuotaEnabled = on
        try? store.setSetting("claude_quota_optin", on ? "true" : "false")
        if on { refresh() }
    }

    func refresh() {
        let fp = engine.logsFingerprint()
        let changed = fp != fingerprint
        fingerprint = fp
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if changed { _ = self.engine.sync() }
            let dash = try? StoreReport.dashboard(from: self.store, flowRange: self.flowRange)
            let tl = try? self.store.recentEvents(provider: self.timelineProvider)
            let ms = try? self.store.totalsByModel()
            DispatchQueue.main.async {
                if let dash { self.dashboard = dash }
                if let tl { self.timeline = tl }
                if let ms { self.models = ms }
            }
        }
        maybeFetchClaudeQuota()
    }

    /// Opt-in, read-only, rate-limited. See ClaudeQuotaProvider.
    private func maybeFetchClaudeQuota() {
        guard claudeQuotaEnabled,
              Date().timeIntervalSince(lastClaudeQuotaFetch) >= ClaudeQuotaProvider.minimumInterval
        else { return }
        lastClaudeQuotaFetch = Date()
        let provider = claudeQuota
        let store = self.store
        Task.detached {
            if case .success(let windows) = await provider.fetch() {
                for w in windows {
                    try? store.insert(quota: w, provider: ClaudeQuotaProvider.providerName)
                }
            }
        }
    }
}

// MARK: - App

@main
struct AIMonitorApp: App {
    @StateObject private var model = MonitorModel()
    private let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some Scene {
        WindowGroup("AI Monitor") {
            RootView()
                .environmentObject(model)
                .frame(width: 400, height: 600)
                .onAppear { model.refresh() }
                .onReceive(timer) { _ in model.refresh() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var model: MonitorModel
    @State private var page: Page = .dashboard

    enum Page: CaseIterable {
        case dashboard, timeline, models, settings
        func label(_ lang: Language) -> String {
            switch self {
            case .dashboard: return L10n.text(.tabToday, lang)
            case .timeline: return L10n.text(.tabTimeline, lang)
            case .models: return L10n.text(.tabModels, lang)
            case .settings: return L10n.text(.tabSettings, lang)
            }
        }
    }

    private var colorScheme: ColorScheme? {
        switch model.appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: serif wordmark + date, then quiet text tabs.
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text(.appTitle, model.language))
                    .font(.system(size: 17, weight: .regular, design: .serif))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(Date(), format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            HStack(spacing: 18) {
                ForEach(Page.allCases, id: \.self) { p in
                    Button { page = p } label: {
                        VStack(spacing: 4) {
                            Text(p.label(model.language))
                                .font(.system(size: 12, weight: page == p ? .medium : .regular))
                                .foregroundStyle(page == p ? Theme.text : Theme.textMuted)
                            Capsule()
                                .fill(page == p ? Theme.accent : .clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.bottom, 6)

            Hairline()

            switch page {
            case .dashboard: DashboardView()
            case .timeline: TimelineView()
            case .models: ModelsView()
            case .settings: SettingsView()
            }
        }
        .background(Theme.window)
        .preferredColorScheme(colorScheme)
    }
}
