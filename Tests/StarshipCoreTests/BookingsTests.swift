@testable import StarshipCore
import XCTest

/// Made-up disciplinary rule sets, competitions that play under them, and players' yellow-card counts, laid out as
/// `MacLayout` says.
extension FakeGame {
    /// The begin, end and capacity words of a vector held inside `record` at `offset`, over `words`.
    func vector(_ words: [Int64], in record: FakeRecord, at offset: Int, named name: String, capacity: Bool = true) {
        let items = allocate(max(8, words.count * 8))
        for (i, word) in words.enumerated() { poke(word, at: items + Int64(i * 8)) }
        let begin = words.isEmpty ? 0 : items, end = words.isEmpty ? 0 : items + Int64(words.count * 8)
        record.set("\(name) begin", offset, begin)
        record.set("\(name) end", offset + 8, end)
        if capacity { record.set("\(name) capacity", offset + 16, end) }
    }

    /// FM's `GAME_DISCIPLINE`, with a rule set for each count type, by rules index. `misnumbered` carries the next one's number.
    func discipline(countTypes: [UInt8], misnumbered: Int? = nil) -> (object: Int64, ruleSets: [Int64]) {
        typealias R = MacLayout.DisciplineRules
        let ruleSets = countTypes.enumerated().map { index, type -> Int64 in
            let record = self.record("Rule set", size: R.size)
            record.set("index", Int(R.index), UInt16(index == misnumbered ? index + 1 : index))
            record.set("countType", Int(R.countType), type)
            return record.address
        }
        let object = record("Discipline", size: Int(MacLayout.Discipline.rules) + 24)
        vector(ruleSets, in: object, at: Int(MacLayout.Discipline.rules), named: "rules")
        return (object.address, ruleSets)
    }

    /// A competition that plays under `ruleSets[slot]`, by the path FM's own check takes. A slot of -1 for none.
    func competition(_ name: String, index: UInt32, ruleSets: [Int64], slot: Int8) -> Int64 {
        let record = self.record("Competition", size: Int(MacLayout.Comp.actual) + 8)
        record.set("index", Int(MacLayout.Comp.index), index)
        record.set("name", MacLayout.competitionName, string(name))
        let holder = self.record("Rules holder", size: Int(MacLayout.CompRules.list) + 24)
        vector(ruleSets, in: holder, at: Int(MacLayout.CompRules.list), named: "rule sets")
        let owner = self.record("Rules owner", size: Int(MacLayout.CompRules.holder) + 8)
        owner.set("holder", Int(MacLayout.CompRules.holder), holder.address)
        let actual = self.record("Actual competition", size: Int(MacLayout.ActualComp.rulesOwner) + 8)
        actual.set("rulesSlot", Int(MacLayout.ActualComp.rulesSlot), slot)
        actual.set("rulesOwner", Int(MacLayout.ActualComp.rulesOwner), owner.address)
        record.set("actual", Int(MacLayout.Comp.actual), actual.address)
        return record.address
    }

    /// A player's counts, each a rules index and its yellow cards.
    func bookingCounts(_ counts: [(rules: Int16, count: UInt8)], on player: FakeRecord) {
        typealias B = MacLayout.BookingCount
        let entries = counts.map { rules, count -> Int64 in
            let record = self.record("Booking count", size: B.size)
            record.set("rules", B.rules, rules)
            record.set("count", B.count, count)
            return record.address
        }
        // The word after the list isn't known to be its capacity, so the reader doesn't read it.
        vector(entries, in: player, at: MacLayout.Player.bookingCounts, named: "booking counts", capacity: false)
    }
}

/// FM's count-until-next-ban as a test wants it: FM's sequences for a few rule sets, worked out from the count it's handed.
private final class BookingEngine: GameRulesEngine {
    let discipline: Int64?
    /// The counts that bring a ban under each rule set.
    var steps: [Int: [Int]] = [0: [2, 4, 6, 8], 2: [2, 4, 6], 3: [4, 6, 8, 10, 12], 4: [2, 3, 4, 5, 6]]
    /// Added to the count FM says it went by, as an answer for another count would be.
    var countOff = 0
    var answers = true
    private(set) var asked: [(rules: Int, count: Int?)] = []

