@testable import StarshipCore
import XCTest

/// The user's inbox as FM keeps it off the human manager's record, in made-up memory laid out as `MacLayout` says.
final class InboxReaderTests: XCTestCase {
    typealias L = MacLayout.Inbox

    /// A club with a first team and an under-19 side, a physio, a director of football, a player and the user's manager.
    private final class Club {
        let game = FakeGame()
        let club: Int64, rivals: Int64
        let first: Int64, rivalsFirst: Int64
        let physio: FakeRecord, director: FakeRecord, player: FakeRecord
        let manager: FakeRecord
        let agent: Int64
        let teams: [UInt32: Int] = [0x438: 0, 0x4401: 11]
        private var items: [Int64] = []

        init() {
            let continent = game.continent("Made-up Continent")
            let nation = game.nation("Mockovia", code: "MCK", continent: continent, area: game.allocate(16))
            let league = game.competition("Mock League")
            club = game.club(full: "Mockport Rovers FC", short: "Mockport", nation: nation)
            rivals = game.club(full: "Fixture Town AFC", short: "Fixture Town", nation: nation)
            for each in [club, rivals] { game.poke(game.vtable("CLUB")!, at: each) }
            first = game.team(club: club, index: 0x438, type: 0, competition: league)
            _ = game.team(club: club, index: 0x4401, type: 11, competition: league)
            rivalsFirst = game.team(club: rivals, index: 0x900, type: 0, competition: league)

            func person(_ name: String, uid: UInt32, index: UInt32) -> FakeGame.PersonValues {
                var values = FakeGame.PersonValues()
                values.commonName = name
                values.uid = uid
                values.index = index
                return values
            }
            physio = game.staff(FakeGame.StaffValues(person: person("Pat Physio", uid: 7001, index: 71)))
            director = game.staff(FakeGame.StaffValues(person: person("Dana Director", uid: 7002, index: 72)))
            player = game.player(FakeGame.PlayerValues(person: person("Sam Striker", uid: 7003, index: 73)))
            for staff in [physio, director] { staff.set("identity vtable", MacLayout.Staff.identity, game.vtable("ACTUAL_NON_PLAYER")!) }
            player.set("identity vtable", MacLayout.Player.identity, game.vtable("ACTUAL_PLAYER")!)
            let agent = game.record("Agent", size: 16, vtable: "AGENT")
            self.agent = agent.address
            manager = game.record("HUMAN_NON_PLAYER", size: Int(L.items) + 8)
        }

        func identity(_ record: FakeRecord) -> Int64 {
            record.address + Int64(record.kind == "Player" ? MacLayout.Player.identity : MacLayout.Staff.identity)
        }

        /// A news item with FM's common header, put at the end of the inbox.
        @discardableResult
        func item(_ kind: String, serial: UInt32, day: UInt16, year: UInt16 = 2029, team: UInt32 = 0x438, from: Int64 = 0,
                  job: UInt8 = 0, size: Int = 0x600) -> FakeRecord {
            let item = game.record(kind, size: size, vtable: kind)
            item.set("sender", Int(L.sender), from)
            item.set("day", Int(L.day), day | 0x2000)
            item.set("year", Int(L.year), year)
            item.set("team", Int(L.team), team)
            item.set("serial", Int(L.serial), serial)
            item.set("job", Int(L.senderJob), job)
            items.append(item.address)
            return item
        }

        /// The inbox vector, as FM's list off the manager's record holds it.
        func inbox(today: Date? = GameDate.checked(year: 2029, dayOfYear: 290), items override: [Int64]? = nil) -> Inbox {
            let list = override ?? items
            let buffer = game.allocate(max(8, list.count * 8))
            for (i, item) in list.enumerated() { game.poke(item, at: buffer + Int64(i * 8)) }
            let head = game.record("vector", size: 24)
            head.set("begin", 0, buffer)
            head.set("end", 8, buffer + Int64(list.count * 8))
            head.set("capacity", 16, buffer + Int64(max(1, list.count) * 8))
            game.poke(head.address, at: manager.address + L.items)
            return InboxReader(game: game.process(), rtti: Rtti(game.process())).inbox(manager: manager.address, teams: teams, today: today)
        }

