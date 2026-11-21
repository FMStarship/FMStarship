import Foundation

public class Person {
    public var uid: UInt32 = 0
    public var block: Int64 = 0
    public var index: UInt32 = 0
    public var firstName = ""
    public var secondName = ""
    public var commonName = ""
    public var fullName = ""
    public var nation = ""
    public var birthYear = 0
    public var birthDay = 0
    public var club = ""
    public var clubFull = ""
    public var league = ""
    public var clubNation = ""
    public var region = ""
    public var area = ""
    public var areaRecord: Int64 = 0
    public var flags: UInt8 = 0
    public var isWoman = false
    public var pers = [UInt8](repeating: 0, count: 8)
    public var personality = ""
    public var media = ""
    public var age = -1
    public var wage = 0
    public var squad = ""
    public var loanClub = ""
    public var loanClubFull = ""
    public var statusFlags: UInt8 = 0
    public var listedYear = 0
    public var listedDay = 0
    public var teamIndex: UInt32 = 0
    public var clubObject: Int64 = 0
    public var loanClubObject: Int64 = 0
    public var endYear = 0
    public var endDay = 0
    public var loanEndYear = 0
    public var loanEndDay = 0
    /// At this club's own B team, which FM reads as a loan out when it keeps that team as a separate club.
    public var isAtOwnBTeam = false
    public var releaseClause: Int64 = 0
    public var releaseForeign: Int64 = 0
    public var releaseDomestic: Int64 = 0
    /// His contract's clauses for goals in the season, as it holds them. Not kept in snapshots.
    public var seasonGoalClauses: [SeasonGoalsClause] = []
    /// How many other clauses his contract holds, release clauses apart: ones FM Starship doesn't know the code of.
    public var unknownClauses = 0

    public init() {}

    public var transferListed: Bool { statusFlags & 1 > 0 }
    public var loanListed: Bool { statusFlags & 2 > 0 }
    public var loanUnavailable: Bool { statusFlags & 64 > 0 }
    public var transferStatus: String { transferListed ? "Listed" : "" }
    public var loanStatus: String { loanListed ? "Listed" : loanUnavailable ? "Unavailable" : "" }

    // Filled once by prepare() after loading, so parallel searches only ever read them.
    private var cachedName: String?
    private var cachedSearchText: String?

    public var name: String {
        cachedName ?? (commonName.isEmpty ? "\(firstName) \(secondName)".trimmingCharacters(in: .whitespaces) : commonName)
    }

    public var searchText: String { cachedSearchText ?? "\(name) \(fullName)".lowercased() }

    /// Call once on one thread when a person is complete, before searching.
    public func prepare() {
        cachedName = name
        cachedSearchText = searchText
    }

    public var birth: Date? {
        guard birthYear > 1800, birthDay >= 1 else { return nil }
        return GameDate.date(year: birthYear, dayOfYear: birthDay)
    }

    public var contractEnd: Date? { GameDate.checked(year: endYear, dayOfYear: endDay) }
    public var loanEnd: Date? { GameDate.checked(year: loanEndYear, dayOfYear: loanEndDay) }
    public var listedDate: Date? { GameDate.checked(year: listedYear, dayOfYear: listedDay) }

    public func p(_ name: String) -> Int { Int(pers[Names.personalityIndex[name]!]) }
}

public enum GameDate {
    public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    public static func date(year: Int, dayOfYear: Int) -> Date? {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return nil }
        return calendar.date(byAdding: .day, value: dayOfYear - 1, to: start)
    }

    public static func checked(year: Int, dayOfYear: Int) -> Date? {
        guard year > 1900, year < 2200, dayOfYear >= 1, dayOfYear <= 366 else { return nil }
        return date(year: year, dayOfYear: dayOfYear)
    }
}

public final class Injury {
    public var record: Int64 = 0
    public var name = ""
    public var date = Date.distantPast
    public var length = 0
    public init() {}
}

/// Condition and match sharpness, 0-10000, as FM keeps them. FM shows them as a heart and a tick, not as numbers.
public struct Fitness: Equatable, Sendable {
    public var condition: Int
    public var sharpness: Int
    public init(condition: Int, sharpness: Int) {
        self.condition = condition
        self.sharpness = sharpness
    }
    public static let range = 0...10_000
}

/// A clause in a player's contract paying a sum once he has scored so many goals in the season: FM's code 10.
public struct SeasonGoalsClause: Equatable, Sendable {
    /// The goals it needs.
    public var goals: Int
    /// In pounds, as his contract holds it.
    public var amount: Int64
    public init(goals: Int, amount: Int64) {
        self.goals = goals
        self.amount = amount
    }
}

/// Whether a player is home-grown for his club, by FM's own two tests: trained at the club, or trained in its nation.
public enum HomeGrown: String, Sendable {
    case club, nation, no
}

