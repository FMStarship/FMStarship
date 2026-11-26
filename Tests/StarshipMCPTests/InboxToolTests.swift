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
        XCTAssertEqual(items.map { $0["team"] }, ["First team", "not addressed to one team", "U19", "First team", "First team"])

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
        XCTAssertEqual(expiring.map { $0["uid"] }, [12, 501, nil])
        XCTAssertEqual(expiring[1]["job"], "Coach")
        XCTAssertEqual(expiring[0]["contract_ends_now"], "2027-04-10", "the contract FM has for him now")
        XCTAssertNil(expiring[1]["contract_ends_now"], "no contract read, so none given")
        XCTAssertNil(expiring[0]["now_at"])
        XCTAssertTrue(items[4]["about"]?["note"]?.string?.contains("keeps no end date") ?? false)
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
        XCTAssertTrue(refusal.contains("no injury report agrees with its player's record"), refusal)
    }

    /// Where another report agrees with its record, the lengths are read right, and a report whose record FM holds another
    /// length for now gives both: FM's on 27.1.1 gave one player 34 days and his record 30, and another 2 and 2.
    func testOneReportAgreeingPassesAndADifferentRecordIsGivenBeside() throws {
        let harness = Harness()
        func day(_ day: Int) -> Date { GameDate.checked(year: 2026, dayOfYear: day)! }
        let hurt = try XCTUnwrap(harness.source.database.players.first { $0.uid == 13 })
        let prospect = try XCTUnwrap(harness.source.database.players.first { $0.uid == 12 })
        func record(_ name: String, _ on: Int, _ length: Int) -> Injury {
            let injury = Injury()
            injury.name = name
            injury.date = day(on)
            injury.length = length
            return injury
        }
        hurt.injuries = [record("Hamstring strain", 256, 30)]
        prospect.injuries = [record("Twisted ankle", 266, 2)]
        let coach = NewsPerson(uid: 501, index: 501, isPlayer: false, name: "Coach One")
        let young = NewsPerson(uid: 12, index: 12, isPlayer: true, name: "Young Prospect")
        harness.source.inbox?.result = .items(World.inbox() + [
            InboxItem(serial: 1005, date: day(266), className: "INJURY_REPORT_NEWS_ITEM", team: World.firstTeamIndex, sender: coach,
                      senderJob: "Head Physio", subject: .injury(player: young, injury: "Twisted ankle", on: day(266), days: 2)),
        ])
        let answer = try harness.answer("inbox", ["kind": "injury"])
        let items = Self.items(answer)
        XCTAssertEqual(items.map { $0["about"]?["player"]?["uid"] }, [12, 13])
        XCTAssertEqual(items[0]["about"]?["days"], 2)
        XCTAssertNil(items[0]["about"]?["record_days"], "the record agrees")
        XCTAssertEqual(items[1]["about"]?["days"], 21, "as FM's report gave it")
        XCTAssertEqual(items[1]["about"]?["record_days"], 30)
        let notes = answer["notes"]?.array?.compactMap(\.string) ?? []
        XCTAssertTrue(notes.contains { $0.contains("record_days") }, "\(notes)")

        let other = try harness.answer("inbox", ["kind": "contract"])
        XCTAssertFalse((other["notes"]?.array?.compactMap(\.string) ?? []).contains { $0.contains("record_days") },
                       "only said when an injury shown has one")
    }

    /// Someone whose contract was running out and who has since left has no contract given, only where they are now.
    func testAContractExpiringForSomeoneWhoHasLeft() throws {
        let harness = Harness()
        let prospect = try XCTUnwrap(harness.source.database.players.first { $0.uid == 12 })
        prospect.clubFull = World.rivals
        let expiring = Self.items(try harness.answer("inbox", ["kind": "contract"])).first?["about"]?["contracts_expiring"]?.array ?? []
        XCTAssertEqual(expiring.first?["now_at"], .string(World.rivals))
        XCTAssertNil(expiring.first?["contract_ends_now"])
        prospect.clubFull = ""
        let gone = Self.items(try harness.answer("inbox", ["kind": "contract"])).first?["about"]?["contracts_expiring"]?.array ?? []
        XCTAssertEqual(gone.first?["now_at"], "no club")
    }

    /// A player unhappy with training, a fine and a coach's feedback name the player, and say what isn't known.
    func testTheKindsAboutOnePlayer() throws {
        let harness = Harness()
        let answer = try harness.answer("inbox", ["kind": "fine"])
        XCTAssertEqual(Self.items(answer).count, 0, "none in the five")
        harness.source.inbox?.result = .items(Self.withMore())
        let items = Self.items(try harness.answer("inbox", ["since": "2026-09-26"]))
        XCTAssertEqual(items.map { $0["kind"] }, ["staff meeting advice", "coach feedback on player", "fine", "player unhappiness training"])
        XCTAssertEqual(items[3]["about"]?["player"]?["uid"], 13)
        XCTAssertEqual(items[3]["about"]?["player"]?["name"], "Hurt Player")
        XCTAssertEqual(items[3]["from"]?["name"], "Coach One")
        XCTAssertEqual(items[2]["about"]?["player"]?["uid"], 5)
        XCTAssertTrue(items[2]["about"]?["note"]?.string?.contains("no amount") ?? false)
        XCTAssertNil(items[2]["about"]?["amount"])
        XCTAssertEqual(items[1]["about"]?["player"]?["uid"], 12)
        XCTAssertNil(items[0]["about"])
    }

    /// A contract add-on activated names the player, and for the clause for goals in the season how many and its sum; a
    /// transfer offer confirmed names the person, the other club and the fee, and says what it doesn't give.
    func testAnAddOnActivatedAndAnOfferConfirmed() throws {
        let harness = Harness()
        func day(_ day: Int) -> Date { GameDate.checked(year: 2026, dayOfYear: day)! }
        let director = NewsPerson(uid: 501, index: 501, isPlayer: false, name: "Coach One")
        let rival = NewsPerson(uid: 502, index: 502, isPlayer: false, name: "Rival Coach")
        harness.source.inbox?.result = .items(World.inbox() + [
            InboxItem(serial: 1005, date: day(270), className: "CONTRACT_ADD_ON_ACTIVATED_NEWS", team: World.firstTeamIndex,
                      sender: director, senderJob: "Director of Football",
                      subject: .addOnsActivated([ActivatedAddOn(player: NewsPerson(uid: 5, index: 5, isPlayer: true, name: "First 5"),
                                                                seasonGoals: 10, amount: 22_310)])),
            InboxItem(serial: 1006, date: day(271), className: "CONTRACT_ADD_ON_ACTIVATED_NEWS", team: World.firstTeamIndex,
                      sender: director, senderJob: "Director of Football",
                      subject: .addOnsActivated([ActivatedAddOn(player: NewsPerson(uid: 13, index: 13, isPlayer: true, name: "Hurt Player"))])),
            InboxItem(serial: 1007, date: day(272), className: "TRANSFER_OFFER_CONFIRMATION_NEWS", team: World.firstTeamIndex,
                      sender: director, senderJob: "Director of Football",
                      subject: .offerConfirmed(person: rival, club: World.rivals, fee: 122_960)),
            InboxItem(serial: 1008, date: day(273), className: "TRANSFER_OFFER_CONFIRMATION_NEWS", team: World.firstTeamIndex,
                      sender: director, senderJob: "Director of Football", subject: .offerConfirmed(person: rival, club: nil, fee: nil)),
        ])
        let items = Self.items(try harness.answer("inbox", ["since": "2026-09-27"]))
        XCTAssertEqual(items.map { $0["kind"] }, ["transfer offer confirmation", "transfer offer confirmation", "contract add on activated",
                                                   "contract add on activated"])

        let goals = try XCTUnwrap(items[3]["about"])
        let activated = try XCTUnwrap(goals["activated"]?.array?.first)
        XCTAssertEqual(activated["player"]?["uid"], 5)
        XCTAssertEqual(activated["player"]?["name"], "First 5")
        XCTAssertEqual(activated["clause"], "10 goals in the season")
        XCTAssertEqual(activated["amount"], "£22.3K")
        let note = goals["note"]?.string ?? ""
        XCTAssertTrue(note.contains("checked on one item"), note)
        XCTAssertFalse(note.contains("doesn't know the code"), note)

        let unknown = try XCTUnwrap(items[2]["about"])
        XCTAssertEqual(unknown["activated"]?.array?.first?["player"]?["uid"], 13)
        XCTAssertNil(unknown["activated"]?.array?.first?["clause"], "a clause whose code isn't known isn't named")
        XCTAssertNil(unknown["activated"]?.array?.first?["amount"])
        XCTAssertEqual(unknown["note"], "FM Starship doesn't know the code of Hurt Player's clause, so which clause it is isn't given.")

        let offer = try XCTUnwrap(items[1]["about"])
        XCTAssertEqual(offer["person"]?["name"], "Rival Coach")
        XCTAssertEqual(offer["other_club"], .string(World.rivals))
        XCTAssertEqual(offer["fee"], "£122.9K")
        XCTAssertNil(offer["direction"], "the timeline has nothing")
        XCTAssertTrue(offer["note"]?.string?.hasPrefix("Which way it went isn't given: FM's transfer timeline has no move") ?? false,
                      "\(String(describing: offer["note"]))")

        let bare = try XCTUnwrap(items[0]["about"])
        XCTAssertNil(bare["other_club"])
        XCTAssertNil(bare["fee"])
        let bareNote = bare["note"]?.string ?? ""
        XCTAssertTrue(bareNote.contains("other club isn't given") && bareNote.contains("No fee is given"), bareNote)
        XCTAssertEqual(Self.items(try harness.answer("inbox", ["important": true, "since": "2026-09-27"])).count, 4)
    }

    /// Which way a transfer went comes from FM's transfer timeline only when exactly one move in it is the person's on the
    /// item's day, between the user's club and the other club, with the item's fee when both have one. Swept for only when a
    /// transfer item is shown.
    func testTheDirectionOfATransferFromFMsTimeline() throws {
        let harness = Harness()
        func day(_ day: Int) -> Date { GameDate.checked(year: 2026, dayOfYear: day)! }
        let director = NewsPerson(uid: 501, index: 501, isPlayer: false, name: "Coach One")
        let rival = NewsPerson(uid: 502, index: 502, isPlayer: false, name: "Rival Coach")
        let player = NewsPerson(uid: 5, index: 5, isPlayer: true, name: "First 5")
        let rivalsTeam: UInt32 = 0x900
        func offer(_ serial: UInt32, _ on: Int, _ who: NewsPerson, fee: Int64?) -> InboxItem {
            InboxItem(serial: serial, date: day(on), className: "TRANSFER_OFFER_CONFIRMATION_NEWS", team: World.firstTeamIndex,
                      sender: director, senderJob: "Director of Football", subject: .offerConfirmed(person: who, club: World.rivals, fee: fee))
        }
        func move(_ who: NewsPerson, _ on: Int, in ours: Bool, fee: Int64?, other: String = World.rivals, otherTeam: UInt32 = 0x900,
                  ourTeam: UInt32 = World.firstTeamIndex) -> TransferEvent {
            ours ? TransferEvent(person: who, date: day(on), fromTeam: otherTeam, from: other, toTeam: ourTeam, to: World.club, fee: fee)
                : TransferEvent(person: who, date: day(on), fromTeam: ourTeam, from: World.club, toTeam: otherTeam, to: other, fee: fee)
        }
        let inbox = try XCTUnwrap(harness.source.inbox)
        inbox.result = .items(World.inbox() + [
            offer(1005, 270, rival, fee: 122_960),
            offer(1006, 271, player, fee: 24_669_585),
            offer(1007, 272, rival, fee: 50_000),
            offer(1008, 273, player, fee: nil),
            offer(1009, 274, rival, fee: nil),
            offer(1010, 275, player, fee: nil),
        ])
        inbox.events = [
            // The coach joined from Rivals FC on the day, for the item's fee: to the club. The youth team counts as the club.
            move(rival, 270, in: true, fee: 122_960),
            // The player left for Rivals FC on the day, and a copy in another kind of entry with the same move counts once.
            move(player, 271, in: false, fee: 24_669_585),
            // The fees don't agree.
            move(rival, 272, in: true, fee: 60_000),
            // Two different moves on the day.
            move(player, 273, in: false, fee: 1_000), move(player, 273, in: true, fee: nil),
            // Not the item's day, and between two other clubs.
            move(rival, 275, in: true, fee: nil),
            TransferEvent(person: player, date: day(275), fromTeam: 0x901, from: "Other Town", toTeam: rivalsTeam, to: World.rivals, fee: nil),
            // The transfer completed of World.inbox, to the youth team.
            move(rival, 258, in: true, fee: nil, ourTeam: World.youthTeamIndex),
        ]
        let items = Self.items(try harness.answer("inbox"))
        XCTAssertEqual(inbox.sweeps, 1, "one sweep for the answer")
        func about(_ date: String) -> JSON? { items.first { $0["date"] == .string(date) }?["about"] }
        XCTAssertEqual(about("2026-09-27")?["direction"], .string("to \(World.club) from \(World.rivals)"))
        XCTAssertNil(about("2026-09-27")?["note"], "nothing to say")
        XCTAssertEqual(about("2026-09-28")?["direction"], .string("from \(World.club) to \(World.rivals)"))
        for date in ["2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02"] {
            XCTAssertNil(about(date)?["direction"], date)
            XCTAssertTrue(about(date)?["note"]?.string?.contains("notable moves") ?? false, date)
        }
        XCTAssertTrue(about("2026-09-30")?["note"]?.string?.contains("more than one move") ?? false)
        XCTAssertEqual(about("2026-09-15")?["direction"], .string("to \(World.club) from \(World.rivals)"), "a transfer completed")

        inbox.events = nil
        let unread = Self.items(try harness.answer("inbox"))
        XCTAssertNil(unread.first?["about"]?["direction"])
        XCTAssertTrue(unread.first?["about"]?["note"]?.string?.hasPrefix("Which way it went isn't given: FM's transfer timeline couldn't be read.") ?? false)

        // No transfer item shown: no sweep.
        _ = try harness.answer("inbox", ["kind": "injury"])
        _ = try harness.answer("inbox", ["limit": 1, "since": "2026-10-02"])
        XCTAssertEqual(inbox.sweeps, 3, "the injury answer doesn't sweep; the last one shows a transfer item")
        _ = try harness.answer("inbox", ["kind": "board"])
        XCTAssertEqual(inbox.sweeps, 3)
    }

    /// important keeps the kinds a manager acts on, false the rest, and left out all of them.
    func testImportant() throws {
        let harness = Harness()
        harness.source.inbox?.result = .items(Self.withMore())
        let important = try harness.answer("inbox", ["important": true])
        XCTAssertEqual(Self.items(important).map { $0["kind"] }, ["fine", "player unhappiness training", "board confidence update",
                                                                  "player come and get me plea", "transfer completed", "injury report",
                                                                  "contract expires soon"])
        XCTAssertEqual(important["important"], true)
        XCTAssertTrue(important["notes"]?.array?.contains { $0.string?.hasPrefix("Important means these kinds") ?? false } ?? false)
        let rest = try harness.answer("inbox", ["important": false])
        XCTAssertEqual(Self.items(rest).map { $0["kind"] }, ["staff meeting advice", "coach feedback on player"])
        XCTAssertEqual(Self.items(try harness.answer("inbox")).count, 9)
        let none = try harness.answer("inbox", ["important": false, "kind": "injury"])
        XCTAssertTrue(none["notes"]?.array?.first?.string?.contains("among the others") ?? false)
        XCTAssertTrue(try harness.refusal("inbox", ["important": "yes"]).contains("important"))
    }

    /// The five of `World.inbox`, then from 27 September: Hurt Player unhappy with training, First 5 fined, a coach's feedback
    /// on Young Prospect and a staff meeting.
    private static func withMore() -> [InboxItem] {
        func day(_ day: Int) -> Date { GameDate.checked(year: 2026, dayOfYear: day)! }
        let coach = NewsPerson(uid: 501, index: 501, isPlayer: false, name: "Coach One")
        func player(_ uid: UInt32, _ name: String) -> NewsPerson { NewsPerson(uid: uid, index: uid, isPlayer: true, name: name) }
        return World.inbox() + [
            InboxItem(serial: 1005, date: day(270), className: "PLAYER_UNHAPPINESS_TRAINING_NEWS", team: World.firstTeamIndex, sender: coach,
                      senderJob: "Coach", subject: .unhappyWithTraining(player: player(13, "Hurt Player"))),
            InboxItem(serial: 1006, date: day(270), className: "FINE_NEWS", team: World.firstTeamIndex, sender: nil, senderJob: nil,
                      subject: .fine(player: player(5, "First 5"))),
            InboxItem(serial: 1007, date: day(271), className: "COACH_FEEDBACK_ON_PLAYER_NEWS_ITEM", team: World.firstTeamIndex, sender: coach,
                      senderJob: "Coach", subject: .coachFeedback(player: player(12, "Young Prospect"))),
            InboxItem(serial: 1008, date: day(272), className: "STAFF_MEETING_ADVICE_NEWS", team: World.firstTeamIndex, sender: coach,
                      senderJob: "Coach"),
        ]
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