        /// As FM keeps them: a vector of pointers, each to a record of its own 0x50 bytes that starts with the person's
        /// club and has their database index at `ContractsExpiring.index`, with a second club, a team and a nation between.
        /// `club` false leaves the club out of the last record.
        func contracts(in item: FakeRecord, indexes: [UInt32], club withClub: Bool = true) {
            let buffer = game.allocate(max(8, indexes.count * 8))
            for (i, index) in indexes.enumerated() {
                let record = game.record("contract expiring", size: 0x50)
                if withClub || i < indexes.count - 1 { record.set("club", L.ContractsExpiring.club, club) }
                record.set("other club", 8, rivals)
                record.set("team", 0x10, first)
                record.set("index", L.ContractsExpiring.index, index)
                record.set("unknown", 0x30, UInt32.max)
                game.poke(record.address, at: buffer + Int64(i * 8))
            }
            item.set("people begin", Int(L.ContractsExpiring.people), buffer)
            item.set("people end", Int(L.ContractsExpiring.people) + 8, buffer + Int64(indexes.count * 8))
            item.set("people capacity", Int(L.ContractsExpiring.people) + 16, buffer + Int64(indexes.count * 8))
        }
    }

    private func items(_ inbox: Inbox, file: StaticString = #filePath, line: UInt = #line) throws -> [InboxItem] {
        switch inbox {
        case .items(let items): return items
        case .failed(let why):
            XCTFail("The inbox failed its check: \(why)", file: file, line: line)
            throw XCTSkip()
        }
    }

    private func failure(_ inbox: Inbox) -> String? {
        if case .failed(let why) = inbox { return why }
        return nil
    }

