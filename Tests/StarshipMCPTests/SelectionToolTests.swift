import StarshipCore
@testable import StarshipMCP
import XCTest

/// The matchday squad the user has picked in FM's tactics, read again for each answer, with a warning for each picked player
/// who can't play the next match, and FM's scout's predicted line-up of the opponent.
final class SelectionToolTests: XCTestCase {
    override func tearDown() {
        GameRules.engine = nil
        super.tearDown()
    }

    private static let nextDay = GameDate.date(year: 2026, dayOfYear: World.nextMatch)!

    private static func rows(_ answer: JSON, _ key: String) -> [[String: JSON]] { answer[key]?.rowsByName ?? [] }

    /// Testing FC's next match is the league at home to Other Town on 4 October. First 1, in goal, has a league ban for it,
    /// and a cup ban that doesn't count. On the bench, after a gap, Hurt Player is injured and has a ban FM Starship can't
    /// place.
    func testTheElevenAndBenchWithEachOnesStateAndWhatStopsThemPlaying() throws {
        let answer = try Harness().answer("selection")
        XCTAssertEqual(answer["club"], .string(World.club))
        XCTAssertEqual(answer["next_match"]?["date"], "2026-10-04")
        XCTAssertEqual(answer["next_match"]?["competition"], "Mock League")
        XCTAssertEqual(answer["next_match"]?["opponent"], .string(World.otherTown))

        let eleven = Self.rows(answer, "starting_eleven")
        XCTAssertEqual(eleven.count, 11)
        XCTAssertEqual(eleven.first?["name"], "First 1")
        XCTAssertEqual(eleven.first?["position"], "GK")
        XCTAssertEqual(eleven.first?["role"], .string(Names.rolesIp[0] ?? ""))
        XCTAssertEqual(eleven.first?["condition"], 85.7)
        XCTAssertEqual(eleven.first?["suspended"], "1 Mock League, 2 Mock Cup")
        XCTAssertEqual(eleven[1]["position"], "DR (R)", "goalkeeper first, then right to left")

        let bench = Self.rows(answer, "bench")
        XCTAssertEqual(bench.map { $0["place"] }, [1, 3], "the gap is kept in the numbering")
        XCTAssertEqual(bench.map { $0["name"] }, ["Young Prospect", "Hurt Player"])
        XCTAssertEqual(bench.last?["injury"], "Hamstring strain")
        XCTAssertEqual(bench.first?["suspended"], .null, "a ban from abroad doesn't count for the club")

        let warnings = answer["warnings"]?.array?.compactMap(\.string) ?? []
        XCTAssertEqual(warnings.count, 3, "\(warnings)")
        XCTAssertTrue(warnings.contains("First 1 is in the starting eleven but is banned for the next match: 1 match of his Mock League ban left."))
        XCTAssertTrue(warnings.contains { $0.hasPrefix("Hurt Player is on the bench but is injured (Hamstring strain)") })
        XCTAssertTrue(warnings.contains { $0.hasPrefix("Hurt Player is on the bench and has a ban FM Starship can't tie to a competition") })
        XCTAssertTrue(answer["notes"]?.array?.first?.string?.contains("saved in FM's tactics now") ?? false)
        XCTAssertNil(answer["opponent_prediction"], "FM has no report")
    }

    /// The user can change the line-up without the date moving, so each answer reads it again.
    func testTheLineUpIsReadAgainForEachAnswer() throws {
        let harness = Harness()
        XCTAssertEqual(Self.rows(try harness.answer("selection"), "bench").count, 2)
        let selection = try XCTUnwrap(harness.source.selection)
        let players = harness.source.database.players
        selection.now = { _ in World.tactic(players, bench: [nil, nil, nil, nil, 12]) }
        let bench = Self.rows(try harness.answer("selection"), "bench")
        XCTAssertEqual(bench.map { $0["place"] }, [5])
        XCTAssertEqual(harness.source.reads, 1, "the line-up, not the save, was read again")

        selection.now = { _ in nil }
        XCTAssertTrue(try harness.refusal("selection").contains("couldn't read Testing FC's line-up again"))
    }

    /// A player who doesn't play for the club, or one named twice, means the memory read isn't the line-up.
    func testALineUpThatFailsItsCheckIsLeftOut() throws {
        let harness = Harness()
        let selection = try XCTUnwrap(harness.source.selection)
        let players = harness.source.database.players
        selection.now = { _ in World.tactic(players, bench: [21]) }
        XCTAssertTrue(try harness.refusal("selection").contains("Rival 21, who plays for Rivals FC, is in it"))
        selection.now = { _ in World.tactic(players, bench: [12, 12]) }
        XCTAssertTrue(try harness.refusal("selection").contains("Young Prospect is in it twice"))
        selection.now = { _ in World.tactic(players, bench: [3]) }
        XCTAssertTrue(try harness.refusal("selection").contains("First 3 is in it twice"), "in the eleven and on the bench")
    }

    /// Someone the read doesn't have, such as a player who is also staff, is named as that, not dropped.
    func testAPlayerFMStarshipDoesntReadIsSaidSo() throws {
        let harness = Harness()
        let players = harness.source.database.players
        harness.source.selection?.now = { _ in World.tactic(players, bench: [12, 9_999]) }
        let bench = Self.rows(try harness.answer("selection"), "bench")
        XCTAssertEqual(bench.last?["uid"], .null)
        XCTAssertEqual(bench.last?["name"], "a player FM Starship doesn't read (database index 9999)")
    }

