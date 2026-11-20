import Foundation
import StarshipAnalysis
import StarshipCore
import StarshipFiles
@testable import StarshipMCP
import StarshipSearch
import XCTest

/// FM's rules as a test wants them: everyone answers, and nothing runs FM's code.
final class FakeEngine: GameRulesEngine, PositionalRoleEngine {
    /// False to stand in for FM giving no role table, as when one of its rules fails.
    var roleRatings = true
    /// When set, only these players get a role table, as when FM's rules fail for some players and not others.
    var ratedPlayers: Set<UInt32>?

    /// Three stars in every role, in and out of possession, wherever they play.
    func roleRows(player: Player, position: Int, team: Int64) -> [RoleRow]? {
        guard roleRatings, ratedPlayers?.contains(player.uid) ?? true else { return nil }
        return (0..<64).flatMap { role in
            [RoleRow(role: Names.rolesIp[role] ?? "Role \(role)", outOfPossession: false, minHalfStars: 6, maxHalfStars: 6, rating: 50),
             RoleRow(role: Names.rolesOop[role] ?? "Role \(role)", outOfPossession: true, minHalfStars: 6, maxHalfStars: 6, rating: 50)]
        }
    }

    var supportsInjuryDays: Bool { true }
    /// How many times FM was asked whether a player would join. The finders ask from several threads at once.
    private var calls = 0
    private let lock = NSLock()
    var interestCalls: Int { lock.withLock { calls } }
    func interest(player: Player, team: Int64) -> (transfer: JoinInterest, loan: JoinInterest)? {
        lock.withLock { calls += 1 }
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
    /// FM's getters, caught up to today: the stored values for a player FM brought up to date today, as FM's own give.
    func fitness(player: Player) -> Fitness? {
        if gettersDisagree { return Fitness(condition: 1, sharpness: 2) }
        return player.fitness ?? Fitness(condition: 9_440, sharpness: 8_020)
    }
    /// True for getters in the wrong vtable slots, which give other numbers than FM stored.
    var gettersDisagree = false
    /// First 1 was trained at the club, First 2 in its nation, and nobody else.
    func homeGrown(player: Player) -> HomeGrown? { player.uid == 1 ? .club : player.uid == 2 ? .nation : .no }

    /// The club's first eleven played both league matches, number 9 scoring in each and number 11 coming off after 64
    /// minutes in the second, where 12 sat on the bench. Number 13's last 20 matches start after the first one.
    func matchHistory(player: Player) -> MatchHistory? {
        guard player.clubFull == World.club else { return MatchHistory() }
        let uid = Int(player.uid)
        func match(_ day: Int, opponent: Int64, played: Bool = true) -> PlayerMatch {
            var match = PlayerMatch(date: GameDate.date(year: 2026, dayOfYear: day) ?? Date(), team: World.team, opponent: opponent)
            match.competitionIndex = World.leagueIndex
            guard played else { return match }
            match.played = true
            match.minutes = day == World.secondMatch && uid == 11 ? 64 : 90
            match.rating = Double(60 + uid) / 10
            match.goals = uid == 9 ? 1 : 0
            match.assists = uid == 10 && day == World.firstMatch ? 1 : 0
            match.yellow = uid == 4 ? 1 : 0
            match.xG = uid == 1 ? nil : Double(uid) / 20
            return match
        }
        switch uid {
        case 1...11: return MatchHistory(matches: [match(World.secondMatch, opponent: World.otherTeam), match(World.firstMatch, opponent: World.rivalsTeam)])
        case 12: return MatchHistory(matches: [match(World.secondMatch, opponent: World.otherTeam, played: false)])
        case 13: return MatchHistory(fullFrom: [World.team: GameDate.date(year: 2026, dayOfYear: World.firstMatch + 2) ?? Date()])
        default: return MatchHistory()
        }
    }
}

/// Fixtures, results and tables built by hand, as `MatchSource` gives them. Counts its sweeps.
final class FakeMatches: MatchSource {
    var teams: [Int64: TeamMatches]
    /// False for a build of FM whose fixture classes weren't found.
    var classesFound = true
    private(set) var sweeps = 0

    init(_ teams: [Int64: TeamMatches]) {
        self.teams = teams
    }

