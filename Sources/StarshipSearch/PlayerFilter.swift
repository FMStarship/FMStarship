import Foundation
import StarshipCore

/// The player filter window's state. `Any` and blank mean "no filter"; see `SearchFilter`.
public struct PlayerFilter: SearchFilter, Equatable {
    // Basics
    public var name = ""
    public var nation = "Any"
    public var club = ""
    public var squad = "Any"
    public var league = "Any"
    public var region = "Any"
    public var ageMin = ""
    public var ageMax = ""
    // Position
    public var position = "Any"
    public var ratingAtLeast = "15"
    // Ability
    public var caMin = ""
    public var caMax = ""
    public var paMin = ""
    public var paMax = ""
    // Physical & fitness
    public var heightMin = ""
    public var heightMax = ""
    public var hideInjured = false
    // Season stats
    public var seasonApps = ""
    public var seasonMinutes = ""
    public var seasonGoals = ""
    public var seasonAssists = ""
    public var seasonRating = ""
    // Attributes
    public var rules = [AttrRule](repeating: AttrRule(), count: 8)
    // Contract
    public var valueMax = ""
    public var wageMax = ""
    public var contractEndsBy = ""
    public var hasClause = false
    public var excludeNotForSale = false
    public var transferListedOnly = false
    public var loanListedOnly = false
    // Hidden
    public var consistency = ""
    public var importantMatches = ""
    public var injuryProneness = ""
    // Personality
    public var personality = "Any"
    public var media = "Any"
    // Traits
    public var trait1 = "Any"
    public var trait2 = "Any"
    // Roles
    public var role = "Any"
    // Interest
    public var onTransfer = false
    public var onLoan = false

    public var showHidden = true {
        didSet { dropHiddenRules() }
    }
    /// While off, the CA and PA boxes keep what's typed but don't apply.
    public var showAbility = true

    public var defaults: [String: String] = [:]

    public init() { markDefaults() }

    /// The club whose interest is checked. It lives in `RulesState` because staff searches and other
    /// windows share it. Setting it picks that club.
    public var interestClub: String {
        get { RulesState.shared.clubName }
        nonmutating set { RulesState.shared.pickClub(newValue) }
    }

    public static var interestEnabled: Bool { RulesState.shared.interestEnabled }

    public static let tabOrder = ["General", "Attributes", "Contract & interest", "Personality & more", "Season stats"]

    public static let ruleAttributes: [String] =
        Net.cultureSorted(Names.playerAttrs.filter { !Names.hidden.contains($0) }) + Names.hidden + Names.personality

    public static let hiddenRuleAttributes = Set(Names.hidden + Names.personality)

