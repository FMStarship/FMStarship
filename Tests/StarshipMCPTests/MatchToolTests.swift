import StarshipCore
@testable import StarshipMCP
import XCTest

/// fixtures, results, league_table, the next fixture in game_status and the last match in squad, on matches built by hand.
final class MatchToolTests: XCTestCase {
    override func tearDown() {
        GameRules.engine = nil
        super.tearDown()
    }

    private func rows(_ answer: JSON) -> [[String: JSON]] { answer.rowsByName }

    // MARK: Fixtures

    func testFixturesFromTodayOldestFirst() throws {
        let harness = Harness()
        let fixtures = try harness.answer("fixtures")
        XCTAssertEqual(fixtures["club"], .string(World.club))
        XCTAssertEqual(fixtures["from"], "2026-09-27", "today, by the game's date")
        XCTAssertEqual(fixtures["found"], 2)
        XCTAssertEqual(fixtures.columnNames, Toolbox.fixtureColumns)
        let next = try XCTUnwrap(rows(fixtures).first)
        XCTAssertEqual(next["date"], "2026-10-04")
        XCTAssertEqual(next["kick_off"], "20:00")
        XCTAssertEqual(next["competition"], "Mock League")
        XCTAssertEqual(next["round"], 3)
        XCTAssertEqual(next["venue"], "H")
        XCTAssertEqual(next["opponent"], .string(World.otherTown))
        XCTAssertEqual(next["score"], .null)
        let later = try XCTUnwrap(rows(fixtures).last)
        XCTAssertEqual(later["kick_off"], .null, "no time set yet")
        XCTAssertEqual(later["stage"], "kvartfinale", "FM's own words, in the game's language")
        XCTAssertEqual(later["round"], .null)
    }

    /// A scorer or assister who isn't in the read is named by the side the goal is for, with "a" or "an" as it reads.
    func testAnUnnamedScorerSaysWhichSide() throws {
        let harness = Harness()
        let matches = try XCTUnwrap(harness.source.matches)
        var ours = try XCTUnwrap(matches.teams[World.team])
        ours.fixtures[0].goals.append(MatchGoal(scorer: 9_998, assist: 9_997, home: false, minute: 70, addedMinute: 0))
        matches.teams[World.team] = ours
        let first = try XCTUnwrap(rows(try harness.answer("fixtures", ["from": "2026-09-01"])).first)
        XCTAssertEqual(first["opponent_scorers"],
                       .array([.string("70' a \(World.rivals) player FM Starship can't name, assist a \(World.rivals) player FM Starship can't name")]))
    }

    func testPlayedFixturesHaveScoresAndGoals() throws {
        let harness = Harness()
        let fixtures = try harness.answer("fixtures", ["from": "2026-09-01", "to": "2026-09-30"])
        XCTAssertEqual(fixtures["found"], 3)
        let list = rows(fixtures)
        XCTAssertEqual(list[0]["score"], "2-0")
        XCTAssertEqual(list[0]["result"], "W")
        XCTAssertEqual(list[0]["attendance"], 8_500)
        XCTAssertEqual(list[0]["kick_off"], "15:00")
        XCTAssertEqual(list[0]["scorers"], ["23' First 9, assist First 10", "45+1' First 11"])
        XCTAssertEqual(list[0]["opponent_scorers"], .null)
        XCTAssertEqual(list[1]["venue"], "A")
        XCTAssertEqual(list[1]["score"], "1-1", "home team first")
        XCTAssertEqual(list[1]["result"], "D")
        XCTAssertEqual(list[1]["scorers"], ["80' First 9"])
        XCTAssertEqual(list[1]["opponent_scorers"], ["60' an Other Town player FM Starship can't name"])
        XCTAssertEqual(list[2]["score"], "2-4")
        XCTAssertEqual(list[2]["result"], "W")
        XCTAssertEqual(list[2]["aggregate"], .string("\(World.minnows) 3-6 \(World.club)"))

        let one = try harness.answer("fixtures", ["from": "2026-09-01", "limit": 1])
        XCTAssertEqual(one["found"], 5)
        XCTAssertEqual(one["shown"], 1)
        XCTAssertEqual(one["rows"]?.array?.count, 1)
        XCTAssertEqual(try harness.answer("fixtures", ["to": "2026-09-14"])["found"], 1, "to alone starts from the first")
    }

