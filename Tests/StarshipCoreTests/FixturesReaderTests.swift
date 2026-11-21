@testable import StarshipCore
import XCTest

/// `FixturesReader` against made-up fixtures, results, tables and histories laid out as `MacLayout` says. Every name and
/// number is made up.
final class FixturesReaderTests: XCTestCase {
    /// A three-club league, and a cup.
    private final class World {
        let game: FakeGame
        let rovers: Int64, town: Int64, united: Int64, minnows: Int64
        let league: Int64, cup: Int64
        let leagueName: Int64, cupName: Int64
        static let leagueIndex: UInt32 = 0x26b, cupIndex: UInt32 = 0x28f

        /// `rows` makes the table from the game and the Rovers', Town's and United's teams, in table order; by default one
        /// that agrees with `playLeague`.
        /// `otherGroup` puts a table of another group of the league ahead of the clubs' own.
        init(rows: ((FakeGame, Int64, Int64, Int64) -> [Int64])? = nil, otherGroup: Bool = false) {
            let game = FakeGame()
            self.game = game
            let nation = game.nation("Mockovia", code: "MCK", continent: game.continent("Made-up Continent"), area: game.allocate(16))
            // The teams come first, so the league can have a table naming them.
            func team(_ name: String) -> FakeRecord {
                let record = game.record("Team", size: MacLayout.Team.competition + 8, vtable: "TEAM")
                record.set("club", MacLayout.Team.club, game.club(full: name, short: name, nation: nation))
                return record
            }
            let teams = ["Mockport Rovers", "Fixture Town", "Testing United", "Little Minnows"].map(team)
            (rovers, town, united, minnows) = (teams[0].address, teams[1].address, teams[2].address, teams[3].address)
            var stages = [game.leagueStage(rows: (rows ?? World.defaultRows)(game, rovers, town, united))]
            if otherGroup {
                let row = game.tableRow(team: minnows, overall: (1, 1, 0, 0, 2, 0, 3), home: (1, 1, 0, 0, 2, 0, 3), away: (0, 0, 0, 0, 0, 0, 0))
                stages.insert(game.leagueStage(rows: [row]), at: 0)
            }
            league = game.competition("Mock League", index: World.leagueIndex, tables: stages)
            cup = game.competition("Mock Cup", index: World.cupIndex)
            leagueName = game.fixtureName(competition: league)
            cupName = game.fixtureName(competition: cup, stage: "kvartfinale")
            for record in teams.prefix(3) { record.set("competition", MacLayout.Team.competition, league) }
            teams[3].set("competition", MacLayout.Team.competition, game.competition("Mock Lower League", index: 0x300))
        }

        /// Rovers P2 W1 D1 3-1, United P1 D1 1-1, Town P1 L1 0-2, after `playLeague`.
        static func defaultRows(_ game: FakeGame, _ rovers: Int64, _ town: Int64, _ united: Int64) -> [Int64] {
            [game.tableRow(team: rovers, overall: (2, 1, 1, 0, 3, 1, 4), home: (1, 1, 0, 0, 2, 0, 3), away: (1, 0, 1, 0, 1, 1, 1)),
             game.tableRow(team: united, overall: (1, 0, 1, 0, 1, 1, 1), home: (1, 0, 1, 0, 1, 1, 1), away: (0, 0, 0, 0, 0, 0, 0)),
             game.tableRow(team: town, overall: (1, 0, 0, 1, 0, 2, 0), home: (0, 0, 0, 0, 0, 0, 0), away: (1, 0, 0, 1, 0, 2, 0))]
        }

        func values(home: Int64, away: Int64, day: UInt16, league: Bool = true) -> FakeGame.MatchValues {
            FakeGame.MatchValues(home: home, away: away, name: league ? leagueName : cupName, day: day)
        }