    init(discipline: Int64?) { self.discipline = discipline }

    var supportsInjuryDays: Bool { false }
    func interest(player: Player, team: Int64) -> (transfer: JoinInterest, loan: JoinInterest)? { nil }
    func staffInterest(staff: Staff, team: Int64, level: Int) -> Bool? { nil }
    func preferredJob(staff: Staff) -> Int? { nil }
    func jobPreferences(staff: Staff) -> [UInt8]? { nil }
    func roleRows(player: Player, team: Int64) -> [RoleRow]? { nil }
    func seasonStats(player: Player, season: Int) -> SeasonStats? { nil }
    func form(player: Player) -> String? { nil }
    func injuryReturnDays(player: Player) -> Int? { nil }

    func nextBan(rules: Int, bookingCount: [UInt8]?) -> NextBan? {
        let count = bookingCount.map { Int($0[MacLayout.BookingCount.count]) }
        asked.append((rules, count))
        if let bookingCount {
            XCTAssertEqual(Int(bookingCount.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: MacLayout.BookingCount.rules, as: Int16.self) }), rules)
        }
        guard answers, let steps = steps[rules] else { return nil }
        let now = count ?? 0
        let next = steps.first { $0 > now } ?? now + 1
        return NextBan(left: next - now, length: 1, count: now + countOff, lastBanAt: steps.last { $0 <= now } ?? 0)
    }
}

/// Yellow cards toward a ban, read from made-up records with FM's answers from a made-up engine, and the checks that switch
/// them off. Every name and number is made up.
final class BookingsTests: XCTestCase {
    static let today: (day: UInt16, year: UInt16) = (255, 2029)
    static let league: UInt32 = 7, cup: UInt32 = 8, secondDivision: UInt32 = 9, nationsCup: UInt32 = 20, friendlies: UInt32 = 30
    static let abroadLeague: UInt32 = 11

    /// Rule sets 0 for a nations' cup, 1 for a league abroad that counts points, 2 that nothing plays under, 3 for the league
    /// and the division below, 4 for the cup.
    private final class World {
        let game = FakeGame()
        let discipline: Int64
        let ruleSets: [Int64]
        let rovers: Int64, roversFirst: Int64, town: Int64, townFirst: Int64, abroad: Int64
        let records: [UInt32: Int64]

        init(countTypes: [UInt8] = [0, 1, 0, 0, 0], misnumbered: Int? = nil) {
            let continent = game.continent("Made-up Continent")
            let area = game.allocate(16)
            let mockovia = game.nation("Mockovia", code: "MCK", continent: continent, area: area, index: 160)
            (discipline, ruleSets) = game.discipline(countTypes: countTypes, misnumbered: misnumbered)
            // An association's competitions share its list of rule sets, each at its own slot.
            let association = [ruleSets[3], ruleSets[4]]
            let league = game.competition("Mock League One", index: BookingsTests.league, ruleSets: association, slot: 0)
            records = [
                BookingsTests.league: league,
                BookingsTests.secondDivision: game.competition("Mock League Two", index: BookingsTests.secondDivision, ruleSets: association, slot: 0),
                BookingsTests.cup: game.competition("Mock Cup", index: BookingsTests.cup, ruleSets: association, slot: 1),
                BookingsTests.nationsCup: game.competition("Made-up Nations Cup", index: BookingsTests.nationsCup, ruleSets: [ruleSets[0]], slot: 0),
                BookingsTests.friendlies: game.competition("Mock Friendlies", index: BookingsTests.friendlies, ruleSets: association, slot: -1),
                BookingsTests.abroadLeague: game.competition("Points Premier", index: BookingsTests.abroadLeague, ruleSets: [ruleSets[1]], slot: 0),
            ]
            rovers = game.club(full: "Mockport Rovers FC", short: "Mockport", nation: mockovia)
            town = game.club(full: "Fixture Town AFC", short: "Fixture Town", nation: mockovia)
            roversFirst = game.team(club: rovers, index: 0x1267, type: 0, competition: league)
            townFirst = game.team(club: town, index: 0x2301, type: 0, competition: league)
            abroad = game.team(club: game.club(full: "Abroad City", short: "Abroad", nation: mockovia), index: 0x3301, type: 0,
                               competition: records[BookingsTests.abroadLeague]!)
            game.transferManager(day: BookingsTests.today.day, year: BookingsTests.today.year)
        }

