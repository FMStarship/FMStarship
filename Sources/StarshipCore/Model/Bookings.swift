import Foundation

/// FM's own answer for a player under one disciplinary rule set, from `DISCIPLINE::get_count_until_next_ban`.
public struct NextBan: Equatable, Sendable {
    /// Yellow cards until his next ban.
    public var left: Int
    /// That ban's length in matches.
    public var length: Int
    /// The count FM went by.
    public var count: Int
    /// The lowest count at the ban step he's on, so the count his last ban came at. 0 for none.
    public var lastBanAt: Int

    public init(left: Int, length: Int, count: Int, lastBanAt: Int) {
        self.left = left
        self.length = length
        self.count = count
        self.lastBanAt = lastBanAt
    }
}

/// A player's yellow cards under one of FM's disciplinary rule sets, and FM's answer for how many more bring a ban. FM keeps
/// one count for each rule set, and one rule set can cover several competitions, such as a league and the division below,
/// whose cards count together.
public struct Booking: Sendable {
    /// FM's rules index.
    public var rules: Int
    /// The competitions under it that his team plays in, else up to three others FM holds fixtures of. Empty when FM
    /// Starship can't name it.
    public var competitions: [String]
    /// Whether `competitions` are his team's.
    public var teamPlays: Bool
    /// How many other competitions use it, past the ones `competitions` names, when they aren't his team's.
    public var moreCompetitions = 0
    /// False for a rule set that counts some other way than yellow cards one by one, such as points or a window of matches,
    /// which FM Starship hasn't checked: its numbers aren't given.
    public var plain: Bool
    /// FM's answer. Nil when it isn't a plain count, or FM's rules didn't answer.
    public var next: NextBan?

    public init(rules: Int, competitions: [String], teamPlays: Bool, plain: Bool = true, next: NextBan?) {
        self.rules = rules
        self.competitions = competitions
        self.teamPlays = teamPlays
        self.plain = plain
        self.next = next
    }
}
