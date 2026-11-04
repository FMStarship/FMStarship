@testable import StarshipAnalysis
@testable import StarshipCore
import XCTest

/// "Would join" goes down to FM's Doubtful, the widest level its recruitment search offers.
final class JoinInterestTests: XCTestCase {
    private final class Engine: GameRulesEngine {
        var answer: (transfer: JoinInterest, loan: JoinInterest)
        init(_ answer: (transfer: JoinInterest, loan: JoinInterest)) { self.answer = answer }

        var supportsInjuryDays: Bool { false }
        func interest(player: Player, team: Int64) -> (transfer: JoinInterest, loan: JoinInterest)? { answer }
        func staffInterest(staff: Staff, team: Int64, level: Int) -> Bool? { nil }
        func preferredJob(staff: Staff) -> Int? { nil }
        func jobPreferences(staff: Staff) -> [UInt8]? { nil }
        func roleRows(player: Player, team: Int64) -> [RoleRow]? { nil }
        func seasonStats(player: Player, season: Int) -> SeasonStats? { nil }
        func form(player: Player) -> String? { nil }
        func injuryReturnDays(player: Player) -> Int? { nil }
    }

    override func tearDown() {
        GameRules.engine = nil
        super.tearDown()
    }

    func testScoreBandsMatchFM() {
        XCTAssertEqual(JoinInterest(score: 50_000), .interested)
        XCTAssertEqual(JoinInterest(score: 10_000), .interested)
        XCTAssertEqual(JoinInterest(score: 9_999), .persuadable)
        XCTAssertEqual(JoinInterest(score: 5_000), .persuadable)
        XCTAssertEqual(JoinInterest(score: 4_999), .doubtful)
        XCTAssertEqual(JoinInterest(score: 0), .doubtful)
        XCTAssertEqual(JoinInterest(score: -2_000), .doubtful)
        XCTAssertEqual(JoinInterest(score: -2_001), .notInterested)
        XCTAssertEqual(JoinInterest(score: -100_000), .notInterested)
    }

    func testOnlyNotInterestedStaysAway() {
        XCTAssertTrue(JoinInterest.interested.wouldJoin)
        XCTAssertTrue(JoinInterest.persuadable.wouldJoin)
        XCTAssertTrue(JoinInterest.doubtful.wouldJoin)
        XCTAssertFalse(JoinInterest.notInterested.wouldJoin)
    }

    private func check(_ answer: (transfer: JoinInterest, loan: JoinInterest)) -> (JoinAnswer?, String) {
        GameRules.engine = Engine(answer)
        let player = Player()
        player.index = 7
        player.block = 1
        let checks = GameChecks(club: ChosenClub(team: 1, name: "Molde"))
        return (checks.check(player), checks.text(player))
    }

    func testDoubtfulPlayersWouldJoin() {
        let (answer, text) = check((.doubtful, .persuadable))
        XCTAssertEqual(answer?.transfer, true)
        XCTAssertEqual(answer?.loan, true)
        XCTAssertEqual(answer?.transferInterest, .doubtful)
        XCTAssertEqual(text, "Transfer, loan")
    }

    func testNotInterestedPlayersWouldNot() {
        let (answer, text) = check((.notInterested, .doubtful))
        XCTAssertEqual(answer?.transfer, false)
        XCTAssertEqual(answer?.loan, true)
        XCTAssertEqual(text, "Loan")
    }
}
