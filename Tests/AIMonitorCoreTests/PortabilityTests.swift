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