    func testFixturesRefuseBadDates() throws {
        let harness = Harness()
        XCTAssertEqual(try harness.refusal("fixtures", ["from": "27/09/2026"]), "from must be a date, as YYYY-MM-DD.")
        XCTAssertEqual(try harness.refusal("fixtures", ["to": "2026-02-30"]), "to must be a date, as YYYY-MM-DD.")
        XCTAssertEqual(try harness.refusal("fixtures", ["from": "2026-10-01", "to": "2026-09-01"]), "to is before from.")
        XCTAssertTrue(try harness.refusal("fixtures", ["date": "2026-10-01"]).contains("doesn't take date"))
    }

    // MARK: Results

    func testResultsNewestFirst() throws {
        let harness = Harness()
        let results = try harness.answer("results")
        XCTAssertEqual(results["found"], 3)
        XCTAssertFalse(results.columnNames.contains("kick_off"))
        XCTAssertEqual(rows(results).map { $0["date"] }, ["2026-09-23", "2026-09-20", "2026-09-13"])
        let two = try harness.answer("results", ["limit": 2])
        XCTAssertEqual(two["shown"], 2)
        XCTAssertEqual(two["rows"]?.array?.count, 2)
    }

    func testOneResultWithThePlayers() throws {
        let harness = Harness()
        let match = try harness.answer("results", ["date": "2026-09-20"])
        XCTAssertEqual(match["opponent"], .string(World.otherTown))
        XCTAssertEqual(match["score"], "1-1")
        XCTAssertNil(match["kick_off"])
        XCTAssertEqual(match.columnNames, ["uid"] + Toolbox.matchPlayerColumns)
        let players = rows(match)
        XCTAssertEqual(players.count, 11)
        XCTAssertEqual(players.last?["uid"], 11, "the substitution comes last, on fewer minutes")
        XCTAssertEqual(players.last?["Minutes"], 64)
        let keeper = try XCTUnwrap(players.first { $0["uid"] == 1 })
        XCTAssertEqual(keeper["xG"], .null)
        XCTAssertEqual(keeper["Rating"], 6.1)
        let striker = try XCTUnwrap(players.first { $0["uid"] == 9 })
        XCTAssertEqual(striker["Goals"], 1)
        XCTAssertEqual(striker["xG"], 0.45)
        XCTAssertEqual(players.first { $0["uid"] == 4 }?["Yellow cards"], 1)
        XCTAssertEqual(match["unused_substitutes"], ["Young Prospect"])
        let note = try XCTUnwrap(match["note"]?.string)
        XCTAssertTrue(note.contains("Only players at \(World.club) now"), note)
        XCTAssertFalse(note.contains("last 20"), "nobody's record of this match has gone")

        let older = try harness.answer("results", ["date": "2026-09-13"])
        XCTAssertTrue(older["note"]?.string?.contains("last 20 matches for a team, and this match has gone from one player's") ?? false,
                      older.text)

        let none = try harness.refusal("results", ["date": "2026-09-14"])
        XCTAssertTrue(none.contains("no result on 2026-09-14"), none)
        XCTAssertTrue(none.contains("2026-09-23, 2026-09-20, 2026-09-13"), none)
        XCTAssertTrue(try harness.refusal("results", ["date": "2026-10-04"]).contains("no result"), "a fixture still to come has none")
    }

    func testPlayersNeedFMsRules() throws {
        let harness = Harness(engine: nil)
        let match = try harness.answer("results", ["date": "2026-09-20"])
        XCTAssertEqual(match["score"], "1-1")
        XCTAssertTrue(match["players"]?.string?.contains("FM's rules") ?? false)
        XCTAssertNil(match["rows"])
    }

    // MARK: League table

    func testLeagueTable() throws {
        let harness = Harness()
        let table = try harness.answer("league_table")
        XCTAssertEqual(table["competition"], "Mock League")
        XCTAssertEqual(table["position"], 1)
        XCTAssertEqual(table.columnNames, Toolbox.tableColumns)
        let first = try XCTUnwrap(rows(table).first)
        XCTAssertEqual(first["club"], .string(World.club))
        XCTAssertEqual(first["played"], 2)
        XCTAssertEqual(first["goal_difference"], 2)
        XCTAssertEqual(first["points"], 4)
        XCTAssertEqual(first["home"], "P1 W1 D0 L0 2-0 3pts")
        XCTAssertEqual(first["away"], "P1 W0 D1 L0 1-1 1pts")
        XCTAssertEqual(rows(table).last?["goal_difference"], -2)
        XCTAssertEqual(try harness.answer("league_table", ["club": "other town"])["position"], 2)
    }

