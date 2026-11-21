@testable import StarshipCore
import XCTest

/// Made-up match summaries, as FM keeps them in its post-match news, laid out as `MacLayout.MatchSummary` says.
extension FakeGame {
    struct SummaryValues {
        var team: Int64
        var opponent: Int64
        var away = false
        var possession: (ours: UInt32, theirs: UInt32) = (58, 42)
        /// × 100.
        var xG: (ours: UInt16, theirs: UInt16) = (138, 52)
        var ours: (fouls: UInt8, shots: UInt8, onTarget: UInt8, goals: UInt8) = (10, 12, 3, 2)
        var theirs: (fouls: UInt8, shots: UInt8, onTarget: UInt8, goals: UInt8) = (12, 8, 4, 1)
    }

    /// A summary at the end of a news item, after its scoreline's date, or with no date nil. `matchStats` stands in for the
    /// match's `GAME_MATCH_STATS`, as some copies point at. Gives the summary's address.
    @discardableResult
    func summary(_ v: SummaryValues, date: (day: UInt16, year: UInt16)?, matchStats: Int64 = 0) -> Int64 {
        typealias S = MacLayout.MatchSummary
        // The summary is 8-aligned, as in FM, where it follows the news item's other fields.
        let before = (-S.day + 7) & ~7
        let record = self.record("Match report news", size: before + S.size)
        if let date {
            record.set("scoreline day", before + S.day, date.day)
            record.set("scoreline year", before + S.year, date.year)
        }
        let o = before
        record.set("team", o + S.team, v.team)
        record.set("opponent", o + S.opponent, v.opponent)
        record.set("possession", o + S.possession, v.possession.ours)
        record.set("their possession", o + S.possession + 4, v.possession.theirs)
        record.set("xG", o + S.xG, v.xG.ours)
        record.set("their xG", o + S.xG + 2, v.xG.theirs)
        record.set("figures", o + S.fouls, bytes: [v.ours.fouls, v.ours.shots, v.ours.onTarget, v.theirs.fouls, v.theirs.shots, v.theirs.onTarget])
        record.set("goals", o + S.goals, v.ours.goals)
        record.set("away", o + S.away, UInt8(v.away ? 1 : 0))
        record.set("their goals", o + S.theirGoals, v.theirs.goals)
        record.set("match stats", o + S.matchStats, matchStats)
        return record.address + Int64(o)
    }

    /// A stand-in for a match's `GAME_MATCH_STATS`, pointing at its result.
    func matchStats(result: Int64) -> Int64 {
        let record = self.record("Game match stats", size: Int(MacLayout.MatchSummary.matchStatsResult) + 8)
        record.set("result", Int(MacLayout.MatchSummary.matchStatsResult), result)
        return record.address
    }
}

/// `MatchStatsReader` against made-up summaries, and its self-check against made-up players' records. Every name and number
/// is made up.
final class MatchStatsReaderTests: XCTestCase {
    private final class World {
        let game: FakeGame
        let molde: Int64, rivals: Int64, cupSide: Int64

        init() {
            let game = FakeGame()
            self.game = game
            let nation = game.nation("Mockovia", code: "MCK", continent: game.continent("Made-up Continent"), area: game.allocate(16))
            func team(_ name: String) -> Int64 {
                let record = game.record("Team", size: MacLayout.Team.competition + 8, vtable: "TEAM")
                record.set("club", MacLayout.Team.club, game.club(full: name, short: name, nation: nation))
                return record.address
            }
            (molde, rivals, cupSide) = (team("Mockport Rovers"), team("Fixture Town"), team("Little Minnows"))
        }

        func reader(checked: Bool = true) -> MatchStatsReader {
            MatchStatsReader(game: game.process(), rtti: Rtti(game.process()), checkedBuild: checked)
        }
    }

