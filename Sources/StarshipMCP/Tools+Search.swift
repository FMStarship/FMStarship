import Foundation
import StarshipAnalysis
import StarshipCore
import StarshipSearch

extension Sequence {
    /// Sorted, keeping equal items in the order they came in.
    func stableSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in
            if areInIncreasingOrder(a.element, b.element) { return true }
            if areInIncreasingOrder(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}

extension Toolbox {
    /// A number for a filter box, which takes millions or thousands as typed.
    private static func boxText(_ amount: Double, per unit: Double) -> String { String(amount / unit) }

    /// The attribute rules, each refused if it isn't an attribute or is hidden while Hidden attributes is off.
    private static func rules(_ args: Arguments, known: [String], hidden: Set<String>, _ visibility: Visibility) throws -> [AttrRule] {
        guard let items = try args.array("rules") else { return [] }
        var rules: [AttrRule] = []
        for item in items {
            guard let typed = item["attribute"]?.string else { throw ToolError("Each rule needs an attribute, by FM's name.") }
            guard let attribute = known.first(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) else {
                throw ToolError("\(typed) isn't an attribute FM Starship knows. Use FM's names, such as Finishing or Work Rate.")
            }
            if hidden.contains(attribute), !visibility.showHidden { throw ToolError(Visibility.hiddenSentence(attribute)) }
            let bounds = [("at_least", true), ("at_most", false)].compactMap { key, atLeast in item[key].map { (key, atLeast, $0) } }
            guard !bounds.isEmpty else { throw ToolError("The rule on \(attribute) needs at_least or at_most.") }
            for (key, atLeast, value) in bounds {
                guard let limit = value.int, (1...20).contains(limit) else { throw ToolError("\(key) on \(attribute) must be 1-20.") }
                var rule = AttrRule()
                rule.attribute = attribute
                rule.atLeast = atLeast
                rule.value = String(limit)
                rules.append(rule)
            }
        }
        guard rules.count <= AttrRule.maxCount else { throw ToolError("At most \(AttrRule.maxCount) rules.") }
        return rules
    }

    /// The column to order by, if it may be used now.
    private static func sortColumn(_ args: Arguments, in catalogue: [Col], _ visibility: Visibility) throws -> Col? {
        guard let name = try args.string("sort") else { return nil }
        guard let col = catalogue.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ToolError("There's no column called \(name) to order by.")
        }
        if col.ability, !visibility.showsAbility { throw ToolError(Visibility.abilitySentence(col.name, showHidden: visibility.showHidden)) }
        if col.hidden, !visibility.showHidden { throw ToolError(Visibility.hiddenSentence(col.name)) }
        if Columns.sortsAfterChecks(col) { throw ToolError("\(col.name) can't be ordered by here.") }
        return col
    }

    /// A value from the save's own list, matched without case, such as a personality.
    private static func known(_ key: String, _ typed: String?, in values: [String]) throws -> String? {
        guard let typed else { return nil }
        guard let found = values.first(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) else {
            throw ToolError("No \(key) is called \(typed) in this save. There are: \(values.joined(separator: ", ")).")
        }
        return found
    }

    func searchPlayers(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let visibility = context.visibility
        var filter = PlayerFilter(showHidden: visibility.showHidden, showAbility: visibility.showsAbility)
        filter.reset()
        filter.name = try args.string("name") ?? ""
        if let position = try args.choice("position", Names.positions) { filter.position = position }
        if let rating = try args.int("min_rating", in: 1...20) { filter.ratingAtLeast = String(rating) }
        filter.ageMin = try args.int("age_min").map(String.init) ?? ""
        filter.ageMax = try args.int("age_max").map(String.init) ?? ""
        filter.nation = try args.string("nation") ?? "Any"
        filter.league = try args.string("league") ?? "Any"
        filter.club = try args.string("club") ?? ""
        if let squad = try args.choice("squad", Names.squadOrder + ["On loan"]) { filter.squad = squad }
        filter.valueMax = try args.number("value_max").map { Self.boxText($0, per: 1_000_000) } ?? ""
        filter.wageMax = try args.number("wage_max").map { Self.boxText($0, per: 1000) } ?? ""
        filter.contractEndsBy = try args.int("contract_ends_by").map(String.init) ?? ""
        filter.transferListedOnly = try args.bool("transfer_listed") ?? false
        filter.loanListedOnly = try args.bool("loan_listed") ?? false
        filter.hasClause = try args.bool("has_clause") ?? false
        filter.excludeNotForSale = try args.bool("exclude_not_for_sale") ?? false
        filter.hideInjured = try args.bool("fit_only") ?? false
        filter.heightMin = try args.int("height_min").map(String.init) ?? ""
        filter.heightMax = try args.int("height_max").map(String.init) ?? ""
        let personalities = Array(Set(context.db.players.map(\.personality).filter { !$0.isEmpty })).sorted()
        filter.personality = try Self.known("personality", try args.string("personality"), in: personalities) ?? "Any"
        if let trait = try args.choice("trait", Names.traitList) { filter.trait1 = trait }
        if let role = try args.choice("role", Names.roleList) { filter.role = role }
        for key in ["ca_min", "ca_max", "pa_min", "pa_max"] where args.has(key) && !visibility.showsAbility {
            throw ToolError(Visibility.abilitySentence(key.hasPrefix("ca") ? "CA" : "PA", showHidden: visibility.showHidden))
        }
        filter.caMin = try args.int("ca_min").map(String.init) ?? ""
        filter.caMax = try args.int("ca_max").map(String.init) ?? ""
        filter.paMin = try args.int("pa_min").map(String.init) ?? ""
        filter.paMax = try args.int("pa_max").map(String.init) ?? ""
        filter.seasonApps = try args.int("apps_min").map(String.init) ?? ""
        filter.seasonMinutes = try args.int("minutes_min").map(String.init) ?? ""
        filter.seasonGoals = try args.int("goals_min").map(String.init) ?? ""
        filter.seasonAssists = try args.int("assists_min").map(String.init) ?? ""
        filter.seasonRating = try args.number("rating_min").map { String($0) } ?? ""
        let rules = try Self.rules(args, known: PlayerFilter.ruleAttributes, hidden: PlayerFilter.hiddenRuleAttributes, visibility)
        filter.rules = rules
        let catalogue = Columns.forPlayers()
        let sort = try Self.sortColumn(args, in: catalogue, visibility)
        let limit = try args.int("limit", in: 1...100) ?? 25

        var found = filter.criteria().filter(context.db.players)
        var shownNames = Self.playerListColumns
        if let clauseMax = try args.number("clause_max") {
            let nation = (try? context.ownClub(nil)).flatMap { club in context.db.players.first { $0.clubFull == club.name }?.clubNation } ?? ""
            let most = Units.toPounds(clauseMax)
            found = found.filter { player in
                let clause = Self.clause(player, buyerNation: nation)
                return clause > 0 && Double(clause) <= most
            }
            shownNames.append("Release clause")
        }
        let ordered = Columns.ordered(players: found, sortBy: sort, descending: try args.bool("descending") ?? (sort?.numeric ?? true),
                                      byAbility: visibility.showsAbility)
        if let sort, !shownNames.contains(sort.name) { shownNames.append(sort.name) }
        for rule in rules where !shownNames.contains(rule.attribute) { shownNames.append(rule.attribute) }
        let columns = Output.columns(shownNames, in: catalogue, visibility)
        let order = sort?.name ?? (visibility.showsAbility ? "CA" : "Value")
        return .object([("found", .int(found.count)), ("shown", .int(min(limit, found.count))), ("order", .string(order)),
                        ("wages", .string(Units.wageSuffix))]
                       + Output.rows(Array(ordered.prefix(limit)), columns, visibility))
    }

