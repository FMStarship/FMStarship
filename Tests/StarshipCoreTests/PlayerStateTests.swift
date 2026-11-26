@testable import StarshipCore
import XCTest

/// Made-up bans, laid out as `MacLayout.Ban` says.
extension FakeGame {
    struct BanValues {
        var association: UInt32 = PlayerStateTests.mockoviaFA
        var scope: UInt8 = PlayerStateTests.leagueScope
        /// From `banMatch`, for a red card.
        var match: Int64 = 0
        var day: UInt16 = 240
        var year: UInt16 = 2029
        var kind: UInt8 = 0
        var matches: UInt8 = 1
        var served: UInt8 = 0
        /// The rule set's rules index, and the yellow-card count a ban for bookings came at.
        var rules: UInt16 = 0
        var bookingsAt: UInt8 = 0
    }

    func ban(_ values: BanValues) -> Int64 {
        typealias B = MacLayout.Ban
        let record = self.record("Ban", size: B.size)
        record.set("association", B.association, values.association)
        record.set("scope", B.scope, values.scope)
        record.set("match", B.match, values.match)
        record.set("day", B.day, values.day)
        record.set("year", B.year, values.year)
        record.set("kind", B.kind, values.kind)
        record.set("matches", B.matches, values.matches)
        record.set("served", B.served, values.served)
        record.set("rules", B.rules, values.rules)
        record.set("bookingsAt", B.bookingsAt, values.bookingsAt)
        return record.address
    }

    /// The match a red card was in.
    func banMatch(competition: Int64, home: Int64, away: Int64) -> Int64 {
        typealias M = MacLayout.BanMatch
        let record = self.record("Ban match", size: 0x28)
        record.set("name", Int(M.name), fixtureName(competition: competition))
        record.set("home", Int(M.home), home)
        record.set("away", Int(M.away), away)
        return record.address
    }
}

/// FM's getters as a test wants them: one answer for everyone, and a count of the questions.
private final class StateEngine: GameRulesEngine {
    var answer: Fitness?
    /// Answers with the stored values for a player brought up to date today, as FM's getters do.
    var echo = false
    private(set) var asked = 0
    init(_ answer: Fitness?) { self.answer = answer }
    var supportsInjuryDays: Bool { false }
    func interest(player: Player, team: Int64) -> (transfer: JoinInterest, loan: JoinInterest)? { nil }
    func staffInterest(staff: Staff, team: Int64, level: Int) -> Bool? { nil }
    func preferredJob(staff: Staff) -> Int? { nil }
    func jobPreferences(staff: Staff) -> [UInt8]? { nil }
    func roleRows(player: Player, team: Int64) -> [RoleRow]? { nil }
    func seasonStats(player: Player, season: Int) -> SeasonStats? { nil }
    func form(player: Player) -> String? { nil }
    func injuryReturnDays(player: Player) -> Int? { nil }
    func fitness(player: Player) -> Fitness? {
        asked += 1
        return echo ? player.fitness ?? answer : answer
    }
}

/// Condition, sharpness, morale, playing time and bans, read from made-up records, and the checks that switch each off.
/// Every name and number is made up.
final class PlayerStateTests: XCTestCase {
    static let mockoviaFA: UInt32 = 160, fixturelandFA: UInt32 = 18, notANation: UInt32 = 3_492
    static let leagueScope: UInt8 = 6, cupScope: UInt8 = 5
    static let today: (day: UInt16, year: UInt16) = (255, 2029)

    /// Two clubs in two nations, a league with a second division under the same rule set, and a cup.
    private final class World {
        let game = FakeGame()
        let mockovia: Int64, fixtureland: Int64, twin: Int64
        let rovers: Int64, town: Int64
        let roversFirst: Int64, townFirst: Int64
        /// Fixture Town's team in Fixtureland's own league.
        let townAtHome: Int64
        let league: Int64, secondDivision: Int64, cup: Int64
        static let leagueIndex: UInt32 = 7, cupIndex: UInt32 = 8, secondDivisionIndex: UInt32 = 9, fixturelandIndex: UInt32 = 11

