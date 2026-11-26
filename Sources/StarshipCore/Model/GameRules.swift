import Foundation

public struct SeasonStats {
    public var apps = 0, starts = 0, subs = 0, minutes = 0, goals = 0, assists = 0
    public var rating = 0.0
    public var playerOfTheMatch = 0, yellow = 0, red = 0, cleanSheets = 0, conceded = 0
    public var xG = 0.0, xA = 0.0
    public var passPercent = 0, shotsOnTargetPercent = 0, tacklePercent = 0
    public var tackles = 0, dribbles = 0, fouls = 0, fouled = 0
    public init() {}
}

/// One role on a player's profile: stars are stored as half-stars, as FM does.
public struct RoleRow {
    public var role: String
    public var outOfPossession: Bool
    public var minHalfStars: Int
    public var maxHalfStars: Int
    public var rating: Int
    public init(role: String, outOfPossession: Bool, minHalfStars: Int, maxHalfStars: Int, rating: Int) {
        self.role = role
        self.outOfPossession = outOfPossession
        self.minHalfStars = minHalfStars
        self.maxHalfStars = maxHalfStars
        self.rating = rating
    }
}

/// How keen a player is to join, in the words of FM's recruitment search. Anything from Doubtful up would join,
/// though the less keen may want more money.
public enum JoinInterest: Int, Comparable, Sendable {
    case notInterested, doubtful, persuadable, interested

    /// FM's own join score, cut where FM's score bands are and where its recruitment search splits them.
    public init(score: Int32) {
        switch score {
        case 10_000...: self = .interested
        case 5_000...: self = .persuadable
        case (-2_000)...: self = .doubtful
        default: self = .notInterested
        }
    }

    public var wouldJoin: Bool { self != .notInterested }

    public var text: String {
        switch self {
        case .interested: return "Interested"
        case .persuadable: return "Persuadable"
        case .doubtful: return "Doubtful"
        case .notInterested: return "Not interested"
        }
    }

    public static func < (lhs: JoinInterest, rhs: JoinInterest) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The features that FM Starship gets by running the game's own code on a copy of its memory.
/// Everything here is optional: a nil engine or a nil answer means "not available on this build",
/// and the app must show that rather than a guess.
public protocol GameRulesEngine: AnyObject {
    var supportsInjuryDays: Bool { get }
    func interest(player: Player, team: Int64) -> (transfer: JoinInterest, loan: JoinInterest)?
    func staffInterest(staff: Staff, team: Int64, level: Int) -> Bool?
    func preferredJob(staff: Staff) -> Int?
    func jobPreferences(staff: Staff) -> [UInt8]?
    func roleRows(player: Player, team: Int64) -> [RoleRow]?
    func seasonStats(player: Player, season: Int) -> SeasonStats?
    func form(player: Player) -> String?
    func injuryReturnDays(player: Player) -> Int?
    /// The player's recent matches, from the same record as `form`.
    func matchHistory(player: Player) -> MatchHistory?
    /// Condition and sharpness as FM's own getters give them today.
    func fitness(player: Player) -> Fitness?
    /// Whether he's home-grown for his club, by FM's own tests. Nil for a player with no club.
    func homeGrown(player: Player) -> HomeGrown?
    /// FM's `GAME_DISCIPLINE`, which holds its disciplinary rule sets by rules index. Nil where it isn't found.
    var discipline: Int64? { get }
    /// FM's own answer for one rule set: how many more yellow cards bring a ban, and how long. `bookingCount` is the
    /// player's `MacLayout.BookingCount` under it as FM's memory holds it now, or nil for a player with none yet.
    func nextBan(rules: Int, bookingCount: [UInt8]?) -> NextBan?
}

extension GameRulesEngine {
    public func matchHistory(player: Player) -> MatchHistory? { nil }
    public func fitness(player: Player) -> Fitness? { nil }
    public func homeGrown(player: Player) -> HomeGrown? { nil }
    public var discipline: Int64? { nil }
    public func nextBan(rules: Int, bookingCount: [UInt8]?) -> NextBan? { nil }
}

public enum GameRules {
    public static var engine: GameRulesEngine?
}
