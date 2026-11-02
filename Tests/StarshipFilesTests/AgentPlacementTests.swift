@testable import StarshipCore
import Darwin
import XCTest

/// FM loads a copy of the agent from outside the app, so that replacing the app can't take it away.
final class AgentPlacementTests: XCTestCase {
    private var folder: URL!
    private var agent: URL { folder.appendingPathComponent("app/libStarshipAgent.dylib") }
    private var target: URL { folder.appendingPathComponent("support/FMStarship") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testTheCopyOutlivesTheApp() throws {
        try Data("agent".utf8).write(to: agent)
        let placed = try GameLauncher.placeAgent(agent, in: target)
        try FileManager.default.removeItem(at: agent)
        XCTAssertEqual(try Data(contentsOf: placed), Data("agent".utf8))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: placed.path))
    }

    func testANewVersionReplacesTheOldCopy() throws {
        try Data("old".utf8).write(to: agent)
        _ = try GameLauncher.placeAgent(agent, in: target)
        try Data("new".utf8).write(to: agent)
        XCTAssertEqual(try Data(contentsOf: GameLauncher.placeAgent(agent, in: target)), Data("new".utf8))
    }

    func testTheCopyLeavesTheQuarantineFlagBehind() throws {
        try Data("agent".utf8).write(to: agent)
        let flag = "0081;00000000;Safari;"
        XCTAssertEqual(setxattr(agent.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0), 0)
        let placed = try GameLauncher.placeAgent(agent, in: target)
        XCTAssertEqual(getxattr(placed.path, "com.apple.quarantine", nil, 0, 0, 0), -1)
    }
}