        /// `namelessTwin`: a nation record with Mockovia's index and no name, found before Mockovia's own.
        init(dated: Bool = true, namelessTwin: Bool = false) {
            let continent = game.continent("Made-up Continent")
            let area = game.allocate(16)
            twin = namelessTwin ? game.nation("", code: "", continent: continent, area: area, index: PlayerStateTests.mockoviaFA) : 0
            mockovia = game.nation("Mockovia", code: "MCK", continent: continent, area: area, index: PlayerStateTests.mockoviaFA)
            fixtureland = game.nation("Fixtureland", code: "FXL", continent: continent, area: area, index: PlayerStateTests.fixturelandFA)
            league = game.competition("Mock League One", index: World.leagueIndex)
            secondDivision = game.competition("Mock League Two", index: World.secondDivisionIndex)
            cup = game.competition("Mock Cup", index: World.cupIndex)
            rovers = game.club(full: "Mockport Rovers FC", short: "Mockport", nation: mockovia)
            town = game.club(full: "Fixture Town AFC", short: "Fixture Town", nation: fixtureland)
            roversFirst = game.team(club: rovers, index: 0x1267, type: 0, competition: league)
            townFirst = game.team(club: town, index: 0x2301, type: 0, competition: league)
            townAtHome = game.team(club: town, index: 0x2302, type: 0,
                                   competition: game.competition("Fixtureland Premier", index: World.fixturelandIndex))
            if dated { game.transferManager(day: PlayerStateTests.today.day, year: PlayerStateTests.today.year) }
        }

        /// A Rovers player, brought up to date today unless the test says otherwise.
        func values(_ uid: UInt32) -> FakeGame.PlayerValues {
            var values = FakeGame.PlayerValues()
            values.person.uid = uid
            values.person.index = uid
            values.person.commonName = "Made-up Player \(uid)"
            values.person.contract?.team = roversFirst
            values.currentTeam = roversFirst
            values.fitnessUpdated = PlayerStateTests.today
            values.morale = 12
            values.playingTime(10)
            return values
        }

        /// Matches for Rovers in these competitions, so a ban for bookings can find its competition.
        func played(_ competitions: [UInt32], bans: [Int64]) -> Int64 {
            game.history([(team: roversFirst, entries: competitions.enumerated().map { i, competition in
                FakeGame.HistoryEntry(opponent: townFirst, day: UInt16(230 + i), competition: competition, played: FakeGame.PlayedValues())
            })], bans: bans)
        }

        /// Rovers matches on these days, in these competitions, with his yellow cards in each.
        func booked(_ matches: [(day: UInt16, competition: UInt32, yellow: UInt8)], bans: [Int64]) -> Int64 {
            game.history([(team: roversFirst, entries: matches.map { match in
                var played = FakeGame.PlayedValues()
                played.yellow = match.yellow
                return FakeGame.HistoryEntry(opponent: townFirst, day: match.day, competition: match.competition, played: played)
            })], bans: bans)
        }

        func read() throws -> [UInt32: Player] {
            let database = try game.read()
            return Dictionary(uniqueKeysWithValues: database.players.map { ($0.uid, $0) })
        }

        /// Each player's bans, as `PlayerStateReader` works them out when asked. Nil where they weren't read.
        func bans() throws -> [UInt32: [Ban]?] {
            let database = try game.read()
            let reader = PlayerStateReader(game: game.process(), database: database)
            return Dictionary(uniqueKeysWithValues: database.players.map { ($0.uid, reader.bans(of: $0)) })
        }
    }

    // MARK: Every field

