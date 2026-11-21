import StarshipCore
@testable import StarshipMCP
import XCTest

/// A match's team stats in `results`, from the summaries `World.matchStats` gives, checked against the players' records.
final class MatchStatsToolTests: XCTestCase {
    override func tearDown() {
        GameRules.engine = nil
        super.tearDown()
    }

    func testOneResultGivesBothSides() throws {
        let harness = Harness()
        let match = try harness.answer("results", ["date": "2026-09-20"])
        let sides = try XCTUnwrap(match["team_stats"]?.array)
        XCTAssertEqual(sides.count, 2)
        func values(_ side: JSON) -> [JSON?] { Toolbox.teamStatsKeys.map { side[$0] } }
        XCTAssertEqual(values(sides[0]), [.string(World.club), 46, 3.25, 15, 3, 3, 1])
        XCTAssertEqual(values(sides[1]), [.string(World.otherTown), 54, 0.85, 9, 4, 11, 1], "the opponent's, though the club was away")
        XCTAssertEqual(match.columnNames, ["uid"] + Toolbox.matchPlayerColumns, "the players are still there")
    }

    /// The 2-0 against Rivals FC has two goals in FM's match stats, and its players' records add up to one.
    func testAMatchThatFailsTheCheckSaysWhy() throws {
        let harness = Harness()
        let stats = try XCTUnwrap(try harness.answer("results", ["date": "2026-09-13"])["team_stats"]?.string)
        XCTAssertEqual(stats, "Not available: FM Starship's check of this match's team stats failed: the players' records add up "
                       + "to 1 goal, and FM's match stats say 2. They're left out rather than guessed.")
    }

    func testAMatchWithoutThemSaysHowFarBackFMKeepsThem() throws {
        let harness = Harness()
        let stats = try XCTUnwrap(try harness.answer("results", ["date": "2026-09-23"])["team_stats"]?.string)
        XCTAssertTrue(stats.hasPrefix("Not available: FM keeps a match's team stats only in its post-match news"), stats)
        XCTAssertTrue(stats.hasSuffix("It has them now for 2 of \(World.club)'s matches, back to 2026-09-13, about the last 2 weeks."), stats)

        harness.source.matches?.stats = []
        harness.source.current = false
        let none = try XCTUnwrap(try harness.answer("results", ["date": "2026-09-20"])["team_stats"]?.string)
        XCTAssertTrue(none.hasSuffix("It has them for none of \(World.club)'s matches now."), none)
    }

    func testTheListGivesTheClubsXGAndShots() throws {
        let harness = Harness()
        let results = try harness.answer("results")
        XCTAssertEqual(results.columnNames, Toolbox.resultColumns + ["xg", "shots"])
        let rows = results.rowsByName
        XCTAssertEqual(rows.map { $0["xg"] }, [.null, 3.25, .null], "the cup tie has none, and the 2-0 failed its check")
        XCTAssertEqual(rows.map { $0["shots"] }, [.null, 15, .null])
        let note = try XCTUnwrap(results["note"]?.string)
        XCTAssertTrue(note.contains("xg and shots are the club's"), note)
        XCTAssertTrue(note.contains("back to 2026-09-13"), note)
    }

    /// FM keeps them only in the news about the user's club.
    func testOnlyTheUsersClubHasThem() throws {
        let harness = Harness()
        let match = try harness.answer("results", ["club": .string(World.rivals), "date": "2026-09-13"])
        XCTAssertTrue(match["team_stats"]?.string?.contains("only in its news about the user's club") ?? false)
        let list = try harness.answer("results", ["club": .string(World.rivals)])
        XCTAssertEqual(list.columnNames, Toolbox.resultColumns)
        XCTAssertEqual(list["note"], "Newest first. Ask with date for one match's players.")
        XCTAssertEqual(harness.source.matches?.statsSweeps, 0)
    }

    func testOffWithoutFMsRulesOrOnAnUncheckedBuild() throws {
        let rules = Harness(engine: nil)
        XCTAssertTrue(try rules.answer("results", ["date": "2026-09-20"])["team_stats"]?.string?.contains("come with FM's rules") ?? false)
        XCTAssertEqual(try rules.answer("results").columnNames, Toolbox.resultColumns)
        XCTAssertEqual(rules.source.matches?.statsSweeps, 0)

        let unchecked = Harness()
        unchecked.source.matches?.stats = nil
        XCTAssertTrue(try unchecked.answer("results", ["date": "2026-09-20"])["team_stats"]?.string?.contains("hasn't been checked") ?? false)
        XCTAssertEqual(try unchecked.answer("results").columnNames, Toolbox.resultColumns)
    }

    func testCopiesThatDisagreeLeaveThemOut() throws {
        let harness = Harness()
        var other = try XCTUnwrap(World.matchStats().last)
        other.theirs.shots = 10
        harness.source.matches?.stats?.append(other)
        XCTAssertEqual(try harness.answer("results", ["date": "2026-09-20"])["team_stats"]?.string,
                       "Not available: FM Starship's check of this match's team stats failed: FM holds 2 different copies of them. "
                       + "They're left out rather than guessed.")
    }

    /// One sweep for each read, and another once a match has been played since.
    func testOneSweepForEachReadAndMatch() throws {
        let harness = Harness()
        var now = Date(timeIntervalSinceReferenceDate: 0)
        harness.toolbox.clock = { now }
        harness.source.matches?.teams[World.team]?.fixtures.insert(World.fixture(270, home: World.team, away: World.rivalsTeam), at: 3)
        _ = try harness.answer("results")
        _ = try harness.answer("results", ["date": "2026-09-20"])
        _ = try harness.answer("results", ["date": "2026-09-13"])
        XCTAssertEqual(harness.source.matches?.statsSweeps, 1)

        // Full time today, on the same read.
        harness.source.matches?.teams[World.team]?.fixtures[3].homeGoals = 3
        harness.source.matches?.teams[World.team]?.fixtures[3].awayGoals = 1
        now += 61
        _ = try harness.answer("results")
        XCTAssertEqual(harness.source.matches?.statsSweeps, 2)

        harness.source.current = false
        _ = try harness.answer("results")
        XCTAssertEqual(harness.source.matches?.statsSweeps, 3, "a new read sweeps again")
    }
}
