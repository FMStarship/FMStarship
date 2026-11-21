@testable import StarshipCore
import XCTest

/// Made-up squad rules, by the path FM's import code writes, laid out as `MacLayout` says.
extension FakeGame {
    /// One rule: its type, limit and direction (-1 at most, 0 exactly, 1 at least), and a condition if it has one.
    struct SquadRuleValues {
        var type: UInt16
        var limit: Int32
        var direction: Int8
        var condition: [UInt8] = []
    }

    /// FM's `FIXTURE_RULES` for `owner` at `slot`, with these rules, or a null list for `rules` nil.
    func fixtureRules(owner: Int64, slot: UInt8, group: Int8, rules: [SquadRuleValues]?) -> Int64 {
        typealias F = MacLayout.FixtureRules
        typealias R = MacLayout.SquadRule
        let record = self.record("Fixture rules", size: 0x138)
        record.set("owner", Int(F.owner), owner)
        record.set("slot", Int(F.slot), slot)
        record.set("group", Int(F.group), group)
        if let rules {
            let entries = rules.map { values -> Int64 in
                let rule = self.record("Squad rule", size: R.size)
                if !values.condition.isEmpty { rule.set("condition", R.condition, bytes: values.condition) }
                rule.set("limit", R.limit, values.limit)
                rule.set("type", R.type, values.type)
                rule.set("direction", R.direction, values.direction)
                return rule.address
            }
            let list = self.record("Squad rule list", size: 24)
            vector(entries, in: list, at: 0, named: "rules")
            record.set("squadRules", Int(F.squadRules), list.address)
        }
        return record.address
    }

    /// An owner of rule sets, holding `sets` FIXTURE_RULES made by `make` with the owner's address.
    func rulesOwner(_ make: (Int64) -> [Int64]) -> Int64 {
        let owner = record("Rules owner", size: Int(MacLayout.CompRules.holder) + 8)
        let holder = record("Rules holder", size: Int(MacLayout.CompRules.fixtureRules) + 24)
        vector(make(owner.address), in: holder, at: Int(MacLayout.CompRules.fixtureRules), named: "fixture rules")
        owner.set("holder", Int(MacLayout.CompRules.holder), holder.address)
        return owner.address
    }

    /// A competition whose squad rules are the owner's at `slot`, -1 for none.
    func competition(_ name: String, index: UInt32, owner: Int64, slot: Int8) -> Int64 {
        let record = self.record("Competition", size: Int(MacLayout.Comp.actual) + 8)
        record.set("index", Int(MacLayout.Comp.index), index)
        record.set("name", MacLayout.competitionName, string(name))
        let actual = self.record("Actual competition", size: Int(MacLayout.ActualComp.rulesOwner) + 8)
        actual.set("fixtureRulesSlot", Int(MacLayout.ActualComp.fixtureRulesSlot), slot)
        actual.set("rulesOwner", Int(MacLayout.ActualComp.rulesOwner), owner)
        record.set("actual", Int(MacLayout.Comp.actual), actual.address)
        return record.address
    }

    /// A C string, as FM's tables of names point at.
    func cString(_ text: String) -> Int64 {
        let bytes = Array(text.utf8) + [0]
        let at = allocate(bytes.count)
        for (offset, byte) in bytes.enumerated() { poke(byte, at: at + Int64(offset)) }
        return at
    }
}

/// FM's squad-rule types and per-player values as a test wants them. The types are made-up numbers: the reader finds them
/// by FM's names.
private final class RulesEngineForSquads: GameRulesEngine {
    static let size = 1, atClub = 2, inNation = 3, notHomeGrown = 4, contract = 5, goalkeepers = 6, matchSquad = 7, minimumSize = 8, unnamed = 99

    var squadRuleTypes: [Int: [String]]? = [
        size: ["max_squad_size"], minimumSize: ["min_squad_size"], atClub: ["homegrown_players_0_21_from_club", "homegrown_players_from_club"],
        inNation: ["homegrown_players_0_21_from_nation", "homegrown_players_from_nation"], notHomeGrown: ["non_homegrown_players_in_squad"],
        contract: ["players_on_pt_or_ft_contract_in_squad"], goalkeepers: ["goalkeepers_in_squad"],
        matchSquad: ["non_eec_players_in_match_squad"],
    ]
    var squadRuleDirections: [Int: String]? = [-1: "less_than", 0: "equals", 1: "more_than"]
    /// By uid: trained at the club (1, 5), in the nation (2), or neither (3, 4). 6 has no home-grown answer.
    var homeGrownByUID: [UInt32: HomeGrown] = [1: .club, 2: .nation, 3: .no, 4: .no, 5: .club]
    /// Values that aren't FM's home-grown tests' or the made-up ones below, by uid and type.
    var overrides: [UInt32: [Int: Int?]] = [:]
    private(set) var asked: [(uid: UInt32, type: Int, team: Int64, group: Int, competition: Int64)] = []