    func testReadsEveryStateField() throws {
        let world = World()
        let game = world.game
        let cupRed = game.banMatch(competition: world.cup, home: world.townFirst, away: world.roversFirst)
        var values = world.values(1)
        values.condition = 8_570
        values.sharpness = 9_210
        values.morale = 18
        values.playingTime(-37)
        values.history = world.played([World.leagueIndex, World.cupIndex], bans: [
            game.ban(FakeGame.BanValues(day: 244, kind: 0, matches: 1)),
            game.ban(FakeGame.BanValues(scope: PlayerStateTests.cupScope, match: cupRed, day: 251, kind: 2, matches: 1)),
        ])
        game.player(values)

        let database = try game.read()
        XCTAssertEqual(database.stateOff, [:])
        let player = try XCTUnwrap(database.players.first)
        XCTAssertEqual(player.fitness, Fitness(condition: 8_570, sharpness: 9_210))
        XCTAssertFalse(player.fitnessNeedsCatchUp)
        XCTAssertNil(player.fitnessUpdated)
        XCTAssertEqual(player.fitness(nil), Fitness(condition: 8_570, sharpness: 9_210), "today's needs no engine")
        XCTAssertEqual(player.morale, 18)
        XCTAssertEqual(player.playingTime, -37)

        XCTAssertEqual(player.storedBans?.count, 2)
        let bans = try XCTUnwrap(PlayerStateReader(game: game.process(), database: database).bans(of: player))
        XCTAssertEqual(bans.count, 2)
        // A ban for bookings names no match. The red card below is under the cup's rule set, not the league's, and he
        // wasn't booked in either match he played, so nothing says which competition it's for.
        XCTAssertEqual(bans[0].reason, .bookings)
        XCTAssertEqual(bans[0].competition, "")
        XCTAssertEqual(bans[0].associationName, "Mockovia")
        XCTAssertTrue(bans[0].domestic)
        XCTAssertFalse(bans[0].countsForClub)
        XCTAssertEqual(bans[0].issued, GameDate.checked(year: 2029, dayOfYear: 244))
        XCTAssertEqual(bans[1].reason, .redCard)
        XCTAssertEqual(bans[1].competition, "Mock Cup")
        XCTAssertEqual(bans[1].competitionIndex, World.cupIndex)
        XCTAssertEqual(bans[1].opponent, "Fixture Town AFC")
        XCTAssertEqual(bans[1].associationName, "Mockovia")
        XCTAssertEqual(bans[1].scope, Int(PlayerStateTests.cupScope))
        XCTAssertEqual(bans[1].left, 1)
        XCTAssertTrue(bans[1].countsForClub)
    }

    /// The league and the division below share a rule set. A ban for bookings under it is named after the one of the two
    /// the player plays in, and stays unnamed where none of the red cards' competitions is his.
    func testABanForBookingsTakesItsCompetitionFromRedCardsUnderTheSameRules() throws {
        let world = World()
        let game = world.game
        // Red cards under the league's rule set: one in each division, and one in the cup under the cup's.
        let leagueRed = game.banMatch(competition: world.league, home: world.roversFirst, away: world.townFirst)
        let secondRed = game.banMatch(competition: world.secondDivision, home: world.roversFirst, away: world.townFirst)
        var red = world.values(1)
        red.history = world.played([World.leagueIndex], bans: [
            game.ban(FakeGame.BanValues(match: leagueRed, kind: 6, matches: 3, served: 1)),
            game.ban(FakeGame.BanValues(match: secondRed, kind: 2, matches: 1)),
        ])
        game.player(red)

        var leagueBookings = world.values(2)
        leagueBookings.history = world.played([World.leagueIndex, World.cupIndex], bans: [game.ban(FakeGame.BanValues(kind: 0, matches: 1))])
        game.player(leagueBookings)

        // Plays in neither division's matches here, but the league red card above makes this the league's rule set, and
        // his team is in Mock League One.
        var cupOnly = world.values(3)
        cupOnly.history = world.played([World.cupIndex], bans: [game.ban(FakeGame.BanValues(kind: 0, matches: 2))])
        game.player(cupOnly)
        // A rule set of his own association's that nothing names.
        var unknownRules = world.values(5)
        unknownRules.history = world.played([World.leagueIndex], bans: [game.ban(FakeGame.BanValues(scope: 9, kind: 0, matches: 1))])
        game.player(unknownRules)

        // A rule set nobody has a red card under, from an association that isn't a nation the read knows, and one from
        // his own nation's.
        var abroad = world.values(4)
        abroad.person.nation = world.fixtureland
        abroad.history = world.played([World.leagueIndex], bans: [
            game.ban(FakeGame.BanValues(association: PlayerStateTests.notANation, scope: 20, year: 2028, kind: 0, matches: 2)),
            game.ban(FakeGame.BanValues(association: PlayerStateTests.fixturelandFA, scope: 3, year: 2028, kind: 0, matches: 1)),
        ])
        game.player(abroad)

        let players = try world.bans()
        let reds = try XCTUnwrap(players[1] ?? nil)
        XCTAssertEqual(reds.map(\.competition), ["Mock League One", "Mock League Two"])
        XCTAssertEqual(reds.map(\.left), [2, 1])
        XCTAssertEqual(reds.map(\.reason), [.redCard, .redCard], "both kinds of red card")
        XCTAssertEqual(reds.map(\.opponent), ["Fixture Town AFC", "Fixture Town AFC"])

        XCTAssertEqual(players[2]??.map(\.competition), ["Mock League One"])
        XCTAssertEqual(players[3]??.map(\.competition), ["Mock League One"])
        XCTAssertEqual(players[5]??.map(\.competition), [""])
        XCTAssertEqual(players[5]??.map(\.associationName), ["Mockovia"])
        XCTAssertEqual(players[5]??.map(\.countsForClub), [false])
        let foreign = try XCTUnwrap(players[4] ?? nil)
        XCTAssertEqual(foreign.map(\.competition), ["", ""])
        XCTAssertEqual(foreign.map(\.associationName), ["", "Fixtureland"])
        XCTAssertEqual(foreign.map(\.domestic), [false, false])
        XCTAssertEqual(foreign.map(\.left), [2, 1])
    }