        /// Rovers 2-0 Town in round 1, held as a fixture, a half-made result and the result; United 1-1 Rovers in round 2.
        func playLeague() {
            var first = values(home: rovers, away: town, day: 100)
            game.match(first)
            first.score = (0, 0)
            first.matchNumber = .max
            game.match(first)
            first.score = (2, 0)
            first.matchNumber = 7
            first.attendance = 12_345
            first.goals = [(11, 12, true, 0, 23, 0), (13, nil, true, 2, 45, 1), (21, nil, false, 3, 60, 0)]
            game.match(first)
            var second = values(home: united, away: rovers, day: 107)
            second.round = 1
            second.score = (1, 1)
            second.kickOff = 55
            game.match(second)
        }

        func reader() throws -> FixturesReader {
            try XCTUnwrap(FixturesReader(game: game.process(), rtti: Rtti(game.process()), checkedBuild: true))
        }
    }

    func testReadsATeamsFixturesResultsAndTable() throws {
        let world = World()
        world.playLeague()
        var leg = world.values(home: world.rovers, away: world.minnows, day: 110, league: false)
        leg.score = (4, 2)
        leg.aggregate = (6, 2)
        leg.kickOff = 60
        world.game.match(leg)
        var next = world.values(home: world.rovers, away: world.united, day: 120)
        next.round = 2
        world.game.match(next)
        // Not a match of the Rovers.
        var other = world.values(home: world.town, away: world.united, day: 100)
        other.score = (3, 3)
        world.game.match(other)

        let found = try world.reader().teamMatches(team: world.rovers)
        XCTAssertEqual(found.check, .passed)
        XCTAssertEqual(found.fixtures.count, 4)
        XCTAssertEqual(found.fixtures.map(\.awayName), ["Fixture Town", "Mockport Rovers", "Little Minnows", "Testing United"])

        let first = found.fixtures[0]
        XCTAssertEqual(first.date, GameDate.date(year: 2029, dayOfYear: 100))
        XCTAssertEqual(first.homeName, "Mockport Rovers")
        XCTAssertEqual(first.competition, "Mock League")
        XCTAssertEqual(first.competitionIndex, World.leagueIndex)
        XCTAssertEqual(first.stage, "")
        XCTAssertEqual(first.round, 1)
        XCTAssertEqual(first.season, 2029)
        XCTAssertEqual(first.kickOff, 15 * 60)
        XCTAssertEqual(first.homeGoals, 2, "the half-made copy's 0-0 is left out")
        XCTAssertEqual(first.awayGoals, 0)
        XCTAssertEqual(first.attendance, 12_345)
        XCTAssertNil(first.homeAggregate)
        XCTAssertEqual(first.goals, [MatchGoal(scorer: 11, assist: 12, home: true, minute: 23, addedMinute: 0),
                                     MatchGoal(scorer: 13, assist: nil, home: true, minute: 45, addedMinute: 1)],
                       "a kind 3, which doesn't count, is left out")

        XCTAssertEqual(found.fixtures[1].round, 2)
        XCTAssertEqual(found.fixtures[1].kickOff, 19 * 60 + 30)

        let cup = found.fixtures[2]
        XCTAssertEqual(cup.competition, "Mock Cup")
        XCTAssertEqual(cup.stage, "kvartfinale")
        XCTAssertNil(cup.round, "rounds are for the league only")
        XCTAssertEqual([cup.homeGoals, cup.awayGoals, cup.homeAggregate, cup.awayAggregate], [4, 2, 6, 2])
        XCTAssertEqual(cup.kickOff, 20 * 60 + 45)
        XCTAssertTrue(cup.goals.isEmpty, "a result with no goal list has none")

        let upcoming = found.fixtures[3]
        XCTAssertFalse(upcoming.played)
        XCTAssertNil(upcoming.homeGoals)
        XCTAssertEqual(upcoming.round, 3)

        let table = try XCTUnwrap(found.table)
        XCTAssertEqual(table.competition, "Mock League")
        XCTAssertEqual(table.competitionIndex, World.leagueIndex)
        XCTAssertEqual(table.rows.map(\.name), ["Mockport Rovers", "Testing United", "Fixture Town"])
        XCTAssertEqual(table.rows.map(\.position), [1, 2, 3])
        XCTAssertEqual(table.rows[0].overall, TableRecord(played: 2, won: 1, drawn: 1, lost: 0, goalsFor: 3, goalsAgainst: 1, points: 4))
        XCTAssertEqual(table.rows[0].home, TableRecord(played: 1, won: 1, drawn: 0, lost: 0, goalsFor: 2, goalsAgainst: 0, points: 3))
        XCTAssertEqual(table.rows[0].away.drawn, 1)
    }

