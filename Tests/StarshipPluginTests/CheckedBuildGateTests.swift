import StarshipCore
@testable import StarshipPlugin
import XCTest

/// What the plugin's start does with the gate's answer: on a build nobody has checked it starts nothing and tells the app
/// through the status file; once it runs, the file goes. These use a temporary home, never the real Application Support.
final class CheckedBuildGateTests: XCTestCase {
    private let checked = FMBuild(version: "27.0.1.2494769", gameAssembly: "94BE5439-0807-3A78-8C32-E1F12FE5E7BB")
    private let unchecked = FMBuild(version: "27.0.2.2500000", gameAssembly: "0D1E2F3A-0000-0000-0000-000000000000")
    private var home: URL!
    private var status: URL { PluginStatus.file(home: home) }
    private var lines: [String] = []

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("CheckedBuildGateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: status.deletingLastPathComponent(), withIntermediateDirectories: true)
        lines = []
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    private func allows(_ build: FMBuild?, developer: Bool) -> Bool {
        PluginStartGate.allows(build, developer: developer, home: home, pid: 42) { self.lines.append($0) }
    }

    func testAnUncheckedBuildStartsNothingWritesOneLineAndTellsTheApp() throws {
        XCTAssertFalse(allows(unchecked, developer: false))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("27.0.2.2500000 0D1E2F3A-0000-0000-0000-000000000000"), lines[0])
        XCTAssertTrue(lines[0].contains("stays out of FM"), lines[0])
        let written = try XCTUnwrap(PluginStatus.read(from: status))
        XCTAssertEqual(written.plugin, "off")
        XCTAssertEqual(written.reason, PluginStatus.uncheckedBuild)
        XCTAssertEqual(written.fm, "27.0.2.2500000")
        XCTAssertEqual(written.build, unchecked, "The whole key the gate went by")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: written.at))
    }

    func testABuildThatCouldntBeReadStaysOutAndSaysSo() throws {
        XCTAssertFalse(allows(nil, developer: false))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("couldn't be read"), lines[0])
        XCTAssertFalse(lines[0].contains("nobody has checked"), lines[0])
        let written = try XCTUnwrap(PluginStatus.read(from: status))
        XCTAssertEqual(written.reason, PluginStatus.unreadableBuild)
        XCTAssertNil(written.build)
    }

    func testACheckedBuildStartsAndClearsTheStatus() throws {
        try PluginStatus(reason: PluginStatus.crashLoop, detail: "Left by the launcher.", at: "2026-11-11T12:00:00Z", fm: checked.version)
            .write(to: status)
        XCTAssertTrue(allows(checked, developer: false))
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: status.path))
    }

    func testADeveloperBuildStartsOnAnUncheckedBuildAndSaysSo() throws {
        try PluginStatus.keptOut(unchecked).write(to: status)
        XCTAssertTrue(allows(unchecked, developer: true))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("isn't checked"), lines[0])
        XCTAssertTrue(lines[0].contains("developer"), lines[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: status.path))
    }

    func testWithNowhereToWriteItStillStaysOut() throws {
        try FileManager.default.removeItem(at: status.deletingLastPathComponent())
        XCTAssertFalse(allows(unchecked, developer: false))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("couldn't be told"), lines[0])
    }
}