    /// No league red card in the save: a ban for bookings takes the competition of the match he was last booked in, up to
    /// a week before it was given, when that's his team's league or a competition a red card has named. Once the league's
    /// rule set is known that way, other bans from his club's association under it are for his team's league too.
    func testABanForBookingsIsNamedFromTheMatchHeWasBookedIn() throws {
        let world = World()
        let game = world.game
        typealias Match = (day: UInt16, competition: UInt32, yellow: UInt8)
        let league = World.leagueIndex, cup = World.cupIndex
        func add(_ uid: UInt32, _ matches: [Match], _ bans: [FakeGame.BanValues], at team: Int64? = nil) {
            var values = world.values(uid)
            if let team {
                values.person.contract?.team = team
                values.currentTeam = team
            }
            values.history = world.booked(matches, bans: bans.map(game.ban))
            game.player(values)
        }
        // Booked in the league on the day of his league ban, and in the cup the day before his cup ban.
        add(1, [(240, league, 0), (244, league, 1), (250, cup, 1)],
            [FakeGame.BanValues(day: 244), FakeGame.BanValues(scope: PlayerStateTests.cupScope, day: 251)])
        // A cup red card, which says what the cup's index is called.
        let cupRed = game.banMatch(competition: world.cup, home: world.roversFirst, away: world.townFirst)
        add(2, [], [FakeGame.BanValues(scope: PlayerStateTests.cupScope, match: cupRed, kind: 2)])
        // His booking isn't in his record, but the league's rule set is known now.
        add(3, [(244, league, 0)], [FakeGame.BanValues(day: 244)])
        // Under a rule set nothing else names, booked in the league more than a week before: too long ago to be why.
        add(4, [(236, league, 1)], [FakeGame.BanValues(scope: 9, day: 244)])
        // A week before to the day is close enough, under another rule set, so as not to teach the one above.
        add(6, [(237, league, 1)], [FakeGame.BanValues(scope: 10, day: 244)])
        // At a club in another nation's league: a ban from Mockovia's association isn't for his league.
        add(5, [], [FakeGame.BanValues(day: 244)], at: world.townAtHome)

        let players = try world.bans()
        XCTAssertEqual(players[1]??.map(\.competition), ["Mock League One", "Mock Cup"])
        XCTAssertEqual(players[1]??.map(\.competitionIndex), [league, cup])
        XCTAssertEqual(players[1]??.map(\.countsForClub), [true, true])
        XCTAssertEqual(players[3]??.map(\.competition), ["Mock League One"])
        XCTAssertEqual(players[4]??.map(\.competition), [""])
        XCTAssertEqual(players[6]??.map(\.competition), ["Mock League One"])
        let abroad = try XCTUnwrap(players[5]??.first)
        XCTAssertEqual(abroad.competition, "")
        XCTAssertFalse(abroad.domestic)
        XCTAssertFalse(abroad.countsForClub)
    }

