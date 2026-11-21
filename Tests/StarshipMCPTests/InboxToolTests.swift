import StarshipCore
@testable import StarshipMCP
import XCTest

/// The user's inbox, newest first, with the window FM keeps, what each checked kind is about, and the filters.
final class InboxToolTests: XCTestCase {
    override func tearDown() {
        GameRules.engine = nil
        super.tearDown()
    }

    private static func items(_ answer: JSON) -> [JSON] { answer["items"]?.array ?? [] }

    func testItemsNewestFirstWithTheWindowAndWhatEachIsAbout() throws {
        let harness = Harness()
        let answer = try harness.answer("inbox")
        XCTAssertEqual(answer["club"], .string(World.club))
        let window = try XCTUnwrap(answer["window"]?.string)
        XCTAssertTrue(window.hasPrefix("FM keeps the user's inbox from 2026-09-08, 5 items."), window)
        XCTAssertTrue(window.contains("isn't there"))
        XCTAssertEqual(answer["found"], 5)

        let items = Self.items(answer)
        XCTAssertEqual(items.map { $0["date"] }, ["2026-09-25", "2026-09-22", "2026-09-15", "2026-09-13", "2026-09-08"])
        XCTAssertEqual(items.map { $0["kind"] }, ["board confidence update", "player come and get me plea", "transfer completed",
                                                   "injury report", "contract expires soon"])
        XCTAssertEqual(items.map { $0["team"] }, ["First team", "world news", "U19", "First team", "First team"])

        let board = items[0]
        XCTAssertEqual(board["from"]?["name"], "The Chairman")
        XCTAssertNil(board["from"]?["uid"], "someone FM Starship doesn't read has no uid to ask about")
        XCTAssertEqual(board["from"]?["job"], "Chairperson")
        XCTAssertNil(board["about"], "a kind whose fields aren't known says nothing more")

        XCTAssertEqual(items[1]["from"]?["name"], "an agent")
        XCTAssertEqual(items[1]["about"]?["player"]?["uid"], 5)
        XCTAssertEqual(items[1]["about"]?["wants_to_join"], "Big Club FC")

        XCTAssertEqual(items[2]["about"]?["person"]?["name"], "Rival Coach")
        XCTAssertEqual(items[2]["about"]?["other_club"], .string(World.rivals))

        let injury = try XCTUnwrap(items[3]["about"])
        XCTAssertEqual(injury["player"]?["uid"], 13)
        XCTAssertEqual(injury["player"]?["name"], "Hurt Player")
        XCTAssertEqual(injury["injury"], "Hamstring strain")
        XCTAssertEqual(injury["injured_on"], "2026-09-13")
        XCTAssertEqual(injury["days"], 21)
        XCTAssertEqual(items[3]["from"]?["uid"], 501)
        XCTAssertEqual(items[3]["from"]?["job"], "Head Physio", "the job the item gives")

        let expiring = items[4]["about"]?["contracts_expiring"]?.array ?? []
        XCTAssertEqual(expiring.map { $0["name"] }, ["Young Prospect", "Coach One", "someone FM Starship doesn't read (database index 9999)"])
        XCTAssertEqual(expiring[1]["job"], "Coach")
        XCTAssertEqual(answer["kinds"]?["injury report"], 1)

        let asked = try XCTUnwrap(harness.source.inbox?.asked)
        XCTAssertEqual(asked.manager, 500)
        XCTAssertEqual(asked.teams, [World.firstTeamIndex: 0, World.youthTeamIndex: 11])
        XCTAssertEqual(asked.today, harness.source.database.gameDate)
    }

    func testSinceKindAndLimit() throws {
        let harness = Harness()
        let since = try harness.answer("inbox", ["since": "2026-09-13"])
        XCTAssertEqual(Self.items(since).map { $0["date"] }, ["2026-09-25", "2026-09-22", "2026-09-15", "2026-09-13"])
        XCTAssertNil(since["notes"]?.array?.first { $0.string?.contains("oldest item") ?? false })

        let contracts = try harness.answer("inbox", ["kind": "CONTRACT"])
        XCTAssertEqual(Self.items(contracts).map { $0["kind"] }, ["contract expires soon"])

        let limited = try harness.answer("inbox", ["limit": 2])
        XCTAssertEqual(Self.items(limited).count, 2)
        XCTAssertEqual(limited["found"], 5)
        XCTAssertTrue(limited["notes"]?.array?.contains { $0.string == "Showing the newest 2 of 5." } ?? false)

        let none = try harness.answer("inbox", ["kind": "bid", "since": "2026-09-20"])
        XCTAssertEqual(Self.items(none).count, 0)
        let note = none["notes"]?.array?.first?.string ?? ""
        XCTAssertTrue(note.contains("No item's kind contains \"bid\" since 2026-09-20"), note)
        XCTAssertTrue(note.contains("board confidence update, player come and get me plea"), note)
        XCTAssertEqual(harness.source.reads, 1, "the inbox, not the save, is read again")
        XCTAssertEqual(harness.source.inbox?.reads, 4, "each answer reads the inbox again: new items come without the date moving")
    }

    /// Before the oldest item, the answer says it can't tell, rather than that nothing happened.
    func testSinceBeforeTheWindowSaysItCantTell() throws {
        let answer = try Harness().answer("inbox", ["since": "2026-09-01"])
        XCTAssertEqual(answer["found"], 5)
        let notes = answer["notes"]?.array?.compactMap(\.string) ?? []
        XCTAssertTrue(notes.contains { $0.hasPrefix("since is before 2026-09-08, the oldest item FM keeps, so this can't say what happened from 2026-09-01") },
                      "\(notes)")
    }

    func testAFailedCheckSwitchesItOffWithTheReason() throws {
        let harness = Harness()
        harness.source.inbox?.result = .failed("the dates go back along the list at item 4")
        let refusal = try harness.refusal("inbox")
        XCTAssertTrue(refusal.contains("check of \(World.club)'s inbox failed: the dates go back along the list at item 4"), refusal)
        XCTAssertTrue(refusal.contains("left out rather than guessed"))
    }

    /// An injury report whose length isn't the player's own record of that injury fails the check.
    func testAnInjuryReportMustAgreeWithThePlayersOwnRecord() throws {
        let harness = Harness()
        let hurt = try XCTUnwrap(harness.source.database.players.first { $0.uid == 13 })
        let record = Injury()
        record.name = "Hamstring strain"
        record.date = GameDate.checked(year: 2026, dayOfYear: 256)!
        record.length = 21
        hurt.injuries = [record]
        XCTAssertEqual(Self.items(try harness.answer("inbox")).count, 5, "they agree")
        record.length = 30
        let refusal = try harness.refusal("inbox")
        XCTAssertTrue(refusal.contains("gives Hurt Player 21 days, and his own injury record 30"), refusal)
    }

    func testAnEmptyInboxAndNoInbox() throws {
        let harness = Harness()
        harness.source.inbox?.result = .items([])
        let empty = try harness.answer("inbox")
        XCTAssertEqual(Self.items(empty).count, 0)
        XCTAssertTrue(empty["window"]?.string?.contains("FM holds no items") ?? false)

        harness.source.database.humanClubs = [(team: 1, name: World.club, manager: 0)]
        XCTAssertTrue(try harness.refusal("inbox").contains("doesn't know who manages"))

        let without = Harness()
        without.source.inbox = nil
        XCTAssertTrue(try without.refusal("inbox").contains("can't read FM's inbox"))
        XCTAssertTrue(try without.refusal("inbox", ["since": "8 Sep"]).contains("since must be a date"))
    }
}