        /// A player at `team` with these counts (none for no list), matches for it and bans.
        @discardableResult
        func player(_ uid: UInt32, counts: [(rules: Int16, count: UInt8)]?, matches: [(day: UInt16, competition: UInt32)] = [],
                    bans: [FakeGame.BanValues] = [], at team: Int64? = nil) -> FakeRecord {
            let team = team ?? roversFirst
            var values = FakeGame.PlayerValues()
            values.person.uid = uid
            values.person.index = uid
            values.person.commonName = "Made-up Player \(uid)"
            values.person.contract?.team = team
            values.currentTeam = team
            values.fitnessUpdated = BookingsTests.today
            values.morale = 12
            values.person.contract?.playingTime = 10
            values.history = game.history([(team: team, entries: matches.map { match in
                FakeGame.HistoryEntry(opponent: team == townFirst ? roversFirst : townFirst, day: match.day, competition: match.competition,
                                      played: FakeGame.PlayedValues())
            })], bans: bans.map(game.ban))
            let record = game.player(values)
            if let counts { game.bookingCounts(counts, on: record) }
            return record
        }

        /// The reader, with Rovers as the human club.
        func reader(_ engine: (World) -> GameRulesEngine? = { BookingEngine(discipline: $0.discipline) },
                    database prepare: (Database) -> Void = { _ in }) throws -> (reader: BookingsReader, players: [UInt32: Player]) {
            let database = try game.read()
            database.humanClubs = [(team: roversFirst, name: "Mockport Rovers FC", manager: 0)]
            prepare(database)
            let records = self.records
            let reader = BookingsReader(game: game.process(), database: database, engine: engine(self), competitionRecords: { records })
            return (reader, Dictionary(uniqueKeysWithValues: database.players.map { ($0.uid, $0) }))
        }
    }

    /// A ban for bookings in the league at 4 and in the cup at 2, both given in the last few days.
    private static let recentBans = [
        FakeGame.BanValues(day: 250, kind: 0, rules: 3, bookingsAt: 4),
        FakeGame.BanValues(scope: 5, day: 248, kind: 0, rules: 4, bookingsAt: 2),
    ]

    // MARK: What it gives

    func testGivesEachRuleSetsCountWithFMsAnswer() throws {
        let world = World()
        // Has played in both divisions and the cup for Rovers, has a card for his nation, and a count at 0 under a rule set
        // nothing plays under.
        world.player(1, counts: [(3, 5), (4, 2), (0, 1), (2, 0)],
                     matches: [(200, BookingsTests.league), (230, BookingsTests.secondDivision), (240, BookingsTests.cup)],
                     bans: Self.recentBans)
        // No counts yet. His teammates' matches say Rovers play in the cup and the second division.
        world.player(2, counts: nil)
        // At another club, which only plays its league.
        world.player(3, counts: [(3, 1)], at: world.townFirst)

        let (reader, players) = try world.reader()
        XCTAssertNil(reader.off)
        XCTAssertTrue(reader.status.hasPrefix("on: FM's own count and answer"), reader.status)
        XCTAssertTrue(reader.status.contains("2 of 2 bans for bookings given in the last 30 days"), reader.status)

        let first = try XCTUnwrap(reader.bookings(of: try XCTUnwrap(players[1])))
        XCTAssertEqual(first.map(\.rules), [3, 4, 0], "his team's league first, then its cup, then the rest; nothing at 0 that isn't his team's")
        XCTAssertEqual(first.map(\.competitions), [["Mock League One", "Mock League Two"], ["Mock Cup"], ["Made-up Nations Cup"]])
        XCTAssertEqual(first.map(\.teamPlays), [true, true, false])
        XCTAssertEqual(first.map(\.next), [NextBan(left: 1, length: 1, count: 5, lastBanAt: 4), NextBan(left: 1, length: 1, count: 2, lastBanAt: 2),
                                           NextBan(left: 1, length: 1, count: 1, lastBanAt: 0)])

        let second = try XCTUnwrap(reader.bookings(of: try XCTUnwrap(players[2])))
        XCTAssertEqual(second.map(\.rules), [3, 4])
        XCTAssertEqual(second.map(\.next), [NextBan(left: 4, length: 1, count: 0, lastBanAt: 0), NextBan(left: 2, length: 1, count: 0, lastBanAt: 0)],
                       "from 0, by FM's answer for no count")

        let other = try XCTUnwrap(reader.bookings(of: try XCTUnwrap(players[3])))
        XCTAssertEqual(other.map(\.competitions), [["Mock League One"]])
        XCTAssertEqual(other.first?.next?.left, 3)
    }