    /// What FM's squad screen counts: a ban for a competition his team plays in, its league or one in his recent matches
    /// for it. A red card for his country, or in a youth league, is named from its match but isn't counted.
    func testOnlyBansInHisTeamsCompetitionsCount() throws {
        let world = World()
        let game = world.game
        let europe = game.competition("Mock Continental Cup", index: 20), youth = game.competition("Mock Under-19 League", index: 21)
        let otherClub = game.club(full: "Elsewhere United", short: "Elsewhere", nation: world.fixtureland)
        let elsewhere = game.team(club: otherClub, index: 0x3001, type: 0, competition: world.league)
        let continental = game.banMatch(competition: europe, home: world.roversFirst, away: elsewhere)
        let youthMatch = game.banMatch(competition: youth, home: elsewhere, away: world.townFirst)
        var values = world.values(1)
        values.history = world.booked([(240, 20, 0)], bans: [
            game.ban(FakeGame.BanValues(association: 3_000, scope: 1, match: continental, kind: 2)),
            game.ban(FakeGame.BanValues(scope: 4, match: youthMatch, kind: 2)),
        ])
        game.player(values)

        let bans = try XCTUnwrap(try world.bans()[1] ?? nil)
        XCTAssertEqual(bans.map(\.competition), ["Mock Continental Cup", "Mock Under-19 League"])
        XCTAssertEqual(bans.map(\.countsForClub), [true, false])
        XCTAssertEqual(bans.map(\.opponent), ["Elsewhere United", ""])
        XCTAssertEqual(bans.map(\.domestic), [false, true])
    }

    /// A ban already served is left out, a kind FM Starship doesn't know has no reason, and a red card in a match that
    /// isn't his club's, as for his nation, names no opponent.
    func testServedBansUnknownKindsAndOtherTeamsMatches() throws {
        let world = World()
        let game = world.game
        let otherClub = game.club(full: "Elsewhere United", short: "Elsewhere", nation: 0)
        let otherTeam = game.team(club: otherClub, index: 0x3001, type: 0, competition: world.league)
        let notHis = game.banMatch(competition: world.cup, home: world.townFirst, away: otherTeam)
        var values = world.values(1)
        values.history = world.played([], bans: [
            game.ban(FakeGame.BanValues(day: 200, kind: 0, matches: 2, served: 2)),
            game.ban(FakeGame.BanValues(day: 210, kind: 9, matches: 1)),
            game.ban(FakeGame.BanValues(scope: PlayerStateTests.cupScope, match: notHis, day: 220, kind: 2, matches: 4, served: 1)),
        ])
        game.player(values)
        var clean = world.values(2)
        clean.history = world.played([World.leagueIndex], bans: [])
        game.player(clean)
        // No record of matches or bans at all.
        game.player(world.values(3))

        let players = try world.bans()
        let bans = try XCTUnwrap(players[1] ?? nil)
        XCTAssertEqual(bans.count, 2, "the served one is gone")
        XCTAssertNil(bans[0].reason)
        XCTAssertEqual(bans[1].reason, .redCard)
        XCTAssertEqual(bans[1].competition, "Mock Cup")
        XCTAssertEqual(bans[1].opponent, "")
        XCTAssertEqual(bans[1].left, 3)
        XCTAssertEqual(players[2]??.count, 0)
        XCTAssertEqual(players[3]??.count, 0)
    }

    /// A free agent has no contract, so neither playing time nor the record holding his bans is read.
    func testAFreeAgentHasNoPlayingTimeAndNoBansRead() throws {
        let world = World()
        world.game.player(world.values(1))
        var free = world.values(2)
        free.person.contract = nil
        world.game.player(free)

        let players = try world.read()
        XCTAssertNil(players[2]?.playingTime)
        XCTAssertNil(players[2]?.storedBans)
        XCTAssertEqual(players[2]?.morale, 12)
        XCTAssertEqual(players[1]?.storedBans?.count, 0)
    }

    // MARK: Another day

    /// Stored condition and sharpness are FM's for the day they were brought up to date. On any other day only FM's
    /// getters can say, so without the engine there's no number at all.
    func testAStaleDayNeedsFMsGetters() throws {
        let world = World()
        var values = world.values(1)
        values.condition = 9_900
        values.sharpness = 9_000
        values.fitnessUpdated = (PlayerStateTests.today.day - 3, PlayerStateTests.today.year)
        world.game.player(values)

        let player = try XCTUnwrap(try world.read()[1])
        XCTAssertNil(player.fitness, "never a number from another day")
        XCTAssertTrue(player.fitnessNeedsCatchUp)
        XCTAssertEqual(player.fitnessUpdated, GameDate.checked(year: 2029, dayOfYear: 252))
        XCTAssertNil(player.fitness(nil), "no engine, no number")

        let engine = StateEngine(Fitness(condition: 9_950, sharpness: 8_800))
        XCTAssertEqual(player.fitness(engine), Fitness(condition: 9_950, sharpness: 8_800))
        engine.answer = nil
        XCTAssertNil(player.fitness(engine), "FM's getters failing leaves nothing")
        XCTAssertEqual(player.morale, 12, "morale has no day")
    }

