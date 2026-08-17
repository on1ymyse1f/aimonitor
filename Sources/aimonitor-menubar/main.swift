import AIMonitorCore
import AppKit
import UserNotifications

/// Menu-bar front end, store-backed.
///
/// The status bar reads SQLite only — milliseconds. Log parsing happens in the
/// background and only when the logs actually changed (a stat-only fingerprint
/// gates every sync), so the steady state costs nothing.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var store: EventStore!
    private var syncEngine: SyncEngine!
    private var refreshTimer: Timer?
    private var lastFingerprint = -1
    private var syncing = false
    /// Quota thresholds already notified, per window id — reset when usage drops.
    private var notifiedThresholds: [String: Int] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            store = try EventStore(path: EventStore.defaultPath())
        } catch {
            let alert = NSAlert()
            alert.messageText = "AI Monitor could not open its database"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        syncEngine = SyncEngine(store: store)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "AI …"

        // First sync unconditionally (the store may be brand new), then a cheap
        // fingerprint check on a timer.
        kickSync(force: true)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.kickSync(force: false)
        }
    }

    /// Syncs when logs changed (or forced), then re-renders. All heavy work off
    /// the main thread.
    private func kickSync(force: Bool) {
        guard !syncing else { return }
        let fingerprint = syncEngine.logsFingerprint()
        guard force || fingerprint != lastFingerprint else { render(); return }
        syncing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            _ = self.syncEngine.sync()
            DispatchQueue.main.async {
                self.syncing = false
                self.lastFingerprint = fingerprint
                self.render()
                self.maybeNotify()
            }
        }
    }

    private func render() {
        guard let data = try? StoreReport.dashboard(from: store) else { return }

        // Status bar title: the configured metric, defaulting to the tightest quota.
        let metric = store.setting("menubar_metric") ?? "quota"
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
        statusItem.button?.title = title

        var menu = NSMenu()
        menu.addItem(header("AI Monitor"))

        // Active now
        if let active = data.activeNow.first {
            let ago = Int(Date().timeIntervalSince(active.lastEventAt))
            menu.addItem(item("● \(active.provider)\(active.model.map { " · \($0)" } ?? "") · \(ago)s ago"))
        }

        // Today
        menu.addItem(.separator())
        let costText = data.todayCostUSD.map { "~" + ReportFormatter.money(Decimal($0)) + " eq." } ?? "n/a"
        menu.addItem(item("Today: \(StoreReport.compact(data.todayTokens)) tokens · \(StoreReport.duration(minutes: data.todayActiveMinutes)) · \(costText)"))

        // Usage shares
        if !data.usageShares.isEmpty {
            menu.addItem(.separator())
            for share in data.usageShares.prefix(6) {
                menu.addItem(item(String(format: "%-14@ %3.0f%%  %@", share.provider as NSString, share.fraction * 100, StoreReport.compact(share.billable))))
            }
        }

        // Quotas
        if !data.quotas.isEmpty {
            menu.addItem(.separator())
            for q in data.quotas {
                var line = String(format: "%@ %@ — %.0f%% · %@",
                                  q.provider, q.window.label, q.window.usedPercent,
                                  StoreReport.resetDescription(q.window.resetsAt))
                if let p = q.projection {
                    line += String(format: " · exhausted in %.1fh at current pace", p.exhaustedAt.timeIntervalSinceNow / 3600)
                }
                menu.addItem(item(line))
            }
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        open.target = self
        menu.addItem(open)
        let resync = NSMenuItem(title: "Sync now", action: #selector(forceSync), keyEquivalent: "r")
        resync.target = self
        menu.addItem(resync)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        func header(_ s: String) -> NSMenuItem { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }
        func item(_ s: String) -> NSMenuItem { let i = NSMenuItem(title: "   " + s, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }
    }

    /// Local notifications: off by default. Enabled via `notifications_enabled`
    /// setting; fires once per threshold (80/90/100) per window per session.
    private func maybeNotify() {
        guard store.setting("notifications_enabled") == "true" else { return }
        guard let quotas = try? store.latestQuotas() else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        for (window, provider) in quotas {
            let crossed = [100, 90, 80].filter { window.usedPercent >= Double($0) }.max()
            guard let threshold = crossed, (notifiedThresholds[window.id] ?? 0) < threshold else { continue }
            notifiedThresholds[window.id] = threshold

            let content = UNMutableNotificationContent()
            content.title = "AI Monitor — \(provider)"
            content.body = "\(window.label) quota reached \(Int(window.usedPercent))%."
            if let history = try? store.quotaHistory(windowId: window.id),
               let p = BurnRate.project(history: history, windowMinutes: window.windowMinutes, resetsAt: window.resetsAt),
               p.exhaustedAt.timeIntervalSinceNow < (window.resetsAt?.timeIntervalSinceNow ?? 0) {
                content.body += String(format: " At current pace it runs out in %.0fh %02.0fm.",
                                       floor(p.exhaustedAt.timeIntervalSinceNow / 3600),
                                       (p.exhaustedAt.timeIntervalSinceNow.truncatingRemainder(dividingBy: 3600)) / 60)
            }
            let request = UNNotificationRequest(identifier: "quota-\(window.id)-\(threshold)", content: content, trigger: nil)
            center.add(request)
        }
    }

    @objc private func forceSync() { kickSync(force: true) }

    @objc private func openDashboard() {
        // The dashboard binary is built alongside this one in the same
        // products directory.
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("aimonitor-app")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            let task = Process()
            task.executableURL = sibling
            try? task.run()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
