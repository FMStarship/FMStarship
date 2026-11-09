import StarshipSearch
import XCTest

/// Money is cut off the way FM shows it, not rounded.
final class MoneyTextTests: XCTestCase {
    private let kroner = DisplayCurrency(name: "Norwegian Krone", symbol: "Kr ", perPound: 12.583678245544434)

    override func tearDown() {
        Units.money = Units.pound
        Units.wages = .week
    }

    /// Molde on a real save: FM showed Available Kr 9.01M and Spent This Season Kr 95.84M for these pounds.
    func testMillionsMatchFM() {
        Units.money = kroner
        XCTAssertEqual(Units.moneyText(716_735), "Kr 9.01M")
        XCTAssertEqual(Units.moneyText(7_616_856), "Kr 95.84M")
    }

    func testWagesAreCutOffToo() {
        Units.money = kroner
        XCTAssertEqual(Units.wageText(51_321, withSuffix: true), "Kr 645,806 p/w")
        XCTAssertEqual(Units.wageText(1, withSuffix: false), "Kr 12")
    }

    func testAnExactFigureKeepsItsLastDigit() {
        XCTAssertEqual(Units.moneyText(9_010_000), "£9.01M")
        XCTAssertEqual(Units.moneyText(1_500), "£1.5K")
    }
}