    /// A rule set that counts points or a window of matches is listed, but FM's numbers for it aren't given.
    func testARuleSetThatCountsAnotherWayGivesNoNumbers() throws {
        let world = World()
        world.player(1, counts: [(3, 5), (4, 2)], bans: Self.recentBans)
        world.player(2, counts: [(1, 3)], at: world.abroad)
        let (reader, players) = try world.reader()
        XCTAssertNil(reader.off)
        let bookings = try XCTUnwrap(reader.bookings(of: try XCTUnwrap(players[2])))
        XCTAssertEqual(bookings.map(\.competitions), [["Points Premier"]])
        XCTAssertEqual(bookings.map(\.plain), [false])
        XCTAssertNil(bookings.first?.next)
    }

    /// A count FM's memory changed after the check, as when FM plays a match without the date moving, is read again.
    func testEachAnswerReadsTheCountAgain() throws {
        let world = World()
        let record = world.player(1, counts: [(3, 2)])
        let (reader, players) = try world.reader()
        let player = try XCTUnwrap(players[1])
        XCTAssertEqual(reader.bookings(of: player)?.first?.next?.count, 2)
        let list = world.game.process().readPointer(record.address + Int64(MacLayout.Player.bookingCounts))
        let entry = world.game.process().readPointer(list)
        world.game.poke(UInt8(3), at: entry + Int64(MacLayout.BookingCount.count))
        XCTAssertEqual(reader.bookings(of: player)?.first?.next, NextBan(left: 1, length: 1, count: 3, lastBanAt: 0))
    }

    /// A list whose bounds are garbage reads as no list for that player, without a trap, and one in a hundred doesn't
    /// switch the rest off.
    func testAGarbageListIsNoList() throws {
        let world = World()
        world.player(1, counts: [(3, 2)])
        for uid in 2...110 { world.player(UInt32(uid), counts: [], at: world.townFirst) }
        let bad = world.player(200, counts: nil, at: world.townFirst)
        bad.set("bad begin", MacLayout.Player.bookingCounts, Int64.max - 3)
        bad.set("bad end", MacLayout.Player.bookingCounts + 8, Int64.max)
        let (reader, players) = try world.reader()
        XCTAssertNil(reader.off)
        XCTAssertNil(reader.bookings(of: try XCTUnwrap(players[200])))
        XCTAssertEqual(reader.bookings(of: try XCTUnwrap(players[1]))?.first?.next?.count, 2)
    }

    // MARK: The check

    /// The check's bans are the ones of the last 30 days: an older one, from before FM reset the count, doesn't count.
    func testAnOldBanFromBeforeAResetIsNotChecked() throws {
        let world = World()
        world.player(1, counts: [(3, 0)], bans: [FakeGame.BanValues(day: 200, kind: 0, rules: 3, bookingsAt: 4)])
        let (reader, _) = try world.reader()
        XCTAssertNil(reader.off)
        XCTAssertTrue(reader.status.contains("no ban for bookings was given in the last 30 days"), reader.status)
    }

    /// FM's answers must agree with the save's bans: a ban at 4 for a player whose count is 3 switches it off for the read.
    func testABanFMsAnswerDisagreesWithSwitchesItOff() throws {
        let world = World()
        world.player(1, counts: [(3, 3)], bans: [Self.recentBans[0]])
        let (reader, players) = try world.reader()
        XCTAssertEqual(reader.off, "its check failed: FM's answers disagree with 1 of 1 bans for bookings given in the last 30 days "
                       + "under the rule sets of your club's competitions")
        XCTAssertTrue(reader.status.hasPrefix("off: its check failed"))
        XCTAssertNil(reader.bookings(of: try XCTUnwrap(players[1])))
    }

