import StarshipCore
@testable import StarshipMCP
import XCTest

/// A player's season kept apart by competition, as FM keeps it, and the competition and opponent of each of his matches, so a
/// cup goal isn't read as a league one.
final class CompetitionStatsTests: XCTestCase {
    override func tearDown() {
        GameRules.engine = nil
        super.tearDown()
    }

    /// An object's keys, in order.
    private static func keys(_ object: JSON?) -> [String] {
        guard case .object(let pairs)? = object else { return [] }
        return pairs.map(\.0)
    }

    private static func rows(_ squad: JSON) -> [Int: [String: JSON]] {
        Dictionary(uniqueKeysWithValues: squad.rowsByName.compactMap { row in row["uid"]?.int.map { ($0, row) } })
    }

    private static func match(_ day: Int, team: String, index: UInt32, name: String = "", opponent: String, goals: Int) -> PlayerMatch {
        var match = PlayerMatch(date: GameDate.date(year: 2026, dayOfYear: day)!, team: 50, opponent: 60)
        match.teamName = team
        match.competitionIndex = index
        match.competitionName = name
        match.opponentName = opponent
        match.played = true
        match.minutes = 90
        match.rating = 8.8
        match.goals = goals
        return match
    }

    func testSquadRowsGiveEachCompetitionApart() throws {
        let squad = try Harness().answer("squad")
        XCTAssertTrue(squad["season_stats"]?.string?.contains("club total") ?? false)
        let first = try XCTUnwrap(Self.rows(squad)[9])
        XCTAssertEqual(first["Goals"], 3, "the club total")
        XCTAssertEqual(first["League stats"], "6 (1) apps, 630 min, 0 goals, 1 assist, 6.80 rating")
        XCTAssertEqual(first["Cup stats"], "2 (0) apps, 180 min, 3 goals, 0 assists, 8.40 rating")
        XCTAssertEqual(first["Continental stats"], "1 (0) apps, 90 min, 0 goals, 1 assist, 7.00 rating")

        let rivals = try Harness().answer("squad", ["club": .string(World.rivals)])
        XCTAssertEqual(rivals.rowsByName.first?["Continental stats"], .null, "a competition he hasn't played in is empty")
    }

    func testPersonGivesEachCompetitionInFullAfterTheTotal() throws {
        let harness = Harness()
        let person = try harness.answer("person", ["uid": 9])
        // In the order it goes out, which parsing doesn't keep: the split after the total, league first.
        let text = try XCTUnwrap(harness.toolbox.call("person", arguments: ["uid": 9])).text
        let order = ["\"Season stats\"", "\"Season stats by competition\"", "\"Technical\""].map { text.range(of: $0)?.lowerBound }
        XCTAssertFalse(order.contains(nil))
        XCTAssertEqual(order.compactMap { $0 }, order.compactMap { $0 }.sorted())
        let splitText = try XCTUnwrap(text.components(separatedBy: "\"Season stats by competition\"").last)
        let competitions = ["\"League\"", "\"Cup\"", "\"Continental\""].map { splitText.range(of: $0)?.lowerBound }
        XCTAssertFalse(competitions.contains(nil))
        XCTAssertEqual(competitions.compactMap { $0 }, competitions.compactMap { $0 }.sorted())
        let split = try XCTUnwrap(person["Season stats by competition"])
        XCTAssertEqual(Set(Self.keys(split)), ["League", "Cup", "Continental"])
        XCTAssertEqual(split["League"]?["Goals"], 0)
        XCTAssertEqual(split["League"]?["Starts"], 6)
        XCTAssertEqual(split["League"]?["Sub appearances"], 1)
        XCTAssertEqual(split["Cup"]?["Goals"], 3)
        XCTAssertEqual(split["Cup"]?["Average rating"], 8.4)
        XCTAssertEqual(split["Continental"]?["Assists"], 1)

        let rival = try Harness().answer("person", ["uid": 21])
        XCTAssertEqual(Set(Self.keys(rival["Season stats by competition"])), ["League", "Cup"])
    }

    func testLastMatchSaysWhichCompetitionAndOpponent() throws {
        let first = try XCTUnwrap(Self.rows(try Harness().answer("squad"))[9])
        XCTAssertEqual(first["Last match competition"], "Mock League")
        XCTAssertEqual(first["Last match opponent"], .string(World.otherTown))
        XCTAssertEqual(first["Last match minutes"], 90)
    }

