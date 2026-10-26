import XCTest
@testable import AIMonitorCore

// MARK: - Paths and credentials that differ between macOS, Linux and Windows

final class PortabilityTests: XCTestCase {

    /// Claude Code slugs the project's absolute path. On Windows the drive
    /// leads (`C:\Users\…` → `C--Users-…`); both must reduce to the same name.
    func testClaudeProjectNameStripsMacAndWindowsPrefixes() {
        let dir = TempDir()
        let mac = dir.url.appendingPathComponent("-Users-alice-Claude-trotflow/s1.jsonl")
        let win = dir.url.appendingPathComponent("C--Users-alice-Claude-trotflow/s1.jsonl")
        let nested = dir.url.appendingPathComponent("C--Users-alice-Claude-trotflow/s1/subagents/a.jsonl")
        XCTAssertEqual(SyncEngine.claudeProjectName(for: mac, under: dir.url), "Claude-trotflow")
        XCTAssertEqual(SyncEngine.claudeProjectName(for: win, under: dir.url), "Claude-trotflow")
        XCTAssertEqual(SyncEngine.claudeProjectName(for: nested, under: dir.url), "Claude-trotflow")
    }

    /// The enumerator may return resolved paths for a symlinked root (macOS
    /// `/var` → `/private/var`, or a symlinked `~/.claude`); the project is
    /// still the first directory below the root.
    func testProjectNameUnderASymlinkedRoot() throws {
        let dir = TempDir()
        // Deeper than the link, as `/private/var/…` is deeper than `/var/…`.
        let real = dir.url.appendingPathComponent("private/real", isDirectory: true)
        let link = dir.url.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real.appendingPathComponent("-Users-alice-demo"), withIntermediateDirectories: true)
        do {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        } catch {
            // Windows without Developer Mode or admin rights cannot create symlinks.
            throw XCTSkip("symlinks unavailable here: \(error)")
        }
        let resolvedFile = real.appendingPathComponent("-Users-alice-demo/s1.jsonl")
        XCTAssertEqual(SyncEngine.claudeProjectName(for: resolvedFile, under: link), "demo")
        XCTAssertNil(PathParts.first(of: dir.url.appendingPathComponent("elsewhere/x.jsonl"), under: link))
    }

    /// Local-time buckets come from `Calendar`, not SQLite's 'localtime'
    /// (which the Windows system SQLite returns NULL for). In a +5:30 zone UTC
    /// hours straddle local hours; on a DST change a local day is 25 hours.
    func testLocalTimeBucketsFollowTheCalendar() throws {
        let store = try EventStore.inMemory()
        for (id, iso, billable) in [
            ("a", "2026-10-25T19:00:00Z", 1000),  // Kolkata: Oct 26 00:30
            ("b", "2026-10-26T04:20:00Z", 1),     // 09:50
            ("c", "2026-10-26T04:40:00Z", 10),    // 10:10
            ("d", "2026-10-26T05:10:00Z", 100),   // 10:40
        ] {
            try store.insert(usage: AIEvent(id: id, timestamp: Timestamps.parse(iso), provider: "Claude Code",
                                            tokens: TokenBreakdown(output: billable), costUSD: nil, confidence: .estimated),
                             keepLargest: false)
        }
        var kolkata = Calendar(identifier: .gregorian)
        kolkata.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let day = kolkata.startOfDay(for: try XCTUnwrap(Timestamps.parse("2026-10-26T04:20:00Z")))

        let hourly = try store.tokenFlow(since: day, until: day.addingTimeInterval(86_400), calendar: kolkata)
        XCTAssertEqual(hourly.map { kolkata.component(.hour, from: $0.0) }, [0, 9, 10])
        XCTAssertEqual(hourly.map(\.1), [1000, 1, 110])

        let daily = try store.dailyBillable(provider: "Claude Code", calendar: kolkata)
        XCTAssertEqual(daily.map(\.day), [day])
        XCTAssertEqual(daily.map(\.billable), [1111])
        XCTAssertEqual(try store.activeMinutes(since: day), 4)

        // New York leaves DST on Nov 1 2026: 00:30 EDT … 23:30 EST is one local day.
        let dst = try EventStore.inMemory()
        for (id, iso) in [("e", "2026-11-01T04:30:00Z"), ("f", "2026-11-01T05:30:00Z"),
                          ("g", "2026-11-01T06:30:00Z"), ("h", "2026-11-02T04:30:00Z")] {
            try dst.insert(usage: AIEvent(id: id, timestamp: Timestamps.parse(iso), provider: "Codex CLI",
                                          tokens: TokenBreakdown(output: 1), costUSD: nil, confidence: .exact),
                           keepLargest: false)
        }
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let nov1 = try dst.dailyBillable(provider: "Codex CLI", calendar: newYork)
        XCTAssertEqual(nov1.map(\.billable), [4])
        XCTAssertEqual(nov1.map { newYork.component(.day, from: $0.day) }, [1])
    }

    /// A `cwd` / `workDir` inside a log keeps the separator of the OS the tool
    /// ran on, independent of the OS reading it.
    func testRecordedPathLastComponentAcceptsEitherSeparator() {
        XCTAssertEqual(PathParts.last(of: "/Users/me/my-project"), "my-project")
        XCTAssertEqual(PathParts.last(of: #"C:\Users\me\my-project"#), "my-project")
        XCTAssertEqual(PathParts.last(of: #"C:\Users\me\my-project\"#), "my-project")
        XCTAssertNil(PathParts.last(of: ""))
    }

    func testKimiProjectFromWindowsWorkDir() {
        let sessions = TempDir().url
        let file = sessions.appendingPathComponent("wd_me_deadbeef/session_s1/agents/main/wire.jsonl")
        let index = ["session_s1": #"C:\Users\me\my-project"#]
        XCTAssertEqual(KimiCollector.projectName(for: file, under: sessions, index: index), "my-project")
    }

    /// The Keychain item (macOS) and `.credentials.json` (Linux, Windows) hold
    /// the same JSON; only the access token and its expiry come out.
    func testClaudeCredentialsParsing() throws {
        let raw = Data(#"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"ref","expiresAt":1767225600000}}"#.utf8)
        let parsed = try XCTUnwrap(ClaudeQuotaProvider.accessToken(fromCredentials: raw))
        XCTAssertEqual(parsed.token, "tok")
        XCTAssertEqual(parsed.expiresAt, Date(timeIntervalSince1970: 1_767_225_600))

        XCTAssertNil(ClaudeQuotaProvider.accessToken(fromCredentials: Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)))
        XCTAssertNil(ClaudeQuotaProvider.accessToken(fromCredentials: Data("not json".utf8)))
    }

    /// An on-disk store opened from a `URL.path`, the way the CLI and apps do,
    /// with the parent directory not yet created.
    func testOnDiskStoreFromURLPath() throws {
        let dir = TempDir()
        let path = dir.url.appendingPathComponent("nested/aimonitor.db").path
        let store = try EventStore(path: path)
        try store.setSetting("probe", "ok")
        XCTAssertEqual(try EventStore(path: path).setting("probe"), "ok")
    }

    func testStorageNoteNamesThisPlatformsLocation() {
        let dir = EventStore.defaultDirectoryForDisplay()
        XCTAssertTrue(L10n.text(.storageNote, .en).contains(dir))
        XCTAssertTrue(L10n.text(.storageNote, .zh).contains(dir))
        #if os(macOS)
        XCTAssertEqual(dir, "~/Library/Application Support/AIMonitor")
        #elseif os(Windows)
        XCTAssertEqual(dir, #"%LOCALAPPDATA%\AIMonitor"#)
        #endif
    }

    #if os(Windows)
    func testDefaultPathIsLocalAppData() throws {
        let local = try XCTUnwrap(ProcessInfo.processInfo.environment["LOCALAPPDATA"])
        XCTAssertEqual(EventStore.defaultPath(), local + #"\AIMonitor\aimonitor.db"#)
    }
    #endif
}