/// One suspension as FM keeps it in the player's history, before anything is worked out from it.
public struct StoredBan: Sendable, Equatable {
    /// The football association, by the index of its nation where it's a nation.
    public var association: UInt32 = 0
    /// Which of the association's rule sets it falls under, as FM numbers them. One rule set can cover several competitions.
    public var scope = 0
    /// The red card's match, 0 for a ban for bookings.
    public var match: Int64 = 0
    public var day = 0, year = 0
    public var kind: UInt8 = 0
    public var matches = 0, served = 0
    /// The rule set's rules index, as a player's booking counts name it.
    public var rules = 0
    /// For a ban for bookings, the yellow-card count it came at.
    public var bookingsAt = 0
    public var issued: Date? { GameDate.checked(year: year, dayOfYear: day) }
    public var isReal: Bool { issued != nil && matches > 0 && served <= matches }
    public var left: Int { matches - served }
    public init() {}
}

/// One suspension a player hasn't finished serving, with what FM Starship could work out about it.
public struct Ban: Sendable {
    public enum Reason: String, Sendable {
        case bookings, redCard = "red card"
    }

    /// The football association's index, and its nation's name where it's a nation FM Starship read, else "".
    public var association: UInt32 = 0
    public var associationName = ""
    /// Which of the association's rule sets it falls under, as FM numbers them.
    public var scope = 0
    /// The competition, where FM Starship can tell from FM's records: see `PlayerStateReader`. "" when it can't. A rule set
    /// can cover more competitions than this one.
    public var competition = ""
    public var competitionIndex: UInt32?
    /// Nil for a kind of ban FM Starship doesn't know.
    public var reason: Reason?
    /// The red card's match: the other side's club, as FM names it. Only set when it was his club's match.
    public var opponent = ""
    /// From the football association of his club's league, as FM's bans show it, else of his club's nation.
    public var domestic = false
    public var issued: Date
    public var matches: Int
    public var served: Int
    public var left: Int { matches - served }
    /// Whether it's for a competition his team plays in, which is what FM's squad screen counts. A ban from another
    /// association is most likely for his national team or a youth side, and one whose competition isn't known can't be
    /// counted.
    public var countsForClub = false

    public init(issued: Date, matches: Int, served: Int) {
        self.issued = issued
        self.matches = matches
        self.served = served
    }
}

public final class Player: Person {
    public var value: Int64 = 0
    public var ca = 0
    public var pa = 0
    public var pos = [UInt8](repeating: 0, count: 15)
    public var raw = [UInt8](repeating: 0, count: 54)
    public var traitBits: UInt64 = 0
    public var height = 0
    public var injuries: [Injury]?
    public var injury: Injury?
    public var injuryText = ""
    public var injuryDays = 0
    public var topRoles = [UInt8](repeating: 0, count: 6)
    public var season: SeasonStats?
    public var form = ""
    /// Condition and sharpness as FM stored them, only when FM brought them up to date on the game's day. Nil otherwise,
    /// since they're FM's for that day only: see `fitness(_:)`.
    public var fitness: Fitness?
    /// The day FM last brought them up to date, when it isn't the game's day, so they come from FM's getters.
    public var fitnessUpdated: Date?
    public var fitnessNeedsCatchUp = false
    /// 1-20.
    public var morale: Int?
    /// How happy he is with his playing time, −100 to 100, from his contract.
    public var playingTime: Int?
    /// The suspensions he still has to serve, as FM keeps them. Nil when they weren't read. `PlayerStateReader` works out
    /// what they're for, which takes more reads than the app needs.
    public var storedBans: [StoredBan]?

    /// FM stores attributes 1-100; what players see is 1-20.
    public func attribute(at index: Int) -> Int { max(1, Int(Double(raw[index]) / 5.0 + 0.5)) }
    public func a(_ name: String) -> Int { attribute(at: Names.playerIndex[name]!) }

    public var notForSale: Bool { value == 300_000_000 }

    /// Condition and sharpness as FM would show them today: as stored when FM brought them up to date today, else from
    /// FM's own getters, which gave FM's last stored values for players it hadn't updated for days. Nil when neither can
    /// say.
    public func fitness(_ engine: GameRulesEngine?) -> Fitness? {
        if let fitness { return fitness }
        guard fitnessNeedsCatchUp, let engine else { return nil }
        return engine.fitness(player: self)
    }

    public func hasTrait(_ bit: Int) -> Bool { (traitBits >> UInt64(bit & 63)) & 1 > 0 }

    private var cachedTraits: String?
    private var cachedBestPositions: String?

    public var traits: String {
        cachedTraits ?? (0..<64).filter { hasTrait($0) && Names.traits[$0] != nil }.map { Names.traits[$0]! }.joined(separator: "; ")
    }

    /// A rating of 18 or more. From 15 to 17 FM calls a player Accomplished: able to play there, but it isn't their position.
    public func isNatural(at position: Int) -> Bool { pos[position] >= 18 }

