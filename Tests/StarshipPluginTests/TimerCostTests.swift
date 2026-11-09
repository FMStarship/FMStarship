@testable import FMStarshipUI
import XCTest

/// What the plugin logs once a minute about its timers on FM's main thread.
@MainActor
final class TimerCostTests: XCTestCase {
    func testAverageAndWorstSinceLastAsked() {
        let cost = TimerCost()
        XCTAssertNil(cost.take())
        cost.add(0.001)
        cost.add(0.003)
        XCTAssertEqual(cost.take(), "2 runs, average 2.00 ms, worst 3.00 ms")
        XCTAssertNil(cost.take())
        cost.add(0.0005)
        XCTAssertEqual(cost.take(), "1 runs, average 0.50 ms, worst 0.50 ms")
    }

    func testMeasuresWhatItRuns() {
        let cost = TimerCost()
        var ran = false
        cost.measure { ran = true }
        XCTAssertTrue(ran)
        XCTAssertTrue(cost.take()?.hasPrefix("1 runs") == true)
    }
}
