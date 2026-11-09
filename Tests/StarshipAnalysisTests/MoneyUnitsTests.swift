@testable import StarshipAnalysis
import XCTest

/// Money in reports is cut off the way FM shows it, not rounded.
final class MoneyUnitsTests: XCTestCase {
    private let kroner = MoneyUnits(symbol: "Kr ", perPound: 12.583678245544434)

    /// Molde on a real save: FM showed Available Kr 9.01M and Spent This Season Kr 95.84M for these pounds.
    func testMillionsMatchFM() {
        XCTAssertEqual(kroner.money(716_735), "Kr 9.01M")
        XCTAssertEqual(kroner.money(7_616_856), "Kr 95.84M")
    }

    func testWagesAreCutOffToo() {
        XCTAssertEqual(kroner.wageText(51_321, suffix: true), "Kr 645,806 p/w")
        XCTAssertEqual(kroner.wageText(1), "Kr 12")
    }

    func testAnExactFigureKeepsItsLastDigit() {
        XCTAssertEqual(MoneyUnits().money(9_010_000), "£9.01M")
    }

    /// The Bargains and staff boxes start from the budget, so they never offer more than there is.
    func testABoxNeverStartsAboveTheBudget() {
        XCTAssertEqual(NetFormat.fixed(9.06, min: 0, max: 1, truncating: true), "9")
        XCTAssertEqual(NetFormat.fixed(9.06, min: 0, max: 1), "9.1")
    }
}