    func testAnotherTeamChecksAgainstItsOwnRow() throws {
        let world = World()
        world.playLeague()
        let found = try world.reader().teamMatches(team: world.town)
        XCTAssertEqual(found.fixtures.count, 1)
        XCTAssertEqual(found.check, .passed)
    }

    func testResultsThatDontAddUpToTheTableSwitchItOff() throws {
        let world = World { game, rovers, town, _ in
            [game.tableRow(team: rovers, overall: (2, 2, 0, 0, 3, 1, 6), home: (1, 1, 0, 0, 2, 0, 3),
                                 away: (1, 1, 0, 0, 1, 1, 3))]
        }
        world.playLeague()
        guard case .failed(let why) = try world.reader().teamMatches(team: world.rovers).check else { return XCTFail("should fail") }
        XCTAssertTrue(why.contains("P2 W1 D1 L0 3-1"), why)
    }

    func testAPointsDeductionDoesntFailTheCheck() throws {
        let world = World { game, rovers, town, _ in
            [game.tableRow(team: rovers, overall: (2, 1, 1, 0, 3, 1, 1), home: (1, 1, 0, 0, 2, 0, 3),
                                 away: (1, 0, 1, 0, 1, 1, 1))]
        }
        world.playLeague()
        XCTAssertEqual(try world.reader().teamMatches(team: world.rovers).check, .passed)
    }

    func testAnExtraResultFailsTheCheck() throws {
        let world = World()
        world.playLeague()
        // Only half-made copies of a third league match the table doesn't know of either: still adds up.
        var half = world.values(home: world.town, away: world.rovers, day: 114)
        half.score = (0, 0)
        half.matchNumber = .max
        world.game.match(half)
        XCTAssertEqual(try world.reader().teamMatches(team: world.rovers).check, .passed)
        // A result the table doesn't have.
        var extra = world.values(home: world.town, away: world.rovers, day: 115)
        extra.score = (1, 0)
        world.game.match(extra)
        guard case .failed = try world.reader().teamMatches(team: world.rovers).check else { return XCTFail("should fail") }
    }

    /// The table counts a league match the sweep didn't find, or found only as half-made copies.
    func testAMissingResultFailsTheCheck() throws {
        let world = World { game, rovers, town, _ in
            [game.tableRow(team: rovers, overall: (3, 2, 1, 0, 4, 1, 7), home: (1, 1, 0, 0, 2, 0, 3), away: (2, 1, 1, 0, 2, 1, 4)),
             game.tableRow(team: town, overall: (2, 0, 0, 2, 0, 3, 0), home: (1, 0, 0, 1, 0, 1, 0), away: (1, 0, 0, 1, 0, 2, 0))]
        }
        world.playLeague()
        var third = world.values(home: world.town, away: world.rovers, day: 114)
        third.score = (0, 0)
        third.matchNumber = .max
        world.game.match(third)
        guard case .failed(let why) = try world.reader().teamMatches(team: world.rovers).check else { return XCTFail("should fail") }
        XCTAssertTrue(why.contains("add up to P2") && why.contains("says P3"), why)
    }

    /// A play-off in the league's own competition, which the table doesn't count, is left out of the sum.
    func testAPlayOffInTheLeaguesCompetitionIsLeftOut() throws {
        let world = World()
        world.playLeague()
        var playOff = world.values(home: world.rovers, away: world.town, day: 130)
        playOff.name = world.game.fixtureName(competition: world.league, stage: "play-off")
        playOff.score = (3, 1)
        world.game.match(playOff)
        let found = try world.reader().teamMatches(team: world.rovers)
        XCTAssertEqual(found.check, .passed)
        XCTAssertEqual(found.fixtures.last?.stage, "play-off")
        XCTAssertEqual(found.fixtures.last?.homeGoals, 3, "it's still a result")
    }

