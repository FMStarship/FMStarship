import Foundation

/// One of FM's squad rules for a competition, as FM holds it: a type FM's own table names, a limit and a direction.
public struct SquadRule: Sendable, Equatable {
    public enum Direction: Sendable, Equatable {
        case atMost, exactly, atLeast
    }

    /// FM's type, which its per-player rule value is asked with.
    public var type: Int
    /// FM's own names for the type, in its table's order. A few types have two, such as `homegrown_players_from_club` and
    /// `homegrown_players_0_21_from_club`.
    public var names: [String]
    public var limit: Int
    public var direction: Direction
    /// True for a rule with a condition FM Starship hasn't decoded, which looks like it limits the rule to one kind of team.
    public var conditional: Bool

    public init(type: Int, names: [String], limit: Int, direction: Direction, conditional: Bool = false) {
        self.type = type
        self.names = names
        self.limit = limit
        self.direction = direction
        self.conditional = conditional
    }

    /// FM's first name for it, else its type.
    public var name: String { names.first ?? "type \(type)" }

    /// Whether it limits the squad's size, which every player counts toward.
    public var isSize: Bool { names.contains { Self.sizeNames.contains($0) } }
    public static let sizeNames: Set<String> = ["max_squad_size", "min_squad_size"]

    /// Why FM Starship doesn't count it against a squad, nil where it does. Only rules that count the squad are counted: FM
    /// names the others for a matchday squad, the team on the pitch or the bench, a season, a transfer window or wages.
    public var notCounted: String? {
        if conditional {
            return "FM holds a condition on it that FM Starship hasn't decoded, which looks like it limits the rule to some kinds of team"
        }
        if isSize || names.contains(where: Self.countsSquad) { return nil }
        return "it isn't a count of the squad (by FM's name for it, it's about a matchday squad, the team on the pitch, a season, a "
            + "transfer window or wages), which FM Starship doesn't count"
    }

    /// Why FM's value for it can't be had for a player at another club, as if he joined the club its team is asked for. Nil
    /// where it can. FM works out home-grown status, nationality and the EU against the club and nation of the team it's
    /// asked for, from the player's own history and nationalities, and a goalkeeper is one wherever he plays, so those FM
    /// gives as if he were at the club. Squad size counts him. Contract rules read his contract with the club, which he
    /// doesn't have yet, and other types haven't been checked.
    public var notKnownElsewhere: String? {
        if isSize || names.contains(where: Self.elsewhereNames.contains) { return nil }
        if names.contains(where: { $0.contains("contract") || $0.contains("amateur") }) {
            return "FM reads it from his contract with the club, which a player at another club doesn't have yet"
        }
        return "FM Starship hasn't checked that FM's value for it holds for a player at another club"
    }

    /// The types FM works out against the club its team is asked for, or by the player alone, as on 27.1.0.
    public static let elsewhereNames: Set<String> = [
        "homegrown_players_from_club", "homegrown_players_0_21_from_club", "homegrown_players_from_nation",
        "homegrown_players_0_21_from_nation", "homegrown_players_15_21_from_club", "homegrown_players_15_21_from_nation",
        "homegrown_players_0_21_ignore_loans_from_club_in_squad", "non_homegrown_players_in_squad", "all_foreign_players_in_squad",
        "non_eec_players_in_squad", "goalkeepers_in_squad",
    ]

    /// Whether FM's name for a type is a count of players in the squad.
    static func countsSquad(_ name: String) -> Bool {
        if ["match_squad", "_11", "on_bench", "season", "window", "wage"].contains(where: name.contains) { return false }
        return name.hasSuffix("_in_squad") || name.contains("_in_squad_") || name.hasPrefix("homegrown_players_")
            || name.hasPrefix("non_homegrown_players_")
    }
}

/// A competition's squad rules as FM holds them now.
public struct SquadRuleSet: Sendable {
    /// The competition's database index and name.
    public var index: UInt32
    public var name: String
    /// Its `db::COMP`, which FM's per-player rule value is asked with.
    public var record: Int64
    /// FM's squad-selection group, which FM's per-player rule value is asked with too. -1 for none.
    public var group: Int
    /// Empty where FM holds none, as for a cup with no squad rules.
    public var rules: [SquadRule]
    /// Why its rules couldn't be read, so none are given. Nil where they could.
    public var unreadable: String?

    public init(index: UInt32, name: String, record: Int64, group: Int, rules: [SquadRule], unreadable: String? = nil) {
        self.index = index
        self.name = name
        self.record = record
        self.group = group
        self.rules = rules
        self.unreadable = unreadable
    }
}

/// One rule counted against a group of players by FM's own per-player value.
public struct SquadRuleCount {
    public enum Standing: Equatable, Sendable {
        /// Inside the limit, not on it.
        case within
        /// Exactly on it: one more for a maximum, or one fewer for a minimum, and it's past it.
        case atLimit
        /// Past a maximum, or short of a minimum, or not the number a rule of "exactly" says.
        case over, under, notEqual
    }

    public var rule: SquadRule
    /// Those FM's value counts toward it, in the order given. Nil where it isn't counted.
    public var players: [Player]?
    /// Why it isn't counted, where it isn't.
    public var notCounted: String?

    public init(rule: SquadRule, players: [Player]?, notCounted: String? = nil) {
        self.rule = rule
        self.players = players
        self.notCounted = notCounted
    }

    public var count: Int? { players?.count }

    /// How the count stands against FM's number. Nil where it isn't counted.
    public var standing: Standing? {
        guard let count else { return nil }
        switch rule.direction {
        case .atMost: return count < rule.limit ? .within : count == rule.limit ? .atLimit : .over
        case .atLeast: return count > rule.limit ? .within : count == rule.limit ? .atLimit : .under
        case .exactly: return count == rule.limit ? .atLimit : .notEqual
        }
    }
}
