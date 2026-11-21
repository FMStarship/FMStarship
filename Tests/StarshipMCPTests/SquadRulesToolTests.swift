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

    /// Only the first note may name registration, to say what the answer isn't.
    private func assertNeverRegistration(_ answer: JSON, file: StaticString = #filePath, line: UInt = #line) {
        var rest = answer
        if case .object(var pairs) = answer, let index = pairs.firstIndex(where: { $0.0 == "notes" }) {
            pairs[index].1 = .array(Array((answer["notes"]?.array ?? []).dropFirst()))
            rest = .object(pairs)
        }
        let result = String(describing: rest)
        for word in ["registered", "legal", "breaking", "breaks"] {
            XCTAssertNil(result.range(of: word, options: .caseInsensitive), "says \(word): \(result)", file: file, line: line)
        }
    }

    /// Which players FM counts isn't known, so each rule is counted for the first team and for the whole club, and stands only
    /// where the two agree.
    func testEachRuleCountedForTheFirstTeamAndTheWholeClub() throws {
        let harness = Harness()
        let answer = try harness.answer("squad_rules")
        XCTAssertEqual(answer["club"], .string(World.club))
        XCTAssertEqual(answer["first_team"], 12)
        XCTAssertEqual(answer["whole_club"], 13)
        XCTAssertEqual(answer["squads"], ["First team", "U19"])
        XCTAssertEqual((answer["competitions"]?.array ?? []).map { $0["competition"] }, ["Mock League"],
                       "the league, and the cup in its fixtures, which has no rules")
        XCTAssertEqual(answer["no_squad_rules"], ["Mock Cup"])

        let league = Self.rules(answer, "Mock League")
        XCTAssertEqual(league.map { $0["text"] }, [
            "squad size: first team 12, whole club 13, of at most 25 (within)",
            "players on a professional or part-time contract: 11 of at most 11 (at the limit)",
            .string("trained in the club's nation up to 21, at the club or elsewhere: at least 3: depends on which players FM "
                    + "counts: first team 2, whole club 3"),
            "not home-grown: 10 of at most 10 (at the limit)",
            "from outside the EU (FM's non-EEC) in a matchday squad: at most 3",
        ])
        XCTAssertEqual(league.map { $0["fm_name"] }, ["max_squad_size", "players_on_pt_or_ft_contract_in_squad",
                                                      "homegrown_players_0_21_from_nation", "non_homegrown_players_in_squad",
                                                      "non_eec_players_in_match_squad"])
        XCTAssertEqual(league.map { $0["standing"] }, ["within", "at the limit", nil, "at the limit", nil],
                       "under the minimum for the first team and at it for the whole club, so no standing")
        XCTAssertEqual(league.map { $0["first_team"] }, [12, 11, 2, 10, nil])
        XCTAssertEqual(league.map { $0["whole_club"] }, [13, 11, 3, 10, nil])
        XCTAssertNil(league[0]["players"], "squad size counts everyone")
        XCTAssertEqual(Self.uids(league[1]), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        XCTAssertEqual(Self.uids(league[2]), [1, 2, 12])
        XCTAssertEqual(league[2]["players"]?.array?.map { $0["squad"] }, ["First team", "First team", "U19"],
                       "each says which count it's in")
        XCTAssertEqual(Self.uids(league[3]).sorted(), [3, 4, 5, 6, 7, 8, 9, 10, 11, 13])
        XCTAssertEqual(league[1]["players"]?.array?.first?["name"], "First 1")
        XCTAssertNil(league[4]["first_team"])
        XCTAssertTrue(league[4]["not_counted"]?.string?.contains("isn't a count of the squad") ?? false)

        XCTAssertEqual(answer["at_or_past_a_limit"], [
            "Mock League, players on a professional or part-time contract: 11 of at most 11 (at the limit)",
            "Mock League, not home-grown: 10 of at most 10 (at the limit)",
        ])
        XCTAssertEqual(answer["depends_on_which_players_fm_counts"], [
            .string("Mock League, trained in the club's nation up to 21, at the club or elsewhere: at least 3: depends on which "
                    + "players FM counts: first team 2, whole club 3"),
        ])
        let notes = (answer["notes"]?.array ?? []).compactMap(\.string)
        XCTAssertTrue(notes.first?.hasPrefix("FM keeps no registration list for this club, so these are the squad as it is, "
                                             + "counted by FM's own rules.") ?? false, "\(notes)")
        XCTAssertTrue(notes.first?.contains("Never tell the user the squad is registered, legal or breaking a rule unless the "
                                            + "standing says so.") ?? false, "\(notes)")

        let asked = try XCTUnwrap(harness.source.squadRules?.asked)
        XCTAssertTrue(asked.allSatisfy { $0.team == World.team && $0.players.sorted() == Array(1...13) },
                      "everyone at the club, asked once, for the club's team")
        assertNeverRegistration(answer)
        XCTAssertEqual(try harness.refusal("squad_rules", ["squad": "all"]), "squad_rules doesn't take squad. It takes club, competition.")
    }

    /// Counts that stand the same way give that standing, with both numbers where they differ; counts that don't give none.
    func testAStandingOnlyWhereTheCountsAgree() {
        func standing(_ direction: SquadRule.Direction, limit: Int, first: Int, whole: Int) -> String? {
            let rule = SquadRule(type: 1, names: ["goalkeepers_in_squad"], limit: limit, direction: direction)
            func players(_ count: Int) -> [Player] { (0..<count).map { World.player(UInt32($0 + 1), name: "P", age: 20, ca: 1, pa: 1) } }
            return Toolbox.standingText(first: SquadRuleCount(rule: rule, players: players(first)),
                                        whole: SquadRuleCount(rule: rule, players: players(whole)))
        }
        XCTAssertEqual(standing(.atMost, limit: 9, first: 9, whole: 9), "at the limit")
        XCTAssertEqual(standing(.atMost, limit: 30, first: 22, whole: 25), "within")
        XCTAssertEqual(standing(.atLeast, limit: 20, first: 22, whole: 45), "within")
        XCTAssertEqual(standing(.atLeast, limit: 16, first: 13, whole: 15), "under the minimum by 3 (first team) or 1 (whole club)")
        XCTAssertEqual(standing(.atMost, limit: 5, first: 7, whole: 7), "over the maximum by 2")
        XCTAssertNil(standing(.atMost, limit: 30, first: 22, whole: 45), "within or over the maximum by 15")
        XCTAssertNil(standing(.atLeast, limit: 16, first: 13, whole: 20), "under the minimum by 3 or within")
        XCTAssertNil(standing(.atMost, limit: 5, first: 5, whole: 13), "at the limit or over it")
        XCTAssertNil(standing(.atMost, limit: 25, first: 22, whole: 25), "within or at the limit")
    }

    /// One competition by name, any FM holds fixtures of, such as one the club could qualify for.
    func testOneCompetitionByName() throws {
        let harness = Harness()
        let answer = try harness.answer("squad_rules", ["competition": "champions"])
        XCTAssertEqual((answer["competitions"]?.array ?? []).map { $0["competition"] }, ["Made-up Champions Cup"])
        let rules = Self.rules(answer, "Made-up Champions Cup")
        XCTAssertEqual(rules.map { $0["text"] }, ["squad size: first team 12, whole club 13, of at most 25 (within)",
                                                  "goalkeepers: 1 of at least 2 (under the minimum by 1)"])
        XCTAssertEqual(answer["at_or_past_a_limit"], ["Made-up Champions Cup, goalkeepers: 1 of at least 2 (under the minimum by 1)"])
        XCTAssertNil(answer["depends_on_which_players_fm_counts"])
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
        XCTAssertTrue(league.allSatisfy { $0["first_team"] == nil && $0["whole_club"] == nil && $0["standing"] == nil
                && $0["players"] == nil && $0["not_counted"] == nil })
        XCTAssertNil(answer["at_or_past_a_limit"])
        XCTAssertNil(answer["depends_on_which_players_fm_counts"])
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
