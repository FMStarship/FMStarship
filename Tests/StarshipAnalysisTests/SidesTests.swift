@testable import StarshipAnalysis
@testable import StarshipCore
import XCTest

/// Men's clubs only sign men and women's clubs only women, which FM's join rules won't say for us.
final class SidesTests: XCTestCase {
    private func player(_ uid: UInt32, at club: String, woman: Bool = false, ca: Int = 150) -> Player {
        let player = Player()
        player.uid = uid
        player.index = uid
        player.block = 1
        player.club = club
        player.clubFull = club
        player.clubObject = club.isEmpty ? 0 : (club == "Women's FC" ? 2 : 1)
        player.isWoman = woman
        player.squad = "First team"
        player.age = 24
        player.ca = ca
        player.pa = ca + 10
        player.value = 100_000
        player.wage = 1000
        player.endYear = 2027
        player.endDay = 100
        for position in player.pos.indices { player.pos[position] = 20 }
        return player
    }

    private func session(womensClub: Bool) -> AnalysisSession {
        let home = womensClub ? "Women's FC" : "Men's FC"
        let squad = (1...12).map { player(UInt32($0), at: home, woman: womensClub, ca: 100) }
        let db = Database()
        db.players = squad + [
            player(21, at: "Men's United"), player(22, at: "Women's United", woman: true),
            player(23, at: ""), player(24, at: "", woman: true),
        ]
        db.knowsSides = true
        db.gameDate = GameDate.checked(year: 2026, dayOfYear: 270)
        if womensClub { db.womensTeams = [1] }
        return AnalysisSession(db: db, club: ChosenClub(team: 1, name: home), display: DisplayOptions(reveal: .numbers, showHidden: false))
    }

    func testEachClubOnlySignsItsOwnSide() {
        let mens = session(womensClub: false), womens = session(womensClub: true)
        XCTAssertTrue(mens.canSign(mens.db.players[12]))
        XCTAssertFalse(mens.canSign(mens.db.players[13]))
        XCTAssertFalse(womens.canSign(womens.db.players[12]))
        XCTAssertTrue(womens.canSign(womens.db.players[13]))
    }

    func testSigningsOnlyComeFromTheClubsOwnSide() {
        func found(_ session: AnalysisSession) -> Set<UInt32> {
            let table = SigningRecommender(session: session).find(RecommendOptions(), status: { _ in })
            return Set(table?.people.map(\.uid) ?? [])
        }
        XCTAssertEqual(found(session(womensClub: false)), [21, 23])
        XCTAssertEqual(found(session(womensClub: true)), [22, 24])
    }

    func testPeopleAndClubsMustAgreeBeforeTheFlagsAreBelieved() {
        let men = (1...2000).map { player(UInt32($0), at: "Men's FC") }
        let women = (1...10).map { player(UInt32(3000 + $0), at: "Women's FC", woman: true) }
        XCTAssertTrue(GameReader.sidesAgree(men + women, womensClubs: [2]))
        // One odd record is not a moved offset.
        let odd = player(5000, at: "Men's FC", woman: true)
        XCTAssertTrue(GameReader.sidesAgree(men + women + [odd], womensClubs: [2]))
        // Women all over the men's clubs is.
        let mixed = men.enumerated().map { $0.offset % 5 == 0 ? player($0.element.uid, at: "Men's FC", woman: true) : $0.element }
        XCTAssertFalse(GameReader.sidesAgree(mixed + women, womensClubs: [2]))
        // A free agent proves nothing either way.
        XCTAssertTrue(GameReader.sidesAgree(men + [player(6000, at: "", woman: true)], womensClubs: [2]))
    }
}
