import Foundation
import StarshipAnalysis
import StarshipCore
@testable import StarshipMCP
import StarshipSearch
import XCTest

/// development: how the club's players have changed between two of the records FM Starship keeps of the squad.
final class DevelopmentToolTests: XCTestCase {
    override func tearDown() {
        GameRules.engine = nil
        super.tearDown()
    }

    private func harness(hidden: Bool = true, reveal: Reveal = .exact) throws -> Harness {
        let harness = Harness(hidden: hidden, reveal: reveal)
        try harness.saveDevelopment(World.history())
        return harness
    }

    private func row(_ answer: JSON, _ uid: Int) -> [String: JSON]? { answer.rowsByName.first { $0["uid"]?.int == uid } }

    /// By the squad each player is in now: the youngster is in the U19s, the others in the first team.
    func testASquadNarrowsTheRows() throws {
        let h = try harness()
        let youth = try h.answer("development", ["squad": "u19"])
        XCTAssertEqual(youth.rowsByName.compactMap { $0["uid"]?.int }, [12])
        XCTAssertTrue(youth["squad"]?.string?.hasPrefix("u19: players in that squad now") ?? false)
        let first = try h.answer("development", ["squad": "First team"])
        XCTAssertFalse(first.rowsByName.isEmpty)
        XCTAssertFalse(first.rowsByName.contains { $0["uid"] == 12 })
        XCTAssertTrue(try h.answer("development", ["squad": "On loan"]).rowsByName.isEmpty, "nobody is out on loan")
    }

