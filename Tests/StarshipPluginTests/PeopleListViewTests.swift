@testable import StarshipPlugin
import StarshipAnalysis
import StarshipCore
import XCTest

/// The in-game Players and Staff screens show what the app's search found, which needs no game.
@MainActor
final class PeopleListViewTests: XCTestCase {
    private func players(_ count: Int) -> [Person] {
        (0..<count).map { index in
            let player = Player()
            player.uid = UInt32(index + 1)
            player.commonName = "Player \(index + 1)"
            player.ca = 150 - index % 50
            player.pa = 160
            return player
        }
    }

    func testFMsTableGetsTheFirstFewHundredInTheSearchsOrder() {
        let list = PeopleListView(people: players(1_200), staff: false, filter: "", display: DisplayOptions(reveal: .numbers, showHidden: true))
        XCTAssertEqual(list.table.rows.count, PeopleListView.limit)
        XCTAssertEqual(list.table.rows.first?.cells[0], "Player 1")
        XCTAssertEqual(list.found, 1_200)
        XCTAssertTrue(list.count.hasPrefix("The first \(PeopleListView.limit.formatted()) of \(1_200.formatted()) players found"))
    }

    func testAShortListSaysHowManyWereFound() {
        let list = PeopleListView(people: players(1), staff: false, filter: "", display: DisplayOptions(reveal: .numbers, showHidden: true))
        XCTAssertEqual(list.count, "1 player found.")
    }

    func testStaffHaveTheirOwnCAAndPA() {
        let staff = Staff()
        staff.commonName = "Coach"
        staff.ca = 130
        staff.pa = 140
        let list = PeopleListView(people: [staff], staff: true, filter: "Coaching staff", display: DisplayOptions(reveal: .numbers, showHidden: true))
        XCTAssertEqual(list.table.rows[0].cells, ["Coach", "130", "140"])
        XCTAssertEqual(list.title, "Staff")
    }

    func testWithCAAndPAOffFMsTableGetsNoneOfThem() {
        let list = PeopleListView(people: players(3), staff: false, filter: "", display: DisplayOptions(reveal: .hidden, showHidden: false))
        XCTAssertEqual(list.table.columns.map(\.title), ["Name"])
        XCTAssertEqual(FMTable.columns(NativeSearch.playerColumns, with: FMTable.extras(from: list.table, titles: ["CA", "PA"])),
                       NativeSearch.playerColumns)
    }

    func testOurColumnsCopyAHiddenColumnOfFMsThatIsntCAOrPA() {
        XCTAssertEqual(FMTable.spare(among: ["name", "hidden-current-ability", "hidden-potential-ability", "hidden-loyalty", "hidden-ambition"]),
                       "hidden-ambition")
        XCTAssertNil(FMTable.spare(among: ["name", "hidden-current-ability"]))
    }
}
