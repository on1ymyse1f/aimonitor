// swift-tools-version:6.0
import PackageDescription

var targets: [Target] = [
    // Apple SDKs ship an `SQLite3` module; Linux and Windows do not. This one
    // wraps the system SQLite there: libsqlite3 on Linux, winsqlite3 (part of
    // the Windows SDK, shipped with Windows 10+) on Windows.
    .systemLibrary(name: "CSQLite"),
    .target(
        name: "AIMonitorCore",
        dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux, .windows]))],
        swiftSettings: [.swiftLanguageMode(.v5)],
        linkerSettings: [
            .linkedLibrary("sqlite3", .when(platforms: [.linux])),
            .linkedLibrary("winsqlite3", .when(platforms: [.windows])),
        ]
    ),
    .executableTarget(
        name: "aimonitor",
        dependencies: ["AIMonitorCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "aimonitor-probe",
        dependencies: ["AIMonitorCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "AIMonitorCoreTests",
        dependencies: ["AIMonitorCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]

// The menu bar and the dashboard are AppKit / SwiftUI, which exist only on
// macOS. Elsewhere they are left out so `swift build` and `swift test` cover
// everything that can compile there.
#if os(macOS)
targets += [
    .executableTarget(
        name: "aimonitor-menubar",
        dependencies: ["AIMonitorCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "aimonitor-app",
        dependencies: ["AIMonitorCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]
#endif

let package = Package(
    name: "AIMonitor",
    platforms: [.macOS(.v14)],
    targets: targets
)