    func testTodaysNeverAsksTheEngine() throws {
        let world = World()
        world.game.player(world.values(1))
        let engine = StateEngine(Fitness(condition: 1, sharpness: 1))
        let player = try XCTUnwrap(try world.read()[1])
        XCTAssertEqual(player.fitness(engine), Fitness(condition: 10_000, sharpness: 10_000))
        XCTAssertEqual(engine.asked, 0)
    }

    /// Without the game date, no day is today.
    func testWithNoGameDateEveryoneNeedsCatchingUp() throws {
        let world = World(dated: false)
        world.game.player(world.values(1))
        let player = try XCTUnwrap(try world.read()[1])
        XCTAssertNil(player.fitness)
        XCTAssertTrue(player.fitnessNeedsCatchUp)
        XCTAssertEqual(player.fitness(StateEngine(Fitness(condition: 7_000, sharpness: 7_100))), Fitness(condition: 7_000, sharpness: 7_100))
    }

    // MARK: Read again

    /// FM plays a match without the date moving. Read again, a player's state is what FM's memory holds now, while the
    /// whole read's checks still decide which fields are on, and a record that's no longer his is left alone.
    func testAPlayersStateIsReadAgainForAnAnswer() throws {
        typealias L = MacLayout.Player
        let world = World()
        let game = world.game
        let ban = game.ban(FakeGame.BanValues(matches: 2))
        var values = world.values(1)
        values.sharpness = 9_000
        values.history = world.played([World.leagueIndex], bans: [ban])
        let record = game.player(values)
        let database = try game.read()
        let player = try XCTUnwrap(database.players.first)
        XCTAssertEqual(player.fitness, Fitness(condition: 10_000, sharpness: 9_000))
        XCTAssertEqual(player.storedBans?.map(\.left), [2])

        let process = game.process()
        let contract = process.readPointer(record.address + Int64(L.person + MacLayout.Person.contract))
        game.poke(Int16(6_500), at: record.address + Int64(L.condition))
        game.poke(Int16(9_800), at: record.address + Int64(L.sharpness))
        game.poke(Int8(15), at: record.address + Int64(L.morale))
        game.poke(Int8(-5), at: contract + Int64(MacLayout.Contract.playingTime))
        game.poke(UInt8(1), at: ban + Int64(MacLayout.Ban.served))
        GameReader.refreshState(player, in: database, game: process)
        XCTAssertEqual(player.fitness, Fitness(condition: 6_500, sharpness: 9_800))
        XCTAssertEqual(player.morale, 15)
        XCTAssertEqual(player.playingTime, -5)
        XCTAssertEqual(player.storedBans?.map(\.left), [1])

        // Served in full, FM drops it from the list; here it's still there, and isn't kept.
        game.poke(UInt8(2), at: ban + Int64(MacLayout.Ban.served))
        database.stateOff[.morale] = "its check failed: made up"
        game.poke(Int8(16), at: record.address + Int64(L.morale))
        GameReader.refreshState(player, in: database, game: process)
        XCTAssertEqual(player.storedBans?.count, 0)
        XCTAssertNil(player.morale, "off for the read stays off")

        game.poke(UInt32(999), at: record.address + Int64(L.identity + MacLayout.Identity.uid))
        game.poke(Int16(1_000), at: record.address + Int64(L.condition))
        GameReader.refreshState(player, in: database, game: process)
        XCTAssertEqual(player.fitness?.condition, 6_500, "no longer his record")
    }

    // MARK: FM's getters

    /// For a player brought up to date today, FM's getters have nothing to catch up, so they must give what FM stored. If
    /// they don't, a slot or an offset has moved, and condition and sharpness are off for everyone.
    func testFMsGettersMustGiveTodaysStoredValues() throws {
        func read() throws -> Database {
            let world = World()
            for uid in 1...3 {
                var values = world.values(UInt32(uid))
                values.condition = Int16(9_000 + uid)
                world.game.player(values)
            }
            var stale = world.values(4)
            stale.fitnessUpdated = (PlayerStateTests.today.day - 1, PlayerStateTests.today.year)
            world.game.player(stale)
            return try world.game.read()
        }
        let agreeing = StateEngine(nil)
        agreeing.echo = true
        let database = try read()
        XCTAssertNil(GameReader.checkFitnessGetters(database, engine: agreeing))
        XCTAssertEqual(agreeing.asked, 3, "only today's players")
        XCTAssertTrue(database.stateIsOn(.fitness))

        for engine in [StateEngine(Fitness(condition: 9_001, sharpness: 10_000)), StateEngine(nil)] {
            let database = try read()
            let reason = try XCTUnwrap(GameReader.checkFitnessGetters(database, engine: engine))
            XCTAssertEqual(database.stateOff[.fitness], reason)
            XCTAssertTrue(reason.hasPrefix("its check failed: FM's own getters"), reason)
            XCTAssertTrue(database.players.allSatisfy { $0.fitness == nil && !$0.fitnessNeedsCatchUp })
            XCTAssertTrue(database.stateIsOn(.morale))
        }
    }

