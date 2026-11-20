import Foundation
import StarshipAnalysis
import StarshipCore
import StarshipFiles
@testable import StarshipMCP
import StarshipSearch
import XCTest

/// FM's rules as a test wants them: everyone answers, and nothing runs FM's code.
final class FakeEngine: GameRulesEngine, PositionalRoleEngine {
    /// Three stars in every role, in and out of possession, wherever they play.
    func roleRows(player: Player, position: Int, team: Int64) -> [RoleRow]? {
        (0..<64).flatMap { role in
            [RoleRow(role: Names.rolesIp[role] ?? "Role \(role)", outOfPossession: false, minHalfStars: 6, maxHalfStars: 6, rating: 50),
             RoleRow(role: Names.rolesOop[role] ?? "Role \(role)", outOfPossession: true, minHalfStars: 6, maxHalfStars: 6, rating: 50)]
        }
    }

    var supportsInjuryDays: Bool { true }
    /// How many times FM was asked whether a player would join.
    private(set) var interestCalls = 0
    func interest(player: Player, team: Int64) -> (transfer: JoinInterest, loan: JoinInterest)? {
        interestCalls += 1
        return (.interested, .doubtful)
    }
    func staffInterest(staff: Staff, team: Int64, level: Int) -> Bool? { level == 1 }
    func preferredJob(staff: Staff) -> Int? { nil }
    func jobPreferences(staff: Staff) -> [UInt8]? { nil }
    func roleRows(player: Player, team: Int64) -> [RoleRow]? { nil }
    func seasonStats(player: Player, season: Int) -> SeasonStats? {
        var stats = SeasonStats()
        stats.apps = 10
        stats.starts = 9
        stats.subs = 1
        stats.minutes = 900
        stats.goals = 3
        stats.assists = 2
        stats.rating = 7.05
        stats.yellow = 2
        stats.red = 1
        return stats
    }
    func form(player: Player) -> String? { "7.1 6.8 7.4" }
    func injuryReturnDays(player: Player) -> Int? { 14 }
}

/// A save built by hand, as `GameSource` gives it. It counts its reads, and can say the save has moved on.
final class FakeSource: GameSource {
    var database: Database
    var engine: GameRulesEngine?
    var problem: GameProblem?
    var current = true
    private(set) var reads = 0

    init(database: Database, engine: GameRulesEngine?) {
        self.database = database
        self.engine = engine
    }

    func read() throws -> GameRead {
        if let problem { throw problem }
        reads += 1
        return GameRead(database: database, engine: engine, number: reads)
    }

    func isCurrent(_ read: GameRead) -> Bool { current }
}

/// One human club with a first team, a youngster, an injured player and staff, and a rival club. CAs, PAs, hidden
/// attributes and personality numbers are values nothing else in the save has, so a test can look for them anywhere.
enum World {
    static let club = "Testing FC"
    static let rivals = "Rivals FC"
    /// What no visible value is: CAs and PAs, hidden attributes (19) and personality numbers (17).
    static let hiddenNumbers = #"\b(171|183|137|197|139|177|19|17)\b"#

    static func player(_ uid: UInt32, name: String, age: Int, ca: Int, pa: Int, at club: String = World.club, squad: String = "First team") -> Player {
        let player = Player()
        player.uid = uid
        player.index = uid
        player.block = Int64(uid)
        player.commonName = name
        player.club = club
        player.clubFull = club
        player.clubNation = "Mockovia"
        player.nation = "Mockovia"
        player.league = "Mock League"
        player.squad = squad
        player.age = age
        player.ca = ca
        player.pa = pa
        player.value = Int64(uid) * 100_000
        player.wage = 1000
        player.endYear = 2027
        player.endDay = 100
        player.personality = "Resolute"
        player.media = "Reserved"
        player.pers = [UInt8](repeating: 17, count: 8)
        for index in player.raw.indices { player.raw[index] = 50 }
        for name in Names.hidden { player.raw[Names.playerIndex[name]!] = 95 }
        for position in player.pos.indices { player.pos[position] = 5 }
        player.pos[Names.positions.firstIndex(of: "DC")!] = 20
        return player
    }

    static func staff(_ uid: UInt32, name: String, job: String, block: Int64, at club: String = World.club) -> Staff {
        let staff = Staff()
        staff.uid = uid
        staff.index = uid
        staff.block = block
        staff.commonName = name
        staff.club = club
        staff.clubFull = club
        staff.clubNation = "Mockovia"
        staff.nation = "Mockovia"
        staff.league = "Mock League"
        staff.squad = "First team"
        staff.job = job
        staff.age = 45
        staff.ca = 171
        staff.pa = 183
        staff.wage = 2000
        staff.repWorld = 3000
        staff.personality = "Balanced"
        staff.pers = [UInt8](repeating: 17, count: 8)
        // FM shows a member of staff's Adaptability, so it's an ordinary number here.
        for name in Names.staffShownPersonality { staff.pers[Names.personalityIndex[name]!] = 12 }
        for index in staff.attr.indices { staff.attr[index] = 12 }
        for name in StaffFilter.hiddenRuleAttributes {
            if let index = Names.staffIndex[name] { staff.attr[index] = 19 }
        }
        staff.stars = [4.5, 3.5, 3, 3, 2.5, 2.5, 1, 2, 2]
        return staff
    }