    var supportsInjuryDays: Bool { false }
    func interest(player: Player, team: Int64) -> (transfer: JoinInterest, loan: JoinInterest)? { nil }
    func staffInterest(staff: Staff, team: Int64, level: Int) -> Bool? { nil }
    func preferredJob(staff: Staff) -> Int? { nil }
    func jobPreferences(staff: Staff) -> [UInt8]? { nil }
    func roleRows(player: Player, team: Int64) -> [RoleRow]? { nil }
    func seasonStats(player: Player, season: Int) -> SeasonStats? { nil }
    func form(player: Player) -> String? { nil }
    func injuryReturnDays(player: Player) -> Int? { nil }
    func homeGrown(player: Player) -> HomeGrown? { homeGrownByUID[player.uid] }

    /// 1 to 4 on professional contracts, 1 the goalkeeper.
    func squadRuleValue(player: Player, type: Int, team: Int64, group: Int, competition: Int64) -> Int? {
        asked.append((player.uid, type, team, group, competition))
        if let value = overrides[player.uid]?[type] { return value }
        let homeGrown = homeGrownByUID[player.uid]
        switch type {
        case Self.size: return 1
        case Self.atClub: return homeGrown == .club ? 1 : 0
        case Self.inNation: return homeGrown == .club || homeGrown == .nation ? 1 : 0
        case Self.notHomeGrown: return homeGrown == .no ? 1 : 0
        case Self.contract: return (1...4).contains(player.uid) ? 1 : 0
        case Self.goalkeepers: return player.uid == 1 ? 1 : 0
        default: return 0
        }
    }
}

/// Squad rules read from made-up records, counted with FM's values from a made-up engine, and the checks that switch them
/// off. Every name and number is made up.
final class SquadRulesTests: XCTestCase {
    static let league: UInt32 = 7, cup: UInt32 = 8, continental: UInt32 = 20, friendlies: UInt32 = 30
    fileprivate typealias E = RulesEngineForSquads

    /// The league's rules: a squad of 3 to 6, at most 4 on professional contracts, at least 2 trained in the nation, at most
    /// 2 not home-grown, and at most 1 from outside the EU in a matchday squad.
    static let leagueRules = [
        FakeGame.SquadRuleValues(type: UInt16(E.size), limit: 6, direction: -1),
        FakeGame.SquadRuleValues(type: UInt16(E.minimumSize), limit: 3, direction: 1),
        FakeGame.SquadRuleValues(type: UInt16(E.contract), limit: 4, direction: -1),
        FakeGame.SquadRuleValues(type: UInt16(E.inNation), limit: 2, direction: 1),
        FakeGame.SquadRuleValues(type: UInt16(E.notHomeGrown), limit: 2, direction: -1),
        FakeGame.SquadRuleValues(type: UInt16(E.matchSquad), limit: 1, direction: -1),
    ]

    private final class World {
        let game = FakeGame()
        let first: Int64, club: Int64
        var records: [UInt32: Int64] = [:]

        /// `leagueRules` at the league's slot, which `leagueSlot` can point elsewhere, and `misplaced` has carry another slot.
        init(leagueRules: [FakeGame.SquadRuleValues] = SquadRulesTests.leagueRules, leagueSlot: Int8 = 0, misplaced: Bool = false) {
            let continent = game.continent("Made-up Continent")
            let mockovia = game.nation("Mockovia", code: "MCK", continent: continent, area: game.allocate(16), index: 160)
            let game = self.game
            // The association's: the league's at 0, the cup's at 1 with no rules, and an empty list at 2.
            let association = game.rulesOwner { owner in
                [game.fixtureRules(owner: owner, slot: misplaced ? 1 : 0, group: 8, rules: leagueRules),
                 game.fixtureRules(owner: owner, slot: 1, group: -1, rules: nil),
                 game.fixtureRules(owner: owner, slot: 2, group: -1, rules: [])]
            }
            // The continent's: at most 5 with at least 1 goalkeeper, and a rule FM limits with a condition.
            let continental = game.rulesOwner { owner in
                [game.fixtureRules(owner: owner, slot: 0, group: 0, rules: [
                    FakeGame.SquadRuleValues(type: UInt16(E.size), limit: 5, direction: -1),
                    FakeGame.SquadRuleValues(type: UInt16(E.goalkeepers), limit: 1, direction: 1),
                    FakeGame.SquadRuleValues(type: UInt16(E.contract), limit: 2, direction: -1, condition: Array("tag1".utf8)),
                ])]
            }
            let league = game.competition("Mock League", index: SquadRulesTests.league, owner: association, slot: leagueSlot)
            records = [
                SquadRulesTests.league: league,
                SquadRulesTests.cup: game.competition("Mock Cup", index: SquadRulesTests.cup, owner: association, slot: 1),
                SquadRulesTests.friendlies: game.competition("Mock Friendlies", index: SquadRulesTests.friendlies, owner: association, slot: -1),
                SquadRulesTests.continental: game.competition("Made-up Champions Cup", index: SquadRulesTests.continental, owner: continental, slot: 0),
            ]
            club = game.club(full: "Mockport Rovers FC", short: "Mockport", nation: mockovia)
            first = game.team(club: club, index: 0x1267, type: 0, competition: league)
            game.transferManager(day: 255, year: 2029)
            for uid in 1...6 { player(UInt32(uid), at: first) }
            // At another club, so not in the check.
            let other = game.club(full: "Fixture Town AFC", short: "Fixture Town", nation: mockovia)
            player(40, at: game.team(club: other, index: 0x2301, type: 0, competition: league))
        }