    // MARK: Other clubs

    func testAnotherClubFromTheLeagueOrTheFixtures() throws {
        let harness = Harness()
        let rivals = try harness.answer("results", ["club": "rivals fc"])
        XCTAssertEqual(rivals["club"], .string(World.rivals))
        XCTAssertEqual(rows(rivals).first?["venue"], "A")
        XCTAssertEqual(rows(rivals).first?["result"], "L")
        XCTAssertEqual(rows(rivals).first?["scorers"], .null)
        XCTAssertEqual(rows(rivals).first?["opponent_scorers"], ["23' First 9, assist First 10", "45+1' First 11"])
        // A cup opponent outside the league, which FM has no table for here.
        XCTAssertTrue(try harness.refusal("results", ["club": .string(World.minnows)]).contains("no league table"))

        let unknown = try harness.refusal("fixtures", ["club": "Other"])
        XCTAssertTrue(unknown.contains("Did you mean: \(World.otherTown)?"), unknown)
        XCTAssertTrue(unknown.contains("the clubs in its league and the clubs it plays"), unknown)
    }

    // MARK: When the matches can't be trusted

    func testAFailedCheckSwitchesThemOff() throws {
        let harness = Harness()
        harness.source.matches?.teams[World.team]?.check = .failed("its league results add up to P2, and the table says P3")
        for tool in ["fixtures", "results", "league_table"] {
            let sentence = try harness.refusal(tool)
            XCTAssertTrue(sentence.hasPrefix("FM Starship's check of \(World.club)'s matches failed: its league results add up"), sentence)
            XCTAssertTrue(sentence.contains("A league with play-offs or a split can do this"), sentence)
            XCTAssertFalse(sentence.contains("build"), "a failed check isn't put down to FM's build")
            XCTAssertTrue(sentence.contains("switched off rather than guessed"), sentence)
        }
        let status = try harness.answer("game_status")
        XCTAssertNil(status["next_fixture"])
        XCTAssertTrue(status["fixtures"]?.string?.hasPrefix("off: ") ?? false)
    }

    func testNothingToCheckAgainstLeavesResultsOut() throws {
        let harness = Harness()
        harness.source.matches?.teams[World.team]?.check = .nothingPlayed
        XCTAssertTrue(try harness.refusal("results").contains("hasn't played a league match yet this season"))
        let fixtures = try harness.answer("fixtures", ["from": "2026-09-01"])
        XCTAssertEqual(rows(fixtures).first?["score"], .null)
        XCTAssertEqual(rows(fixtures).first?["scorers"], .null)
        XCTAssertTrue(fixtures["note"]?.string?.contains("can't check its results") ?? false)
        XCTAssertNotNil(try harness.answer("game_status")["next_fixture"], "dates aren't scores")
        XCTAssertEqual(try harness.answer("league_table")["note"], .string("\(World.club) hasn't played a league match yet this season."))

        harness.source.matches?.teams[World.team]?.check = .noTable
        harness.source.current = false
        XCTAssertTrue(try harness.refusal("results").contains("no league table"))
    }

    func testWithoutMatchesTheToolsSaySo() throws {
        let harness = Harness()
        harness.source.matches?.classesFound = false
        XCTAssertTrue(try harness.refusal("fixtures").contains("keeps its fixtures differently"))
        XCTAssertNil(try harness.answer("game_status")["next_fixture"])

        let none = Harness()
        none.source.matches = nil
        XCTAssertTrue(try none.refusal("league_table").contains("can't read fixtures"))
        XCTAssertNil(try none.answer("game_status")["next_fixture"])
    }

    func testATableWithoutTheClubIsntShown() throws {
        let harness = Harness()
        harness.source.matches?.teams[World.team]?.table?.rows.removeFirst()
        XCTAssertTrue(try harness.refusal("league_table").contains("no league table"))
    }

    // MARK: Match day