    func matches(team: Int64) -> TeamMatches? {
        sweeps += 1
        guard classesFound else { return nil }
        return teams[team] ?? TeamMatches(team: team, fixtures: [], table: nil, check: .noTable)
    }
}

/// Players' state as `PlayerStateSource` gives it: bans worked out by hand, and what FM's memory holds now, which a test
/// can change between calls. Counts the players it reads again.
final class FakeStates: PlayerStateSource {
    var bans: [UInt32: [Ban]]
    /// What a player's record says now, applied when he's read again.
    var now: [UInt32: (Player) -> Void] = [:]
    private(set) var refreshed: [UInt32] = []

    init(_ bans: [UInt32: [Ban]]) {
        self.bans = bans
    }

    func refresh(_ player: Player) {
        refreshed.append(player.uid)
        now[player.uid]?(player)
    }

    func bans(of player: Player) -> [Ban]? { player.storedBans == nil ? nil : bans[player.uid] ?? [] }
}

/// A save built by hand, as `GameSource` gives it. It counts its reads, and can say the save has moved on.
final class FakeSource: GameSource {
    var database: Database
    var engine: GameRulesEngine?
    var problem: GameProblem?
    var current = true
    var matches: FakeMatches? = World.matches()
    var states: FakeStates? = FakeStates(World.bans())
    private(set) var reads = 0

    init(database: Database, engine: GameRulesEngine?) {
        self.database = database
        self.engine = engine
    }

    func read() throws -> GameRead {
        if let problem { throw problem }
        reads += 1
        return GameRead(database: database, engine: engine, number: reads, matches: matches, states: states)
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
        for player in players {
            player.fitness = Fitness(condition: 10_000, sharpness: 9_650)
            player.morale = 12
            player.playingTime = 20
            player.storedBans = []
        }
        state(players)

        let db = Database()
        db.players = players
        db.staff = [staff(500, name: "The Manager", job: "Manager", block: 500),
                    staff(501, name: "Coach One", job: "Coach", block: 501),
                    staff(502, name: "Rival Coach", job: "Coach", block: 502, at: World.rivals)]
        db.gameDate = GameDate.checked(year: 2026, dayOfYear: 270)
        db.build = "27.1.0 (test)"
        db.checks = "PASS"
        db.stateOff = [:]
        db.humanClubs = [(team: 1, name: World.club, manager: 500)]
        db.budgets = [1: (transfer: 5_000_000, wageRoom: 20_000)]
        db.tactics = [1: tactic(players)]
        db.prepare()
        return db
    }

    /// First 1 is tired and unhappy with his playing time. FM last brought First 2's condition up to date three days ago,
    /// so it takes FM's getters.
    static func state(_ players: [Player]) {
        let byUID = Dictionary(uniqueKeysWithValues: players.map { ($0.uid, $0) })
        let tired = byUID[1]!
        tired.fitness = Fitness(condition: 8_570, sharpness: 9_210)
        tired.morale = 2
        tired.playingTime = -89

        let stale = byUID[2]!
        stale.fitness = nil
        stale.fitnessNeedsCatchUp = true
        stale.fitnessUpdated = GameDate.date(year: 2026, dayOfYear: 267)
    }