    /// The league's first stage is another group's: the table is the club's own group.
    func testTheTableIsTheGroupTheClubIsIn() throws {
        let world = World(otherGroup: true)
        world.playLeague()
        let found = try world.reader().teamMatches(team: world.rovers)
        XCTAssertEqual(found.table?.rows.map(\.name), ["Mockport Rovers", "Testing United", "Fixture Town"])
        XCTAssertEqual(found.check, .passed)
        let other = try world.reader().leagueTable(team: world.minnows)
        XCTAssertNil(other, "the Minnows' own league has no table here, and another competition's group isn't it")
    }

    func testMorePointsThanWinsAndDrawsGiveFails() throws {
        let world = World { game, rovers, _, _ in
            [game.tableRow(team: rovers, overall: (2, 1, 1, 0, 3, 1, 5), home: (1, 1, 0, 0, 2, 0, 3), away: (1, 0, 1, 0, 1, 1, 1))]
        }
        world.playLeague()
        guard case .failed(let why) = try world.reader().teamMatches(team: world.rovers).check else { return XCTFail("should fail") }
        XCTAssertTrue(why.contains("5 points"), why)
    }

    /// Kick-off, attendance and aggregate aren't covered by the check, so a build of game_plugin nobody has checked doesn't
    /// get them. The made-up game's isn't FM's.
    func testUncheckedFieldsNeedTheCheckedBuild() throws {
        let world = World()
        world.playLeague()
        var leg = world.values(home: world.rovers, away: world.minnows, day: 110, league: false)
        leg.score = (4, 2)
        leg.aggregate = (6, 2)
        leg.attendance = 5_000
        world.game.match(leg)
        let unchecked = try XCTUnwrap(FixturesReader(game: world.game.process(), rtti: Rtti(world.game.process())))
        let found = unchecked.teamMatches(team: world.rovers)
        XCTAssertEqual(found.check, .passed)
        XCTAssertEqual(found.fixtures.compactMap(\.homeGoals), [2, 1, 4], "scores are covered by the check")
        XCTAssertTrue(found.fixtures.allSatisfy { $0.kickOff == nil && $0.attendance == nil && $0.homeAggregate == nil })
        XCTAssertEqual(try world.reader().teamMatches(team: world.rovers).fixtures.last?.attendance, 5_000)
    }

    func testAnAggregateBelowTheLegsScoreIsLeftOut() throws {
        let world = World()
        var leg = world.values(home: world.rovers, away: world.minnows, day: 110, league: false)
        leg.score = (4, 2)
        leg.aggregate = (3, 2)
        world.game.match(leg)
        let match = try XCTUnwrap(try world.reader().teamMatches(team: world.rovers).fixtures.first)
        XCTAssertEqual(match.homeGoals, 4)
        XCTAssertNil(match.homeAggregate)
        XCTAssertNil(match.awayAggregate)
    }

    func testCopiesThatDisagreeLeaveTheScoreOut() throws {
        let world = World()
        world.playLeague()
        var cup = world.values(home: world.minnows, away: world.rovers, day: 104, league: false)
        cup.score = (1, 3)
        cup.attendance = 900
        world.game.match(cup)
        cup.score = (1, 2)
        world.game.match(cup)
        let found = try world.reader().teamMatches(team: world.rovers)
        let match = try XCTUnwrap(found.fixtures.first { $0.competition == "Mock Cup" })
        XCTAssertTrue(match.played)
        XCTAssertTrue(match.scoreUnknown)
        XCTAssertNil(match.homeGoals)
        XCTAssertNil(match.attendance)
        XCTAssertEqual(found.check, .passed, "a cup match isn't in the league's sum")

        // In the league, a match whose score isn't known can't be added up.
        var league = world.values(home: world.town, away: world.rovers, day: 114)
        league.score = (1, 0)
        world.game.match(league)
        league.score = (0, 1)
        world.game.match(league)
        guard case .failed(let why) = try world.reader().teamMatches(team: world.rovers).check else { return XCTFail("should fail") }
        XCTAssertTrue(why.contains("disagree"), why)
    }

