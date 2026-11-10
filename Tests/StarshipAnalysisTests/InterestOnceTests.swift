@testable import StarshipAnalysis
@testable import StarshipCore
import StarshipSearch
import XCTest

/// The Players search (RulesState) and Recommended signings and Bargains (GameChecks) keep their own answers, but a
/// player one of them has checked costs FM's rule nothing when the other asks.
final class InterestOnceTests: XCTestCase {
    /// Answers through InterestAnswers as RulesEngine does, and counts the times FM's rule would run.
    private final class Engine: GameRulesEngine {
        private let answers = InterestAnswers()
        var asked = 0
        var failuresLeft = 0

        var supportsInjuryDays: Bool { false }
        func interest(player: Player, team: Int64) -> (transfer: JoinInterest, loan: JoinInterest)? {
            answers.answer(player: player.block, team: team) {
                asked += 1
                if failuresLeft > 0 {
                    failuresLeft -= 1
                    return nil
                }
                return (.persuadable, .notInterested)
            }
        }
        func staffInterest(staff: Staff, team: Int64, level: Int) -> Bool? { nil }
        func preferredJob(staff: Staff) -> Int? { nil }
        func jobPreferences(staff: Staff) -> [UInt8]? { nil }
        func roleRows(player: Player, team: Int64) -> [RoleRow]? { nil }
        func seasonStats(player: Player, season: Int) -> SeasonStats? { nil }
        func form(player: Player) -> String? { nil }
        func injuryReturnDays(player: Player) -> Int? { nil }
    }

    private var savedClub = ""

    override func setUp() {
        super.setUp()
        savedClub = Settings.current.interestClub
    }

    override func tearDown() {
        GameRules.engine = nil
        Settings.current.interestClub = savedClub
        super.tearDown()
    }

    private func start(_ engine: Engine) -> (RulesState, GameChecks) {
        GameRules.engine = engine
        let db = Database()
        db.humanClubs = [(team: 1, name: "Molde", manager: 0)]
        let rules = RulesState()
        rules.fill(db)
        XCTAssertEqual(rules.team, 1)
        return (rules, GameChecks(club: ChosenClub(team: 1, name: "Molde")))
    }

    private func player(_ index: UInt32) -> Player {
        let player = Player()
        player.index = index
        player.block = 0x1000 + Int64(index) * 0x400
        return player
    }

    func testTheSearchThenTheSigningsAskOnce() {
        let engine = Engine()
        let (rules, checks) = start(engine)
        let player = player(7)
        XCTAssertEqual(rules.check(player)?.transfer, true)
        XCTAssertEqual(checks.check(player)?.transferInterest, .persuadable)
        XCTAssertEqual(checks.text(player), "Transfer")
        XCTAssertEqual(engine.asked, 1)
    }

    func testTheSigningsThenTheSearchAskOnce() {
        let engine = Engine()
        let (rules, checks) = start(engine)
        let player = player(8)
        XCTAssertEqual(checks.check(player)?.loan, false)
        XCTAssertEqual(rules.check(player)?.loan, false)
        XCTAssertEqual(rules.text(player), "Transfer")
        XCTAssertEqual(engine.asked, 1)
    }

    /// RulesState tries twice when FM is busy. The answer that finally came is the one the others get.
    func testAFailedAskIsTriedAgain() {
        let engine = Engine()
        engine.failuresLeft = 1
        let (rules, checks) = start(engine)
        let player = player(9)
        XCTAssertEqual(rules.check(player)?.transfer, true)
        XCTAssertEqual(checks.check(player)?.transfer, true)
        XCTAssertEqual(engine.asked, 2)
    }

    func testEachPlayerIsAskedSeparately() {
        let engine = Engine()
        let (rules, checks) = start(engine)
        let players = (10..<15).map(player)
        for player in players { _ = rules.check(player) }
        for player in players { _ = checks.check(player) }
        XCTAssertEqual(engine.asked, players.count)
    }
}
