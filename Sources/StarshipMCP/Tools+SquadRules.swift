import Foundation
import StarshipAnalysis
import StarshipCore

/// Each competition's squad rules as FM holds them, counted against the user's squad by FM's own per-player values. FM
/// keeps no registration list for a club like Molde, so this is the squad as it is now, counted by FM's rules, never a
/// registration list, and its words never say a player is "registered" or a squad "legal". Nothing in it
/// is hidden in FM: home-grown status and contracts are on its squad and registration screens, and no rating is read.
extension Toolbox {
    /// How far back the club's fixtures show the competitions it plays in, as for bookings.
    static let rulesPlaysDays = 120

    /// FM's names for the types, in plain words. Any other goes out as FM's name with spaces.
    static let ruleWords: [String: String] = [
        "max_squad_size": "squad size",
        "min_squad_size": "squad size",
        "players_on_pt_or_ft_contract_in_squad": "players on a professional or part-time contract",
        "youth_or_amateur_players_in_squad": "players on a youth or amateur contract",
        "outfield_youth_or_amateur_players_in_squad": "outfield players on a youth or amateur contract",
        "homegrown_players_from_club": "trained at the club up to 21",
        "homegrown_players_0_21_from_club": "trained at the club up to 21",
        "homegrown_players_0_21_ignore_loans_from_club_in_squad": "trained at the club up to 21, by FM's count that ignores loans",
        "homegrown_players_from_nation": "trained in the club's nation up to 21, at the club or elsewhere",
        "homegrown_players_0_21_from_nation": "trained in the club's nation up to 21, at the club or elsewhere",
        "homegrown_players_15_21_from_club": "trained at the club between 15 and 21",
        "homegrown_players_15_21_from_nation": "trained in the club's nation between 15 and 21, at the club or elsewhere",
        "non_homegrown_players_in_squad": "not home-grown",
        "all_foreign_players_in_squad": "foreign by nationality",
        "non_eec_players_in_squad": "from outside the EU (FM's non-EEC)",
        "goalkeepers_in_squad": "goalkeepers",
        "non_eec_players_in_match_squad": "from outside the EU (FM's non-EEC) in a matchday squad",
        "over_19_players_in_match_squad": "over 19 in a matchday squad",
        "over_20_players_in_match_squad": "over 20 in a matchday squad",
    ]

    static func ruleWords(_ rule: SquadRule) -> String {
        rule.names.lazy.compactMap { ruleWords[$0] }.first ?? rule.name.replacingOccurrences(of: "_", with: " ")
    }

    static func limitText(_ rule: SquadRule) -> String {
        switch rule.direction {
        case .atMost: return "at most \(rule.limit)"
        case .atLeast: return "at least \(rule.limit)"
        case .exactly: return "exactly \(rule.limit)"
        }
    }

    static func standingText(_ count: SquadRuleCount) -> String? {
        guard let standing = count.standing, let number = count.count else { return nil }
        let off = abs(number - count.rule.limit)
        switch standing {
        case .within: return "within"
        case .atLimit: return "at the limit"
        case .over: return "over the maximum by \(off)"
        case .under: return "under the minimum by \(off)"
        case .notEqual: return "\(off) off the number FM sets"
        }
    }

    func squadRules(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let club = try context.ownClub(try args.string("club"))
        let named = try args.string("competition")
        guard let source = context.read.squadRules else {
            throw ToolError("FM Starship can't read FM's squad rules on this build of FM.")
        }
        if let off = source.off {
            throw ToolError("FM's squad rules are off for this read: \(off). So they're left out rather than guessed. "
                            + "game_status with refresh reads the save again.")
        }
        let db = context.db

        // Everyone at the club now: its own players not out on loan, and those on loan here.
        let atClub = db.players.filter { ($0.clubFull == club.name && $0.loanClubFull.isEmpty) || $0.loanClubFull == club.name }
        let squads = Names.squadOrder.filter { name in atClub.contains { $0.squad == name } }
        let wanted = try args.string("squad") ?? (squads.contains("First team") ? "First team" : "all")
        var shown: String?
        if wanted.caseInsensitiveCompare("all") != .orderedSame {
            guard let match = squads.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw ToolError("\(club.name) has no squad called \(wanted). Its squads: \(squads.joined(separator: ", ")), or all.")
            }
            shown = match
        }
        let players = atClub.filter { shown == nil || $0.squad == shown }.stableSorted(by: Self.positionOrder)

        var notes: [String] = []
        let indexes = try ruleCompetitions(named, club: club, source: source, context: context, notes: &notes)
        let countsOff = source.countsOff
        if let countsOff {
            notes.append("FM's per-player values are off for this read, so the rules are given without counts: \(countsOff).")
        }