    // MARK: Names

    /// A nation record that can't be read, with the same index, mustn't take the name's place.
    func testAnAssociationsNameIsNeverLostToANamelessRecord() throws {
        let world = World(namelessTwin: true)
        var values = world.values(1)
        values.person.nation = world.twin
        values.history = world.played([], bans: [world.game.ban(FakeGame.BanValues())])
        world.game.player(values)
        XCTAssertEqual(try world.bans()[1]??.map(\.associationName), ["Mockovia"])
    }

    // MARK: Self-checks

    /// A value a field can't have, for the only player at a club, is more than one in a hundred: that field is off for the
    /// read, with why, and gives nothing. The others are still on.
    func testEachFieldThatFailsItsCheckIsOffAndSaysSo() throws {
        let cases: [(PlayerStateField, (inout FakeGame.PlayerValues) -> Void)] = [
            (.fitness, { $0.condition = 12_000 }),
            (.fitness, { $0.sharpness = -1 }),
            (.fitness, { $0.fitnessUpdated = (0, 0) }),
            (.morale, { $0.morale = 0 }),
            (.morale, { $0.morale = 21 }),
            (.playingTime, { $0.playingTime(-120) }),
            (.playingTime, { $0.playingTime(101) }),
        ]
        for (field, spoil) in cases {
            let world = World()
            var values = world.values(1)
            spoil(&values)
            world.game.player(values)
            let database = try world.game.read()
            XCTAssertEqual(Set(database.stateOff.keys), [field], "\(field)")
            XCTAssertTrue(database.stateOff[field]?.hasPrefix("its check failed: 1 of 1 players at a club") ?? false, database.stateOff[field] ?? "")
            let player = try XCTUnwrap(database.players.first)
            switch field {
            case .fitness:
                XCTAssertNil(player.fitness)
                XCTAssertFalse(player.fitnessNeedsCatchUp, "off means the engine isn't asked either")
                XCTAssertNil(player.fitness(StateEngine(Fitness(condition: 1, sharpness: 1))))
            case .morale: XCTAssertNil(player.morale)
            case .playingTime: XCTAssertNil(player.playingTime)
            case .bans: break
            }
            XCTAssertNotNil(player.storedBans)
        }
    }

    /// One odd player in more than a hundred doesn't switch a field off, but his own value is left out.
    func testOneOddPlayerInMoreThanAHundredOnlyLosesHisOwn() throws {
        let world = World()
        for uid in 1...101 {
            var values = world.values(UInt32(uid))
            values.morale = Int8(1 + uid % 20)
            values.condition = Int16(9_000 + uid)
            values.playingTime(Int8(uid % 50))
            if uid == 1 {
                values.morale = 0
                values.condition = 10_001
                values.playingTime(-101)
            }
            world.game.player(values)
        }
        let database = try world.game.read()
        XCTAssertEqual(database.stateOff, [:])
        let players = Dictionary(uniqueKeysWithValues: database.players.map { ($0.uid, $0) })
        XCTAssertNil(players[1]?.morale)
        XCTAssertNil(players[1]?.fitness)
        XCTAssertNil(players[1]?.playingTime)
        XCTAssertEqual(players[2]?.morale, 3)
        XCTAssertEqual(players[2]?.fitness?.condition, 9_002)
        XCTAssertEqual(players[2]?.playingTime, 2)
    }