    func testFindsEachMatchOnceFromItsCopies() throws {
        let world = World()
        let home = FakeGame.SummaryValues(team: world.molde, opponent: world.rivals)
        // FM keeps a copy in each news item about the match.
        for _ in 0..<3 { world.game.summary(home, date: (286, 2029)) }
        var away = FakeGame.SummaryValues(team: world.molde, opponent: world.cupSide, away: true)
        away.possession = (72, 28)
        away.xG = (304, 52)
        away.ours = (10, 32, 18, 7)
        away.theirs = (16, 5, 3, 0)
        // One copy has no scoreline before it, but points at the match's stats, whose result has the date.
        var result = FakeGame.MatchValues(home: world.cupSide, away: world.molde, name: 0, day: 251)
        result.score = (0, 7)
        let gms = world.game.matchStats(result: world.game.match(result).address)
        world.game.summary(away, date: nil, matchStats: gms)
        world.game.summary(away, date: (251, 2029))

        let found = try XCTUnwrap(world.reader().stats(team: world.molde))
        guard found.count == 2 else { return XCTFail("found \(found.count)") }
        let cup = found[0]
        XCTAssertEqual(cup.date, GameDate.date(year: 2029, dayOfYear: 251))
        XCTAssertEqual(cup.opponent, world.cupSide)
        XCTAssertFalse(cup.home)
        XCTAssertEqual(cup.ours, MatchSideStats(possession: 72, xG100: 304, shots: 32, shotsOnTarget: 18, fouls: 10, goals: 7))
        XCTAssertEqual(cup.theirs, MatchSideStats(possession: 28, xG100: 52, shots: 5, shotsOnTarget: 3, fouls: 16, goals: 0))
        XCTAssertEqual(cup.ours.xG, 3.04)
        let league = found[1]
        XCTAssertEqual(league.date, GameDate.date(year: 2029, dayOfYear: 286))
        XCTAssertTrue(league.home)
        XCTAssertEqual(league.theirs.shots, 8)

        XCTAssertNil(world.reader(checked: false).stats(team: world.molde), "off on a build of FM that hasn't been checked")
        XCTAssertEqual(try XCTUnwrap(world.reader().stats(team: world.rivals)), [], "only the summaries with the team first")
    }

    func testLeavesOutWhatIsntASummary() throws {
        let world = World()
        var values = FakeGame.SummaryValues(team: world.molde, opponent: world.rivals)
        values.possession = (58, 41)
        world.game.summary(values, date: (286, 2029))
        values.possession = (58, 42)
        // The opponent isn't a team.
        var notATeam = values
        notATeam.opponent = world.game.allocate(16)
        world.game.summary(notATeam, date: (286, 2029))
        // More on target than shots.
        var tooMany = values
        tooMany.theirs.onTarget = 9
        world.game.summary(tooMany, date: (286, 2029))
        // No date anywhere.
        world.game.summary(values, date: nil)
        XCTAssertEqual(try XCTUnwrap(world.reader().stats(team: world.molde)), [])

        // The same figures on two dates can't be told apart.
        world.game.summary(values, date: (286, 2029))
        world.game.summary(values, date: (290, 2029))
        XCTAssertEqual(try XCTUnwrap(world.reader().stats(team: world.molde)), [])
    }

    /// A result's date, from its match stats, wins over a scoreline's.
    func testTheResultsDateWins() throws {
        let world = World()
        var result = FakeGame.MatchValues(home: world.molde, away: world.rivals, name: 0, day: 286)
        result.score = (2, 1)
        let gms = world.game.matchStats(result: world.game.match(result).address)
        let values = FakeGame.SummaryValues(team: world.molde, opponent: world.rivals)
        world.game.summary(values, date: (300, 2029), matchStats: gms)
        world.game.summary(values, date: (286, 2029))
        let found = try XCTUnwrap(world.reader().stats(team: world.molde))
        XCTAssertEqual(found.map(\.date), [GameDate.date(year: 2029, dayOfYear: 286)])

        // A result of another match isn't this one's.
        let other = World()
        var elsewhere = FakeGame.MatchValues(home: other.rivals, away: other.cupSide, name: 0, day: 280)
        elsewhere.score = (0, 0)
        other.game.summary(FakeGame.SummaryValues(team: other.molde, opponent: other.rivals), date: (286, 2029),
                           matchStats: other.game.matchStats(result: other.game.match(elsewhere).address))
        XCTAssertEqual(try XCTUnwrap(other.reader().stats(team: other.molde)).map(\.date), [GameDate.date(year: 2029, dayOfYear: 286)])
    }

    // MARK: The self-check

    private let day = GameDate.date(year: 2029, dayOfYear: 286)!

    /// Molde 2-1 Rosenborg: Molde's side as its players' records add up, and Rosenborg's xG as Molde's keeper faced it.
    private func stats() -> MatchStats {
        MatchStats(date: day, team: 1, opponent: 2, home: true,
                   ours: MatchSideStats(possession: 55, xG100: 138, shots: 12, shotsOnTarget: 3, fouls: 10, goals: 2),
                   theirs: MatchSideStats(possession: 45, xG100: 52, shots: 8, shotsOnTarget: 4, fouls: 12, goals: 1))
    }

    private func fixture(_ home: Int, _ away: Int, goals: [MatchGoal] = []) -> MatchFixture {
        var match = MatchFixture(date: day, home: 1, away: 2)
        (match.homeGoals, match.awayGoals) = (home, away)
        match.goals = goals
        return match
    }