        var limits: [String] = []
        var none: [String] = []
        var competitions: [JSON] = []
        for index in indexes {
            guard let set = source.rules(competition: index) else { continue }
            let name = set.name.isEmpty ? "competition \(index)" : set.name
            if let why = set.unreadable {
                competitions.append(.object([("competition", .string(name)),
                                             ("note", .string("Its squad rules couldn't be read: \(why). So they're left out."))]))
                continue
            }
            if set.rules.isEmpty {
                none.append(name)
                continue
            }
            let rules: [JSON] = set.rules.map { rule in
                let counted = source.count(rule, in: set, players: players, team: club.team)
                let words = Self.ruleWords(rule)
                var text = "\(words): \(Self.limitText(rule))"
                if let number = counted.count {
                    text = "\(words): \(number) of \(Self.limitText(rule))"
                    if let standing = Self.standingText(counted) { text += " (\(standing))" }
                    if counted.standing != .within { limits.append("\(name), \(text)") }
                }
                let everyone = !players.isEmpty && counted.count == players.count
                return .object(dropping: [
                    ("rule", .string(words)),
                    ("fm_name", .string(rule.name)),
                    ("fm_limit", .string(Self.limitText(rule))),
                    ("count", counted.count.map { .int($0) }),
                    ("standing", Self.standingText(counted).map { .string($0) }),
                    ("text", .string(text)),
                    ("players", everyone || countsOff != nil ? nil : counted.players.map { found in
                        .array(found.map { .object([("uid", .int(Int($0.uid))), ("name", .string($0.name))]) })
                    }),
                    ("everyone_counts", everyone && !rule.isSize ? .bool(true) : nil),
                    ("not_counted", countsOff == nil ? counted.notCounted.map { .string($0) } : nil),
                ])
            }
            competitions.append(.object([("competition", .string(name)), ("rules", .array(rules))]))
        }

        notes.append("FM keeps no registration list for this club, so this is the squad as it is now, counted by FM's own rules, "
                     + "not a registration list: it doesn't settle who FM lets play in a competition. FM's own registration "
                     + "screen does.")
        if shown != nil {
            notes.append("Only the \(shown ?? "") is counted. Which of the club's players FM counts toward each competition isn't "
                         + "known: a league's limits on youth or amateur contracts suggest it counts players outside the first team "
                         + "too. squad all counts everyone at the club.")
        }
        return .object(dropping: [
            ("club", .string(club.name)),
            ("counted", .string(shown ?? "all: everyone at the club now, not those out on loan")),
            ("squads", .array(squads.map { .string($0) })),
            ("players", .int(players.count)),
            ("competitions", .array(competitions)),
            ("no_squad_rules", none.isEmpty ? nil : .array(none.map { .string($0) })),
            ("at_or_past_a_limit", countsOff != nil ? nil : .array(limits.map { .string($0) })),
            ("notes", .array(notes.map { .string($0) })),
        ])
    }

    /// The competitions asked about: the one named, else the club's league and the competitions in its fixtures from
    /// `rulesPlaysDays` ago on, the league first and the rest by name.
    private func ruleCompetitions(_ named: String?, club: ChosenClub, source: SquadRulesSource, context: CallContext,
                                  notes: inout [String]) throws -> [UInt32] {
        if let named {
            let names = source.competitionNames()
            var found = names.filter { $0.value.compare(named, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            if found.isEmpty { found = names.filter { $0.value.range(of: named, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
            let distinct = Set(found.values).sorted()
            guard !distinct.isEmpty else {
                throw ToolError("No competition FM holds fixtures of is called \(named). Name it as FM does, in the game's language.")
            }
            guard distinct.count == 1 else {
                throw ToolError("\(named) could be any of: \(distinct.prefix(12).joined(separator: ", "))\(distinct.count > 12 ? ", ..." : ""). "
                                + "Name one exactly.")
            }
            return found.keys.sorted()
        }
        var indexes: [UInt32] = []
        if let league = source.league(of: club.team) { indexes.append(league) }
        guard let matches = context.read.matches else {
            notes.append("FM Starship can't read the club's fixtures on this build of FM, so only its league is here. Name another "
                         + "competition to see its rules.")
            return indexes
        }
        var found = cachedMatches(context.read, team: club.team, source: matches)
        if case .failed = found?.check { found = nil }
        if let found {
            let today = context.db.gameDate ?? clock()
            let from = GameDate.calendar.date(byAdding: .day, value: -Self.rulesPlaysDays, to: today) ?? today
            let names = competitionNames(context.read)
            let more = Set(found.fixtures.filter { $0.date >= from }.map(\.competitionIndex)).subtracting(indexes)
            indexes += more.sorted { (names[$0] ?? "", $0) < (names[$1] ?? "", $1) }
        } else {
            notes.append("FM Starship couldn't read the club's fixtures, so only its league is here. Name another competition to see "
                         + "its rules.")
        }
        return indexes
    }
}