    func testReadsEachItemWithWhatItsKindIsAbout() throws {
        let world = Club()
        let injury = world.game.record("INJURY", size: 0x28, vtable: "INJURY")
        injury.set("name", Int(MacLayout.Injury.name), world.game.string("a twisted knee"))

        let report = world.item("INJURY_REPORT_NEWS_ITEM", serial: 100, day: 271, from: world.identity(world.physio), job: 50)
        report.set("injured on day", Int(L.InjuryReport.injuredOn), UInt16(271))
        report.set("injured on year", Int(L.InjuryReport.injuredOn) + 2, UInt16(2029))
        report.set("days", Int(L.InjuryReport.days), UInt16(38))
        report.set("injury", Int(L.InjuryReport.injury), injury.address)
        report.set("player", Int(L.InjuryReport.player), world.identity(world.player))

        let expiring = world.item("CONTRACT_EXPIRES_SOON_NEWS", serial: 101, day: 274, from: world.identity(world.director), job: 10)
        world.contracts(in: expiring, indexes: [73, 71, 999])

        let transfer = world.item("TRANSFER_COMPLETED_NEWS", serial: 102, day: 274, team: 0x4401, from: world.identity(world.director), job: 10)
        transfer.set("person", Int(L.TransferCompleted.person), world.identity(world.physio))
        transfer.set("team", Int(L.TransferCompleted.team), world.rivalsFirst)

        let plea = world.item("PLAYER_COME_AND_GET_ME_PLEA_NEWS_ITEM", serial: 103, day: 280, team: L.world, from: world.agent)
        plea.set("player", Int(L.ComeAndGetMe.player), world.identity(world.player))
        plea.set("team", Int(L.ComeAndGetMe.team), world.rivalsFirst)

        world.item("BOARD_CONFIDENCE_UPDATE_NEWS", serial: 104, day: 280, from: world.identity(world.director), job: 4)

        let unhappy = world.item("PLAYER_UNHAPPINESS_TRAINING_NEWS", serial: 105, day: 281, from: world.identity(world.director), job: 2)
        unhappy.set("player", Int(L.UnhappyWithTraining.player), world.identity(world.player))
        unhappy.set("coach", Int(L.UnhappyWithTraining.player) + 8, world.identity(world.director))
        unhappy.set("team", Int(L.UnhappyWithTraining.player) + 16, world.first)
        let fine = world.item("FINE_NEWS", serial: 106, day: 281)
        fine.set("player", Int(L.Fine.player), world.identity(world.player))
        fine.set("user", Int(L.Fine.player) + 8, world.identity(world.director))
        fine.set("club", Int(L.Fine.player) + 16, world.club)
        let feedback = world.item("COACH_FEEDBACK_ON_PLAYER_NEWS_ITEM", serial: 107, day: 282, from: world.identity(world.director), job: 20)
        feedback.set("user", Int(L.CoachFeedback.player) - 8, world.identity(world.director))
        feedback.set("player", Int(L.CoachFeedback.player), world.identity(world.player))

        let items = try items(world.inbox())
        XCTAssertEqual(items.map(\.serial), [100, 101, 102, 103, 104, 105, 106, 107])
        XCTAssertEqual(items.map(\.kind), ["injury report", "contract expires soon", "transfer completed", "player come and get me plea",
                                           "board confidence update", "player unhappiness training", "fine", "coach feedback on player"])
        XCTAssertEqual(items.map { Output.day($0.date) }, [271, 274, 274, 280, 280, 281, 281, 282], "the upper bits of the day word aren't the day")
        XCTAssertEqual(items.map(\.team), [0x438, 0x438, 0x4401, nil, 0x438, 0x438, 0x438, 0x438])
        XCTAssertEqual(items.map(\.isImportant), [true, true, true, true, true, true, true, false])
        XCTAssertEqual(items[0].sender?.name, "Pat Physio")
        XCTAssertEqual(items[0].sender?.uid, 7001)
        XCTAssertEqual(items[0].senderJob, "Head Physio")
        XCTAssertEqual(items[1].senderJob, "Director of Football")
        XCTAssertEqual(items[4].senderJob, "Chairperson", "the job is the item's, not the person's now")
        XCTAssertNil(items[3].sender)
        XCTAssertTrue(items[3].fromAgent)
        XCTAssertNil(items[3].senderJob)

        let player = NewsPerson(uid: 7003, index: 73, isPlayer: true, name: "Sam Striker")
        XCTAssertEqual(items[0].subject, .injury(player: player, injury: "A twisted knee", on: GameDate.checked(year: 2029, dayOfYear: 271), days: 38))
        XCTAssertEqual(items[1].subject, .contractsExpiring(indexes: [73, 71, 999]))
        XCTAssertEqual(items[2].subject, .transfer(person: NewsPerson(uid: 7001, index: 71, isPlayer: false, name: "Pat Physio"),
                                                   club: "Fixture Town AFC"))
        XCTAssertEqual(items[3].subject, .comeAndGetMe(player: player, club: "Fixture Town AFC"))
        XCTAssertNil(items[4].subject, "a kind whose fields aren't known says nothing more")
        XCTAssertEqual(items[5].subject, .unhappyWithTraining(player: player))
        XCTAssertEqual(items[6].subject, .fine(player: player))
        XCTAssertEqual(items[7].subject, .coachFeedback(player: player))
    }

    /// The people a contracts-expiring item names are a vector of pointers to records of their own, as on Molde's save, not
    /// records inline: two pointers are 16 bytes, which no record size divides.
    func testContractsExpiringAreAVectorOfPointersToRecords() throws {
        let world = Club()
        let two = world.item("CONTRACT_EXPIRES_SOON_NEWS", serial: 1, day: 274)
        world.contracts(in: two, indexes: [35080, 37369])
        let one = world.item("CONTRACT_EXPIRES_SOON_NEWS", serial: 2, day: 274)
        world.contracts(in: one, indexes: [7141])
        let items = try items(world.inbox())
        XCTAssertEqual(items.map(\.subject), [.contractsExpiring(indexes: [35080, 37369]), .contractsExpiring(indexes: [7141])])
    }

