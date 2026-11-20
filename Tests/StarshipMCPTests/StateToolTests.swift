import StarshipCore
@testable import StarshipMCP
import XCTest

/// Condition, sharpness, morale, playing time, suspensions and home-grown status in `squad`, `person` and `game_status`.
final class StateToolTests: XCTestCase {
    override func tearDown() {
        GameRules.engine = nil
        super.tearDown()
    }

    private static let names = ["Condition", "Sharpness", "Morale", "Playing time", "Suspended", "Home-grown"]

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
        XCTAssertEqual(tired["Home-grown"], "club")

        // Brought up to date three days ago, so FM's getters answer.
        let stale = try XCTUnwrap(rows[2])
        XCTAssertEqual(stale["Condition"], 94.4)
        XCTAssertEqual(stale["Sharpness"], 80.2)
        XCTAssertEqual(stale["Home-grown"], "nation")

        let fit = try XCTUnwrap(rows[3])
        XCTAssertEqual(fit["Condition"], 100)
        XCTAssertEqual(fit["Sharpness"], 96.5)
        XCTAssertEqual(fit["Suspended"], .null)
        XCTAssertEqual(fit["Home-grown"], "no")

        let youth = try harness.answer("squad", ["squad": "U19"])
        XCTAssertEqual(youth.rowsByName.first?["Suspended"], "2 (Fixtureland, competition not known)")
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

        // A competition that isn't known isn't sent at all.
        let youngster = try XCTUnwrap(try harness.answer("person", ["uid": 12])["Fitness and morale"]?["Suspensions"]?.array?.first)
        XCTAssertNil(youngster["competition"])
        XCTAssertEqual(youngster["association"], "Fixtureland")
        XCTAssertEqual(try harness.answer("person", ["uid": 3])["Fitness and morale"]?["Suspensions"], .array([]))
        XCTAssertNil(try harness.answer("person", ["uid": 500])["Fitness and morale"], "staff have none")
    }

    func testGameStatusSaysEachIsOn() throws {
        let status = try Harness().answer("game_status")
        XCTAssertEqual(Self.pairs(try XCTUnwrap(status["player_state"])),
                       ["condition": "on", "sharpness": "on", "morale": "on", "playing_time": "on", "suspensions": "on", "home_grown": "on"])
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
    }
}
