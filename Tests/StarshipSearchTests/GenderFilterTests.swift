import StarshipCore
import StarshipSearch
import XCTest

final class GenderFilterTests: XCTestCase {
    private func player(woman: Bool) -> Player {
        let player = Player()
        player.block = 1
        player.isWoman = woman
        return player
    }

    func testTheFilterKeepsOneSideOrBoth() {
        var filter = PlayerFilter(showHidden: true, showAbility: true)
        filter.ratingAtLeast = ""
        XCTAssertTrue(filter.matches(player(woman: false)))
        XCTAssertTrue(filter.matches(player(woman: true)))
        filter.gender = "Men"
        XCTAssertTrue(filter.matches(player(woman: false)))
        XCTAssertFalse(filter.matches(player(woman: true)))
        XCTAssertTrue(filter.describe().contains("Men"))
        filter.gender = "Women"
        XCTAssertFalse(filter.matches(player(woman: false)))
        XCTAssertTrue(filter.matches(player(woman: true)))
        filter.reset()
        XCTAssertEqual(filter.gender, "Any")
    }
}
