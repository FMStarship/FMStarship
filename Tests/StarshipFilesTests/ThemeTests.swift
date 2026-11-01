@testable import StarshipFiles
import XCTest

final class ThemeTests: XCTestCase {
    func testNothingChosenMeansTheDefaultPalette() {
        XCTAssertEqual(Theme.named("").name, "Starship")
        XCTAssertEqual(Theme.named(nil).name, "Starship")
        XCTAssertEqual(Theme.named("No such theme").name, "Starship")
    }

    func testAWarningLooksLikeOneOnEveryPalette() {
        for palette in Theme.all {
            XCTAssertTrue(palette.warning.isWarm, "\(palette.name): \(palette.warning.css)")
        }
    }
}