    public static let sections: [FilterSection<PlayerFilter>] = [
        FilterSection("Basics", tab: "General", fields: [
            FilterField("name", "Name", .text(\.name), placeholder: .text("Any name")),
            FilterField("nation", "Nation", .choice(\.nation, .nations, editable: true)),
            FilterField("club", "Club", .text(\.club), placeholder: .text("Any club")),
            FilterField("squad", "Squad", .choice(\.squad, .fixed(["Any"] + Names.squadOrder), editable: false)),
            FilterField("league", "League", .choice(\.league, .leagues, editable: true)),
            FilterField("region", "Region", .choice(\.region, .regions, editable: false)),
            FilterField("age", "Age", .range(min: \.ageMin, max: \.ageMax)),
        ]),
        FilterSection("Position", tab: "General", fields: [
            FilterField("position", "Position", .choice(\.position, .fixed(["Any"] + Names.positions), editable: false)),
            FilterField("ratingAtLeast", "Rating at least", .text(\.ratingAtLeast)),
        ]),
        FilterSection("Ability", tab: "General", abilityOnly: true, fields: [
            FilterField("ca", "CA", .range(min: \.caMin, max: \.caMax)),
            FilterField("pa", "PA", .range(min: \.paMin, max: \.paMax)),
        ]),
        FilterSection("Physical & fitness", tab: "General", fields: [
            FilterField("height", "Height", .range(min: \.heightMin, max: \.heightMax), placeholder: .text("cm")),
            FilterField("hideInjured", "Hide injured players", .toggle(\.hideInjured)),
        ]),
        FilterSection("Season stats (this season, club)", tab: "Season stats", fields: [
            FilterField("seasonApps", "Appearances at least", .text(\.seasonApps), placeholder: .text("e.g. 10")),
            FilterField("seasonMinutes", "Minutes at least", .text(\.seasonMinutes)),
            FilterField("seasonGoals", "Goals at least", .text(\.seasonGoals)),
            FilterField("seasonAssists", "Assists at least", .text(\.seasonAssists)),
            FilterField("seasonRating", "Average rating at least", .text(\.seasonRating), placeholder: .text("e.g. 7.0")),
        ]),
        FilterSection("Attributes", tab: "Attributes", fields: (0..<8).map { FilterField("rule\($0)", "", .rule($0)) }),
        FilterSection("Contract", tab: "Contract & interest", fields: [
            FilterField("valueMax", "Value up to", .text(\.valueMax), placeholder: .moneyMillions),
            FilterField("wageMax", "Wage up to", .text(\.wageMax), placeholder: .wageThousands),
            FilterField("contractEndsBy", "Contract ends by", .text(\.contractEndsBy), placeholder: .text("year")),
            FilterField("hasClause", "Has a release clause", .toggle(\.hasClause)),
            FilterField("excludeNotForSale", "Exclude 'not for sale'", .toggle(\.excludeNotForSale)),
            FilterField("transferListedOnly", "Transfer-listed only", .toggle(\.transferListedOnly)),
            FilterField("loanListedOnly", "Loan-listed only", .toggle(\.loanListedOnly)),
        ]),
        FilterSection("Hidden", tab: "Attributes", hiddenOnly: true, fields: [
            FilterField("consistency", "Consistency at least", .text(\.consistency), placeholder: .text("1-20")),
            FilterField("importantMatches", "Imp. matches at least", .text(\.importantMatches), placeholder: .text("1-20")),
            FilterField("injuryProneness", "Inj. proneness at most", .text(\.injuryProneness), placeholder: .text("1-20")),
        ]),
        FilterSection("Personality", tab: "Personality & more", fields: [
            FilterField("personality", "Personality", .choice(\.personality, .personalities, editable: true)),
            FilterField("media", "Media handling", .choice(\.media, .media, editable: true)),
        ]),
        FilterSection("Traits (preferred moves)", tab: "Personality & more", fields: [
            FilterField("trait1", "Has", .choice(\.trait1, .fixed(["Any"] + Names.traitList), editable: false)),
            FilterField("trait2", "And", .choice(\.trait2, .fixed(["Any"] + Names.traitList), editable: false)),
        ]),
        FilterSection("Roles (the game's best three)", tab: "Personality & more", fields: [
            FilterField("role", "Suits", .choice(\.role, .fixed(["Any"] + Names.roleList), editable: false)),
        ]),
        FilterSection("Interested in joining you", tab: "Contract & interest", fields: [
            FilterField("interestClub", "Your club", .choice(\.interestClub, .humanClubs, editable: false),
                        isFilter: false, needsGame: true),
            FilterField("onTransfer", "On a transfer", .toggle(\.onTransfer), needsGame: true),
            FilterField("onLoan", "On loan", .toggle(\.onLoan), needsGame: true),
            FilterField("interestNote", "", .note(.playerInterest)),
        ]),
    ]

    /// "Reset all". The interest toggles and each rule's operator stay as they are, and the result becomes
    /// the new baseline, as in the original.
    public mutating func reset() {
        name = ""
        club = ""
        ageMin = ""
        ageMax = ""
        caMin = ""
        caMax = ""
        paMin = ""
        paMax = ""
        consistency = ""
        importantMatches = ""
        injuryProneness = ""
        valueMax = ""
        wageMax = ""
        contractEndsBy = ""
        heightMin = ""
        heightMax = ""
        seasonApps = ""
        seasonMinutes = ""
        seasonGoals = ""
        seasonAssists = ""
        seasonRating = ""
        hideInjured = false
        loanListedOnly = false
        transferListedOnly = false
        excludeNotForSale = false
        hasClause = false
        ratingAtLeast = "15"
        nation = "Any"
        league = "Any"
        personality = "Any"
        media = "Any"
        region = "Any"
        position = "Any"
        squad = "Any"
        trait1 = "Any"
        trait2 = "Any"
        role = "Any"
        for index in rules.indices { rules[index].clear() }
        markDefaults()
    }