    private func record(shots: Int, onTarget: Int = 0, fouls: Int = 0, goals: Int = 0, xG: Double? = nil, faced: Double? = nil) -> PlayerMatch {
        var record = PlayerMatch(date: day, team: 1, opponent: 2)
        record.played = true
        (record.shots, record.shotsOnTarget, record.fouls, record.goals) = (shots, onTarget, fouls, goals)
        record.xG = faced == nil ? xG ?? 0 : nil
        record.xGFaced = faced
        return record
    }

    /// Eleven players whose figures add up to `stats()`: xG 1.39 against the team's 1.38, as rounding gives.
    private func records() -> [PlayerMatch] {
        [record(shots: 0, faced: 0.53),
         record(shots: 5, onTarget: 1, fouls: 2, goals: 1, xG: 0.71),
         record(shots: 4, onTarget: 1, fouls: 3, goals: 1, xG: 0.44),
         record(shots: 3, onTarget: 1, fouls: 1, xG: 0.24)]
            + (0..<7).map { i in record(shots: 0, fouls: i < 4 ? 1 : 0) }
    }

    func testPassesWhenThePlayersAddUp() {
        XCTAssertNil(MatchStatsReader.check(stats(), match: fixture(2, 1), records: records()))
    }

    func testFailsOnEachDisagreement() throws {
        func why(_ stats: MatchStats? = nil, _ match: MatchFixture? = nil, _ records: [PlayerMatch]? = nil) -> String {
            MatchStatsReader.check(stats ?? self.stats(), match: match ?? fixture(2, 1), records: records ?? self.records()) ?? "passed"
        }
        var away = stats()
        away.home = false
        XCTAssertEqual(why(away), "FM's match stats have the club away, and the fixture at home")
        XCTAssertEqual(why(nil, fixture(2, 2)), "FM's match stats give 2-1, and the score is 2-2")
        XCTAssertEqual(why(nil, nil, []), "no player's record of the match is left to check them against")

        var shots = records()
        shots[3].shots = 4
        XCTAssertEqual(why(nil, nil, shots), "the players' records add up to 13 shots, and FM's match stats say 12")
        var onTarget = records()
        onTarget[3].shotsOnTarget = 0
        XCTAssertEqual(why(nil, nil, onTarget), "the players' records add up to 2 shots on target, and FM's match stats say 3")
        var fouls = records()
        fouls.removeLast(4)
        XCTAssertEqual(why(nil, nil, fouls), "the players' records add up to 9 fouls, and FM's match stats say 10")
        var goals = records()
        goals[2].goals = 0
        XCTAssertEqual(why(nil, nil, goals), "passed", "without the result's goal list, own goals can't be told")
        let listed = fixture(2, 1, goals: [MatchGoal(scorer: 1, assist: nil, home: true, minute: 10, addedMinute: 0),
                                           MatchGoal(scorer: 2, assist: nil, home: true, minute: 20, addedMinute: 0),
                                           MatchGoal(scorer: 3, assist: nil, home: false, minute: 30, addedMinute: 0)])
        XCTAssertEqual(why(nil, listed, goals), "the players' records add up to 1 goal, and FM's match stats say 2")
        var xG = records()
        xG[3].xG = 0.26
        XCTAssertEqual(why(nil, nil, xG), "the players' xG adds up to 1.41, and FM's match stats say 1.38")
        var faced = records()
        faced[0].xGFaced = 0.50
        XCTAssertEqual(why(nil, nil, faced), "the goalkeepers faced 0.50 xG, and FM's match stats give the opponent 0.52")
        XCTAssertEqual(why(nil, nil, Array(records().dropFirst())),
                       "no goalkeeper's record of the match is left to check the opponent's xG against")
    }

    /// An own goal for the club is in no record of its players, so it comes off the goals they must add up to.
    func testAnOwnGoalForTheClubIsntTheirs() {
        var stats = stats()
        stats.ours.goals = 3
        let goals = [MatchGoal(scorer: 1, assist: nil, home: true, minute: 10, addedMinute: 0),
                     MatchGoal(scorer: 2, assist: nil, home: true, minute: 20, addedMinute: 0),
                     MatchGoal(scorer: 3, assist: nil, home: true, minute: 30, addedMinute: 0, ownGoal: true),
                     MatchGoal(scorer: 4, assist: nil, home: false, minute: 40, addedMinute: 0)]
        XCTAssertNil(MatchStatsReader.check(stats, match: fixture(3, 1, goals: goals), records: records()))
        // Without the goal list it can't be told, so the goals aren't checked against the players'.
        XCTAssertNil(MatchStatsReader.check(stats, match: fixture(3, 1), records: records()))
        XCTAssertNotNil(MatchStatsReader.check(stats, match: fixture(3, 1, goals: goals.map { var g = $0; g.ownGoal = false; return g }),
                                               records: records()))
    }
}