    func testTheOldestAndNewestRecordsAreComparedByDefault() throws {
        let answer = try harness().answer("development")
        XCTAssertEqual(answer["club"], "Testing FC")
        XCTAssertTrue(answer["about"]?.string?.contains("not FM's history") ?? false)
        XCTAssertTrue(answer["about"]?.string?.contains("days nobody read the save") ?? false)
        XCTAssertEqual(answer["recorded"]?["records"], 4)
        XCTAssertEqual(answer["recorded"]?["dates"], ["2026-07-01", "2026-08-01", "2026-09-01", "2026-09-20"])
        XCTAssertEqual(answer["compared"]?["from"], "2026-07-01")
        XCTAssertEqual(answer["compared"]?["to"], "2026-09-20")
        XCTAssertEqual(answer["compared"]?["game_days"], 81)
        XCTAssertTrue(answer["newest_record"]?.string?.contains("7 days before the game date, 2026-09-27") ?? false)
        XCTAssertEqual(answer.columnNames, ["uid", "Name", "Age", "CA from", "CA to", "CA change", "PA", "PA change", "Up", "Down"])
        XCTAssertEqual(answer["order"], "CA gained, most first")

        let young = try XCTUnwrap(row(answer, 12))
        XCTAssertEqual(answer.rowsByName.first?["uid"], 12, "the most CA gained first")
        XCTAssertEqual(young["Name"], "Young Prospect")
        XCTAssertEqual(young["Age"], 18)
        XCTAssertEqual(young["CA from"], 137)
        XCTAssertEqual(young["CA to"], 171)
        XCTAssertEqual(young["CA change"], 34)
        XCTAssertEqual(young["PA change"], 0)
        XCTAssertEqual(young["Up"], .object([("Passing", 4)]))
        XCTAssertEqual(young["Down"], .null, "Pace went up and back, so it's no change")

        let first = try XCTUnwrap(row(answer, 1))
        XCTAssertEqual(first["Up"], .object([("Consistency", 2)]))
        XCTAssertEqual(first["Down"], .object([("Stamina", -2)]))
        XCTAssertEqual(row(answer, 2)?["Up"], .null)

        XCTAssertNil(row(answer, 13), "Hurt Player joined in between")
        XCTAssertNil(row(answer, 22), "Rival 22 left in between")
        let joined = try XCTUnwrap(answer["joined"]?.array)
        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(joined.first?["uid"], 13)
        XCTAssertEqual(joined.first?["name"], "Hurt Player")
        XCTAssertEqual(joined.first?["first_recorded"], "2026-08-01")
        let left = try XCTUnwrap(answer["left"]?.array)
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left.first?["uid"], 22)
        XCTAssertEqual(left.first?["last_recorded"], "2026-08-01")
        XCTAssertEqual(left.first?["now_at"], "Rivals FC", "where he is now, from the save")
    }

    /// Without since, the club view compares the last 90 days up to the newest record, so a record from long ago doesn't
    /// bring in players long gone. since still reaches back, and the player view keeps every date.
    func testWithoutSinceTheLast90DaysAreCompared() throws {
        let harness = Harness()
        var old = DevelopmentStore.Snap(gameDate: try XCTUnwrap(GameDate.date(year: 2025, dayOfYear: 200)))
        old.players[12] = World.record("Young Prospect", ca: 100, pa: 197)
        old.players[99] = World.record("Long Gone", ca: 120, pa: 150)
        try harness.saveDevelopment([old] + World.history())

        let answer = try harness.answer("development")
        XCTAssertEqual(answer["recorded"]?["records"], 5)
        XCTAssertEqual(answer["compared"]?["from"], "2026-07-01", "the oldest record in the 90 days up to 2026-09-20")
        XCTAssertEqual(answer["compared"]?["to"], "2026-09-20")
        let why = try XCTUnwrap(answer["compared"]?["why"]?.string)
        XCTAssertTrue(why.contains("90 days up to to, as since wasn't given"), why)
        XCTAssertEqual(row(answer, 12)?["CA change"], 34)
        XCTAssertFalse(answer.text.contains("Long Gone"))
        XCTAssertTrue(answer["note"]?.string?.contains("every attribute that went up or down") ?? false)

        let whole = try harness.answer("development", ["since": "2025-01-01"])
        XCTAssertEqual(whole["compared"]?["from"], "2025-07-19", "since still reaches back")
        XCTAssertNil(whole["compared"]?["why"])
        XCTAssertEqual(whole["left"]?.array?.first?["name"], "Long Gone")

        let until = try harness.answer("development", ["until": "2026-08-15"])
        XCTAssertEqual(until["compared"]?["from"], "2026-07-01", "90 days up to the last record on or before until")
        XCTAssertEqual(until["compared"]?["to"], "2026-08-01")

        XCTAssertEqual(try harness.answer("development", ["uid": 12])["rows"]?.array?.count, 5, "the player view keeps every date")
    }

    /// With no other record in the 90 days, the latest one before them is compared rather than nothing.
    func testWithNoOtherRecordIn90DaysTheLatestBeforeIsCompared() throws {
        let harness = Harness()
        let history = World.history()
        try harness.saveDevelopment([history[0], history[1], history[3]].map { snap in
            var snap = snap
            if snap.gameDate == history[3].gameDate {
                snap.gameDate = GameDate.calendar.date(byAdding: .day, value: 120, to: history[1].gameDate) ?? snap.gameDate
            }
            return snap
        })
        let answer = try harness.answer("development")
        XCTAssertEqual(answer["compared"]?["from"], "2026-08-01")
        XCTAssertEqual(answer["compared"]?["to"], "2026-11-29")
        XCTAssertTrue(answer["compared"]?["why"]?.string?.hasPrefix("No other record is in the 90 days up to to") ?? false)
    }

    func testSinceAndUntilPickTheRecordsInBetween() throws {
        let answer = try harness().answer("development", ["since": "2026-07-15", "until": "2026-09-10"])
        XCTAssertEqual(answer["compared"]?["from"], "2026-08-01")
        XCTAssertEqual(answer["compared"]?["to"], "2026-09-01")
        XCTAssertNil(answer["newest_record"], "until picks the newest record compared")
        XCTAssertEqual(row(answer, 12)?["CA change"], 0)
        XCTAssertEqual(row(answer, 12)?["Up"], .object([("Passing", 2)]))
        XCTAssertEqual(row(answer, 12)?["Down"], .object([("Pace", -1)]))
        XCTAssertNotNil(row(answer, 13), "he was there on both days")
        XCTAssertNil(answer["joined"])
        XCTAssertEqual(answer["left"]?.array?.first?["uid"], 22)

        let later = try harness().answer("development", ["since": "2026-08-01"])
        XCTAssertEqual(later["compared"]?["from"], "2026-08-01", "a record on the day itself counts")
    }

    func testOnePlayerAtEveryRecordedDate() throws {
        let answer = try harness().answer("development", ["uid": 12])
        XCTAssertEqual(answer["player"]?["uid"], 12)
        XCTAssertEqual(answer["player"]?["name"], "Young Prospect")
        XCTAssertEqual(answer["player"]?["age"], 18)
        XCTAssertEqual(answer.columnNames, ["Date", "CA", "PA", "Passing", "Pace"], "the attributes that moved most")
        XCTAssertEqual(answer["rows"], [["2026-07-01", 137, 197, 8, 10], ["2026-08-01", 139, 197, 9, 13],
                                        ["2026-09-01", 139, 197, 11, 12], ["2026-09-20", 171, 197, 12, 10]])
        let change = try XCTUnwrap(answer["change"])
        XCTAssertEqual(change["from"], "2026-07-01")
        XCTAssertEqual(change["to"], "2026-09-20")
        XCTAssertEqual(change["CA"], 34)
        XCTAssertEqual(change["PA"], 0)
        XCTAssertEqual(change["up"], .object([("Passing", 4)]))
        XCTAssertNil(change["down"], "Pace went up and back")

        let joined = try harness().answer("development", ["uid": 13])
        XCTAssertEqual(joined["rows"]?.array?.count, 3, "only the records he's in")
        XCTAssertEqual(joined.columnNames, ["Date", "CA", "PA"], "nothing moved")

        let window = try harness().answer("development", ["uid": 12, "until": "2026-08-01"])
        XCTAssertEqual(window["rows"]?.array?.count, 2)
        XCTAssertTrue(try harness().refusal("development", ["uid": 999]).contains("Nobody with uid 999"))
    }

    func testHiddenOffLeavesOutCAPAAndHiddenAttributes() throws {
        let harness = try harness(hidden: false)
        let answer = try harness.answer("development")
        XCTAssertEqual(answer.columnNames, ["uid", "Name", "Age", "Up", "Down"])
        XCTAssertEqual(answer["order"], "attributes gained less those lost, most first")
        XCTAssertEqual(row(answer, 1)?["Up"], .null, "Consistency is hidden")
        XCTAssertEqual(row(answer, 1)?["Down"], .object([("Stamina", -2)]))
        XCTAssertEqual(answer.rowsByName.first?["uid"], 12)
        XCTAssertEqual(answer.rowsByName.last?["uid"], 1, "ordered by what's shown, not by CA")

        let one = try harness.answer("development", ["uid": 1])
        XCTAssertEqual(one.columnNames, ["Date", "Stamina"])
        XCTAssertNil(one["change"]?["up"])
        XCTAssertNil(one["change"]?["CA"])
    }

    func testStarsShowCAAndPAAsStarsWithNoChange() throws {
        let answer = try harness(reveal: .stars).answer("development")
        XCTAssertEqual(answer.columnNames, ["uid", "Name", "Age", "CA from", "CA to", "PA", "Up", "Down"])
        XCTAssertEqual(row(answer, 12)?["CA from"], "3.5★")
        XCTAssertEqual(row(answer, 12)?["CA to"], "4.5★")
        let one = try harness(reveal: .stars).answer("development", ["uid": 12])
        XCTAssertEqual(one["rows"]?.array?.first?.array?[1], "3.5★")
        XCTAssertNil(one["change"]?["CA"])
    }

    func testNoRecordSaysHowOneIsMade() throws {
        let sentence = try Harness().refusal("development")
        XCTAssertTrue(sentence.hasPrefix("FM Starship has no development record of Testing FC yet."), sentence)
        XCTAssertTrue(sentence.contains("Load Save"), sentence)
    }

    func testOneRecordHasNothingToCompareWith() throws {
        let harness = Harness()
        try harness.saveDevelopment(Array(World.history().prefix(1)))
        XCTAssertTrue(try harness.refusal("development").contains("only one record of Testing FC"))
        XCTAssertEqual(try harness.answer("development", ["uid": 12])["rows"]?.array?.count, 1)
        let late = try self.harness().refusal("development", ["since": "2027-01-01"])
        XCTAssertTrue(late.contains("no record of Testing FC from 2027-01-01"), late)
        XCTAssertTrue(late.contains("from 2026-07-01 to 2026-09-20"), late)
    }

    func testANamedClubWithARecord() throws {
        let harness = try harness()
        XCTAssertTrue(try harness.refusal("development", ["club": "Rivals FC"]).contains("Clubs it has a record of: Testing FC."))
        try harness.saveDevelopment(World.history(), club: World.rivals)
        XCTAssertEqual(try harness.answer("development", ["club": "rivals fc"])["club"], "Rivals FC")
        try harness.saveDevelopment(World.history(), club: "Gone United")
        XCTAssertEqual(try harness.answer("development", ["club": "gone united"])["club"], "Gone United",
                       "a club no longer in the save, by its file")
    }

    func testNothingIsWritten() throws {
        let harness = try harness()
        let file = DevelopmentStore(directory: harness.development).path(db: harness.source.database, club: World.club)
        let before = try Data(contentsOf: file)
        _ = try harness.answer("development")
        _ = try harness.answer("development", ["uid": 12])
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["Testing FC.json"])
    }
}