    /// Shows one club's squad: everyone in it, whatever their position rating.
    public mutating func openSquad(club: String, squad: String?) {
        reset()
        ratingAtLeast = ""
        self.club = "=\(club)"
        self.squad = squad.flatMap { Names.squadOrder.contains($0) ? $0 : nil } ?? "Any"
    }

    /// Season stats load in the background, so a search using them is re-run once they arrive.
    public var usesSeasonStats: Bool {
        [seasonApps, seasonMinutes, seasonGoals, seasonAssists, seasonRating].contains { !Net.trim($0).isEmpty }
    }

    /// Which interest answers to require. Off without a live game and a club, whatever the toggles say.
    public var interestWanted: (transfer: Bool, loan: Bool) {
        guard GameRules.engine != nil, RulesState.shared.team != 0 else { return (false, false) }
        return (onTransfer, onLoan)
    }

    /// Whether a player passes `interestWanted`, once `RulesState.check` has answered for them.
    public func matchesInterest(_ player: Player) -> Bool {
        let wanted = interestWanted
        guard let known = RulesState.shared.known(player) else { return false }
        return (wanted.transfer && known.transfer) || (wanted.loan && known.loan)
    }

    /// The summary line under the filters.
    public func describe() -> String {
        let wanted = interestWanted
        let rating = Net.int32(ratingAtLeast)
        let symbol = Units.money.symbol
        let club = RulesState.shared.clubName

        var positionText: String?
        if position != "Any" {
            positionText = position + (rating == nil || rating == 15 ? "" : " (rating \(rating!)+)")
        }

        let opening: [String?] = [
            positionText,
            FilterText.typed(name, "name: "),
            FilterText.pick(nation, ""),
            FilterText.typed(self.club, ""),
            squad == "Any" ? nil : squad,
            FilterText.pick(league, ""),
            FilterText.pick(region, ""),
            FilterText.range("age", ageMin, ageMax),
            showAbility ? FilterText.range("CA", caMin, caMax) : nil,
            showAbility ? FilterText.range("PA", paMin, paMax) : nil,
            FilterText.range("height", heightMin, heightMax, suffix: " cm"),
            hideInjured ? "fit" : nil,
            FilterText.typed(seasonApps, "apps "),
            FilterText.typed(seasonMinutes, "minutes "),
            FilterText.typed(seasonGoals, "goals "),
            FilterText.typed(seasonAssists, "assists "),
            FilterText.typed(seasonRating, "av. rating "),
        ]
        let atLeastPrefixes = ["apps ", "minutes ", "goals ", "assists ", "av. rating "]
        let marked = opening.map { text -> String? in
            guard let text else { return nil }
            return atLeastPrefixes.contains { text.hasPrefix($0) } ? text + "+" : text
        }

        var interest: String?
        if wanted.transfer && wanted.loan {
            interest = "would join \(club)"
        } else if wanted.transfer {
            interest = "would join \(club) on a transfer"
        } else if wanted.loan {
            interest = "would join \(club) on loan"
        }

        let closing: [String?] = [
            FilterText.typed(valueMax, "value up to \(symbol)"),
            FilterText.typed(wageMax, "wage up to \(symbol)"),
            FilterText.typed(contractEndsBy, "contract ends by "),
            hasClause ? "has a release clause" : nil,
            excludeNotForSale ? "for sale" : nil,
            transferListedOnly ? "transfer-listed" : nil,
            loanListedOnly ? "loan-listed" : nil,
            showHidden ? FilterText.typed(consistency, "consistency ") : nil,
            showHidden ? FilterText.typed(importantMatches, "imp. matches ") : nil,
            showHidden ? FilterText.typed(injuryProneness, "inj. proneness up to ") : nil,
            FilterText.pick(personality, ""),
            FilterText.pick(media, ""),
            FilterText.pick(trait1, ""),
            FilterText.pick(trait2, ""),
            FilterText.pick(role, "suits "),
            interest,
        ]
        return Net.join(marked + activeRuleTexts + closing)
    }

