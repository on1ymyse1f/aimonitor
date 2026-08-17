import AIMonitorCore
import AppKit

/// Menu-bar front end.
///
/// Deliberately thin: it renders what `AIMonitorCore` returns and nothing more.
/// Every number keeps the confidence marker the core assigned it, because the
/// whole point is that a reconstructed figure should not look like a billed one
/// just because it reached a status bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private let aggregator = Aggregator()
    private var lastReport: UsageReport?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "AI …"
        refresh()
        // Log scanning is I/O bound and the numbers move slowly; a minute is
        // frequent enough to be useful and rare enough to stay invisible.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let report = self.aggregator.report()
            DispatchQueue.main.async {
                self.lastReport = report
                self.render(report)
            }
        }
    }

    /// Title shows the most actionable number available: the tightest quota if
    /// one is known, otherwise reconstructed cost. A missing number is shown as
    /// "n/a", never as a zero.
    private func render(_ report: UsageReport) {
        var fragments: [String] = []

        let tightest = report.providers
            .flatMap { $0.quotas }
            .max { $0.usedPercent < $1.usedPercent }

        if let tightest {
            fragments.append("\(tightest.label) \(Int(tightest.usedPercent.rounded()))%")
        }

        if let claude = report.providers.first(where: { $0.provider == ClaudeCodeCollector.providerName }),
           let cost = claude.apiEquivalentCostUSD,
           claude.apiEquivalentCostConfidence != .unavailable {
            fragments.append("~" + ReportFormatter.money(cost))
        }

        statusItem.button?.title = fragments.isEmpty ? "AI n/a" : fragments.joined(separator: "  ")
        statusItem.menu = buildMenu(report)
    }

    private func buildMenu(_ report: UsageReport) -> NSMenu {
        let menu = NSMenu()

        for provider in report.providers {
            let header = NSMenuItem(title: provider.provider, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            if let tokens = provider.tokens, provider.tokenConfidence != .unavailable {
                menu.addItem(indented("\(tokens.billableEquivalent.formatted()) tokens  [\(provider.tokenConfidence.marker)]"))
            } else {
                menu.addItem(indented("tokens: unavailable"))
            }

            if let cost = provider.apiEquivalentCostUSD, provider.apiEquivalentCostConfidence != .unavailable {
                menu.addItem(indented("API-equivalent \(ReportFormatter.money(cost))  [\(provider.apiEquivalentCostConfidence.marker)]"))
                menu.addItem(indented("actually billed: unavailable"))
            }

            for quota in provider.quotas {
                menu.addItem(indented(String(format: "%@ %.1f%% used  [%@]", quota.label, quota.usedPercent, provider.quotaConfidence.marker)))
            }

            if provider.tokens == nil, let reason = provider.notes.first {
                menu.addItem(indented(reason))
            }
            menu.addItem(.separator())
        }

        let copy = NSMenuItem(title: "Copy full report", action: #selector(copyReport), keyEquivalent: "c")
        copy.target = self
        menu.addItem(copy)

        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private func indented(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "   " + title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func copyReport() {
        guard let lastReport else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ReportFormatter.text(lastReport), forType: .string)
    }

    @objc private func refreshNow() { refresh() }
}

// Runs as an accessory app: status-bar presence, no Dock icon, no window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
