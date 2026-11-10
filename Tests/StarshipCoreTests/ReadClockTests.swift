@testable import StarshipCore
import XCTest

/// The timings a read logs, which need no game.
final class ReadClockTests: XCTestCase {
    func testSaysWhatEachPartAskedOfTheAgent() {
        XCTAssertEqual(ReadClock.describe("sweep", seconds: 12.345, requests: 1_200, bytes: 3 << 29, throughAgent: true),
                       "sweep 12.35 s (1200 round trips, 1536.0 MiB)")
    }

    /// Inside FM there is no agent to count trips to.
    func testOnlyTimesInsideFM() {
        XCTAssertEqual(ReadClock.describe("resolve", seconds: 0.5, requests: 0, bytes: 0, throughAgent: false), "resolve 0.50 s")
    }

    func testLapsFollowOneAnother() throws {
        let game = try XCTUnwrap(GameProcess.inside(imageEndingWith: "/libSystem.B.dylib"))
        let clock = ReadClock(game)
        clock.lap("one")
        clock.lap("two")
        let parts = clock.line.components(separatedBy: "; ")
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].hasPrefix("one "))
        XCTAssertTrue(parts[1].hasPrefix("two "))
        XCTAssertTrue(game.agentTraffic == (0, 0))
    }
}
