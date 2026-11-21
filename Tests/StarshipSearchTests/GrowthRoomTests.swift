import StarshipCore
@testable import StarshipSearch
import XCTest

/// Growth room is PA minus CA only while a player can still grow: up to 23 for an outfield player and 27 for a goalkeeper.
final class GrowthRoomTests: XCTestCase {
    private let goalkeeper = 0

    private func player(age: Int, ca: Int = 100, pa: Int = 140, keeper: Bool = false) -> Player {
        let player = Player()
        player.block = 1
        player.age = age
        player.ca = ca
        player.pa = pa
        player.pos[keeper ? goalkeeper : 11] = 20
        return player
    }

    private var growthRoom: Col { Columns.forPlayers().first { $0.name == "Growth room" }! }

    func testAnOutfieldPlayerHasGrowthRoomUpTo23() {
        XCTAssertEqual(growthRoom.get(player(age: 23)), .int(40))
        XCTAssertEqual(growthRoom.cell(player(age: 23), reveal: .exact).text, "40")
        XCTAssertEqual(growthRoom.get(player(age: 24)), .empty)
        XCTAssertEqual(growthRoom.cell(player(age: 24), reveal: .exact).text, "", "Empty, not a dash")
    }

    func testAGoalkeeperHasGrowthRoomUpTo27() {
        XCTAssertEqual(growthRoom.get(player(age: 27, keeper: true)), .int(40))
        XCTAssertEqual(growthRoom.get(player(age: 28, keeper: true)), .empty)
        XCTAssertEqual(growthRoom.cell(player(age: 28, keeper: true), reveal: .exact).text, "")
    }

    func testOnlyANaturalGoalkeeperGetsTheGoalkeepersAge() {
        let accomplished = player(age: 25)
        accomplished.pos[goalkeeper] = 15
        XCTAssertEqual(growthRoom.get(accomplished), .empty)
    }

    func testANaturalGoalkeeperWhoAlsoPlaysOutfieldGetsTheGoalkeepersAge() {
        let both = player(age: 27)
        both.pos[goalkeeper] = 20
        XCTAssertEqual(growthRoom.get(both), .int(40))
        both.age = 28
        XCTAssertEqual(growthRoom.get(both), .empty)
    }

    func testAPlayerWithNoKnownAgeHasNone() {
        XCTAssertEqual(growthRoom.get(player(age: -1)), .empty)
    }

    func testTheOldStillGetNothingWhileAbilityShowsAsStars() {
        XCTAssertEqual(growthRoom.cell(player(age: 30), reveal: .stars).text, "")
        XCTAssertTrue(growthRoom.cell(player(age: 20), reveal: .stars).text.hasSuffix("★"))
    }

    func testSortingPutsTheOldWithTheOtherEmpties() {
        let rows = [player(age: 30, ca: 53, pa: 122), player(age: 20, ca: 100, pa: 110), player(age: 21, ca: 100, pa: 150)]
        let ascending = Columns.sortRows(rows, by: growthRoom, descending: false).map(\.age)
        XCTAssertEqual(ascending, [20, 21, 30], "Empty last going up")
        let descending = Columns.sortRows(rows, by: growthRoom, descending: true).map(\.age)
        XCTAssertEqual(descending, [21, 20, 30], "And last going down too, so highest first doesn't start with blanks")
    }

    func testOtherNumericColumnsStillPutEmptiesFirstGoingDown() throws {
        let height = try XCTUnwrap(Columns.forPlayers().first { $0.name == "Height" })
        let rows = [player(age: 20), player(age: 21), player(age: 22)]
        rows[0].height = 180
        rows[2].height = 190
        XCTAssertEqual(Columns.sortRows(rows, by: height, descending: true).map(\.age), [21, 22, 20])
        XCTAssertEqual(Columns.sortRows(rows, by: height, descending: false).map(\.age), [20, 22, 21])
    }

    func testAFilterOnGrowthRoomLeavesTheOldOut() throws {
        let filter = try XCTUnwrap(ColumnFilter.parse("0-200", numeric: true))
        XCTAssertTrue(ColumnFilter.matchesAll([(growthRoom, filter)], player(age: 23)))
        XCTAssertFalse(ColumnFilter.matchesAll([(growthRoom, filter)], player(age: 24)))
        XCTAssertTrue(ColumnFilter.matchesAll([(growthRoom, filter)], player(age: 27, keeper: true)))
        XCTAssertFalse(ColumnFilter.matchesAll([(growthRoom, filter)], player(age: 28, keeper: true)))
    }
}
