import XCTest
@testable import AIMonitorCore

// MARK: - Claude quota endpoint parsing + localization

final class ClaudeQuotaProviderTests: XCTestCase {

    /// The documented response shape: every window present.
    func testParsesAllWindows() {
        let json: [String: Any] = [
            "five_hour": ["utilization": 33.0, "resets_at": "2026-08-18T07:00:00.528743+00:00"],
            "seven_day": ["utilization": 13.0, "resets_at": "2026-08-24T00:59:59.951713+00:00"],
            "seven_day_opus": NSNull(),
            "seven_day_sonnet": ["utilization": 1.0, "resets_at": "2026-08-23T03:00:00.951719+00:00"],
            "extra_usage": ["is_enabled": false],
        ]
        let windows = ClaudeQuotaProvider.parseWindows(from: json, now: Date())
        XCTAssertEqual(windows.map(\.id), ["claude-five_hour", "claude-seven_day", "claude-seven_day_sonnet"],
                       "null windows (seven_day_opus) must be absent, not 0%")
        XCTAssertEqual(windows[0].usedPercent, 33)
        XCTAssertNotNil(windows[0].resetsAt)
        XCTAssertEqual(windows[0].windowMinutes, 300)
        XCTAssertEqual(windows[1].windowMinutes, 10080)
    }

    /// Plans that expose only the 5-hour window: emit exactly that one.
    func testMissingWindowsAreAbsentNotZero() {
        let json: [String: Any] = [
            "five_hour": ["utilization": 4.0, "resets_at": "2026-08-18T11:00:00+00:00"],
        ]
        let windows = ClaudeQuotaProvider.parseWindows(from: json, now: Date())
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].id, "claude-five_hour")
    }

    func testEmptyResponseYieldsNoWindows() {
        XCTAssertTrue(ClaudeQuotaProvider.parseWindows(from: [:], now: Date()).isEmpty)
    }
}

final class L10nTests: XCTestCase {

    func testEveryKeyHasBothLanguages() {
        for key in L10n.Key.allCases {
            let en = L10n.text(key, .en)
            let zh = L10n.text(key, .zh)
            XCTAssertFalse(en.isEmpty, "\(key) missing English")
            XCTAssertFalse(zh.isEmpty, "\(key) missing Chinese")
        }
    }

    func testSystemResolves() {
        XCTAssertNotEqual(Language.system.resolved, .system, "system must resolve to a concrete language")
    }

    func testResetDescriptionLocalized() {
        let soon = Date().addingTimeInterval(2 * 3600 + 14 * 60)
        XCTAssertTrue(StoreReport.resetDescription(soon, lang: .en).contains("resets in"))
        XCTAssertTrue(StoreReport.resetDescription(soon, lang: .zh).contains("后重置"))
        XCTAssertEqual(StoreReport.resetDescription(nil, lang: .zh), "重置时间未知")
    }
}