    /// The filter read once, ready to test many players.
    public func criteria() -> PlayerCriteria { PlayerCriteria(self) }

    /// One-off check. To test many players, build `criteria()` once.
    public func matches(_ player: Player) -> Bool { criteria().matches(player) }
}

/// A `PlayerFilter` parsed for matching: the original's `Criteria()` closure. Excludes the interest filter,
/// which needs game calls and runs after this one.
public struct PlayerCriteria {
    private let name: NameTest
    private let nation: TextTest
    private let club: TextTest
    private let league: TextTest
    private let media: TextTest
    private let squad: String?
    private let region: RegionTest
    private let ageMin: Int?
    private let ageMax: Int?
    private let caMin: Int?
    private let caMax: Int?
    private let paMin: Int?
    private let paMax: Int?
    private let heightMin: Int?
    private let heightMax: Int?
    private let endsBy: Int?
    private let fitOnly: Bool
    private let position: Int
    private let positionNeed: Int
    private let maxValue: Double?
    private let maxWage: Double?
    private let clause: Bool
    private let forSale: Bool
    private let transferListed: Bool
    private let loanListed: Bool
    private let consistency: Int?
    private let importantMatches: Int?
    private let injuryProneness: Int?
    private let tests: [RuleTest]
    private let personality: String?
    private let trait1: Int
    private let trait2: Int
    private let role: Int
    private let roleOop: Bool
    private let apps: Int?
    private let minutes: Int?
    private let goals: Int?
    private let assists: Int?
    private let rating: Double?
    private let anySeason: Bool

    private static let consistencyIndex = Names.playerIndex["Consistency"]!
    private static let importantMatchesIndex = Names.playerIndex["Important Matches"]!
    private static let injuryPronenessIndex = Names.playerIndex["Injury Proneness"]!

    fileprivate init(_ filter: PlayerFilter) {
        name = NameTest(filter.name)
        nation = TextTest(filter.nation)
        club = TextTest(filter.club)
        league = TextTest(filter.league)
        media = TextTest(filter.media)
        squad = filter.squad == "Any" ? nil : filter.squad
        region = RegionTest(filter.region)
        ageMin = Net.int32(filter.ageMin)
        ageMax = Net.int32(filter.ageMax)
        caMin = filter.showAbility ? Net.int32(filter.caMin) : nil
        caMax = filter.showAbility ? Net.int32(filter.caMax) : nil
        paMin = filter.showAbility ? Net.int32(filter.paMin) : nil
        paMax = filter.showAbility ? Net.int32(filter.paMax) : nil
        heightMin = Net.int32(filter.heightMin)
        heightMax = Net.int32(filter.heightMax)
        endsBy = Net.int32(filter.contractEndsBy)
        fitOnly = filter.hideInjured
        position = Names.positions.firstIndex(of: filter.position) ?? -1
        positionNeed = Net.int32(filter.ratingAtLeast) ?? 15
        maxValue = FilterText.decimal(filter.valueMax).map { Units.toPounds($0 * 1_000_000.0) }
        maxWage = FilterText.decimal(filter.wageMax).map { Units.toWeeklyPounds($0 * 1_000.0) }
        clause = filter.hasClause
        forSale = filter.excludeNotForSale
        transferListed = filter.transferListedOnly
        loanListed = filter.loanListedOnly

        consistency = filter.showHidden ? Net.int32(filter.consistency) : nil
        importantMatches = filter.showHidden ? Net.int32(filter.importantMatches) : nil
        injuryProneness = filter.showHidden ? Net.int32(filter.injuryProneness) : nil
        tests = filter.ruleTests(attributes: Names.playerIndex)

        personality = filter.personality == "Any" || filter.personality.isEmpty ? nil : filter.personality
        trait1 = filter.trait1 == "Any" ? -1 : Names.traits.firstIndex(of: filter.trait1) ?? -1
        trait2 = filter.trait2 == "Any" ? -1 : Names.traits.firstIndex(of: filter.trait2) ?? -1

        var roleNumber = -1
        var outOfPossession = false
        if filter.role != "Any" {
            outOfPossession = filter.role.hasSuffix(" (OOP)")
            let table = outOfPossession ? Names.rolesOop : Names.rolesIp
            if let bracket = filter.role.range(of: " (", options: .backwards) {
                roleNumber = table.firstIndex(of: String(filter.role[..<bracket.lowerBound])) ?? -1
            }
        }
        role = roleNumber
        roleOop = outOfPossession

        apps = Net.int32(filter.seasonApps)
        minutes = Net.int32(filter.seasonMinutes)
        goals = Net.int32(filter.seasonGoals)
        assists = Net.int32(filter.seasonAssists)
        rating = FilterText.decimal(filter.seasonRating)
        anySeason = apps != nil || minutes != nil || goals != nil || assists != nil || rating != nil
    }

