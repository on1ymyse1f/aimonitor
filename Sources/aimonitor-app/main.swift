import AIMonitorCore
import SwiftUI

// MARK: - View model

@MainActor
final class MonitorModel: ObservableObject {
    @Published var dashboard: StoreReport.Dashboard?
    @Published var flowRange: StoreReport.FlowRange = .today
    @Published var timeline: [EventStore.TimelineEvent] = []
    @Published var models: [EventStore.ModelTotals] = []
    @Published var projects: [EventStore.ProjectTotals] = []
    @Published var timelineProvider: String? = nil

    let store: EventStore
    let engine: SyncEngine
    private var fingerprint = -1

    init() {
        let s = try! EventStore(path: EventStore.defaultPath())
        store = s
        engine = SyncEngine(store: s)
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
            let pj = try? self.store.totalsByProject()
            DispatchQueue.main.async {
                if let dash { self.dashboard = dash }
                if let tl { self.timeline = tl }
                if let ms { self.models = ms }
                if let pj { self.projects = pj }
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
                .frame(width: 380, height: 620)
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
        case dashboard, timeline, models, privacy

        var icon: String {
            switch self {
            case .dashboard: return "gauge.with.dots.needle.33percent"
            case .timeline: return "clock"
            case .models: return "cpu"
            case .privacy: return "lock.shield"
            }
        }
        var label: String {
            switch self {
            case .dashboard: return "Dashboard"
            case .timeline: return "Timeline"
            case .models: return "Models"
            case .privacy: return "Privacy"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: title + date, then the page switch.
            HStack(alignment: .firstTextBaseline) {
                Text("AI monitor")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(Date(), format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)

            HStack(spacing: 4) {
                ForEach(Page.allCases, id: \.label) { p in
                    Button { page = p } label: {
                        HStack(spacing: 5) {
                            Image(systemName: p.icon).font(.system(size: 10))
                            Text(p.label).font(.system(size: 11, weight: page == p ? .semibold : .regular))
                        }
                        .foregroundStyle(page == p ? Theme.text : Theme.textMuted)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(page == p ? Theme.card : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(page == p ? Theme.border : .clear, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.bottom, 10)

            Hairline()

            switch page {
            case .dashboard: DashboardView()
            case .timeline: TimelineView()
            case .models: ModelsView()
            case .privacy: PrivacyView()
            }
        }
        .background(Theme.window)
    }
}
