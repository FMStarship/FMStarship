@testable import FMStarship
import StarshipCore
import XCTest

/// The app tells the player, once, when FM Starship is kept out of FM: from the status file the plugin or its launcher left,
/// or from the installed FM before it's even started. These read status files from a temporary home.
final class PluginNoticeTests: XCTestCase {
    private let checked = FMBuild(version: "27.0.1.2494769", gameAssembly: "94BE5439-0807-3A78-8C32-E1F12FE5E7BB")
    private let unchecked = FMBuild(version: "27.0.2.2500000", gameAssembly: "0D1E2F3A-0000-0000-0000-000000000000")
    private var home: URL!
    private var file: URL { PluginStatus.file(home: home) }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("PluginNoticeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    /// As the launcher writes it, by hand rather than through PluginStatus.
    private func written(_ json: String) throws -> PluginStatus? {
        try Data(json.utf8).write(to: file)
        return PluginStatus.read(from: file)
    }

    func testTheLaunchersCrashLoopIsToldInItsOwnWords() throws {
        let status = try written("""
            {"plugin": "off", "reason": "crash-loop", "detail": "FM closed twice just after starting, so it starts without FM Starship for now.", \
            "at": "2026-11-11T20:15:03Z", "fm": "27.0.1.2494769"}
            """)
        let notice = try XCTUnwrap(PluginNotice.notice(installed: .fromApp(build: "9"), status: status, installedFM: checked))
        XCTAssertEqual(notice.title, "FM Starship stayed out of FM")
        XCTAssertEqual(notice.message, "FM closed twice just after starting, so it starts without FM Starship for now.")
        XCTAssertEqual(notice.key, "crash-loop 2026-11-11T20:15:03Z")
    }

    func testThePluginsUncheckedBuildSaysFMHasUpdated() throws {
        let status = try written("""
            {"plugin":"off","reason":"unchecked-build","detail":"FM has updated.","at":"2026-11-11T20:15:03Z","fm":"27.0.2.2500000"}
            """)
        let notice = try XCTUnwrap(PluginNotice.notice(installed: .fromScript, status: status, installedFM: unchecked))
        XCTAssertEqual(notice.title, "FM has updated")
        XCTAssertTrue(notice.message.contains("27.0.2.2500000"), notice.message)
        XCTAssertTrue(notice.message.contains("comes back with the next FM Starship update"), notice.message)
        XCTAssertEqual(notice.key, "unchecked-build 27.0.2.2500000")
    }

    func testTheInstalledFMIsCheckedBeforeFMStarts() throws {
        XCTAssertNil(PluginStatus.read(from: file))
        let notice = try XCTUnwrap(PluginNotice.notice(installed: .fromApp(build: "9"), status: nil, installedFM: unchecked))
        XCTAssertEqual(notice.title, "FM has updated")
        XCTAssertEqual(notice.key, "unchecked-build 27.0.2.2500000", "The same key as the plugin's file, so it's said once")
        XCTAssertNil(PluginNotice.notice(installed: .fromApp(build: "9"), status: nil, installedFM: checked))
        XCTAssertNil(PluginNotice.notice(installed: .fromApp(build: "9"), status: nil, installedFM: nil), "FM not found")
    }

    func testADevelopersOwnBuildIsOnlyToldByWhatItWrites() {
        XCTAssertNil(PluginNotice.notice(installed: .fromScript, status: nil, installedFM: unchecked))
    }

    func testWithoutThePluginThereIsNothingToSay() throws {
        let status = try written(#"{"plugin":"off","reason":"crash-loop","detail":"x","at":"2026-11-11T20:15:03Z","fm":"27.0.1.2494769"}"#)
        XCTAssertNil(PluginNotice.notice(installed: .nothing, status: status, installedFM: unchecked))
    }

    func testAnOldFileIsntToldOnceFMIsOnACheckedBuildAgain() throws {
        let status = try written(#"{"plugin":"off","reason":"unchecked-build","detail":"x","at":"2026-11-11T20:15:03Z","fm":"27.0.2.2500000"}"#)
        XCTAssertNil(PluginNotice.notice(installed: .fromApp(build: "10"), status: status, installedFM: checked,
                                         checked: [checked]))
    }

    func testABrokenFileIsLeftUnread() throws {
        XCTAssertNil(try written("{\"plugin\": \"off\""))
        XCTAssertNil(try written(#"{"plugin":"off","reason":"crash-loop"}"#), "Every field is needed")
    }

    func testEachIsToldOnce() throws {
        let suite = "PluginNoticeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try XCTUnwrap(PluginNotice.notice(installed: .fromApp(build: "9"), status: nil, installedFM: unchecked))
        XCTAssertTrue(PluginNotice.shouldShow(first, defaults: defaults))
        PluginNotice.markShown(first, defaults: defaults)
        XCTAssertFalse(PluginNotice.shouldShow(first, defaults: defaults))
        let next = try XCTUnwrap(PluginNotice.notice(installed: .fromApp(build: "9"), status: nil,
                                                     installedFM: FMBuild(version: "27.0.3.2510000", gameAssembly: unchecked.gameAssembly)))
        XCTAssertTrue(PluginNotice.shouldShow(next, defaults: defaults), "The next build of FM is told again")
    }
}