    func testGoalsThatDontAddUpToTheScoreAreLeftOut() throws {
        let world = World()
        var match = world.values(home: world.rovers, away: world.minnows, day: 104, league: false)
        match.score = (2, 0)
        match.goals = [(11, nil, true, 0, 10, 0)]
        world.game.match(match)
        let found = try world.reader().teamMatches(team: world.rovers)
        XCTAssertEqual(found.fixtures.first?.homeGoals, 2)
        XCTAssertEqual(found.fixtures.first?.goals.count, 0)
    }

    /// FM's goal kind 1 is an own goal: its scorer plays for the side that conceded it.
    func testKnowsAnOwnGoalByItsKind() throws {
        let world = World()
        var match = world.values(home: world.rovers, away: world.minnows, day: 104, league: false)
        match.score = (2, 1)
        match.goals = [(11, nil, true, 0, 10, 0), (31, nil, true, 1, 30, 0), (32, nil, false, 2, 80, 0)]
        world.game.match(match)
        let goals = try XCTUnwrap(world.reader().teamMatches(team: world.rovers).fixtures.first?.goals)
        XCTAssertEqual(goals.map(\.ownGoal), [false, true, false])
        XCTAssertEqual(goals.map(\.home), [true, true, false], "an own goal counts for the side it went in for")
    }

    func testNothingToCheckAgainst() throws {
        let fresh = World { game, rovers, town, _ in
            [game.tableRow(team: rovers, overall: (0, 0, 0, 0, 0, 0, 0), home: (0, 0, 0, 0, 0, 0, 0),
                                 away: (0, 0, 0, 0, 0, 0, 0))]
        }
        fresh.game.match(fresh.values(home: fresh.rovers, away: fresh.town, day: 100))
        XCTAssertEqual(try fresh.reader().teamMatches(team: fresh.rovers).check, .nothingPlayed)

        let world = World()
        world.playLeague()
        let minnows = try world.reader().teamMatches(team: world.minnows)
        XCTAssertNil(minnows.table, "the lower league has no table here")
        XCTAssertEqual(minnows.check, .noTable)
    }

    func testATableWhoseHomeAndAwayDontAddUpFails() throws {
        let world = World { game, rovers, town, _ in
            [game.tableRow(team: rovers, overall: (2, 1, 1, 0, 3, 1, 4), home: (1, 1, 0, 0, 2, 0, 3),
                                 away: (1, 0, 1, 0, 1, 1, 1)),
             game.tableRow(team: town, overall: (1, 0, 0, 1, 0, 2, 0), home: (1, 0, 0, 1, 0, 2, 0),
                                 away: (1, 0, 0, 1, 0, 2, 0))]
        }
        world.playLeague()
        guard case .failed(let why) = try world.reader().teamMatches(team: world.rovers).check else { return XCTFail("should fail") }
        XCTAssertTrue(why.contains("Fixture Town"), why)
    }

    func testTheCheckOnlyCountsTheLatestSeason() {
        func match(_ season: Int, _ home: Int, _ away: Int) -> MatchFixture {
            var match = MatchFixture(date: GameDate.date(year: season, dayOfYear: 100) ?? Date(), home: 1, away: 2)
            match.season = season
            match.competitionIndex = 9
            (match.homeGoals, match.awayGoals) = (home, away)
            return match
        }
        let row = LeagueTableRow(team: 1, name: "Us", position: 1,
                                 overall: TableRecord(played: 1, won: 1, goalsFor: 1, points: 3),
                                 home: TableRecord(played: 1, won: 1, goalsFor: 1, points: 3), away: TableRecord())
        let table = LeagueTable(competition: "League", competitionIndex: 9, rows: [row])
        XCTAssertEqual(FixturesReader.check([match(2028, 0, 4), match(2029, 1, 0)], team: 1, table: table), .passed)
        XCTAssertNotEqual(FixturesReader.check([match(2029, 0, 4), match(2029, 1, 0)], team: 1, table: table), .passed)
    }

