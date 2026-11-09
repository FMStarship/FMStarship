@testable import StarshipPlugin
import StarshipAnalysis
import StarshipCore
import XCTest

/// The in-game Shortlists screen shows a shortlist file's players as the app does, which needs no game.
@MainActor
final class ShortlistViewTests: XCTestCase {
    private func player(_ uid: UInt32, _ name: String, club: String, ca: Int = 120, pa: Int = 140) -> Player {
        let player = Player()
        player.uid = uid
        player.commonName = name
        player.club = club
        player.clubFull = club
        player.ca = ca
        player.pa = pa
        return player
    }

    private lazy var players: [UInt32: Player] = Dictionary(uniqueKeysWithValues: [
        player(1, "Abel", club: "Brann"), player(2, "Berg", club: "Molde FK"), player(3, "Carr", club: "Viking", ca: 130, pa: 150),
    ].map { ($0.uid, $0) })

    private func view(_ uids: [UInt32], display: DisplayOptions = DisplayOptions()) -> ShortlistView {
        ShortlistView(url: URL(fileURLWithPath: "/tmp/Targets.fmf"), name: "Targets", modified: .distantPast, uids: uids,
                      players: players, club: "Molde FK", display: display)
    }

    func testPlayersComeInTheFilesOrderWithoutYourOwnClubs() {
        let list = view([3, 2, 1, 3])
        XCTAssertEqual(list.table.rows.map { $0.cells[0] }, ["Carr", "Abel"])
        XCTAssertEqual(list.atClub, 1)
        XCTAssertEqual(list.missing, 0)
        XCTAssertEqual(list.table.rows[0].cells, ["Carr", "130", "150"])
    }

    func testPeopleNotInThisSaveAreCountedNotShown() {
        let list = view([1, 9, 8])
        XCTAssertEqual(list.people, 1)
        XCTAssertEqual(list.missing, 2)
        XCTAssertEqual(list.left, "2 aren't in this save. They stay in the file, so the shortlist keeps working in other saves.")
    }

    func testWithCAAndPAOffTheirColumnsAreGone() {
        let list = view([1, 3], display: DisplayOptions(reveal: .hidden))
        XCTAssertEqual(list.table.columns.map(\.title), ["Name"])
        XCTAssertTrue(FMTable.extras(from: list.table, titles: ["CA", "PA"]).isEmpty)
    }

    func testNothingLeftOutSaysNothing() {
        XCTAssertEqual(view([1, 3]).left, "")
        XCTAssertEqual(view([2, 1]).left, "1 already at your club isn't shown. They stay in the file, so the shortlist keeps working in other saves.")
    }
}