    private func matchesClub(_ player: Player) -> Bool {
        if club.matches(player.club) || club.matches(player.clubFull) { return true }
        return !player.loanClub.isEmpty && (club.matches(player.loanClub) || club.matches(player.loanClubFull))
    }

    public func matches(_ player: Player) -> Bool {
        if anySeason {
            guard let stats = player.season else { return false }
            if let apps, stats.apps < apps { return false }
            if let minutes, stats.minutes < minutes { return false }
            if let goals, stats.goals < goals { return false }
            if let assists, stats.assists < assists { return false }
            if let rating, stats.rating < rating { return false }
        }

        if trait1 >= 0, !player.hasTrait(trait1) { return false }
        if trait2 >= 0, !player.hasTrait(trait2) { return false }
        if role >= 0, !player.suitsRole(role, outOfPossession: roleOop) { return false }

        if fitOnly, player.injury != nil { return false }
        if let heightMin, player.height < heightMin { return false }
        if let heightMax, player.height > heightMax { return false }

        if name.isActive, !name.matches(player.searchText) { return false }
        guard nation.matches(player.nation), matchesClub(player), league.matches(player.league) else { return false }

        if let squad {
            let inSquad = squad == "On loan" ? !player.loanClub.isEmpty : player.squad == squad
            if !inSquad { return false }
        }
        if !region.matches(player) { return false }

        // Unknown age is -1, which fails a maximum as well as any minimum of zero or more.
        if let ageMin, player.age < ageMin { return false }
        if let ageMax, player.age < 0 || player.age > ageMax { return false }

        if position >= 0, Int(player.pos[position]) < positionNeed { return false }

        if let caMin, player.ca < caMin { return false }
        if let caMax, player.ca > caMax { return false }
        if let paMin, player.pa < paMin { return false }
        if let paMax, player.pa > paMax { return false }

        if let personality, player.personality != personality { return false }
        if !media.matches(player.media) { return false }

        if let maxValue, player.notForSale || Double(player.value) > maxValue { return false }
        if let maxWage, Double(player.wage) > maxWage { return false }

        if let endsBy {
            guard let end = player.contractEnd, Net.year(end) <= endsBy else { return false }
        }
        if clause, player.releaseClause == 0, player.releaseForeign == 0, player.releaseDomestic == 0 { return false }
        if forSale, player.notForSale { return false }
        if transferListed, !player.transferListed { return false }
        if loanListed, !player.loanListed { return false }

        if let consistency, player.attribute(at: Self.consistencyIndex) < consistency { return false }
        if let importantMatches, player.attribute(at: Self.importantMatchesIndex) < importantMatches { return false }
        if let injuryProneness, player.attribute(at: Self.injuryPronenessIndex) > injuryProneness { return false }

        for test in tests {
            let read = test.isPersonality ? Int(player.pers[test.index]) : player.attribute(at: test.index)
            if !test.passes(read) { return false }
        }
        return true
    }

    /// Everyone who matches, in the order given. Runs in parallel.
    public func filter(_ players: [Player]) -> [Player] {
        // `searchText` is lazy and its first read isn't thread-safe.
        if name.isActive { players.forEach { _ = $0.searchText } }
        return parallelFilter(players, matches)
    }
}
