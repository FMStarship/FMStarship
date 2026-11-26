import Foundation
import StarshipAnalysis
import StarshipCore

/// Each competition's squad rules as FM holds them, counted against the user's club by FM's own per-player values. FM
/// keeps no registration list for a club like Molde, so which players FM counts isn't known: each rule is counted for the
/// first team and the whole club, and stands only where the two agree. Only its first note names registration, to say the
/// answer never settles it. Nothing in it
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

    /// The squad FM Starship counts besides the whole club.
    static let firstTeam = "First team"

    /// How the first team's and the whole club's counts stand against FM's number, where they agree. Nil where either isn't
    /// counted, or they stand differently, so the answer depends on which players FM counts.
    static func standingText(first: SquadRuleCount, whole: SquadRuleCount) -> String? {
        guard let standing = whole.standing, first.standing == standing, let inFirst = first.count, let inWhole = whole.count else {
            return nil
        }
        let limit = whole.rule.limit
        let off = inFirst == inWhole ? "\(abs(inWhole - limit))" : "\(abs(inFirst - limit)) (first team) or \(abs(inWhole - limit)) (whole club)"
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

        // Everyone at the club now: its own players not out on loan, and those on loan here. Which of them FM counts toward a
        // competition isn't known, so each rule is counted for the first team and for all of them, and stands only where the
        // two agree.
        let players = db.players.filter { ($0.clubFull == club.name && $0.loanClubFull.isEmpty) || $0.loanClubFull == club.name }
            .stableSorted(by: Self.positionOrder)
        let squads = Names.squadOrder.filter { name in players.contains { $0.squad == name } }
        let firstTeam = players.filter { $0.squad == Self.firstTeam }

        var notes = ["FM keeps no registration list for this club, so these are the squad as it is, counted by FM's own rules. "
                     + "Which players FM counts toward a competition isn't known, so each rule is counted for the first team and "
                     + "for the whole club (everyone at the club now, not those out on loan), and has a standing only where the "
                     + "two agree; elsewhere it depends on which players FM counts. Never tell the user the squad is registered, "
                     + "legal or breaking a rule unless the standing says so. FM's own registration screen settles who FM lets play."]
        let change = try squadChange(args, club: club, players: players, context: context)
        let indexes = try ruleCompetitions(named, club: club, source: source, context: context, notes: &notes)
        let countsOff = source.countsOff
        if let countsOff {
            notes.append("FM's per-player values are off for this read, so the rules are given without counts: \(countsOff).")
        }

        var limits: [String] = []
        var depends: [String] = []
        var none: [String] = []
        var changedLimits: [String] = []
        var changedDepends: [String] = []
        var notKnown: [String] = []
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
                // FM's value is the player's own, so the first team's count is the whole club's, narrowed to the first team.
                let whole = source.count(rule, in: set, players: players, team: club.team)
                let first = whole.players.map { found in
                    SquadRuleCount(rule: rule, players: found.filter { $0.squad == Self.firstTeam })
                }
                let words = Self.ruleWords(rule)
                var text = "\(words): \(Self.limitText(rule))"
                let standing = first.flatMap { Self.standingText(first: $0, whole: whole) }
                if let first, let inFirst = first.count, let inWhole = whole.count {
                    if let standing {
                        text = inFirst == inWhole ? "\(words): \(inWhole) of \(Self.limitText(rule))"
                            : "\(words): first team \(inFirst), whole club \(inWhole), of \(Self.limitText(rule))"
                        text += " (\(standing))"
                        if whole.standing != .within { limits.append("\(name), \(text)") }
                    } else {
                        text += ": depends on which players FM counts: first team \(inFirst), whole club \(inWhole)"
                        depends.append("\(name), \(text)")
                    }
                }
                var changed: JSON?
                if let change, let counted = whole.players, let inFirst = first?.count, let inWhole = whole.count {
                    let found = Self.changedCount(rule, in: set, counted: counted, change: change, source: source, team: club.team)
                    let limit = Self.limitText(rule)
                    switch found {
                    case .notKnown(let why):
                        let text = "\(words): \(limit): not known with the change: \(why)"
                        notKnown.append("\(name), \(text)")
                        changed = .object([("not_known", .string(why)), ("text", .string(text))])
                    case .counted(let after, let joining, let leaving):
                        let standing = Self.standingText(first: after.first, whole: after.whole)
                        let firstAfter = after.first.count ?? 0, wholeAfter = after.whole.count ?? 0
                        let counts = "first team \(inFirst) → \(firstAfter), whole club \(inWhole) → \(wholeAfter)"
                        var text: String
                        if let standing {
                            text = inFirst == inWhole && firstAfter == wholeAfter ? "\(words): \(inWhole) → \(wholeAfter) of \(limit)"
                                : "\(words): \(counts), of \(limit)"
                            text += " (\(standing))"
                            if after.whole.standing != .within { changedLimits.append("\(name), \(text)") }
                        } else {
                            text = "\(words): \(limit): depends on which players FM counts: \(counts)"
                            changedDepends.append("\(name), \(text)")
                        }
                        func people(_ list: [Player]) -> JSON? {
                            list.isEmpty || rule.isSize ? nil : .array(list.map { .object([("uid", .int(Int($0.uid))), ("name", .string($0.name))]) })
                        }
                        changed = .object(dropping: [
                            ("first_team", .int(firstAfter)),
                            ("whole_club", .int(wholeAfter)),
                            ("standing", standing.map { .string($0) }),
                            ("text", .string(text)),
                            ("joining", people(joining)),
                            ("leaving", people(leaving)),
                        ])
                    }
                }
                let everyone = !players.isEmpty && whole.count == players.count
                return .object(dropping: [
                    ("rule", .string(words)),
                    ("fm_name", .string(rule.name)),
                    ("fm_limit", .string(Self.limitText(rule))),
                    ("first_team", first?.count.map { .int($0) }),
                    ("whole_club", whole.count.map { .int($0) }),
                    ("standing", standing.map { .string($0) }),
                    ("text", .string(text)),
                    ("players", everyone || countsOff != nil ? nil : whole.players.map { found in
                        .array(found.map { .object([("uid", .int(Int($0.uid))), ("name", .string($0.name)),
                                                    ("squad", .string($0.squad))]) })
                    }),
                    ("everyone_counts", everyone && !rule.isSize ? .bool(true) : nil),
                    ("not_counted", countsOff == nil ? whole.notCounted.map { .string($0) } : nil),
                    ("if_changed", changed),
                ])
            }
            competitions.append(.object([("competition", .string(name)), ("rules", .array(rules))]))
        }

        if countsOff == nil {
            notes.append("Each rule's players are those at the whole club who count toward it, with their squad: the ones in the "
                         + "\(Self.firstTeam) make the first team's count.")
        }
        var changed: JSON?
        if let change {
            let leaving = Set(change.leaving.map(\.uid))
            let joining = change.joining.count
            notes.append("if_changed counts the squad as if the players in add joined the club's first team and those in remove left "
                         + "the club, by FM's own value for each, and stands by the same rule as the counts now. FM gives a player "
                         + "at another club's home-grown status, nationality and position as if he were at this club, from his own "
                         + "history, so he's trained at the club only if he was; a rule it can't answer for him is not known rather "
                         + "than guessed.")
            changed = .object(dropping: [
                ("add", .array(change.joining.map { player in
                    .object([("uid", .int(Int(player.uid))), ("name", .string(player.name)), ("joins", .string(Self.joins(player, club: club)))])
                } + change.promoted.map { player in
                    .object([("uid", .int(Int(player.uid))), ("name", .string(player.name)),
                             ("joins", .string("the first team, from the \(player.squad.isEmpty ? "club's other squads" : player.squad)"))])
                })),
                ("remove", .array(change.leaving.map { .object([("uid", .int(Int($0.uid))), ("name", .string($0.name)), ("squad", .string($0.squad))]) })),
                ("first_team", .int(firstTeam.filter { !leaving.contains($0.uid) }.count + joining + change.promoted.count)),
                ("whole_club", .int(players.filter { !leaving.contains($0.uid) }.count + joining)),
                ("at_or_past_a_limit", countsOff != nil ? nil : .array(changedLimits.map { .string($0) })),
                ("depends_on_which_players_fm_counts", countsOff != nil || changedDepends.isEmpty ? nil : .array(changedDepends.map { .string($0) })),
                ("not_known", countsOff != nil || notKnown.isEmpty ? nil : .array(notKnown.map { .string($0) })),
            ])
        }
        return .object(dropping: [
            ("club", .string(club.name)),
            ("first_team", .int(firstTeam.count)),
            ("whole_club", .int(players.count)),
            ("squads", .array(squads.map { .string($0) })),
            ("competitions", .array(competitions)),
            ("no_squad_rules", none.isEmpty ? nil : .array(none.map { .string($0) })),
            ("at_or_past_a_limit", countsOff != nil ? nil : .array(limits.map { .string($0) })),
            ("depends_on_which_players_fm_counts", countsOff != nil || depends.isEmpty ? nil : .array(depends.map { .string($0) })),
            ("if_changed", changed),
            ("notes", .array(notes.map { .string($0) })),
        ])
    }

    /// Who an answer with add or remove counts as joining or leaving.
    struct SquadChange {
        /// Joining the club: from another club, from none, or back from a loan.
        var joining: [Player]
        /// At the club already, and into the first team.
        var promoted: [Player]
        var leaving: [Player]
        /// Those joining who aren't contracted to the club, for whom FM's value can't be had for every rule.
        var elsewhere: Set<UInt32>
    }

    /// The players in add and remove, refused where one isn't a player in the save, is in both, or can't join or leave as
    /// asked. Nil where neither is given.
    private func squadChange(_ args: Arguments, club: ChosenClub, players: [Player], context: CallContext) throws -> SquadChange? {
        func list(_ key: String) throws -> [Player] {
            var seen = Set<UInt32>()
            return try (args.array(key) ?? []).compactMap { item in
                guard let uid = item.int else { throw ToolError("Each uid in \(key) must be a whole number.") }
                guard let player = try context.person(uid, kind: "player") as? Player else {
                    throw ToolError("uid \(uid) is a member of staff, not a player.")
                }
                return seen.insert(player.uid).inserted ? player : nil
            }
        }
        let add = try list("add"), remove = try list("remove")
        guard !add.isEmpty || !remove.isEmpty else { return nil }
        if let both = add.first(where: { player in remove.contains { $0.uid == player.uid } }) {
            throw ToolError("\(both.name) (uid \(both.uid)) is in both add and remove.")
        }
        let here = Set(players.map(\.uid))
        for player in remove where !here.contains(player.uid) {
            throw ToolError(player.clubFull == club.name
                            ? "\(player.name) (uid \(player.uid)) is out on loan, so he isn't counted now. Leave him out of remove."
                            : "\(player.name) (uid \(player.uid)) isn't at \(club.name), so he can't leave it.")
        }
        var change = SquadChange(joining: [], promoted: [], leaving: remove, elsewhere: [])
        for player in add {
            if !here.contains(player.uid) {
                change.joining.append(player)
                if player.clubFull != club.name { change.elsewhere.insert(player.uid) }
            } else if player.squad == Self.firstTeam {
                throw ToolError("\(player.name) (uid \(player.uid)) is in \(club.name)'s first team already.")
            } else {
                change.promoted.append(player)
            }
        }
        return change
    }

    /// Where a player in add comes from.
    static func joins(_ player: Player, club: ChosenClub) -> String {
        if player.clubFull == club.name { return "back from his loan at \(player.loanClubFull)" }
        return player.clubFull.isEmpty ? "from no club" : "from \(player.clubFull)"
    }

    enum ChangedCount {
        /// The two counts after the change, with who joining counts toward it and who leaving did.
        case counted((first: SquadRuleCount, whole: SquadRuleCount), joining: [Player], leaving: [Player])
        case notKnown(String)
    }

    /// One rule counted again as if the change were made, from those at the whole club who count toward it now. Only those
    /// joining are asked of FM, for the club's team; a player at another club only for a rule FM answers for him.
    static func changedCount(_ rule: SquadRule, in set: SquadRuleSet, counted: [Player], change: SquadChange,
                             source: SquadRulesSource, team: Int64) -> ChangedCount {
        let outside = change.joining.filter { change.elsewhere.contains($0.uid) }
        if !outside.isEmpty, let why = rule.notKnownElsewhere {
            return .notKnown("\(why) (\(outside.map(\.name).joined(separator: ", ")))")
        }
        var joined: [Player] = []
        if !change.joining.isEmpty {
            let found = source.count(rule, in: set, players: change.joining, team: team)
            guard let players = found.players else {
                return .notKnown(found.notCounted ?? "FM's value for it wasn't had for those joining")
            }
            joined = players
        }
        let leaving = Set(change.leaving.map(\.uid)), promoted = Set(change.promoted.map(\.uid))
        let joining = Set(change.joining.map(\.uid))
        let whole = counted.filter { !leaving.contains($0.uid) } + joined
        let first = whole.filter { $0.squad == firstTeam || promoted.contains($0.uid) || joining.contains($0.uid) }
        return .counted((SquadRuleCount(rule: rule, players: first), SquadRuleCount(rule: rule, players: whole)),
                        joining: joined + counted.filter { promoted.contains($0.uid) },
                        leaving: counted.filter { leaving.contains($0.uid) })
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
