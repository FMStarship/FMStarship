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

    /// FM stores attributes 1-100; what players see is 1-20.
    public func attribute(at index: Int) -> Int { max(1, Int(Double(raw[index]) / 5.0 + 0.5)) }
    public func a(_ name: String) -> Int { attribute(at: Names.playerIndex[name]!) }

    public var notForSale: Bool { value == 300_000_000 }

    public func hasTrait(_ bit: Int) -> Bool { (traitBits >> UInt64(bit & 63)) & 1 > 0 }

    private var cachedTraits: String?
    private var cachedBestPositions: String?

    public var traits: String {
        cachedTraits ?? (0..<64).filter { hasTrait($0) && Names.traits[$0] != nil }.map { Names.traits[$0]! }.joined(separator: "; ")
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

    public func a(_ name: String) -> Int { Int(attr[Names.staffIndex[name]!]) }
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

public final class Database {
    public var players: [Player] = []
    public var staff: [Staff] = []
    public var build = ""
    public var fingerprint = ""
    public var readAt = Date()
    public var gameDate: Date?
    public var unnamed = 0
    public var checks = ""
    public var source = "live game"
    public var currencies: [Currency] = []
    public var humanClubs: [(team: Int64, name: String, manager: Int64)] = []
    public var budgets: [Int64: (transfer: Int64, wageRoom: Int)] = [:]
    /// The human managers' tactics by team. Live games only.
    public var tactics: [Int64: Tactic] = [:]
    public init() {}

    /// What the self-checks found wrong, or nil when there's nothing to say.
    public var checkProblems: String? { checks.hasPrefix("FAIL: ") ? String(checks.dropFirst(6)) : nil }

    /// Caches display text, once, so that parallel searches only read it.
    public func prepare() {
        players.forEach { $0.prepare() }
        staff.forEach { $0.prepare() }
    }
}
