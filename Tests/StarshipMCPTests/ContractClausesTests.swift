import StarshipCore
@testable import StarshipMCP
import XCTest

/// A player's clauses for goals in the season in his contract, each with his league goals this season and whether they've
/// reached it, and how many other clauses FM Starship doesn't know.
final class ContractClausesTests: XCTestCase {
    override func tearDown() {
        GameRules.engine = nil
        super.tearDown()
    }

    private func player(_ harness: Harness, _ uid: UInt32 = 9) throws -> Player {
        try XCTUnwrap(harness.source.database.players.first { $0.uid == uid })
    }

    func testClausesForGoalsInTheSeasonWithHisLeagueGoals() throws {
        let harness = Harness()
        let striker = try player(harness)
        striker.seasonGoalClauses = [SeasonGoalsClause(goals: 10, amount: 5_577), SeasonGoalsClause(goals: 1, amount: 22_310)]
        striker.unknownClauses = 3
        // One league goal this season.
        (harness.source.engine as? FakeEngine)?.goalSinceRead = true
        let contract = try XCTUnwrap(harness.answer("person", ["uid": 9])["Contract"])
        XCTAssertNotNil(contract["Wage"], "with the rest of his contract")
        let clauses = try XCTUnwrap(contract["Clauses for goals in the season"]?.array)
        XCTAssertEqual(clauses.map { $0["goals"] }, [1, 10], "fewest goals first")
        XCTAssertEqual(clauses.map { $0["sum"] }, ["£22.3K", "£5.5K"])
        XCTAssertEqual(clauses.map { $0["league_goals"] }, [1, 1])
        XCTAssertEqual(clauses.map { $0["reached"] }, [true, false])
        let note = contract["Clauses note"]?.string ?? ""
        XCTAssertTrue(note.contains("goals in Europe didn't count") && note.contains("whether cup goals count isn't known"), note)
        XCTAssertTrue(note.contains("whether it pays again next season isn't known"), note)
        XCTAssertEqual(contract["Other clauses"], "3 clauses FM Starship doesn't know the code of, so they aren't given")
    }

    /// No league goals where they can't be known: FM's stats off or not answering, or a loanee, whose stats are his loan club's.
    func testNoLeagueGoalsWhereTheyCantBeKnown() throws {
        for (harness, why) in [(Harness(engine: nil), "FM's stats didn't answer"), (Harness(), "on loan")] {
            let striker = try player(harness)
            striker.seasonGoalClauses = [SeasonGoalsClause(goals: 10, amount: 5_577)]
            if why == "on loan" { striker.loanClubFull = World.rivals }
            let contract = try XCTUnwrap(harness.answer("person", ["uid": 9])["Contract"])
            let clause = try XCTUnwrap(contract["Clauses for goals in the season"]?.array?.first)
            XCTAssertEqual(clause["goals"], 10)
            XCTAssertEqual(clause["league_goals"], "not available", why)
            XCTAssertNil(clause["reached"], why)
            XCTAssertTrue(contract["Clauses note"]?.string?.contains(why) ?? false, why)
            XCTAssertNil(contract["Other clauses"])
        }
    }

    /// A contract with neither says nothing about clauses, and one other clause is one.
    func testNothingWithoutClauses() throws {
        let harness = Harness()
        XCTAssertNil(try harness.answer("person", ["uid": 9])["Contract"]?["Clauses note"])
        try player(harness).unknownClauses = 1
        let contract = try XCTUnwrap(harness.answer("person", ["uid": 9])["Contract"])
        XCTAssertNil(contract["Clauses for goals in the season"])
        XCTAssertEqual(contract["Other clauses"], "1 clause FM Starship doesn't know the code of, so it isn't given")
    }

    /// Contract clauses aren't hidden in FM, so they're given with Hidden attributes off, and nothing hidden comes with them.
    func testGivenWithHiddenAttributesOff() throws {
        let harness = Harness(hidden: false)
        try player(harness).seasonGoalClauses = [SeasonGoalsClause(goals: 10, amount: 5_577)]
        let answer = try harness.answer("person", ["uid": 9])
        XCTAssertNotNil(answer["Contract"]?["Clauses for goals in the season"])
        XCTAssertNil(answer["Hidden"])
        XCTAssertNil(answer["Ability"])
        let text = try XCTUnwrap(harness.toolbox.call("person", arguments: ["uid": 9])).text
        XCTAssertNil(text.range(of: World.hiddenNumbers, options: .regularExpression), text)
    }
}