    func testRecentMatchesSayWhereEachGoalCameFrom() throws {
        let harness = Harness()
        let engine = try XCTUnwrap(harness.source.engine as? FakeEngine)
        engine.moreMatches[9] = [
            Self.match(269, team: World.club, index: World.cupIndex, opponent: World.minnows, goals: 3),
            // A reserve league no fixture in memory names, but the team's own league does.
            Self.match(268, team: World.club, index: 55, name: "Mock Reserve League", opponent: "Reserve Town", goals: 0),
            // On loan, in a competition nothing names.
            Self.match(267, team: "Loan Club", index: 77, opponent: "Away Town", goals: 1),
        ]
        let recent = try XCTUnwrap(try harness.answer("person", ["uid": 9])["Recent matches"])
        XCTAssertEqual(recent.columnNames, ["date", "team", "competition", "opponent", "minutes", "rating", "goals", "assists", "yellow", "red"])
        let rows = recent.rowsByName
        XCTAssertEqual(rows.map { $0["competition"] }, ["Mock Cup", "Mock Reserve League", .null, "Mock League", "Mock League"])
        XCTAssertEqual(rows.map { $0["date"] }, ["2026-09-26", "2026-09-25", "2026-09-24", "2026-09-20", "2026-09-13"])
        XCTAssertEqual(rows[0]["opponent"], .string(World.minnows))
        XCTAssertEqual(rows[0]["goals"], 3)
        XCTAssertEqual(rows[2]["team"], "Loan Club")
        XCTAssertEqual(rows[3]["team"], .string(World.club))
        XCTAssertEqual(rows[3]["opponent"], .string(World.otherTown))
    }

    func testAnUnusedSubstituteHasNoMinutesOrRating() throws {
        let recent = try XCTUnwrap(try Harness().answer("person", ["uid": 12])["Recent matches"])
        let row = try XCTUnwrap(recent.rowsByName.first)
        XCTAssertEqual(row["competition"], "Mock League")
        for column in ["minutes", "rating", "goals", "assists", "yellow", "red"] { XCTAssertEqual(row[column], .null, column) }
    }

    func testHowManyRecentMatches() throws {
        let harness = Harness()
        XCTAssertEqual(try harness.answer("person", ["uid": 9, "matches": 1])["Recent matches"]?["rows"]?.array?.count, 1)
        XCTAssertNil(try harness.answer("person", ["uid": 9, "matches": 0])["Recent matches"])
        XCTAssertEqual(try harness.answer("person", ["uid": 9])["Recent matches"]?["rows"]?.array?.count, 2, "all he has, up to 10")
        _ = try harness.refusal("person", ["uid": 9, "matches": 41])
    }

    /// FM plays a match without the date moving, so the read stays current: the total and the split are asked for again.
    func testSeasonStatsAreAskedForWhenAnswered() throws {
        let harness = Harness()
        let engine = try XCTUnwrap(harness.source.engine as? FakeEngine)
        XCTAssertEqual(Self.rows(try harness.answer("squad"))[9]?["Goals"], 3)
        engine.goalSinceRead = true
        let first = try XCTUnwrap(Self.rows(try harness.answer("squad"))[9])
        XCTAssertEqual(first["Goals"], 4)
        XCTAssertEqual(first["League stats"], "6 (1) apps, 630 min, 1 goal, 1 assist, 6.80 rating")
        XCTAssertEqual(try harness.answer("person", ["uid": 9])["Season stats"]?["Goals"], 4)
        XCTAssertEqual(harness.source.reads, 1)
    }

    func testCompetitionsAreNamedOnceForEachRead() throws {
        let harness = Harness()
        _ = try harness.answer("squad")
        _ = try harness.answer("person", ["uid": 9])
        _ = try harness.answer("squad", ["squad": "all"])
        XCTAssertEqual(harness.source.matches?.nameSweeps, 1)
        harness.source.current = false
        _ = try harness.answer("squad")
        XCTAssertEqual(harness.source.matches?.nameSweeps, 2)
    }

    func testWithoutFMsRulesThereIsNoSplitAndNoMatches() throws {
        let harness = Harness(engine: nil)
        let squad = try harness.answer("squad")
        XCTAssertNil(squad["season_stats"])
        for column in ["League stats", "Cup stats", "Continental stats", "Last match competition"] {
            XCTAssertFalse(squad.columnNames.contains(column), column)
        }
        let person = try harness.answer("person", ["uid": 9])
        XCTAssertNil(person["Season stats by competition"])
        XCTAssertNil(person["Recent matches"])
        XCTAssertEqual(harness.source.matches?.nameSweeps, 0, "nothing to name")
    }
}