    /// The game date doesn't move while FM plays a match, so the read stands, but the match tools must see the result.
    func testAMatchPlayedTodayIsSeenWithinAMinute() throws {
        let harness = Harness()
        var now = Date(timeIntervalSinceReferenceDate: 0)
        harness.toolbox.clock = { now }
        let today = World.fixture(270, home: World.team, away: World.rivalsTeam)
        harness.source.matches?.teams[World.team]?.fixtures.insert(today, at: 3)
        XCTAssertEqual(try harness.answer("game_status")["next_fixture"]?["date"], "2026-09-27")
        XCTAssertTrue(try harness.refusal("results", ["date": "2026-09-27"]).contains("no result on 2026-09-27"))
        XCTAssertEqual(harness.source.matches?.sweeps, 1)

        // Full time, on the same read.
        harness.source.matches?.teams[World.team]?.fixtures[3].homeGoals = 3
        harness.source.matches?.teams[World.team]?.fixtures[3].awayGoals = 1
        now += 30
        XCTAssertTrue(try harness.refusal("results", ["date": "2026-09-27"]).contains("no result"), "at most one sweep a minute")
        XCTAssertEqual(harness.source.matches?.sweeps, 1)
        now += 31
        XCTAssertEqual(try harness.answer("results", ["date": "2026-09-27"])["score"], "3-1")
        XCTAssertEqual(try harness.answer("game_status")["next_fixture"]?["date"], "2026-10-04")
        XCTAssertEqual(harness.source.reads, 1)
        now += 3600
        _ = try harness.answer("fixtures")
        XCTAssertEqual(harness.source.matches?.sweeps, 2, "once it's played, the sweep stands for the read again")
    }

    func testAFailedCheckIsntKept() throws {
        let harness = Harness()
        harness.source.matches?.teams[World.team]?.check = .failed("a match was half-made")
        XCTAssertTrue(try harness.refusal("results").contains("failed"))
        harness.source.matches?.teams[World.team]?.check = .passed
        XCTAssertEqual(try harness.answer("results")["found"], 3)
        XCTAssertEqual(harness.source.matches?.sweeps, 2)
        XCTAssertEqual(harness.source.reads, 1)
    }

    // MARK: Elsewhere

    func testGameStatusGivesTheNextFixture() throws {
        let harness = Harness()
        let next = try XCTUnwrap(try harness.answer("game_status")["next_fixture"])
        XCTAssertEqual(next["date"], "2026-10-04")
        XCTAssertEqual(next["kick_off"], "20:00")
        XCTAssertEqual(next["competition"], "Mock League")
        XCTAssertNil(next["stage"])
        XCTAssertEqual(next["venue"], "home")
        XCTAssertEqual(next["opponent"], .string(World.otherTown))
    }

    func testOneSweepForEachTeamAndRead() throws {
        let harness = Harness()
        _ = try harness.answer("game_status")
        _ = try harness.answer("fixtures")
        _ = try harness.answer("results", ["date": "2026-09-20"])
        _ = try harness.answer("league_table")
        XCTAssertEqual(harness.source.matches?.sweeps, 1)
        _ = try harness.answer("results", ["club": .string(World.rivals)])
        XCTAssertEqual(harness.source.matches?.sweeps, 2)
        harness.source.current = false
        _ = try harness.answer("fixtures")
        XCTAssertEqual(harness.source.matches?.sweeps, 3, "a new read sweeps again")
    }

    func testNothingIsSweptForTheOtherTools() throws {
        let harness = Harness()
        _ = try harness.answer("squad")
        _ = try harness.answer("person", ["uid": 1])
        XCTAssertEqual(harness.source.matches?.sweeps, 0)
    }

    func testSquadRowsGiveTheLastMatch() throws {
        let harness = Harness()
        let squad = try harness.answer("squad")
        let byUID = Dictionary(rows(squad).map { ($0["uid"]?.int ?? 0, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byUID[11]?["Last match"], "2026-09-20")
        XCTAssertEqual(byUID[11]?["Last match minutes"], 64)
        XCTAssertEqual(byUID[11]?["Last match rating"], 7.1)
        XCTAssertEqual(byUID[13]?["Last match"], .null)
        let all = try harness.answer("squad", ["squad": "all"])
        let youngster = try XCTUnwrap(rows(all).first { $0["uid"] == 12 })
        XCTAssertEqual(youngster["Last match"], "2026-09-20")
        XCTAssertEqual(youngster["Last match minutes"], .null, "an unused substitute")
        XCTAssertEqual(youngster["Last match rating"], .null)

        XCTAssertFalse(try Harness(engine: nil).answer("squad").columnNames.contains("Last match"))
    }
}
