@testable import StarshipAnalysis
import StarshipCore
import XCTest

/// A search for a position means players whose position it is, not everyone who could fill in there.
final class NaturalPositionTests: XCTestCase {
    private static let club = "Testing FC"
    private let rightBack = Names.positions.firstIndex(of: "DR")!

    private func player(_ uid: UInt32, rating: UInt8, ca: Int, at club: String = "Elsewhere") -> Player {
        let player = Player()
        player.uid = uid
        player.index = uid
        player.block = 1
        player.club = club
        player.clubFull = club
        player.age = 24
        player.ca = ca
        player.pa = ca + 5
        player.value = 100_000
        player.wage = 1000
        player.pos = [UInt8](repeating: 1, count: 15)
        player.pos[rightBack] = rating
        player.pos[0] = 20
        return player
    }

    private func session(_ players: [Player]) -> AnalysisSession {
        let db = Database()
        db.players = players
        db.gameDate = GameDate.checked(year: 2026, dayOfYear: 270)
        return AnalysisSession(db: db, club: ChosenClub(team: 1, name: Self.club), display: DisplayOptions(reveal: .numbers, showHidden: false))
    }

    /// One of each: two naturals, and two who can only fill in.
    private var market: [Player] {
        [player(1, rating: 20, ca: 150), player(2, rating: 18, ca: 140), player(3, rating: 17, ca: 170), player(4, rating: 15, ca: 160)]
    }

    func testRatingsFromEighteenAreNatural() {
        XCTAssertTrue(player(1, rating: 20, ca: 100).isNatural(at: rightBack))
        XCTAssertTrue(player(1, rating: 18, ca: 100).isNatural(at: rightBack))
        XCTAssertFalse(player(1, rating: 17, ca: 100).isNatural(at: rightBack))
    }

    func testSigningsForAPositionAreNaturalsThere() {
        let table = SigningRecommender(session: session(market)).find(RecommendOptions(position: rightBack, upgradesOnly: false))
        XCTAssertEqual(table?.people.map(\.uid), [1, 2])
    }

    func testBargainsForAPositionAreNaturalsThere() {
        let free = market
        free.forEach { $0.club = ""; $0.clubFull = "" }
        let table = BargainFinder(session: session(free)).find(BargainOptions(kind: .free, position: rightBack))
        XCTAssertEqual(table?.people.map(\.uid), [1, 2])
    }

    func testThePlannerOnlySuggestsNaturals() throws {
        let squad = (10...12).map { player($0, rating: 20, ca: 60, at: Self.club) }
        let session = session(squad + market)
        let line = try XCTUnwrap(SquadPlanner.analyse(session).first { $0.group.positions.contains(rightBack) })
        let picks = SquadPlanner.suggest(session, lines: [line], budget: 100_000_000, wages: 100_000, includeLoans: false).picks
        XCTAssertEqual(picks.map(\.player.uid), [1, 2])
    }

    /// A left back who can fill in at right back isn't the right back a signing has to beat.
    func testYourBestIsYourBestNatural() {
        let filler = player(10, rating: 16, ca: 124, at: Self.club)
        let natural = player(11, rating: 19, ca: 118, at: Self.club)
        let signing = player(12, rating: 20, ca: 120)
        let recommender = SigningRecommender(session: session([filler, natural, signing]))
        XCTAssertEqual(recommender.bestAt[rightBack], 118)
        let table = recommender.find(RecommendOptions(position: rightBack, upgradesOnly: true))
        XCTAssertEqual(table?.people.map(\.uid), [12])
    }
}
