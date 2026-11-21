@testable import StarshipAnalysis
import StarshipCore
import XCTest

/// The Wonderkids list's Room to grow agrees with the lists' Growth room: blank once a player is too old to grow.
final class WonderkidGrowthTests: XCTestCase {
    private func player(_ uid: UInt32, age: Int, keeper: Bool = false) -> Player {
        let player = Player()
        player.uid = uid
        player.block = 1
        player.club = "Rivals FC"
        player.clubFull = "Rivals FC"
        player.age = age
        player.ca = 100
        player.pa = 100 + Int(uid)
        player.value = 1_000_000
        player.pos[keeper ? 0 : 11] = 20
        return player
    }

    func testRoomToGrowIsBlankPastTheAgeAPlayerStopsGrowing() throws {
        let db = Database()
        db.players = [player(1, age: 23), player(2, age: 24), player(3, age: 27, keeper: true), player(4, age: 28, keeper: true)]
        db.gameDate = GameDate.checked(year: 2026, dayOfYear: 270)
        let session = AnalysisSession(db: db, club: ChosenClub(team: 1, name: "Testing FC"),
                                      display: DisplayOptions(reveal: .numbers, showHidden: true))
        let finder = BargainFinder(session: session)
        let table = try XCTUnwrap(finder.find(BargainOptions(kind: .wonderkid, maxAge: "30", onlyJoin: false)))
        let column = try XCTUnwrap(table.columns.firstIndex { $0.title == "Room to grow" })
        var room: [UInt32: String] = [:]
        var key: [UInt32: SortKey] = [:]
        for row in table.rows {
            let uid = try XCTUnwrap(row.person).uid
            room[uid] = row.cells[column]
            key[uid] = row.sortKeys[column]
        }
        XCTAssertEqual(room, [1: "+1", 2: "", 3: "+3", 4: ""])
        XCTAssertEqual(key[1], .number(1))
        XCTAssertEqual(key[3], .number(3))
        XCTAssertTrue(key[1]! < key[2]!, "Blanks sort after every number going up")
        XCTAssertTrue(key[3]! < key[4]!)
    }

    func testRoomToGrowIsInStarsWhenAbilityIsInStars() throws {
        let db = Database()
        db.players = [player(40, age: 20), player(2, age: 24)]
        db.gameDate = GameDate.checked(year: 2026, dayOfYear: 270)
        let session = AnalysisSession(db: db, club: ChosenClub(team: 1, name: "Testing FC"),
                                      display: DisplayOptions(reveal: .stars, showHidden: true))
        let table = try XCTUnwrap(BargainFinder(session: session).find(BargainOptions(kind: .wonderkid, maxAge: "30", onlyJoin: false)))
        let column = try XCTUnwrap(table.columns.firstIndex { $0.title == "Room to grow" })
        var room: [UInt32: String] = [:]
        for row in table.rows { room[try XCTUnwrap(row.person).uid] = row.cells[column] }
        XCTAssertEqual(room, [40: "1.0★", 2: ""], "As the Growth room column shows it")
    }
}
