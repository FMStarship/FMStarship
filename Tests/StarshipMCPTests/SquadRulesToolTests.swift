import StarshipCore
@testable import StarshipMCP
import XCTest

/// Each competition's squad rules, counted against the user's squad by FM's own values, with who counts toward each and
/// where the squad is at a limit. It's never a registration list, so it never says who is registered or calls a squad legal.
final class SquadRulesToolTests: XCTestCase {
    override func tearDown() {
        GameRules.engine = nil
        super.tearDown()
    }

    private static func rules(_ answer: JSON, _ competition: String) -> [JSON] {
        (answer["competitions"]?.array ?? []).first { $0["competition"]?.string == competition }?["rules"]?.array ?? []
    }

    private static func uids(_ rule: JSON) -> [Int] { (rule["players"]?.array ?? []).compactMap { $0["uid"]?.int } }

    private func assertNeverRegistration(_ result: String, file: StaticString = #filePath, line: UInt = #line) {
        for word in ["registered", "legal"] {
            XCTAssertNil(result.range(of: word, options: .caseInsensitive), "says \(word): \(result)", file: file, line: line)
        }
    }

    func testTheFirstTeamCountedAgainstEachOfItsCompetitions() throws {
        let harness = Harness()
        let answer = try harness.answer("squad_rules")
        XCTAssertEqual(answer["club"], .string(World.club))
        XCTAssertEqual(answer["counted"], "First team")
        XCTAssertEqual(answer["squads"], ["First team", "U19"])
        XCTAssertEqual(answer["players"], 12)
        XCTAssertEqual((answer["competitions"]?.array ?? []).map { $0["competition"] }, ["Mock League"],
                       "the league, and the cup in its fixtures, which has no rules")
        XCTAssertEqual(answer["no_squad_rules"], ["Mock Cup"])

        let league = Self.rules(answer, "Mock League")
        XCTAssertEqual(league.map { $0["text"] }, [
            "squad size: 12 of at most 25 (within)",
            "players on a professional or part-time contract: 11 of at most 11 (at the limit)",
            "trained in the club's nation up to 21, at the club or elsewhere: 2 of at least 3 (under the minimum by 1)",
            "not home-grown: 10 of at most 10 (at the limit)",
            "from outside the EU (FM's non-EEC) in a matchday squad: at most 3",
        ])
        XCTAssertEqual(league.map { $0["fm_name"] }, ["max_squad_size", "players_on_pt_or_ft_contract_in_squad",
                                                      "homegrown_players_0_21_from_nation", "non_homegrown_players_in_squad",
                                                      "non_eec_players_in_match_squad"])
        XCTAssertEqual(league.map { $0["standing"] }, ["within", "at the limit", "under the minimum by 1", "at the limit", nil])
        XCTAssertNil(league[0]["players"], "squad size counts everyone")
        XCTAssertEqual(Self.uids(league[1]), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        XCTAssertEqual(Self.uids(league[2]), [1, 2])
        XCTAssertEqual(Self.uids(league[3]).sorted(), [3, 4, 5, 6, 7, 8, 9, 10, 11, 13])
        XCTAssertEqual(league[1]["players"]?.array?.first?["name"], "First 1")
        XCTAssertNil(league[4]["count"])
        XCTAssertTrue(league[4]["not_counted"]?.string?.contains("isn't a count of the squad") ?? false)

        XCTAssertEqual(answer["at_or_past_a_limit"], [
            "Mock League, players on a professional or part-time contract: 11 of at most 11 (at the limit)",
            "Mock League, trained in the club's nation up to 21, at the club or elsewhere: 2 of at least 3 (under the minimum by 1)",
            "Mock League, not home-grown: 10 of at most 10 (at the limit)",
        ])
        let notes = (answer["notes"]?.array ?? []).compactMap(\.string)
        XCTAssertTrue(notes.contains { $0.contains("not a registration list") }, "\(notes)")
        XCTAssertTrue(notes.contains { $0.contains("Only the First team is counted") }, "\(notes)")

        let asked = try XCTUnwrap(harness.source.squadRules?.asked)
        XCTAssertTrue(asked.allSatisfy { $0.team == World.team && !$0.players.contains(12) }, "the first team, for the club's team")
        assertNeverRegistration(try XCTUnwrap(harness.toolbox.call("squad_rules", arguments: [:])).text)
    }

    func testAllCountsEveryoneAtTheClub() throws {
        let harness = Harness()
        let answer = try harness.answer("squad_rules", ["squad": "all"])
        XCTAssertEqual(answer["players"], 13)
        XCTAssertTrue(answer["counted"]?.string?.hasPrefix("all") ?? false)
        let league = Self.rules(answer, "Mock League")
        XCTAssertEqual(league[2]["text"], "trained in the club's nation up to 21, at the club or elsewhere: 3 of at least 3 (at the limit)")
        XCTAssertEqual(Self.uids(league[2]), [1, 2, 12])
        XCTAssertFalse((answer["notes"]?.array ?? []).contains { $0.string?.contains("Only the") ?? false })

        XCTAssertEqual(try harness.answer("squad_rules", ["squad": "u19"])["players"], 1)
        XCTAssertEqual(try harness.refusal("squad_rules", ["squad": "Reserves"]),
                       "\(World.club) has no squad called Reserves. Its squads: First team, U19, or all.")
    }

    /// One competition by name, any FM holds fixtures of, such as one the club could qualify for.
    func testOneCompetitionByName() throws {
        let harness = Harness()
        let answer = try harness.answer("squad_rules", ["competition": "champions"])
        XCTAssertEqual((answer["competitions"]?.array ?? []).map { $0["competition"] }, ["Made-up Champions Cup"])
        let rules = Self.rules(answer, "Made-up Champions Cup")
        XCTAssertEqual(rules.map { $0["text"] }, ["squad size: 12 of at most 25 (within)", "goalkeepers: 1 of at least 2 (under the minimum by 1)"])
        XCTAssertEqual(Self.uids(rules[1]), [1])

        let cup = try harness.answer("squad_rules", ["competition": "mock cup"])
        XCTAssertEqual(cup["competitions"], [])
        XCTAssertEqual(cup["no_squad_rules"], ["Mock Cup"])

        XCTAssertEqual(try harness.refusal("squad_rules", ["competition": "Premier"]),
                       "No competition FM holds fixtures of is called Premier. Name it as FM does, in the game's language.")
        XCTAssertEqual(try harness.refusal("squad_rules", ["competition": "mock"]),
                       "mock could be any of: Mock Cup, Mock League. Name one exactly.")
    }

    /// Without FM's values the rules are given with FM's numbers and no counts, and nothing is said to be at a limit.
    func testWithoutFMsValuesTheRulesComeWithoutCounts() throws {
        let harness = Harness()
        harness.source.squadRules?.countsOff = "its check failed: made up"
        let answer = try harness.answer("squad_rules")
        let league = Self.rules(answer, "Mock League")
        XCTAssertEqual(league.map { $0["text"] }.first, "squad size: at most 25")
        XCTAssertTrue(league.allSatisfy { $0["count"] == nil && $0["players"] == nil && $0["not_counted"] == nil })
        XCTAssertNil(answer["at_or_past_a_limit"])
        XCTAssertTrue((answer["notes"]?.array ?? []).contains { $0.string?.contains("given without counts: its check failed: made up") ?? false })
        XCTAssertEqual(try harness.answer("game_status")["squad_rules"], "on, without counts: its check failed: made up")
    }

    func testARuleSetThatCouldntBeReadIsSaidSo() throws {
        let harness = Harness()
        harness.source.squadRules?.sets[World.leagueIndex]?.unreadable = "its rule set wasn't where FM keeps it"
        let answer = try harness.answer("squad_rules")
        let league = (answer["competitions"]?.array ?? []).first
        XCTAssertEqual(league?["competition"], "Mock League")
        XCTAssertEqual(league?["note"], "Its squad rules couldn't be read: its rule set wasn't where FM keeps it. So they're left out.")
        XCTAssertNil(league?["rules"])
    }

    func testOffOrUnreadableIsRefused() throws {
        let harness = Harness()
        XCTAssertTrue(try harness.answer("game_status")["squad_rules"]?.string?.hasPrefix("on: FM's own rules") ?? false)
        harness.source.squadRules?.off = "made up"
        XCTAssertEqual(try harness.refusal("squad_rules"), "FM's squad rules are off for this read: made up. So they're left out rather "
                       + "than guessed. game_status with refresh reads the save again.")
        XCTAssertEqual(try harness.answer("game_status")["squad_rules"], "off: made up")

        let none = Harness()
        none.source.squadRules = nil
        XCTAssertEqual(try none.refusal("squad_rules"), "FM Starship can't read FM's squad rules on this build of FM.")
        XCTAssertEqual(try none.answer("game_status")["squad_rules"], "off: they can't be read from this save")
    }

    /// Without the club's fixtures, only its league, and it says so.
    func testWithoutFixturesOnlyTheLeague() throws {
        let harness = Harness()
        harness.source.matches = nil
        let answer = try harness.answer("squad_rules")
        XCTAssertEqual((answer["competitions"]?.array ?? []).map { $0["competition"] }, ["Mock League"])
        XCTAssertNil(answer["no_squad_rules"])
        XCTAssertTrue((answer["notes"]?.array ?? []).contains { $0.string?.contains("can't read the club's fixtures") ?? false })
    }
}