    /// A field that isn't what it should be leaves the item's subject out, never a guess, and the item stays.
    func testAFieldThatIsntWhatItShouldBeLeavesTheSubjectOut() throws {
        let world = Club()
        // A record that doesn't start with a club: the whole list goes, not just that person.
        let expiring = world.item("CONTRACT_EXPIRES_SOON_NEWS", serial: 1, day: 274)
        world.contracts(in: expiring, indexes: [73, 71], club: false)
        // A staff member where the player should be.
        let plea = world.item("PLAYER_COME_AND_GET_ME_PLEA_NEWS_ITEM", serial: 2, day: 275)
        plea.set("player", Int(L.ComeAndGetMe.player), world.identity(world.director))
        plea.set("team", Int(L.ComeAndGetMe.team), world.rivalsFirst)
        // An injury report pointing at nothing readable.
        let report = world.item("INJURY_REPORT_NEWS_ITEM", serial: 3, day: 276, from: Int64.max - 3)
        report.set("player", Int(L.InjuryReport.player), Int64.max - 3)
        report.set("injury", Int(L.InjuryReport.injury), Int64.max - 3)
        // A contracts-expiring item whose vector holds a pointer to nothing readable.
        let unreadable = world.item("CONTRACT_EXPIRES_SOON_NEWS", serial: 4, day: 276)
        let pointers = world.game.allocate(8)
        world.game.poke(Int64.max - 7, at: pointers)
        unreadable.set("people begin", Int(L.ContractsExpiring.people), pointers)
        unreadable.set("people end", Int(L.ContractsExpiring.people) + 8, pointers + 8)
        // Staff where the fined, unhappy or reported-on player should be.
        for (serial, kind, at) in [(UInt32(5), "FINE_NEWS", L.Fine.player), (6, "PLAYER_UNHAPPINESS_TRAINING_NEWS", L.UnhappyWithTraining.player),
                                   (7, "COACH_FEEDBACK_ON_PLAYER_NEWS_ITEM", L.CoachFeedback.player)] {
            world.item(kind, serial: serial, day: 277).set("player", Int(at), world.identity(world.director))
        }

        let items = try items(world.inbox())
        XCTAssertEqual(items.count, 7)
        XCTAssertEqual(items.map(\.subject), [nil, nil, nil, nil, nil, nil, nil])
        XCTAssertNil(items[2].sender)
    }

    func testWhichKindsAreImportant() {
        for name in ["INJURY_REPORT_NEWS_ITEM", "INJURY_FULL_TRAINING_NEWS", "TRANSFER_COMPLETED_NEWS", "TRANSFER_OFFER_CONFIRMATION_NEWS",
                     "TRADE_OFFER_NEWS", "PLAYER_COME_AND_GET_ME_PLEA_NEWS_ITEM", "PLAYER_UNHAPPINESS_TRAINING_NEWS", "FINE_NEWS",
                     "CONTRACT_EXPIRES_SOON_NEWS", "CONTRACT_ADD_ON_ACTIVATED_NEWS", "BOARD_CONFIDENCE_UPDATE_NEWS"] {
            XCTAssertTrue(InboxReader.isImportant(name), name)
        }
        for name in ["STAFF_MEETING_ADVICE_NEWS", "PRESS_CONFERENCE_SUMMARY_NEWS", "PRE_MATCH_ODDS_NEWS", "MANAGER_SACK_RACE_NEWS",
                     "COACH_FEEDBACK_ON_PLAYER_NEWS_ITEM", "MONTHLY_FINANCIAL_UPDATE_NEWS", "ACCUMULATIVE_BAN_NEWS", "CUP_DRAW_WARNING"] {
            XCTAssertFalse(InboxReader.isImportant(name), name)
        }
    }