    static func database() -> Database {
        var players = (1...11).map { player(UInt32($0), name: "First \($0)", age: 26, ca: 171, pa: 183) }
        let youngster = player(12, name: "Young Prospect", age: 18, ca: 137, pa: 197, squad: "U19")
        players.append(youngster)
        let injured = player(13, name: "Hurt Player", age: 26, ca: 171, pa: 183)
        let injury = Injury()
        injury.name = "Hamstring strain"
        injured.injury = injury
        injured.injuryText = injury.name
        injured.releaseClause = 3_000_000
        injured.traitBits = 1
        players.append(injured)
        players += (21...32).map { player(UInt32($0), name: "Rival \($0)", age: 24, ca: 139, pa: 177, at: World.rivals) }
        let cheap = players.first { $0.uid == 21 }!
        cheap.releaseForeign = 900_000

        let db = Database()
        db.players = players
        db.staff = [staff(500, name: "The Manager", job: "Manager", block: 500),
                    staff(501, name: "Coach One", job: "Coach", block: 501),
                    staff(502, name: "Rival Coach", job: "Coach", block: 502, at: World.rivals)]
        db.gameDate = GameDate.checked(year: 2026, dayOfYear: 270)
        db.build = "27.1.0 (test)"
        db.checks = "PASS"
        db.humanClubs = [(team: 1, name: World.club, manager: 500)]
        db.budgets = [1: (transfer: 5_000_000, wageRoom: 20_000)]
        db.tactics = [1: tactic(players)]
        db.prepare()
        return db
    }

    /// A 4-4-2 with the first eleven in it.
    static func tactic(_ players: [Player]) -> Tactic {
        let places: [(String, TacticSlot.Side)] = [("GK", .centre), ("DR", .right), ("DC", .right), ("DC", .left), ("DL", .left),
                                                   ("MR", .right), ("MC", .right), ("MC", .left), ("ML", .left), ("ST", .right), ("ST", .left)]
        return Tactic(slots: places.enumerated().map { index, place in
            let position = Names.positions.firstIndex(of: place.0)!
            return TacticSlot(player: players.first { $0.uid == UInt32(index + 1) }, position: position, positionWithoutBall: position,
                              side: place.1, sideWithoutBall: place.1, role: 0, roleWithoutBall: 0)
        })
    }

    static func settings(hidden: Bool, reveal: Reveal = .exact) -> Settings {
        var settings = Settings()
        settings.showHidden = hidden
        settings.reveal = reveal.rawValue
        settings.unitsFollowFm = false
        settings.currencyName = "United Kingdom Pound"
        settings.wagePeriod = "week"
        settings.heightUnit = "cm"
        settings.interestClub = World.club
        return settings
    }
}

/// A toolbox on the made-up save, with settings the test can change between calls.
final class Harness {
    let source: FakeSource
    var settings: Settings
    let shortlists: URL
    lazy var toolbox = Toolbox(source: source, settings: { [unowned self] in self.settings }, shortlistRoots: { [unowned self] in [self.shortlists] })

    init(hidden: Bool = true, reveal: Reveal = .exact, engine: GameRulesEngine? = FakeEngine()) {
        source = FakeSource(database: World.database(), engine: engine)
        settings = World.settings(hidden: hidden, reveal: reveal)
        shortlists = FileManager.default.temporaryDirectory.appendingPathComponent("fmstarship-mcp-tests-\(UUID().uuidString)")
    }

    deinit { try? FileManager.default.removeItem(at: shortlists) }

    func saveShortlist(_ name: String, isStaff: Bool, uids: [UInt32]) throws {
        let folder = shortlists.appendingPathComponent("cloud").appendingPathComponent(isStaff ? "staff shortlists" : "shortlists")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ShortlistFile.write(to: folder.appendingPathComponent("\(name).fmf"), name: name, isStaff: isStaff, uids: uids)
    }

    /// The tool's answer, which must be one.
    func answer(_ tool: String, _ arguments: JSON = [:], file: StaticString = #filePath, line: UInt = #line) throws -> JSON {
        let result = try XCTUnwrap(toolbox.call(tool, arguments: arguments), "no such tool", file: file, line: line)
        XCTAssertFalse(result.isError, result.text, file: file, line: line)
        return try JSON.parse(result.text)
    }

    /// The sentence a tool refuses with.
    func refusal(_ tool: String, _ arguments: JSON = [:], file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let result = try XCTUnwrap(toolbox.call(tool, arguments: arguments), "no such tool", file: file, line: line)
        XCTAssertTrue(result.isError, "expected a refusal: \(result.text)", file: file, line: line)
        return result.text
    }
}

extension JSON {
    /// A list's column names.
    var columnNames: [String] { self["columns"]?.array?.compactMap(\.string) ?? [] }

    /// A list's rows, each by column name.
    var rowsByName: [[String: JSON]] {
        let names = columnNames
        return (self["rows"]?.array ?? []).map { row in
            Dictionary(zip(names, row.array ?? []), uniquingKeysWith: { first, _ in first })
        }
    }
}