        @discardableResult
        func player(_ uid: UInt32, at team: Int64) -> FakeRecord {
            var values = FakeGame.PlayerValues()
            values.person.uid = uid
            values.person.index = uid
            values.person.commonName = "Made-up Player \(uid)"
            values.person.contract?.team = team
            values.currentTeam = team
            return game.player(values)
        }

        func reader(_ engine: GameRulesEngine? = RulesEngineForSquads()) throws -> (reader: SquadRulesReader, players: [Player]) {
            let database = try game.read()
            database.humanClubs = [(team: first, name: "Mockport Rovers FC", manager: 0)]
            let records = self.records
            let reader = SquadRulesReader(game: game.process(), database: database, engine: engine, competitionRecords: { records })
            let players = database.players.filter { $0.clubObject == club }.sorted { $0.uid < $1.uid }
            return (reader, players)
        }
    }

    // MARK: What it gives

    func testReadsEachCompetitionsRulesAsFMHoldsThem() throws {
        let world = World()
        let (reader, _) = try world.reader()
        XCTAssertNil(reader.off)
        XCTAssertEqual(reader.league(of: world.first), Self.league)

        let league = try XCTUnwrap(reader.rules(competition: Self.league))
        XCTAssertNil(league.unreadable)
        XCTAssertEqual(league.name, "Mock League")
        XCTAssertEqual(league.group, 8)
        XCTAssertEqual(league.record, world.records[Self.league])
        XCTAssertEqual(league.rules.map(\.name), ["max_squad_size", "min_squad_size", "players_on_pt_or_ft_contract_in_squad",
                                                  "homegrown_players_0_21_from_nation", "non_homegrown_players_in_squad",
                                                  "non_eec_players_in_match_squad"])
        XCTAssertEqual(league.rules.map(\.limit), [6, 3, 4, 2, 2, 1])
        XCTAssertEqual(league.rules.map(\.direction), [.atMost, .atLeast, .atMost, .atLeast, .atMost, .atMost])
        XCTAssertEqual(league.rules[3].names, ["homegrown_players_0_21_from_nation", "homegrown_players_from_nation"])

        let cup = try XCTUnwrap(reader.rules(competition: Self.cup))
        XCTAssertNil(cup.unreadable)
        XCTAssertEqual(cup.rules, [], "a cup with no squad rules")
        XCTAssertEqual(cup.group, -1)
        XCTAssertEqual(try XCTUnwrap(reader.rules(competition: Self.friendlies)).rules, [], "no rule set at all")

        let continental = try XCTUnwrap(reader.rules(competition: Self.continental))
        XCTAssertEqual(continental.group, 0)
        XCTAssertEqual(continental.rules.map(\.conditional), [false, false, true])
        XCTAssertNil(reader.rules(competition: 999), "no record for it")
        XCTAssertEqual(reader.competitionNames()[Self.continental], "Made-up Champions Cup")
    }

