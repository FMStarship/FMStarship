@testable import StarshipCore
import XCTest

/// A stat is whatever the game's code left in a register, and `Int(_:)` crashes the whole app on some of them.
final class SeasonStatTests: XCTestCase {
    func testAStatKeepsItsWholeNumber() {
        XCTAssertEqual(RulesEngine.wholeStat(0), 0)
        XCTAssertEqual(RulesEngine.wholeStat(73.9), 73)
        XCTAssertEqual(RulesEngine.wholeStat(-1.5), -1)
    }

    func testAnAnswerThatIsNotANumberCountsAsNoAnswer() {
        for value in [Double.nan, .infinity, -.infinity, 1e300] {
            XCTAssertNil(RulesEngine.wholeStat(value), "\(value)")
        }
    }
}
