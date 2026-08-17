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
            DispatchQueue.main.async {
                if let dash { self.dashboard = dash }
                if let tl { self.timeline = tl }
                if let ms { self.models = ms }
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
        case dashboard, timeline, models, privacy
        var label: String {
            switch self {
            case .dashboard: return "Today"
            case .timeline: return "Timeline"
            case .models: return "Models"
            case .privacy: return "Privacy"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: serif wordmark + date, then quiet text tabs.
            HStack(alignment: .firstTextBaseline) {
                Text("AI Monitor")
                    .font(.system(size: 17, weight: .regular, design: .serif))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(Date(), format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            HStack(spacing: 18) {
                ForEach(Page.allCases, id: \.label) { p in
                    Button { page = p } label: {
                        VStack(spacing: 4) {
                            Text(p.label)
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
            case .privacy: PrivacyView()
            }
        }
        .background(Theme.window)
    }
}