    /// The age after which Growth room is left empty: 23 for an outfield player and 27 for a goalkeeper.
    public static let lastGrowingAge = 23
    public static let lastGrowingAgeGoalkeeper = 27

    /// PA minus CA while the player is young enough to grow, and nil once they're older or their age isn't known.
    public var growthRoom: Int? {
        let last = isNatural(at: 0) ? Player.lastGrowingAgeGoalkeeper : Player.lastGrowingAge
        guard age >= 0, age <= last else { return nil }
        return pa - ca
    }

    public var bestPositions: String {
        if let cachedBestPositions { return cachedBestPositions }
        let best = Int(pos.max() ?? 0)
        return (0..<15).filter { Int(pos[$0]) >= max(15, best - 2) }
            .sorted { pos[$0] > pos[$1] }
            .map { Names.positions[$0] }.joined(separator: ", ")
    }

    public override func prepare() {
        super.prepare()
        cachedTraits = traits
        cachedBestPositions = bestPositions
    }

    private static func roleName(_ table: [String?], _ value: UInt8) -> String {
        value < 64 ? (table[Int(value)] ?? "") : ""
    }

    public var bestRoleIp: String { Player.roleName(Names.rolesIp, topRoles[0]) }
    public var bestRoleOop: String { Player.roleName(Names.rolesOop, topRoles[3]) }

    public func suitsRole(_ role: Int, outOfPossession: Bool) -> Bool {
        let picks = outOfPossession ? topRoles[3...5] : topRoles[0...2]
        return picks.contains(UInt8(truncatingIfNeeded: role))
    }
}

public final class Staff: Person {
    public var ca = 0
    public var pa = 0
    public var attr = [UInt8](repeating: 0, count: 52)
    public var job = ""
    public var secondJob = 0
    public var repCurrent = 0
    public var repHome = 0
    public var repWorld = 0
    public var stars = [Double](repeating: 0, count: 9)

    /// Adaptability isn't in the staff record: it's the person's personality number, which FM shows for staff. No other
    /// personality name is read here, so this never hands out a hidden one.
    public func a(_ name: String) -> Int {
        if Names.staffShownPersonality.contains(name) { return p(name) }
        return Int(attr[Names.staffIndex[name]!])
    }
}

public struct Currency {
    public let name: String
    public let symbol: String
    public let rate: Double
    public init(name: String, symbol: String, rate: Double) {
        self.name = name
        self.symbol = symbol
        self.rate = rate
    }
}

/// The parts of a player's state the reader checks. Each one that fails its check is off for the whole read.
public enum PlayerStateField: String, CaseIterable, Sendable {
    /// Condition and sharpness, which are checked together.
    case fitness
    case morale
    case playingTime
    case bans
}

public final class Database {
    public var players: [Player] = []
    public var staff: [Staff] = []
    public var build = ""
    public var fingerprint = ""
    public var readAt = Date()
    public var gameDate: Date?
    public var unnamed = 0
    public var checks = ""
    /// Why each player-state field is off for this read. They're off until a read of the game checks them, so a snapshot
    /// has none.
    public var stateOff: [PlayerStateField: String] = Dictionary(uniqueKeysWithValues: PlayerStateField.allCases.map { ($0, "not read") })
    public var source = "live game"
    public var currencies: [Currency] = []
    public var humanClubs: [(team: Int64, name: String, manager: Int64)] = []
    public var budgets: [Int64: (transfer: Int64, wageRoom: Int)] = [:]
    /// Each human club's teams, by the human's team as in `humanClubs`: each team's database index (`Team.index`) and its
    /// type, as `Names.squadName` names it. FM's news items name the team they're addressed to by that index.
    public var humanTeams: [Int64: [UInt32: Int]] = [:]
    /// The human clubs that are women's sides, by team.
    public var womensTeams: Set<Int64> = []
    /// False when the game's answer isn't here, so `Person.isWoman` and `womensTeams` say nothing.
    public var knowsSides = false
    /// The human managers' tactics by team. Live games only.
    public var tactics: [Int64: Tactic] = [:]
    /// Where the read found the game date, so it can be looked at again without reading everything. Only means
    /// something in the game it was read from, so it isn't kept in snapshots.
    public var dateRecords: [Int64] = []
    /// The nation records the read found, for naming a ban's association when asked. Only means something in the game it
    /// was read from, like `dateRecords`.
    public var nationRecords: [Int64] = []
    public init() {}

    public func stateIsOn(_ field: PlayerStateField) -> Bool { stateOff[field] == nil }

    /// What the self-checks found wrong, or nil when there's nothing to say.
    public var checkProblems: String? { checks.hasPrefix("FAIL: ") ? String(checks.dropFirst(6)) : nil }

    /// Caches display text, once, so that parallel searches only read it.
    public func prepare() {
        players.forEach { $0.prepare() }
        staff.forEach { $0.prepare() }
    }
}
