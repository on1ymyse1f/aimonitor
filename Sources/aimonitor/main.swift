import AIMonitorCore
import Foundation

func usage() -> String {
    """
    aimonitor — local AI coding-tool usage, with the confidence of each number stated

    USAGE
      aimonitor [--since <days>] [--json]
      aimonitor --sync <db-path> [--claude-root <dir>] [--codex-root <dir>] [--kimi-root <dir>]
      aimonitor card [--provider <name>] [--out <file.html>] [--lang en|zh] [--db <db-path>]

    OPTIONS
      --since <days>       Only count usage from the last N days (default: all history)
      --json               Emit machine-readable JSON instead of the text report
      --claude-root <dir>  Read Claude Code transcripts from <dir> instead of
                           ~/.claude/projects
      --codex-root <dir>   Read Codex rollout logs from <dir> instead of
                           ~/.codex/sessions
      --kimi-root <dir>    Read Kimi Code wire logs from <dir> instead of
                           ~/.kimi-code/sessions
      --help               This message

    CARD
      Renders a shareable profile card (heatmap + streaks) as a self-contained
      HTML file, from the store. Options:
        --provider <name>  Provider to feature (default: the one with most usage)
        --out <file>       Output path (default: ~/Desktop/aimonitor-card.html)
        --lang en|zh       Card language (default: system)
        --db <path>        Store path (default: ~/Library/Application Support/AIMonitor)
        --name / --handle  Display name and handle (default: this Mac's user)

    REPRODUCIBILITY
      The live logs grow while you read them — an agent session appends usage
      records as it works, so two runs seconds apart legitimately differ. To
      compare runs, copy the logs aside and point --claude-root / --codex-root at
      the frozen snapshot.

    NOTES
      Every figure carries a confidence marker: exact (read from the provider's
      own accounting), est. (reconstructed from logs, with the caveat named), or
      n/a (not derivable locally — reported as absent, never as zero).

      Run `aimonitor-probe` first to confirm the log formats on this machine still
      match what the parsers expect.
    """
}

var since: Date?
var wantsJSON = false
var claudeRoot: URL?
var codexRoot: URL?
var kimiRoot: URL?
var args = Array(CommandLine.arguments.dropFirst())

func takeDirectory(_ flag: String, from args: inout [String]) -> URL {
    guard let value = args.first else {
        FileHandle.standardError.write(Data("error: \(flag) needs a directory\n".utf8))
        exit(2)
    }
    args.removeFirst()
    return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
}

/// `aimonitor card` — render one provider's whole history as a shareable card.
func runCardCommand(_ cardArgs: [String]) {
    var provider: String?
    var out = "~/Desktop/aimonitor-card.html"
    var dbPath = EventStore.defaultPath()
    var lang = Language.system
    var name = NSFullUserName()
    var handle = NSUserName()

    var rest = cardArgs
    while let arg = rest.first {
        rest.removeFirst()
        func takeValue() -> String {
            guard let v = rest.first else {
                FileHandle.standardError.write(Data("error: \(arg) needs a value\n".utf8))
                exit(2)
            }
            rest.removeFirst()
            return v
        }
        switch arg {
        case "--provider": provider = takeValue()
        case "--out": out = takeValue()
        case "--db": dbPath = (takeValue() as NSString).expandingTildeInPath
        case "--lang": lang = Language(rawValue: takeValue()) ?? .system
        case "--name": name = takeValue()
        case "--handle": handle = takeValue()
        default:
            FileHandle.standardError.write(Data("error: unknown card option '\(arg)'\n".utf8))
            exit(2)
        }
    }

    do {
        let store = try EventStore(path: dbPath)
        let present = try store.providersPresent()
        guard let provider = provider ?? present.first else {
            FileHandle.standardError.write(Data("error: no usage in the store yet — run `aimonitor --sync` first\n".utf8))
            exit(1)
        }
        let days = try store.dailyBillable(provider: provider)
        let stats = CardReport.stats(from: days)
        if name.isEmpty { name = handle }
        let html = CardReport.html(provider: provider, stats: stats, name: name, handle: handle, lang: lang)
        let outURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        try html.write(to: outURL, atomically: true, encoding: .utf8)
        print("card written to \(outURL.path)")
        print("  \(provider): total \(stats.totalBillable), peak day \(stats.peakDay?.billable ?? 0), streak \(stats.currentStreak)/\(stats.longestStreak) days, \(days.count) active days")
    } catch {
        FileHandle.standardError.write(Data("error: card failed: \(error)\n".utf8))
        exit(1)
    }
}

while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--help", "-h":
        print(usage())
        exit(0)
    case "--json":
        wantsJSON = true
    case "--since":
        guard let value = args.first, let days = Double(value) else {
            FileHandle.standardError.write(Data("error: --since needs a number of days\n".utf8))
            exit(2)
        }
        args.removeFirst()
        since = Date().addingTimeInterval(-days * 86_400)
    case "--claude-root":
        claudeRoot = takeDirectory(arg, from: &args)
    case "--codex-root":
        codexRoot = takeDirectory(arg, from: &args)
    case "--kimi-root":
        kimiRoot = takeDirectory(arg, from: &args)
    case "card":
        runCardCommand(args)
        exit(0)
    case "--sync":
        // Sync into the store at the given path, then print what the store
        // believes — for cross-checking the incremental path against the
        // full-scan report on the same logs.
        guard let dbPath = args.first else {
            FileHandle.standardError.write(Data("error: --sync needs a database path\n".utf8))
            exit(2)
        }
        args.removeFirst()
        do {
            let store = try EventStore(path: (dbPath as NSString).expandingTildeInPath)
            let engine = SyncEngine(store: store, claudeRoot: claudeRoot, codexRoot: codexRoot, kimiRoot: kimiRoot)
            let summary = engine.sync()
            print("sync: \(summary.filesScanned) scanned, \(summary.filesSkippedUnchanged) unchanged, \(summary.filesFailed) failed; +\(summary.claudeEvents) claude, +\(summary.codexEvents) codex, +\(summary.kimiEvents) kimi events")
            for provider in [ClaudeCodeCollector.providerName, CodexCollector.providerName, KimiCollector.providerName] {
                guard let b = try store.tokenBreakdown(provider: provider) else { continue }
                print("""
                    \(provider): billable \(b.billableEquivalent) = input \(b.uncachedInput) + cached \(b.cachedInput) \
                    + writes(5m \(b.cacheWrite5m), 1h \(b.cacheWrite1h), ?\(b.cacheWriteUnspecified)) + output \(b.output) \
                    [reasoning \(b.reasoning)], events \(try store.eventCount(provider: provider))
                    """)
            }
        } catch {
            FileHandle.standardError.write(Data("error: sync failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    default:
        FileHandle.standardError.write(Data("error: unknown argument '\(arg)'\n\n".utf8))
        print(usage())
        exit(2)
    }
}

let report = Aggregator(
    codex: CodexCollector(sessionsRoot: codexRoot),
    claudeCode: ClaudeCodeCollector(projectsRoot: claudeRoot),
    kimi: KimiCollector(sessionsRoot: kimiRoot)
).report(since: since)

if wantsJSON {
    do {
        print(try ReportFormatter.json(report))
    } catch {
        FileHandle.standardError.write(Data("error: could not encode report: \(error)\n".utf8))
        exit(1)
    }
} else {
    print(ReportFormatter.text(report))
}