    func testCountsTheSquadByFMsOwnValues() throws {
        let world = World()
        let engine = RulesEngineForSquads()
        let (reader, players) = try world.reader(engine)
        XCTAssertNil(reader.countsOff)
        XCTAssertEqual(reader.status, "on: FM's own rules and per-player values, checked against squad size and FM's own home-grown "
                       + "tests for 5 players at Mockport Rovers FC")
        let league = try XCTUnwrap(reader.rules(competition: Self.league))
        let counts = league.rules.map { reader.count($0, in: league, players: players, team: world.first) }

        XCTAssertEqual(counts.map(\.count), [6, 6, 4, 3, 2, nil])
        XCTAssertEqual(counts.map(\.standing), [.atLimit, .within, .atLimit, .within, .atLimit, nil])
        XCTAssertEqual(counts[2].players?.map(\.uid), [1, 2, 3, 4])
        XCTAssertEqual(counts[3].players?.map(\.uid), [1, 2, 5])
        XCTAssertEqual(counts[4].players?.map(\.uid), [3, 4])
        XCTAssertTrue(counts[5].notCounted?.contains("isn't a count of the squad") ?? false, counts[5].notCounted ?? "")

        // FM was asked with the team, the rule set's group and the competition's record.
        let asked = engine.asked.filter { $0.type == E.contract }
        XCTAssertEqual(asked.count, 6)
        XCTAssertTrue(asked.allSatisfy { $0.team == world.first && $0.group == 8 && $0.competition == world.records[Self.league] })

        // Fewer players: under the minimum, and within the maximum.
        let two = Array(players.prefix(2))
        XCTAssertEqual(reader.count(league.rules[1], in: league, players: two, team: world.first).standing, .under)
        XCTAssertEqual(reader.count(league.rules[2], in: league, players: two, team: world.first).standing, .within)
        XCTAssertEqual(reader.count(league.rules[0], in: league, players: players + players, team: world.first).standing, .over)

        let continental = try XCTUnwrap(reader.rules(competition: Self.continental))
        let goalkeepers = reader.count(continental.rules[1], in: continental, players: players, team: world.first)
        XCTAssertEqual(goalkeepers.players?.map(\.uid), [1])
        XCTAssertEqual(goalkeepers.standing, .atLimit)
        XCTAssertTrue(reader.count(continental.rules[2], in: continental, players: players, team: world.first).notCounted?
            .contains("condition") ?? false)
    }

    /// A value that isn't 0 or 1, or no answer, leaves that rule uncounted and the rest as they are.
    func testAValueFMGivesThatIsntACountLeavesTheRuleUncounted() throws {
        let world = World()
        let engine = RulesEngineForSquads()
        engine.overrides = [3: [E.contract: 2], 4: [E.goalkeepers: Int?.none]]
        let (reader, players) = try world.reader(engine)
        XCTAssertNil(reader.countsOff)
        let league = try XCTUnwrap(reader.rules(competition: Self.league))
        let contract = reader.count(league.rules[2], in: league, players: players, team: world.first)
        XCTAssertNil(contract.count)
        XCTAssertEqual(contract.notCounted, "FM's value for it was 2 for Made-up Player 3, not 0 or 1, so what it counts isn't known")
        let continental = try XCTUnwrap(reader.rules(competition: Self.continental))
        XCTAssertEqual(reader.count(continental.rules[1], in: continental, players: players, team: world.first).notCounted,
                       "FM's rules didn't answer for 1 of 6 players")
        XCTAssertEqual(reader.count(league.rules[4], in: league, players: players, team: world.first).count, 2)
    }

    // MARK: The checks

    func testValuesThatDisagreeWithFMsHomeGrownTestsSwitchTheCountsOff() throws {
        let world = World()
        let engine = RulesEngineForSquads()
        engine.overrides = [2: [E.inNation: 0]]
        let (reader, players) = try world.reader(engine)
        XCTAssertNil(reader.off, "the rules are still given")
        XCTAssertEqual(reader.countsOff, "its check failed: 1 of 21 of FM's values disagree with squad size or FM's own home-grown "
                       + "tests for the players at Mockport Rovers FC")
        XCTAssertTrue(reader.status.hasPrefix("on, without counts: its check failed"), reader.status)
        let league = try XCTUnwrap(reader.rules(competition: Self.league))
        XCTAssertNil(reader.count(league.rules[2], in: league, players: players, team: world.first).count)
    }

    func testSquadSizeNotCountingEveryoneSwitchesTheCountsOff() throws {
        let world = World()
        let engine = RulesEngineForSquads()
        engine.overrides = [6: [E.size: 0]]
        XCTAssertTrue(try world.reader(engine).reader.countsOff?.contains("1 of 21 of FM's values disagree") ?? false)
    }

    func testFMNotAnsweringSwitchesTheCountsOff() throws {
        let world = World()
        let engine = RulesEngineForSquads()
        engine.overrides = [1: [E.atClub: Int?.none]]
        XCTAssertEqual(try world.reader(engine).reader.countsOff, "its check failed: FM's rules didn't answer for 1 of 21 values")
    }