    func testKickOffTimes() {
        XCTAssertEqual(MatchFixture.kickOff(code: 37), 15 * 60)
        XCTAssertEqual(MatchFixture.kickOff(code: 55), 19 * 60 + 30)
        XCTAssertNil(MatchFixture.kickOff(code: 0))
        XCTAssertNil(MatchFixture.kickOff(code: 127))
    }

    func testReadsAPlayersMatchHistory() throws {
        let world = World()
        let played = FakeGame.PlayedValues(minutes: 78, rating: 74, goals: 1, assists: 2, yellow: 1, red: 0, xG: 63, position: 12,
                                           shots: 4, shotsOnTarget: 2, fouls: 3)
        let keeper = FakeGame.PlayedValues(minutes: 90, rating: 66, xG: 614, position: 0)
        let history = world.game.history([
            (world.rovers, [FakeGame.HistoryEntry(opponent: world.town, day: 100, competition: World.leagueIndex, played: played),
                            FakeGame.HistoryEntry(opponent: world.united, day: 107, competition: World.leagueIndex, played: nil),
                            FakeGame.HistoryEntry(opponent: world.minnows, day: 110, competition: World.cupIndex, played: keeper)]),
            (world.minnows, (0..<20).map { FakeGame.HistoryEntry(opponent: world.town, day: UInt16(20 + $0), year: 2028, competition: 0x300) }),
        ])
        var values = FakeGame.PlayerValues()
        values.history = history
        let player = world.game.player(values)

        let found = FixturesReader.history(player: player.address, in: world.game.process()) { GameReader.clubName(team: $0, in: world.game.process()) }
        XCTAssertEqual(found.matches.count, 23)
        XCTAssertEqual(found.matches.prefix(3).map(\.opponentName), ["Little Minnows", "Testing United", "Fixture Town"], "newest first")
        let latest = found.matches[0]
        XCTAssertEqual(latest.team, world.rovers)
        XCTAssertEqual(latest.competitionIndex, World.cupIndex)
        XCTAssertNil(latest.xG, "a goalkeeper's xG field means something else")
        XCTAssertEqual(latest.xGFaced, 6.14, "the xG of the shots he faced")
        XCTAssertEqual(latest.rating, 6.6)
        let unused = found.matches[1]
        XCTAssertFalse(unused.played)
        XCTAssertEqual(unused.minutes, 0)
        XCTAssertNil(unused.rating)
        let first = found.matches[2]
        XCTAssertTrue(first.played)
        XCTAssertEqual(first.date, GameDate.date(year: 2029, dayOfYear: 100))
        XCTAssertEqual([first.minutes, first.goals, first.assists, first.yellow, first.red], [78, 1, 2, 1, 0])
        XCTAssertEqual(first.rating, 7.4)
        XCTAssertEqual(first.xG, 0.63)
        XCTAssertNil(first.xGFaced)
        XCTAssertEqual([first.shots, first.shotsOnTarget, first.fouls], [4, 2, 3])
        XCTAssertNil(found.fullFrom[world.rovers])
        XCTAssertEqual(found.fullFrom[world.minnows], GameDate.date(year: 2028, dayOfYear: 20), "only a full list loses matches")

        // His team's own league names its matches in it, as for a reserve league no fixture in memory names; not the cup.
        XCTAssertEqual(latest.teamName, "Mockport Rovers")
        XCTAssertEqual(latest.teamType, 0, "a first team")
        XCTAssertEqual(latest.competitionName, "")
        XCTAssertEqual(first.competitionName, "Mock League")
        let lower = try XCTUnwrap(found.matches.last)
        XCTAssertEqual(lower.teamName, "Little Minnows")
        XCTAssertEqual(lower.competitionName, "Mock Lower League")
    }

    func testNamesEveryCompetitionAFixtureIsIn() throws {
        let world = World()
        world.playLeague()
        var leg = world.values(home: world.rovers, away: world.minnows, day: 110, league: false)
        leg.score = (4, 2)
        world.game.match(leg)
        XCTAssertEqual(try world.reader().competitionNames(), [World.leagueIndex: "Mock League", World.cupIndex: "Mock Cup"])
    }