    /// A list of bans that isn't one, or bans with no real date or length, mean the offsets have moved: no bans for anyone.
    func testBansThatArentRealSwitchBansOff() throws {
        for spoil in ["list", "date", "length"] {
            let world = World()
            let game = world.game
            var values = world.values(1)
            if spoil == "list" {
                // A begin after its end.
                let holder = game.record("Injuries and matches", size: MacLayout.History.matches + 8)
                holder.set("bans", MacLayout.History.bans, bytes: [Int64(0x1000_0010), 0x1000_0000, 0x1000_0000].flatMap { withUnsafeBytes(of: $0) { Array($0) } })
                values.history = holder.address
            } else {
                values.history = world.played([], bans: [game.ban(spoil == "date" ? FakeGame.BanValues(day: 0) : FakeGame.BanValues(matches: 0))])
            }
            game.player(values)
            var other = world.values(2)
            other.history = world.played([], bans: [game.ban(FakeGame.BanValues())])
            game.player(other)

            let database = try game.read()
            XCTAssertEqual(Set(database.stateOff.keys), [.bans], spoil)
            XCTAssertTrue(database.stateOff[.bans]?.hasPrefix("its check failed") ?? false, spoil)
            XCTAssertTrue(database.players.allSatisfy { $0.storedBans == nil }, spoil)
        }
    }

    /// A moved offset can read the same zeroes for everyone, which is in range. A big save with only one value fails.
    func testOneValueForEveryoneInABigSaveFails() {
        var state = GameReader.RawState()
        state.condition = 10_000
        state.sharpness = 10_000
        state.fitnessDay = 255
        state.fitnessYear = 2029
        state.morale = 10
        state.playingTime = 0
        state.bansRead = true
        let off = GameReader.checkState(Array(repeating: state, count: 100))
        XCTAssertEqual(Set(off.keys), [.fitness, .morale, .playingTime])
        XCTAssertEqual(off[.morale], "its check failed: every player at a club has the same value")

        // Condition can be full for everyone, as long as sharpness isn't the same for all.
        var varied = Array(repeating: state, count: 100)
        for i in varied.indices {
            varied[i].sharpness = 9_000 + i
            varied[i].morale = 1 + i % 20
            varied[i].playingTime = i - 50
        }
        XCTAssertEqual(GameReader.checkState(varied), [:])
        // A small save can be all one value.
        XCTAssertEqual(GameReader.checkState(Array(repeating: state, count: 99)), [:])
    }

    /// A big read with no ban at all is a bans offset on empty lists: unserved old bans pile up in a real save.
    func testABigReadWithNoBanAtAllSwitchesBansOff() {
        var state = GameReader.RawState()
        state.bansRead = true
        state.condition = 10_000
        state.fitnessDay = 255
        state.fitnessYear = 2029
        state.morale = 10
        var states = (0..<GameReader.bigSave).map { i -> GameReader.RawState in
            var varied = state
            varied.sharpness = 9_000 + i % 1_000
            varied.morale = 1 + i % 20
            return varied
        }
        let off = GameReader.checkState(states)[.bans] ?? ""
        XCTAssertTrue(off.hasPrefix("its check failed: none of ") && off.hasSuffix(" players at a club has a ban"), off)
        XCTAssertNil(GameReader.checkState(Array(states.dropFirst()))[.bans], "a smaller read can have none")
        var ban = StoredBan()
        ban.day = 200
        ban.year = 2029
        ban.matches = 1
        states[0].bans = [ban]
        XCTAssertEqual(GameReader.checkState(states), [:])
    }

    /// The checks look at players at a club only: a free agent's odd value doesn't switch a field off.
    func testFreeAgentsDontCountInTheChecks() throws {
        let world = World()
        world.game.player(world.values(1))
        var free = world.values(2)
        free.person.contract = nil
        free.morale = 0
        free.condition = 20_000
        world.game.player(free)
        let database = try world.game.read()
        XCTAssertEqual(database.stateOff, [:])
        let players = Dictionary(uniqueKeysWithValues: database.players.map { ($0.uid, $0) })
        XCTAssertNil(players[2]?.morale)
        XCTAssertNil(players[2]?.fitness)
        XCTAssertEqual(players[1]?.morale, 12)
    }

    /// The fields are off until a read of the game checks them, as in a snapshot.
    func testANewDatabaseHasThemOff() {
        let database = Database()
        XCTAssertTrue(PlayerStateField.allCases.allSatisfy { !database.stateIsOn($0) })
    }
}

private extension FakeGame.PlayerValues {
    mutating func playingTime(_ value: Int8) { person.contract?.playingTime = value }
}