    func testAnInboxThatDoesntReadAsOneFailsAsAWhole() {
        func failing(_ build: (Club) -> Void, today: Date? = GameDate.checked(year: 2029, dayOfYear: 290)) -> String? {
            let world = Club()
            build(world)
            return failure(world.inbox(today: today))
        }
        XCTAssertNotNil(failing { world in
            world.item("BOARD_CONFIDENCE_UPDATE_NEWS", serial: 5, day: 270)
            world.item("BOARD_CONFIDENCE_UPDATE_NEWS", serial: 5, day: 271)
        }, "the counter must rise")
        XCTAssertNotNil(failing { world in
            world.item("BOARD_CONFIDENCE_UPDATE_NEWS", serial: 5, day: 271)
            world.item("BOARD_CONFIDENCE_UPDATE_NEWS", serial: 6, day: 270)
        }, "the dates mustn't go back")
        XCTAssertNotNil(failing { world in world.item("BOARD_CONFIDENCE_UPDATE_NEWS", serial: 5, day: 291) }, "nothing after the game date")
        XCTAssertNotNil(failing { world in world.item("BOARD_CONFIDENCE_UPDATE_NEWS", serial: 5, day: 270, team: 0x900) },
                        "only the user's club's teams")
        XCTAssertNotNil(failing { world in world.item("BOARD_CONFIDENCE_UPDATE_NEWS", serial: 5, day: 0) }, "every item has a date")
        let world = Club()
        world.item("BOARD_CONFIDENCE_UPDATE_NEWS", serial: 5, day: 270)
        XCTAssertNotNil(failure(world.inbox(items: [Int64.max - 3])), "an item that can't be read")
        let notNews = world.game.record("Nothing", size: L.header)
        XCTAssertNotNil(failure(world.inbox(items: [notNews.address])), "an item that isn't one of FM's objects")
        XCTAssertNotNil(failure(InboxReader(game: world.game.process(), rtti: Rtti(world.game.process()))
            .inbox(manager: 0, teams: world.teams, today: nil)), "no manager")
    }

    func testAnEmptyInboxIsNoItems() throws {
        let world = Club()
        XCTAssertEqual(try items(world.inbox()).count, 0)
    }

    func testClassNamesInPlainWords() {
        XCTAssertEqual(InboxReader.plain("N2db23INJURY_REPORT_NEWS_ITEME"), "INJURY_REPORT_NEWS_ITEM")
        XCTAssertEqual(InboxReader.plain("4CLUB"), "CLUB")
        XCTAssertEqual(InboxReader.plain("N6sicore17NULL_TYPED_TRAITSE"), "NULL_TYPED_TRAITS")
        XCTAssertEqual(InboxReader.kind("INJURY_REPORT_NEWS_ITEM"), "injury report")
        XCTAssertEqual(InboxReader.kind("CONTRACT_EXPIRES_SOON_NEWS"), "contract expires soon")
        XCTAssertEqual(InboxReader.kind("CUP_DRAW_WARNING"), "cup draw warning")
    }

    /// The read keeps the human club's teams by index, with their types, and no other club's.
    func testTheReadKeepsTheHumanClubsTeams() throws {
        let world = Club()
        let details = world.game.record("CLUB_HUMAN_MANAGER_DETAILS", size: MacLayout.Human.team + 8, vtable: "CLUB_HUMAN_MANAGER_DETAILS")
        details.set("team", MacLayout.Human.team, world.first)
        let database = try world.game.read()
        XCTAssertEqual(database.humanClubs.map(\.team), [world.first])
        XCTAssertEqual(database.humanTeams[world.first], [0x438: 0, 0x4401: 11])
    }
}

private enum Output {
    static func day(_ date: Date) -> Int { GameDate.calendar.ordinality(of: .day, in: .year, for: date) ?? 0 }
}