    func testWithoutFMsRulesOrTheirTablesItIsOff() throws {
        let world = World()
        XCTAssertEqual(try world.reader(nil).reader.off, "they come from FM's own rules, which are off on this build")
        let noTable = RulesEngineForSquads()
        noTable.squadRuleTypes = nil
        XCTAssertEqual(try world.reader(noTable).reader.off,
                       "FM's table of squad-rule types wasn't found where FM keeps it on this build, or didn't read back as one")
        let directions = RulesEngineForSquads()
        directions.squadRuleDirections = [-1: "more_than", 0: "equals", 1: "less_than"]
        let (reader, _) = try world.reader(directions)
        XCTAssertEqual(reader.off, "FM's names for a rule's direction aren't less_than, equals and more_than where FM keeps them on this build")
        XCTAssertNil(reader.rules(competition: Self.league))
        XCTAssertEqual(reader.status, "off: " + (reader.off ?? ""))
    }

    /// The human club's league must lead to a rule set that carries its own entry and owner.
    func testALeagueWhoseRuleSetIsNotItsOwnSwitchesItOff() throws {
        for world in [World(misplaced: true), World(leagueSlot: 5)] {
            let (reader, _) = try world.reader()
            XCTAssertTrue(reader.off?.hasPrefix("its check failed: the squad rules of Mockport Rovers FC's league couldn't be read") ?? false,
                          reader.off ?? "on")
        }
    }

    /// A rule of a type FM's table doesn't name, or with a direction it doesn't, means the rules weren't read right.
    func testARuleFMsTablesDontNameIsUnreadable() throws {
        for rule in [FakeGame.SquadRuleValues(type: UInt16(E.unnamed), limit: 1, direction: -1),
                     FakeGame.SquadRuleValues(type: UInt16(E.size), limit: 1, direction: 3),
                     FakeGame.SquadRuleValues(type: UInt16(E.size), limit: 5_000, direction: -1)] {
            let world = World(leagueRules: [rule])
            XCTAssertTrue(try world.reader().reader.off?.contains("couldn't be read: one of its squad rules") ?? false, "\(rule)")
        }
    }

    // MARK: FM's tables

    /// FM's {name, value} pairs, up to the end value, and none where a name can't be read.
    func testFMsTablesOfNamesAreReadToTheirEnd() throws {
        let game = FakeGame()
        let pairs: [(String, Int64)] = [("max_squad_size", 1), ("min_squad_size", 8), ("", 65_535), ("after_the_end", 2)]
        let table = game.allocate(pairs.count * 16)
        for (index, pair) in pairs.enumerated() {
            game.poke(game.cString(pair.0), at: table + Int64(index * 16))
            game.poke(pair.1, at: table + Int64(index * 16 + 8))
        }
        let process = game.process()
        let read = try XCTUnwrap(RulesEngine.nameTable(process, at: table, most: 16, endValue: 65_535))
        XCTAssertEqual(read.map(\.name), ["max_squad_size", "min_squad_size"])
        XCTAssertEqual(read.map(\.value), [1, 8])
        XCTAssertNil(RulesEngine.nameTable(process, at: table, most: 2, endValue: 65_535), "no end within most")
        XCTAssertEqual(RulesEngine.nameTable(process, at: table, most: 2, endValue: nil)?.map(\.name), ["max_squad_size", "min_squad_size"])
        game.poke(Int64(0), at: table + 16)
        XCTAssertNil(RulesEngine.nameTable(process, at: table, most: 16, endValue: 65_535), "a name that can't be read")
    }

    // MARK: Which rules count the squad

    func testOnlyRulesThatCountTheSquadAreCounted() {
        func counted(_ name: String) -> Bool { SquadRule(type: 1, names: [name], limit: 1, direction: .atMost).notCounted == nil }
        for name in ["max_squad_size", "min_squad_size", "players_on_pt_or_ft_contract_in_squad", "homegrown_players_0_21_from_nation",
                     "homegrown_players_15_21_from_club", "non_homegrown_players_in_squad", "goalkeepers_in_squad",
                     "homegrown_players_0_21_ignore_loans_from_club_in_squad", "loan_players_in_squad_excluding_affiliate_loans"] {
            XCTAssertTrue(counted(name), name)
        }
        for name in ["non_eec_players_in_match_squad", "over_19_players_in_match_squad", "non_eec_players_in_11", "keepers_on_bench",
                     "loan_players_in_season", "yearly_wage", "foreign_players_registered_in_window", "homegrown_players_0_21_from_club_in_11",
                     "senior_internationals"] {
            XCTAssertFalse(counted(name), name)
        }
    }
}