    /// First 1 is banned in the league and the cup. The youngster has a ban from abroad, in a competition FM Starship
    /// couldn't name, and the injured player one at home that it couldn't name either.
    static func bans() -> [UInt32: [Ban]] {
        var bookings = Ban(issued: GameDate.date(year: 2026, dayOfYear: 244)!, matches: 1, served: 0)
        bookings.competition = "Mock League"
        bookings.associationName = "Mockovia"
        bookings.reason = .bookings
        bookings.domestic = true
        bookings.countsForClub = true
        var red = Ban(issued: GameDate.date(year: 2026, dayOfYear: cupMatch)!, matches: 3, served: 1)
        red.competition = "Mock Cup"
        red.associationName = "Mockovia"
        red.reason = .redCard
        red.opponent = minnows
        red.domestic = true
        red.countsForClub = true

        var abroad = Ban(issued: GameDate.date(year: 2025, dayOfYear: 300)!, matches: 2, served: 0)
        abroad.associationName = "Fixtureland"
        abroad.reason = .bookings
        var unnamed = Ban(issued: GameDate.date(year: 2026, dayOfYear: 250)!, matches: 1, served: 0)
        unnamed.associationName = "Mockovia"
        unnamed.domestic = true
        unnamed.reason = .bookings
        return [1: [bookings, red], 12: [abroad], 13: [unnamed]]
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

    // MARK: Matches

    static let team: Int64 = 1, rivalsTeam: Int64 = 2, otherTeam: Int64 = 3, minnowsTeam: Int64 = 4
    static let otherTown = "Other Town", minnows = "Minnows FC"
    static let leagueIndex: UInt32 = 9, cupIndex: UInt32 = 12
    /// Days of 2026: 13 and 20 September, league; 23 September, cup; 4 October, league, and 11 October, cup, to come.
    static let firstMatch = 256, secondMatch = 263, cupMatch = 266, nextMatch = 277, laterMatch = 284

    static func fixture(_ day: Int, home: Int64, away: Int64, score: (Int, Int)? = nil, cup: Bool = false) -> MatchFixture {
        let names = [team: club, rivalsTeam: rivals, otherTeam: otherTown, minnowsTeam: minnows]
        var match = MatchFixture(date: GameDate.date(year: 2026, dayOfYear: day) ?? Date(), home: home, away: away)
        match.season = 2026
        match.homeName = names[home] ?? ""
        match.awayName = names[away] ?? ""
        match.competition = cup ? "Mock Cup" : "Mock League"
        match.competitionIndex = cup ? cupIndex : leagueIndex
        match.stage = cup ? "kvartfinale" : ""
        match.kickOff = 15 * 60
        if let score { (match.homeGoals, match.awayGoals) = score }
        return match
    }

    /// Testing FC beat Rivals FC 2-0 and drew 1-1 at Other Town in the league, and won 4-2 at Minnows FC in the cup.
    static func matches() -> FakeMatches {
        var first = fixture(firstMatch, home: team, away: rivalsTeam, score: (2, 0))
        first.round = 1
        first.attendance = 8_500
        // Scored by First 9, with First 10's assist, and First 11 in added time.
        first.goals = [MatchGoal(scorer: 9, assist: 10, home: true, minute: 23, addedMinute: 0),
                       MatchGoal(scorer: 11, assist: nil, home: true, minute: 45, addedMinute: 1)]
        var second = fixture(secondMatch, home: otherTeam, away: team, score: (1, 1))
        second.round = 2
        // Other Town's scorer isn't one of the save's players.
        second.goals = [MatchGoal(scorer: 9_999, assist: nil, home: true, minute: 60, addedMinute: 0),
                        MatchGoal(scorer: 9, assist: nil, home: false, minute: 80, addedMinute: 0)]
        var cupTie = fixture(cupMatch, home: minnowsTeam, away: team, score: (2, 4), cup: true)
        (cupTie.homeAggregate, cupTie.awayAggregate) = (3, 6)
        var next = fixture(nextMatch, home: team, away: otherTeam)
        next.round = 3
        next.kickOff = 20 * 60
        var later = fixture(laterMatch, home: team, away: minnowsTeam, cup: true)
        later.kickOff = nil

        func record(_ p: Int, _ w: Int, _ d: Int, _ l: Int, _ f: Int, _ a: Int) -> TableRecord {
            TableRecord(played: p, won: w, drawn: d, lost: l, goalsFor: f, goalsAgainst: a, points: 3 * w + d)
        }
        let none = record(0, 0, 0, 0, 0, 0)
        let table = LeagueTable(competition: "Mock League", competitionIndex: leagueIndex, rows: [
            LeagueTableRow(team: team, name: club, position: 1, overall: record(2, 1, 1, 0, 3, 1), home: record(1, 1, 0, 0, 2, 0),
                           away: record(1, 0, 1, 0, 1, 1)),
            LeagueTableRow(team: otherTeam, name: otherTown, position: 2, overall: record(1, 0, 1, 0, 1, 1), home: record(1, 0, 1, 0, 1, 1),
                           away: none),
            LeagueTableRow(team: rivalsTeam, name: rivals, position: 3, overall: record(1, 0, 0, 1, 0, 2), home: none,
                           away: record(1, 0, 0, 1, 0, 2)),
        ])
        let ours = [first, second, cupTie, next, later]
        return FakeMatches([
            team: TeamMatches(team: team, fixtures: ours, table: table, check: .passed),
            rivalsTeam: TeamMatches(team: rivalsTeam, fixtures: [first], table: table, check: .passed),
            otherTeam: TeamMatches(team: otherTeam, fixtures: [second, next], table: table, check: .passed),
        ])
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