    /// A ban that didn't come at a step of FM's: the count is past it, but FM says his last ban came at another.
    func testABanAtAnotherStepSwitchesItOff() throws {
        let world = World()
        world.player(1, counts: [(3, 5)], bans: [FakeGame.BanValues(day: 250, kind: 0, rules: 3, bookingsAt: 3)])
        XCTAssertTrue(try world.reader().reader.off?.contains("disagree with 1 of 1 bans") ?? false)
    }

    func testFMGoingByAnotherCountSwitchesItOff() throws {
        let world = World()
        world.player(1, counts: [(3, 5), (4, 2)], bans: Self.recentBans)
        let (reader, _) = try world.reader({ world in
            let engine = BookingEngine(discipline: world.discipline)
            engine.countOff = 1
            return engine
        })
        XCTAssertEqual(reader.off, "its check failed: FM's own answer didn't fit the count read for 2 of 2 counts")
    }

    func testFMNotAnsweringSwitchesItOff() throws {
        let world = World()
        world.player(1, counts: [(3, 5)])
        let (reader, _) = try world.reader({ world in
            let engine = BookingEngine(discipline: world.discipline)
            engine.answers = false
            return engine
        })
        XCTAssertEqual(reader.off, "its check failed: FM's rules didn't answer for 1 of 1 counts")
    }

    func testARuleSetWithAnotherNumberSwitchesItOff() throws {
        let world = World(misnumbered: 2)
        world.player(1, counts: [(3, 5)])
        XCTAssertEqual(try world.reader().reader.off, "its check failed: 1 of 5 of FM's disciplinary rule sets don't carry their own number")
    }

    /// A count no season has, two counts under one rule set, or a rules index FM doesn't have: not a list of counts.
    func testImpossibleCountsSwitchItOff() throws {
        for counts: [(rules: Int16, count: UInt8)] in [[(3, 200)], [(3, 1), (3, 2)], [(9, 1)], [(-1, 1)]] {
            let world = World()
            world.player(1, counts: counts)
            world.player(2, counts: [(3, 1)])
            let (reader, players) = try world.reader()
            XCTAssertEqual(reader.off, "its check failed: 1 of 2 players at a club have a list of yellow-card counts that isn't one", "\(counts)")
            XCTAssertNil(reader.bookings(of: try XCTUnwrap(players[2])))
        }
    }

    func testWithoutFMsRulesOrTheirDisciplineOrBansItIsOff() throws {
        let world = World()
        world.player(1, counts: [(3, 5)])
        XCTAssertEqual(try world.reader({ _ in nil }).reader.off, "it comes from FM's own rules, which are off on this build")
        XCTAssertEqual(try world.reader({ _ in BookingEngine(discipline: nil) }).reader.off,
                       "FM's disciplinary rules weren't found where FM keeps them on this build")
        let (reader, _) = try world.reader(database: { $0.stateOff[.bans] = "its check failed: made up" })
        XCTAssertEqual(reader.off, "it's checked against the save's bans, which are off: its check failed: made up")
    }

    /// A league always plays under a rule set: the human club's not leading to one means the path to them has moved.
    func testALeagueWithNoRuleSetSwitchesItOff() throws {
        let world = World()
        let team = world.game.team(club: world.rovers, index: 0x1300, type: 0, competition: world.records[BookingsTests.friendlies]!)
        world.player(1, counts: [(3, 5)], at: team)
        let (reader, _) = try world.reader(database: { $0.humanClubs = [(team: team, name: "Mockport Rovers FC", manager: 0)] })
        XCTAssertEqual(reader.off, "its check failed: the rule set Mockport Rovers FC's league plays under wasn't found where FM keeps it")
    }

    /// The ban's two new fields, as the reader keeps them.
    func testABansRulesAndCountAreRead() throws {
        let world = World()
        world.player(1, counts: [(3, 5)], bans: [Self.recentBans[0]])
        let (_, players) = try world.reader()
        let ban = try XCTUnwrap(players[1]?.storedBans?.first)
        XCTAssertEqual(ban.rules, 3)
        XCTAssertEqual(ban.bookingsAt, 4)
    }
}
