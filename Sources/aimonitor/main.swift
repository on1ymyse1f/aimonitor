import AIMonitorCore
import Foundation

func usage() -> String {
    """
    aimonitor — local AI coding-tool usage, with the confidence of each number stated

    USAGE
      aimonitor [--since <days>] [--json]

    OPTIONS
      --since <days>       Only count usage from the last N days (default: all history)
      --json               Emit machine-readable JSON instead of the text report
      --claude-root <dir>  Read Claude Code transcripts from <dir> instead of
                           ~/.claude/projects
      --codex-root <dir>   Read Codex rollout logs from <dir> instead of
                           ~/.codex/sessions
      --help               This message

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
var args = Array(CommandLine.arguments.dropFirst())

func takeDirectory(_ flag: String, from args: inout [String]) -> URL {
    guard let value = args.first else {
        FileHandle.standardError.write(Data("error: \(flag) needs a directory\n".utf8))
        exit(2)
    }
    args.removeFirst()
    return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
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
            let engine = SyncEngine(store: store, claudeRoot: claudeRoot, codexRoot: codexRoot)
            let summary = engine.sync()
            print("sync: \(summary.filesScanned) scanned, \(summary.filesSkippedUnchanged) unchanged, \(summary.filesFailed) failed; +\(summary.claudeEvents) claude, +\(summary.codexEvents) codex events")
            for provider in [ClaudeCodeCollector.providerName, CodexCollector.providerName] {
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
    claudeCode: ClaudeCodeCollector(projectsRoot: claudeRoot)
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