    /// A copy in freed memory could point at another competition record with the same index: the name most fixtures carry wins.
    func testTheNameMostFixturesCarryWins() throws {
        let world = World()
        world.playLeague()
        let stale = world.game.fixtureName(competition: world.game.competition("Old Name", index: World.leagueIndex))
        world.game.match(FakeGame.MatchValues(home: world.town, away: world.united, name: stale, day: 90))
        XCTAssertEqual(try world.reader().competitionNames()[World.leagueIndex], "Mock League")
    }

    /// Each competition's record, which names the rule sets yellow cards count under, is the one most fixtures name too.
    func testEachCompetitionsRecordIsTheOneMostFixturesName() throws {
        let world = World()
        world.playLeague()
        let old = world.game.competition("Old Name", index: World.leagueIndex)
        world.game.match(FakeGame.MatchValues(home: world.town, away: world.united, name: world.game.fixtureName(competition: old), day: 90))
        XCTAssertEqual(try world.reader().competitionRecords(), [World.leagueIndex: world.league])
    }

    /// FM's entry for a player who didn't play says why: on the bench, left out, suspended or injured. A reason FM Starship
    /// doesn't know is left unmarked.
    func testAnEntryWithoutARecordSaysWhyHeDidntPlay() throws {
        let world = World()
        let reasons: [UInt8] = [5, 12, 0, 6, 0x4c]
        let history = world.game.history([(world.rovers, reasons.enumerated().map { step, reason in
            FakeGame.HistoryEntry(opponent: world.town, day: UInt16(100 + 7 * step), competition: World.leagueIndex, played: nil, reason: reason)
        })])
        var values = FakeGame.PlayerValues()
        values.history = history
        let player = world.game.player(values)
        let matches = FixturesReader.history(player: player.address, in: world.game.process()) { _ in "" }.matches
        XCTAssertEqual(matches.map(\.played), [false, false, false, false, false])
        XCTAssertEqual(matches.map(\.absence), [nil, .injured, .notInSquad, .unusedSubstitute, .suspended], "newest first")
    }

    /// A record of 0 minutes is an appearance: only no record at all means he didn't play.
    func testAZeroMinuteAppearanceIsPlayed() throws {
        let world = World()
        let history = world.game.history([(world.rovers, [
            FakeGame.HistoryEntry(opponent: world.town, day: 100, competition: World.leagueIndex,
                                  played: FakeGame.PlayedValues(minutes: 0, rating: 0)),
        ])])
        var values = FakeGame.PlayerValues()
        values.history = history
        let player = world.game.player(values)
        let match = try XCTUnwrap(FixturesReader.history(player: player.address, in: world.game.process()) { _ in "" }.matches.first)
        XCTAssertTrue(match.played)
        XCTAssertEqual(match.minutes, 0)
        XCTAssertNil(match.rating)
    }

    func testAPlayerWithNoHistoryHasNoMatches() {
        let world = World()
        let player = world.game.player(FakeGame.PlayerValues())
        XCTAssertTrue(FixturesReader.history(player: player.address, in: world.game.process()) { _ in "" }.matches.isEmpty)
    }

    /// FM has no sicomps classes of the names the reader looks for, and the made-up game has two, so a sicomps spelling
    /// mustn't take their place.
    func testTheSicompsSpellingLeavesTheReadersOwnClassesFirst() throws {
        let game = FakeGame()
        let rtti = Rtti(game.process())
        for name in FakeGame.decoys {
            let tables = rtti.vtables(name)
            XCTAssertEqual(tables.count, 2)
            XCTAssertEqual(tables.first.map { game.process().pluginBase + Int64($0.addressPoint) }, game.vtable(name))
        }
        XCTAssertEqual(rtti.vtables("FIXTURE").first.map { game.process().pluginBase + Int64($0.addressPoint) }, game.vtable("FIXTURE"))
        XCTAssertEqual(rtti.vtables("FIXTURE_RESULT").count, 1, "FIXTURE doesn't match inside FIXTURE_RESULT")
    }
}
