import StarshipCore
@testable import StarshipSearch
import XCTest

/// The lists' side of CA and PA being off: no column, no filter, and no order that gives them away.
final class AbilityOffTests: XCTestCase {
    private func player(ca: Int, pa: Int, value: Int64) -> Player {
        let player = Player()
        player.block = 1
        player.ca = ca
        player.pa = pa
        player.value = value
        return player
    }

    func testAbilityColumnsCantBeShownWhileAbilityIsOff() {
        let names = Columns.shown(Columns.forPlayers(), showHidden: true, showAbility: false).map(\.name)
        XCTAssertFalse(names.contains("CA"))
        XCTAssertFalse(names.contains("PA"))
        XCTAssertFalse(Columns.forPlayers().contains { $0.ability && Columns.allowed($0, showHidden: true, showAbility: false) })
        XCTAssertFalse(Columns.forStaff().contains { $0.ability && Columns.allowed($0, showHidden: true, showAbility: false) })
    }

    func testAbilityColumnsShowWhenAbilityIsOn() {
        let names = Columns.shown(Columns.forPlayers(), showHidden: false, showAbility: true).map(\.name)
        XCTAssertTrue(names.contains("CA"))
        XCTAssertTrue(names.contains("PA"))
    }

    func testAnAbilityFilterDoesNothingWhileAbilityIsOff() {
        var filter = PlayerFilter(showHidden: true, showAbility: true)
        filter.caMin = "150"
        filter.paMax = "90"
        let weak = player(ca: 100, pa: 120, value: 1)
        XCTAssertFalse(filter.matches(weak))
        filter.showAbility = false
        XCTAssertTrue(filter.matches(weak))
        XCTAssertFalse(filter.describe().contains("CA"))
        XCTAssertFalse(filter.describe().contains("PA"))
    }

    func testTheAbilitySectionGoesFromTheFilterWindow() {
        var filter = PlayerFilter(showHidden: true, showAbility: true)
        filter.caMin = "150"
        XCTAssertTrue(filter.visibleSections(inTab: "General").contains { $0.title == "Ability" })
        XCTAssertTrue(filter.isActive(tab: "General"))
        filter.showAbility = false
        XCTAssertFalse(filter.visibleSections(inTab: "General").contains { $0.title == "Ability" })
        XCTAssertFalse(filter.isActive(tab: "General"))
    }

    func testAListKeepsItsOrderFromCAOnlyWhileCAIsOn() {
        let rows = [player(ca: 100, pa: 120, value: 9), player(ca: 150, pa: 160, value: 1)]
        XCTAssertEqual(Columns.ordered(players: rows, sortBy: nil, descending: true, byAbility: true).map(\.ca), [150, 100])
        XCTAssertEqual(Columns.ordered(players: rows, sortBy: nil, descending: true, byAbility: false).map(\.value), [9, 1])
    }

    func testNotForSaleDoesntTopAListOrderedByValue() {
        let rows = [player(ca: 100, pa: 120, value: 300_000_000), player(ca: 150, pa: 160, value: 1)]
        XCTAssertEqual(Columns.ordered(players: rows, sortBy: nil, descending: true, byAbility: false).map(\.value), [1, 300_000_000])
    }

    private func layout(ability: Bool, saved: [ColState]?) -> [Col] {
        let all = Columns.forPlayers()
        return Columns.restoreLayout(shown: Columns.shown(all, showHidden: true, showAbility: ability), all: all, saved: saved, restoreWidths: true)
    }

    func testSwitchingAbilityOffAndOnLeavesTheLayoutAlone() {
        let all = Columns.forPlayers()
        let start = Columns.capture(all: all, shown: layout(ability: true, saved: nil), saved: nil)
        let off = Columns.capture(all: all, shown: layout(ability: false, saved: start), saved: start)
        XCTAssertEqual(layout(ability: true, saved: off).map(\.name), layout(ability: true, saved: start).map(\.name))
    }

    func testAColumnMovedWhileAbilityIsOffLeavesCAAndPATogether() throws {
        let all = Columns.forPlayers()
        let start = Columns.capture(all: all, shown: layout(ability: true, saved: nil), saved: nil)
        var moved = layout(ability: false, saved: start)
        moved.insert(moved.remove(at: try XCTUnwrap(moved.firstIndex { $0.name == "Value" })), at: 0)
        let names = layout(ability: true, saved: Columns.capture(all: all, shown: moved, saved: start)).map(\.name)
        XCTAssertEqual(names.first, "Value")
        XCTAssertEqual(names.firstIndex(of: "PA"), names.firstIndex(of: "CA").map { $0 + 1 })
    }

    func testALayoutFirstSavedWhileAbilityIsOffKeepsCAAndPAInPlace() {
        let off = Columns.capture(all: Columns.forPlayers(), shown: layout(ability: false, saved: nil), saved: nil)
        XCTAssertEqual(layout(ability: true, saved: off).map(\.name), layout(ability: true, saved: nil).map(\.name))
    }

    func testNothingInTheStaffRankingNamesCA() {
        XCTAssertFalse(StaffFilter.noRanking.contains("CA"))
        var filter = StaffFilter(showHidden: true)
        filter.rank = StaffFilter.noRanking
        XCTAssertEqual(filter.rankArea, -1)
    }
}
