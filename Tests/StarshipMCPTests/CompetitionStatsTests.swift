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

    private static func match(_ day: Int, team: String, index: UInt32, name: String = "", opponent: String, goals: Int,
                              teamID: Int64 = 50, type: Int? = nil) -> PlayerMatch {
        var match = PlayerMatch(date: GameDate.date(year: 2026, dayOfYear: day)!, team: teamID, opponent: 60)
        match.teamName = team
        match.teamType = type
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
        XCTAssertEqual(first["League stats"], "Mock League: 6 (1) apps, 630 min, 0 goals, 1 assist, 6.80 rating")
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
        XCTAssertEqual(split["League"]?["Competition"], "Mock League")
        XCTAssertEqual(split["League"]?["Goals"], 0)
        XCTAssertEqual(split["League"]?["Starts"], 6)
        XCTAssertEqual(split["League"]?["Sub appearances"], 1)
        XCTAssertEqual(split["Cup"]?["Goals"], 3)
        XCTAssertEqual(split["Cup"]?["Average rating"], 8.4)
        XCTAssertEqual(split["Continental"]?["Assists"], 1)

        let rival = try Harness().answer("person", ["uid": 21])
        XCTAssertEqual(Set(Self.keys(rival["Season stats by competition"])), ["League", "Cup"])
    }

    /// A stats call that fails mustn't read as no matches in that competition.
    func testAFailedCompetitionSaysNotAvailable() throws {
        let harness = Harness()
        let engine = try XCTUnwrap(harness.source.engine as? FakeEngine)
        engine.failingScopes = [RulesEngine.cup]
        let first = try XCTUnwrap(Self.rows(try harness.answer("squad"))[9])
        XCTAssertEqual(first["Cup stats"], "not available")
        XCTAssertEqual(first["League stats"], "Mock League: 6 (1) apps, 630 min, 0 goals, 1 assist, 6.80 rating")
        let split = try XCTUnwrap(try harness.answer("person", ["uid": 9])["Season stats by competition"])
        XCTAssertEqual(split["Cup"], "not available")
        XCTAssertEqual(split["League"]?["Goals"], 0)
    }

    // MARK: Which league League stats are for

    /// The league named for number 9's League stats, with `matches` ahead of his two league matches.
    private func leagueName(_ matches: [PlayerMatch], fullFrom: [Int64: Date] = [:], loanedTo: String? = nil) throws -> String? {
        let harness = Harness()
        let engine = try XCTUnwrap(harness.source.engine as? FakeEngine)
        engine.moreMatches[9] = matches
        engine.fullFrom[9] = fullFrom
        if let loanedTo { harness.source.database.players.first { $0.uid == 9 }?.loanClubFull = loanedTo }
        let league = try harness.answer("person", ["uid": 9])["Season stats by competition"]?["League"]
        return league?["Competition"]?.string
    }

    private static func reserveMatch(_ day: Int) -> PlayerMatch {
        match(day, team: World.club, index: 55, name: "Mock Reserve League", opponent: "Reserve Town", goals: 0, type: 16)
    }

    func testAReserveLeagueIsNamedWithTheFirstTeams() throws {
        XCTAssertEqual(try leagueName([Self.reserveMatch(269)]), "Mock Reserve League and Mock League")
    }

    /// FM counts seven league appearances, so his seven newest league matches are this season's, and older ones aren't named.
    func testOnlyAsManyLeagueMatchesAsFMCountsNameIt() throws {
        XCTAssertEqual(try leagueName((264...270).reversed().map(Self.reserveMatch)), "Mock Reserve League")
    }

    /// FM leaves a youth team's league out of a player's season stats.
    func testAYouthLeagueIsntNamed() throws {
        let youth = Self.match(269, team: World.club, index: 66, name: "Mock U19 League", opponent: "Youth Town", goals: 0, type: 11)
        XCTAssertEqual(try leagueName([youth]), "Mock League")
    }

    /// The reserves' list is full from day 268, so their older matches are gone and may be newer than the first team's.
    func testAFullListStopsTheCount() throws {
        let from = try XCTUnwrap(GameDate.date(year: 2026, dayOfYear: 268))
        XCTAssertEqual(try leagueName([Self.reserveMatch(269)], fullFrom: [50: from]), "Mock Reserve League")
    }

    func testALoaneesLeagueIsHisLoanClubs() throws {
        let loan = Self.match(269, team: "Loan Club", index: 77, name: "Mock Lower League", opponent: "Away Town", goals: 0, teamID: 70)
        XCTAssertEqual(try leagueName([loan], loanedTo: "Loan Club"), "Mock Lower League")
    }

    // MARK: Match load

    /// The game's day is 270, so matches on day 256 and after count: numbers 9 and 11 played both league matches, 11 coming
    /// off after 64 minutes in the second, and 12 sat on the bench.
    func testMatchLoadIsTheLastFourteenDaysMatchesAndMinutes() throws {
        let rows = Self.rows(try Harness().answer("squad", ["squad": "all"]))
        XCTAssertEqual(rows[9]?["Match load (14 days)"], "2 matches, 180 of 180 min")
        XCTAssertEqual(rows[11]?["Match load (14 days)"], "2 matches, 154 of 180 min")
        XCTAssertEqual(rows[12]?["Match load (14 days)"], "no matches", "an unused substitute didn't play")
    }

    func testAMatchMoreThanFourteenDaysAgoDoesntCount() throws {
        let harness = Harness()
        let engine = try XCTUnwrap(harness.source.engine as? FakeEngine)
        engine.moreMatches[9] = [Self.match(255, team: World.club, index: World.cupIndex, opponent: World.minnows, goals: 0)]
        XCTAssertEqual(try harness.answer("person", ["uid": 9])["Match load (14 days)"], "2 matches, 180 of 180 min")
        engine.moreMatches[9] = [Self.match(269, team: World.club, index: World.cupIndex, opponent: World.minnows, goals: 0)]
        XCTAssertEqual(try harness.answer("person", ["uid": 9])["Match load (14 days)"], "3 matches, 270 of 270 min")
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
        XCTAssertEqual(first["League stats"], "Mock League: 6 (1) apps, 630 min, 1 goal, 1 assist, 6.80 rating")
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
        for column in ["League stats", "Cup stats", "Continental stats", "Last match competition", "Match load (14 days)"] {
            XCTAssertFalse(squad.columnNames.contains(column), column)
        }
        let person = try harness.answer("person", ["uid": 9])
        XCTAssertNil(person["Season stats by competition"])
        XCTAssertNil(person["Recent matches"])
        XCTAssertNil(person["Match load (14 days)"])
        XCTAssertEqual(harness.source.matches?.nameSweeps, 0, "nothing to name")
    }
}