    /// When the players picked are exactly the last match's matchday squad, the user may not have picked for this one yet.
    func testTheSameSquadAsTheLastMatchIsSaid() throws {
        let harness = Harness()
        let engine = try XCTUnwrap(harness.source.engine as? FakeEngine)
        let cup = GameDate.date(year: 2026, dayOfYear: World.cupMatch)!
        for uid in 1...12 {
            var match = PlayerMatch(date: cup, team: World.team, opponent: World.minnowsTeam)
            match.played = uid <= 11
            if uid == 12 { match.absence = .unusedSubstitute }
            engine.moreMatches[UInt32(uid)] = [match]
        }
        let players = harness.source.database.players
        harness.source.selection?.now = { _ in World.tactic(players, bench: [12]) }
        let notes = try harness.answer("selection")["notes"]?.array?.compactMap(\.string) ?? []
        XCTAssertTrue(notes.contains { $0.hasPrefix("These are the same players as the matchday squad of the last match, 2026-09-23") }, "\(notes)")

        harness.source.selection?.now = { _ in World.tactic(players, bench: [12, 13]) }
        let changed = try harness.answer("selection")["notes"]?.array?.compactMap(\.string) ?? []
        XCTAssertFalse(changed.contains { $0.hasPrefix("These are the same players") })
    }

    // MARK: The opponent

    /// Other Town's eleven, who aren't in the made-up save otherwise, and a report predicting them on a given day.
    private static func town(_ harness: Harness) -> [Player] {
        let town = (41...52).map { World.player(UInt32($0), name: "Town \($0)", age: 25, ca: 139, pa: 177, at: World.otherTown) }
        harness.source.database.players += town
        return town
    }

    private static func report(_ players: [Player], day: Int, bench: [UInt32?] = [52]) -> ScoutReport {
        var tactic = World.tactic(players, bench: bench)
        for index in tactic.slots.indices {
            let player = players[index]
            tactic.slots[index].player = player
            tactic.slots[index].index = player.index
        }
        return ScoutReport(date: GameDate.date(year: 2026, dayOfYear: day)!, tactic: tactic)
    }

    func testTheScoutsPredictedLineUpOfTheNextOpponent() throws {
        let harness = Harness()
        let town = Self.town(harness)
        let rivals = harness.source.database.players.filter { $0.clubFull == World.rivals }
        // Newest first: a report on another club, then Other Town's, then one from before the last match with them on 20 Sep.
        harness.source.selection?.reports = [Self.report(rivals, day: 274), Self.report(town, day: 272), Self.report(town, day: 262)]
        let prediction = try XCTUnwrap(try harness.answer("selection")["opponent_prediction"])
        XCTAssertEqual(prediction["opponent"], .string(World.otherTown))
        XCTAssertEqual(prediction["report_date"], "2026-09-29")
        XCTAssertTrue(prediction["note"]?.string?.contains("FM's scout's predicted line-up") ?? false)
        let eleven = prediction["starting_eleven"]?.rowsByName ?? []
        XCTAssertEqual(eleven.first?["name"], "Town 41")
        XCTAssertEqual(eleven.first?["position"], "GK")
        XCTAssertEqual(prediction["substitutes"]?.rowsByName.map { $0["name"] }, ["Town 52"])
        XCTAssertEqual(harness.source.selection?.sweeps, 1)
        _ = try harness.answer("selection")
        XCTAssertEqual(harness.source.selection?.sweeps, 1, "swept for once for each read")
    }

    /// A report from before the last match with them, or one on another club, isn't this match's.
    func testNoPredictionWithoutAReportOnThemSinceTheLastMeeting() throws {
        let harness = Harness()
        let town = Self.town(harness)
        let rivals = harness.source.database.players.filter { $0.clubFull == World.rivals }
        harness.source.selection?.reports = [Self.report(rivals, day: 274), Self.report(town, day: 262)]
        XCTAssertNil(try harness.answer("selection")["opponent_prediction"])
        let without = Harness()
        without.source.selection?.reports = nil
        XCTAssertNil(try without.answer("selection")["opponent_prediction"], "a build of FM without the report's class")
    }

    /// Nothing hidden goes out of the opponent's line-up either.
    func testThePredictionShowsNothingHidden() throws {
        let harness = Harness(hidden: false)
        harness.source.selection?.reports = [Self.report(Self.town(harness), day: 272)]
        let text = try XCTUnwrap(harness.toolbox.call("selection", arguments: [:])).text
        XCTAssertTrue(text.contains("opponent_prediction"))
        XCTAssertNil(text.range(of: World.hiddenNumbers, options: .regularExpression), text)
    }

    /// Without the next match, bans can't be tied to it, and it's said.
    func testWithoutFixturesItStillGivesTheLineUp() throws {
        let harness = Harness()
        harness.source.matches = nil
        let answer = try harness.answer("selection")
        XCTAssertNil(answer["next_match"])
        XCTAssertEqual(Self.rows(answer, "starting_eleven").count, 11)
        XCTAssertTrue(answer["notes"]?.array?.contains { $0.string?.contains("doesn't know the next match") ?? false } ?? false)
    }
}