    /// The release clause a club from `buyerNation` would pay: the general one, or the one for buyers from home or abroad,
    /// whichever is lower. 0 when there's none.
    static func clause(_ player: Player, buyerNation: String) -> Int64 {
        let domestic = !player.clubNation.isEmpty && player.clubNation == buyerNation
        let local = domestic ? player.releaseDomestic : player.releaseForeign
        return [player.releaseClause, local].filter { $0 > 0 }.min() ?? 0
    }

    func searchStaff(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let visibility = context.visibility
        var filter = StaffFilter(showHidden: visibility.showHidden, showAbility: visibility.showsAbility)
        filter.reset()
        filter.job = "Any job"
        if let job = try args.string("job") {
            let jobs = ["Coaching staff"] + Array(Set(Names.jobs.values)).sorted()
            guard let found = jobs.first(where: { $0.caseInsensitiveCompare(job) == .orderedSame }) else {
                throw ToolError("job must be one of: \(jobs.joined(separator: ", ")).")
            }
            filter.job = found
        }
        filter.name = try args.string("name") ?? ""
        filter.nation = try args.string("nation") ?? "Any"
        filter.league = try args.string("league") ?? "Any"
        filter.club = try args.string("club") ?? ""
        filter.ageMin = try args.int("age_min").map(String.init) ?? ""
        filter.ageMax = try args.int("age_max").map(String.init) ?? ""
        let rank = try args.choice("rank_by", Names.areasLong)
        filter.rank = rank ?? StaffFilter.noRanking
        if let stars = try args.number("min_stars") {
            guard rank != nil else { throw ToolError("min_stars needs rank_by, the area the stars are in.") }
            filter.minStars = String(stars)
        }
        filter.wageMax = try args.number("wage_max").map { Self.boxText($0, per: 1000) } ?? ""
        filter.contractEndsBy = try args.int("contract_ends_by").map(String.init) ?? ""
        let personalities = Array(Set(context.db.staff.map(\.personality).filter { !$0.isEmpty })).sorted()
        filter.personality = try Self.known("personality", try args.string("personality"), in: personalities) ?? "Any"
        let rules = try Self.rules(args, known: StaffFilter.ruleAttributes + Names.staffShownPersonality,
                                   hidden: StaffFilter.hiddenRuleAttributes, visibility)
        filter.rules = rules
        let catalogue = Columns.forStaff()
        let sort = try Self.sortColumn(args, in: catalogue, visibility)
        let limit = try args.int("limit", in: 1...100) ?? 25

        let found = filter.criteria().filter(context.db.staff)
        let reputation = catalogue.first { $0.name == "World rep." }
        let ordered: [Staff]
        if sort != nil || filter.rankArea >= 0 {
            ordered = Columns.ordered(staff: found, sortBy: sort, descending: try args.bool("descending") ?? (sort?.numeric ?? true),
                                      rankArea: filter.rankArea)
        } else {
            ordered = reputation.map { Columns.sortRows(found, by: $0, descending: true) } ?? found
        }
        var shownNames = Self.staffListColumns
        if filter.rankArea >= 0 { shownNames.append(Names.areas[filter.rankArea]) }
        if let sort, !shownNames.contains(sort.name) { shownNames.append(sort.name) }
        for rule in rules where !shownNames.contains(rule.attribute) { shownNames.append(rule.attribute) }
        let columns = Output.columns(shownNames, in: catalogue, visibility)
        let order = sort?.name ?? rank.map { "\($0) stars" } ?? "World reputation"
        return .object([("found", .int(found.count)), ("shown", .int(min(limit, found.count))), ("order", .string(order)),
                        ("wages", .string(Units.wageSuffix))]
                       + Output.rows(Array(ordered.prefix(limit)), columns, visibility))
    }
}
