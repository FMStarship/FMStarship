import StarshipCore
@testable import StarshipMCP
import XCTest

/// Condition, sharpness, morale, playing time, suspensions and home-grown status in `squad`, `person` and `game_status`.
final class StateToolTests: XCTestCase {
    override func tearDown() {
        GameRules.engine = nil
        super.tearDown()
    }

    private static let names = ["Condition", "Sharpness", "Morale", "Playing time", "Suspended", "Bookings", "Home-grown"]

    /// An object's keys and values, in any order.
    private static func pairs(_ object: JSON) -> [String: JSON] {
        guard case .object(let pairs) = object else { return [:] }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    func testSquadRowsGiveEachPlayersState() throws {
        let harness = Harness()
        let squad = try harness.answer("squad")
        XCTAssertEqual(Array(squad.columnNames.suffix(Self.names.count)), Self.names)
        let rows = Dictionary(uniqueKeysWithValues: squad.rowsByName.compactMap { row in row["uid"]?.int.map { ($0, row) } })

        let tired = try XCTUnwrap(rows[1])
        XCTAssertEqual(tired["Condition"], 85.7)
        XCTAssertEqual(tired["Sharpness"], 92.1)
        XCTAssertEqual(tired["Morale"], 2)
        XCTAssertEqual(tired["Playing time"], -89)
        XCTAssertEqual(tired["Suspended"], "1 Mock League, 2 Mock Cup")
        XCTAssertEqual(tired["Bookings"], "Mock League 2 (2 more: 1-match ban), Mock Cup 1 (1 more: 1-match ban)",
                       "his team's competitions only: not his nation's")
        XCTAssertEqual(tired["Home-grown"], "club")
        XCTAssertEqual(rows[4]?["Bookings"], "Mock League + Mock Reserve League 5 (1 more: 2-match ban), Mock Points Cup: counted another way, not given")

        // Brought up to date three days ago, so FM's getters answer.
        let stale = try XCTUnwrap(rows[2])
        XCTAssertEqual(stale["Condition"], 94.4)
        XCTAssertEqual(stale["Sharpness"], 80.2)
        XCTAssertEqual(stale["Home-grown"], "nation")

        let fit = try XCTUnwrap(rows[3])
        XCTAssertEqual(fit["Condition"], 100)
        XCTAssertEqual(fit["Sharpness"], 96.5)
        XCTAssertEqual(fit["Suspended"], .null)
        XCTAssertEqual(fit["Bookings"], .null)
        XCTAssertEqual(fit["Home-grown"], "no")

        // FM's squad screen doesn't count a ban from another association, or one whose competition isn't known.
        let youth = try harness.answer("squad", ["squad": "U19"])
        XCTAssertEqual(youth.rowsByName.first?["Suspended"], .null)
        XCTAssertEqual(rows[13]?["Suspended"], .null)
    }

    func testPersonGivesEachBanInFull() throws {
        let harness = Harness()
        let state = try XCTUnwrap(try harness.answer("person", ["uid": 1])["Fitness and morale"])
        XCTAssertEqual(state["Condition"], 85.7)
        XCTAssertEqual(state["Sharpness"], 92.1)
        XCTAssertEqual(state["Morale"], 2)
        XCTAssertEqual(state["Playing time"], -89)
        XCTAssertEqual(state["Home-grown"], "club")
        let bans = try XCTUnwrap(state["Suspensions"]?.array)
        XCTAssertEqual(bans.count, 2)
        let expected: [[String: JSON]] = [
            ["matches_left": 1, "matches": 1, "served": 0, "competition": "Mock League", "association": "Mockovia",
             "reason": "bookings", "issued": "2026-09-01"],
            ["matches_left": 2, "matches": 3, "served": 1, "competition": "Mock Cup", "association": "Mockovia",
             "reason": "red card", "opponent": .string(World.minnows), "issued": "2026-09-23"],
        ]
        for (ban, wanted) in zip(bans, expected) { XCTAssertEqual(Self.pairs(ban), wanted) }

        XCTAssertTrue(bans.allSatisfy { $0["note"] == nil }, "both count")

        // A competition that isn't known isn't sent at all, and a ban the squad's Suspended leaves out says why.
        let youngster = try XCTUnwrap(try harness.answer("person", ["uid": 12])["Fitness and morale"]?["Suspensions"]?.array?.first)
        XCTAssertNil(youngster["competition"])
        XCTAssertEqual(youngster["association"], "Fixtureland")
        XCTAssertTrue(youngster["note"]?.string?.contains("national team") ?? false)
        let unnamed = try XCTUnwrap(try harness.answer("person", ["uid": 13])["Fitness and morale"]?["Suspensions"]?.array?.first)
        XCTAssertTrue(unnamed["note"]?.string?.contains("can't tell which competition") ?? false)
        XCTAssertEqual(try harness.answer("person", ["uid": 3])["Fitness and morale"]?["Suspensions"], .array([]))
        XCTAssertNil(try harness.answer("person", ["uid": 500])["Fitness and morale"], "staff have none")
    }

    func testGameStatusSaysEachIsOn() throws {
        let status = try Harness().answer("game_status")
        XCTAssertEqual(Self.pairs(try XCTUnwrap(status["player_state"])),
                       ["condition": "on", "sharpness": "on", "morale": "on", "playing_time": "on", "suspensions": "on",
                        "bookings": "on: FM's own count and answer, checked against 3 of 3 bans for bookings", "home_grown": "on"])
    }

    /// Each rule set in full, his team's and the others, with a note on the ones `squad` leaves out or can't give numbers for.
    func testPersonGivesEachRuleSetsBookingsInFull() throws {
        let harness = Harness()
        let first = try XCTUnwrap(try harness.answer("person", ["uid": 1])["Fitness and morale"]?["Bookings"]?.array)
        XCTAssertEqual(first.map(Self.pairs), [
            ["competitions": "Mock League", "yellow_cards": 2, "more_until_ban": 2, "next_ban_matches": 1],
            ["competitions": "Mock Cup", "yellow_cards": 1, "more_until_ban": 1, "next_ban_matches": 1],
            ["competitions": "Made-up Nations Cup, Made-up Shield, Made-up Trophy and 2 more", "yellow_cards": 1, "more_until_ban": 1,
             "next_ban_matches": 1, "note": .string("not a competition his team plays in: most likely his national team's, a youth or "
                                                    + "reserve side's, or a club's he was at before this season")],
        ])
        let fourth = try XCTUnwrap(try harness.answer("person", ["uid": 4])["Fitness and morale"]?["Bookings"]?.array)
        XCTAssertEqual(Self.pairs(fourth[0]), ["competitions": "Mock League + Mock Reserve League", "yellow_cards": 5, "more_until_ban": 1,
                                               "next_ban_matches": 2, "last_ban_at": 4])
        XCTAssertEqual(Set(Self.pairs(fourth[1]).keys), ["competitions", "note"], "no numbers for a count of another kind")
        XCTAssertTrue(fourth[1]["note"]?.string?.hasPrefix("FM counts these another way") ?? false)
        XCTAssertNil(fourth[2]["competitions"])
        XCTAssertTrue(fourth[2]["note"]?.string?.hasPrefix("a rule set FM Starship can't name (FM's rules index 6)") ?? false)
        XCTAssertEqual(fourth[2]["more_until_ban"], 1)
        XCTAssertEqual(try harness.answer("person", ["uid": 3])["Fitness and morale"]?["Bookings"], .array([]))
    }

    /// Off for the read, they're left out of `squad` and `person`, and `game_status` says why.
    func testBookingsThatFailedTheirCheckAreLeftOutAndSaidWhy() throws {
        let harness = Harness()
        harness.source.bookings?.off = "its check failed: made up"
        XCTAssertEqual(try harness.answer("game_status")["player_state"]?["bookings"], "off: its check failed: made up")
        XCTAssertFalse(try harness.answer("squad").columnNames.contains("Bookings"))
        XCTAssertNil(try harness.answer("person", ["uid": 1])["Fitness and morale"]?["Bookings"])

        harness.source.bookings = nil
        XCTAssertEqual(try harness.answer("game_status", ["refresh": true])["player_state"]?["bookings"],
                       "off: it can't be read from this save")
        XCTAssertFalse(try harness.answer("squad").columnNames.contains("Bookings"))
    }

    /// Without FM's rules, a condition FM hasn't brought up to date today is left out rather than shown as it was, and
    /// home-grown status, which only FM's rules can give, is gone.
    func testWithoutFMsRulesAStaleConditionAndHomeGrownAreLeftOut() throws {
        let harness = Harness(engine: nil)
        let squad = try harness.answer("squad")
        XCTAssertFalse(squad.columnNames.contains("Home-grown"))
        let rows = Dictionary(uniqueKeysWithValues: squad.rowsByName.compactMap { row in row["uid"]?.int.map { ($0, row) } })
        XCTAssertEqual(rows[1]?["Condition"], 85.7, "today's needs no rules")
        XCTAssertEqual(rows[2]?["Condition"], .null)
        XCTAssertEqual(rows[2]?["Sharpness"], .null)
        XCTAssertEqual(rows[2]?["Morale"], 12)

        let state = try XCTUnwrap(try harness.answer("person", ["uid": 2])["Fitness and morale"])
        XCTAssertNil(state["Condition"])
        XCTAssertNil(state["Home-grown"])
        let why = try XCTUnwrap(state["Condition and sharpness"]?.string)
        XCTAssertTrue(why.hasPrefix("not known: FM last brought them up to date on 2026-09-24"), why)

        let status = try XCTUnwrap(try harness.answer("game_status")["player_state"])
        XCTAssertTrue(status["condition"]?.string?.hasPrefix("on for players FM has brought up to date today") ?? false)
        XCTAssertEqual(status["sharpness"], status["condition"])
        XCTAssertTrue(status["home_grown"]?.string?.hasPrefix("off:") ?? false)
        XCTAssertEqual(status["morale"], "on")
    }

    /// A field whose check failed is left out of every answer, not sent empty, and `game_status` says why.
    func testAFieldThatFailedItsCheckIsLeftOutAndSaidWhy() throws {
        let reasons: [PlayerStateField: (key: String, names: [String])] = [
            .fitness: ("condition", ["Condition", "Sharpness"]), .morale: ("morale", ["Morale"]),
            .playingTime: ("playing_time", ["Playing time"]), .bans: ("suspensions", ["Suspended", "Suspensions"]),
        ]
        for (field, expected) in reasons {
            let harness = Harness()
            harness.source.database.stateOff = [field: "its check failed: made up"]
            let status = try XCTUnwrap(try harness.answer("game_status")["player_state"])
            XCTAssertEqual(status[expected.key], "off: its check failed: made up")
            let others = reasons.filter { $0.key != field }.map(\.value.key)
            XCTAssertTrue(others.allSatisfy { status[$0] == "on" }, "\(field)")

            let columns = try harness.answer("squad").columnNames
            let person = try XCTUnwrap(try harness.answer("person", ["uid": 1])["Fitness and morale"])
            for name in expected.names {
                XCTAssertFalse(columns.contains(name), name)
                XCTAssertNil(person[name], name)
            }
            for name in Self.names where !expected.names.contains(name) { XCTAssertTrue(columns.contains(name), name) }
        }
    }

    /// None of these is hidden in FM, so they're there with Hidden attributes off.
    func testTheyAreThereWithHiddenAttributesOff() throws {
        let harness = Harness(hidden: false)
        XCTAssertEqual(Array(try harness.answer("squad").columnNames.suffix(Self.names.count)), Self.names)
        XCTAssertEqual(try harness.answer("person", ["uid": 1])["Fitness and morale"]?["Morale"], 2)
        XCTAssertEqual(try harness.answer("person", ["uid": 1])["Fitness and morale"]?["Bookings"]?.array?.count, 3)
    }

    /// FM can play a match without the date moving, so the read stands, but each row and each person is read again.
    func testEachAnswerReadsThePlayersStateAgain() throws {
        let harness = Harness()
        XCTAssertEqual(try harness.answer("squad").rowsByName.first { $0["uid"] == 3 }?["Morale"], 12)
        let states = try XCTUnwrap(harness.source.states)
        states.now[3] = { player in
            player.morale = 5
            player.fitness = Fitness(condition: 6_400, sharpness: 9_650)
        }
        let row = try XCTUnwrap(try harness.answer("squad").rowsByName.first { $0["uid"] == 3 })
        XCTAssertEqual(row["Morale"], 5)
        XCTAssertEqual(row["Condition"], 64)
        XCTAssertEqual(try harness.answer("person", ["uid": 3])["Fitness and morale"]?["Morale"], 5)
        XCTAssertEqual(harness.source.reads, 1, "no new read of the save")
        XCTAssertTrue(states.refreshed.contains(3))
    }

    /// Getters in the wrong slots give other values than FM stored for today's players: condition and sharpness go.
    func testFMsGettersThatDisagreeSwitchConditionOff() throws {
        let engine = FakeEngine()
        engine.gettersDisagree = true
        let harness = Harness(engine: engine)
        let status = try XCTUnwrap(try harness.answer("game_status")["player_state"])
        XCTAssertTrue(status["condition"]?.string?.hasPrefix("off: its check failed: FM's own getters") ?? false, status.text)
        XCTAssertEqual(status["morale"], "on")
        let columns = try harness.answer("squad").columnNames
        XCTAssertFalse(columns.contains("Condition"))
        XCTAssertFalse(columns.contains("Sharpness"))
        XCTAssertTrue(columns.contains("Morale"))
    }

    /// Without a way to read players again, a player's state is the read's, and his bans aren't known.
    func testWithoutReadingAgainBansAreNotKnown() throws {
        let harness = Harness()
        harness.source.states = nil
        let row = try XCTUnwrap(try harness.answer("squad").rowsByName.first { $0["uid"] == 1 })
        XCTAssertEqual(row["Suspended"], .null)
        XCTAssertEqual(row["Morale"], 2)
        XCTAssertNil(try harness.answer("person", ["uid": 1])["Fitness and morale"]?["Suspensions"])
    }
}
