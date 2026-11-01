import Foundation
import StarshipCore

/// The staff filter window's state. See `SearchFilter`.
public struct StaffFilter: SearchFilter, Equatable {
    private static let coachingJobs: Set<String> = [
        "Assistant Manager", "Coach", "Goalkeeping Coach", "Fitness Coach", "Set Piece Coach", "Manager",
    ]
    private static let anyJob = "Any job"
    private static let coachingStaff = "Coaching staff"
    private static let sortByCA = "(sort by CA)"

    // Basics
    public var name = ""
    public var job = StaffFilter.coachingStaff
    public var nation = "Any"
    public var club = ""
    public var squad = "Any"
    public var league = "Any"
    public var region = "Any"
    public var ageMin = ""
    public var ageMax = ""
    // Coaching stars
    public var rank = Names.areasLong[1]
    public var minStars = "Any"
    // Attributes
    public var rules = [AttrRule](repeating: AttrRule(), count: 8)
    // Contract
    public var wageMax = ""
    public var contractEndsBy = ""
    // Personality
    public var personality = "Any"
    // Interest
    public var firstTeam = false
    public var reserves = false
    public var youthTeam = false

    public var showHidden = true {
        didSet { dropHiddenRules() }
    }

    public var defaults: [String: String] = [:]

    public init() { markDefaults() }

    public static var interestEnabled: Bool { RulesState.shared.staffInterestEnabled }

    public static let tabOrder = ["General", "Attributes", "Contract & more"]

    public static let ruleAttributes: [String] =
        Net.cultureSorted(Names.staffShown)
        + Net.cultureSorted(Columns.hiddenStaffAttributes.filter { !$0.hasPrefix("Unnamed") })

    public static let hiddenRuleAttributes = Set(Columns.hiddenStaffAttributes + Names.personality)

    public static let sections: [FilterSection<StaffFilter>] = [
        FilterSection("Basics", tab: "General", fields: [
            FilterField("name", "Name", .text(\.name), placeholder: .text("Any name")),
            FilterField("job", "Job", .choice(\.job, .fixed(
                [anyJob, coachingStaff] + Net.cultureSorted(Array(Names.jobs.values))), editable: false)),
            FilterField("nation", "Nation", .choice(\.nation, .nations, editable: true)),
            FilterField("club", "Club", .text(\.club), placeholder: .text("Any club")),
            FilterField("squad", "Squad", .choice(\.squad, .fixed(["Any"] + Names.squadOrder), editable: false)),
            FilterField("league", "League", .choice(\.league, .leagues, editable: true)),
            FilterField("region", "Region", .choice(\.region, .regions, editable: false)),
            FilterField("age", "Age", .range(min: \.ageMin, max: \.ageMax)),
        ]),
        FilterSection("Coaching stars", tab: "General", fields: [
            FilterField("rank", "Rank by", .choice(\.rank, .fixed([sortByCA] + Names.areasLong), editable: false)),
            FilterField("minStars", "At least (stars)",
                        .choice(\.minStars, .fixed(["Any", "3.5", "4", "4.5", "5"]), editable: false)),
        ]),
        FilterSection("Attributes", tab: "Attributes", fields: (0..<8).map { FilterField("rule\($0)", "", .rule($0)) }),
        FilterSection("Contract", tab: "Contract & more", fields: [
            FilterField("wageMax", "Wage up to", .text(\.wageMax), placeholder: .wageThousands),
            FilterField("contractEndsBy", "Contract ends by", .text(\.contractEndsBy), placeholder: .text("year")),
        ]),
        FilterSection("Personality", tab: "Contract & more", fields: [
            FilterField("personality", "Personality", .choice(\.personality, .personalities, editable: true)),
        ]),
        FilterSection("Interested in joining you", tab: "Contract & more", fields: [
            FilterField("firstTeam", "First Team", .toggle(\.firstTeam), needsGame: true),
            FilterField("reserves", "Reserves", .toggle(\.reserves), needsGame: true),
            FilterField("youthTeam", "Youth Team", .toggle(\.youthTeam), needsGame: true),
            FilterField("interestNote", "", .note(.staffInterest)),
        ]),
    ]

    /// The coaching area to rank by, or -1 for "(sort by CA)".
    public var rankArea: Int { Names.areasLong.firstIndex(of: rank) ?? -1 }

    /// "Reset all". The interest toggles and each rule's operator stay as they are, and the result becomes
    /// the new baseline, as in the original.
    public mutating func reset() {
        name = ""
        club = ""
        ageMin = ""
        ageMax = ""
        wageMax = ""
        contractEndsBy = ""
        job = Self.coachingStaff
        rank = Names.areasLong[1]
        minStars = "Any"
        nation = "Any"
        league = "Any"
        personality = "Any"
        region = "Any"
        squad = "Any"
        for index in rules.indices { rules[index].clear() }
        markDefaults()
    }

    /// Shows everyone at one club, whatever their job.
    public mutating func openClub(_ club: String) {
        reset()
        job = Self.anyJob
        self.club = "=\(club)"
    }

    /// Which interest answers to require. Off without a live game and a manager, whatever the toggles say.
    public var interestWanted: (firstTeam: Bool, reserves: Bool, youth: Bool) {
        guard GameRules.engine != nil, RulesState.shared.manager != 0 else { return (false, false, false) }
        return (firstTeam, reserves, youthTeam)
    }

    /// Whether a person passes `interestWanted`, once `RulesState.staffCheck` has answered for them.
    public func matchesInterest(_ staff: Staff) -> Bool {
        let wanted = interestWanted
        guard let known = RulesState.shared.staffKnown(staff) else { return false }
        return (wanted.firstTeam && known.firstTeam) || (wanted.reserves && known.reserves)
            || (wanted.youth && known.youth)
    }

    /// The summary line under the filters.
    public func describe() -> String {
        let wanted = interestWanted
        let squads = [wanted.firstTeam ? "first team" : nil, wanted.reserves ? "reserves" : nil,
                      wanted.youth ? "youth team" : nil].compactMap { $0 }

        var ranked: String?
        if rank != Self.sortByCA {
            ranked = "ranked by \(rank)" + (minStars == "Any" ? "" : " (\(minStars)★+)")
        }

        let opening: [String?] = [
            job == Self.anyJob ? nil : job,
            FilterText.typed(name, "name: "),
            FilterText.pick(nation, ""),
            FilterText.typed(club, ""),
            squad == "Any" ? nil : squad,
            FilterText.pick(league, ""),
            FilterText.pick(region, ""),
            FilterText.range("age", ageMin, ageMax),
            ranked,
        ]
        let closing: [String?] = [
            FilterText.typed(wageMax, "wage up to \(Units.money.symbol)"),
            FilterText.typed(contractEndsBy, "contract ends by "),
            FilterText.pick(personality, ""),
            squads.isEmpty ? nil : "would join your \(squads.joined(separator: " / "))",
        ]
        return Net.join(opening + activeRuleTexts + closing)
    }

    /// The filter read once, ready to test many staff.
    public func criteria() -> StaffCriteria { StaffCriteria(self) }

    /// One-off check. To test many people, build `criteria()` once.
    public func matches(_ staff: Staff) -> Bool { criteria().matches(staff) }

    fileprivate enum JobTest {
        case any
        case coaching
        case exactly(String)
    }

    fileprivate var jobTest: JobTest {
        switch job {
        case Self.anyJob: return .any
        case Self.coachingStaff: return .coaching
        default: return .exactly(job)
        }
    }

    fileprivate static func isCoaching(_ job: String) -> Bool { coachingJobs.contains(job) }
}

/// A `StaffFilter` parsed for matching: the original's `Criteria()` closure. Excludes the interest filter,
/// which needs game calls and runs after this one.
public struct StaffCriteria {
    private let name: NameTest
    private let nation: TextTest
    private let club: TextTest
    private let league: TextTest
    private let region: RegionTest
    private let squad: String?
    private let job: StaffFilter.JobTest
    private let ageMin: Int?
    private let ageMax: Int?
    private let personality: String?
    private let maxWage: Double?
    private let endsBy: Int?
    private let area: Int
    private let need: Double
    private let tests: [RuleTest]

    fileprivate init(_ filter: StaffFilter) {
        name = NameTest(filter.name)
        nation = TextTest(filter.nation)
        club = TextTest(filter.club)
        league = TextTest(filter.league)
        region = RegionTest(filter.region)
        squad = filter.squad == "Any" ? nil : filter.squad
        job = filter.jobTest
        ageMin = Net.int32(filter.ageMin)
        ageMax = Net.int32(filter.ageMax)
        personality = filter.personality == "Any" || filter.personality.isEmpty ? nil : filter.personality

        maxWage = FilterText.decimal(filter.wageMax).map { Units.toWeeklyPounds($0 * 1_000.0) }
        endsBy = Net.int32(filter.contractEndsBy)
        area = filter.rankArea
        need = filter.minStars == "Any" ? 0.0 : Net.double(filter.minStars) ?? 0.0
        tests = filter.ruleTests(attributes: Names.staffIndex)
    }

    public func matches(_ staff: Staff) -> Bool {
        if name.isActive, !name.matches(staff.searchText) { return false }
        guard nation.matches(staff.nation), club.matches(staff.club) || club.matches(staff.clubFull),
              league.matches(staff.league) else { return false }
        if !region.matches(staff) { return false }
        if let squad, staff.squad != squad { return false }

        switch job {
        case .any: break
        case .coaching: if !StaffFilter.isCoaching(staff.job) { return false }
        case .exactly(let wanted): if staff.job != wanted { return false }
        }

        if let ageMin, staff.age < ageMin { return false }
        if let ageMax, staff.age < 0 || staff.age > ageMax { return false }

        if let personality, staff.personality != personality { return false }
        if let maxWage, Double(staff.wage) > maxWage { return false }

        if let endsBy {
            guard let end = staff.contractEnd, Net.year(end) <= endsBy else { return false }
        }

        if area >= 0, need > 0 {
            guard let stars = Columns.starText(staff, area), stars >= need else { return false }
        }

        for test in tests {
            let read = test.isPersonality ? Int(staff.pers[test.index]) : Int(staff.attr[test.index])
            if !test.passes(read) { return false }
        }
        return true
    }

    /// Everyone who matches, in the order given. Runs in parallel.
    public func filter(_ staff: [Staff]) -> [Staff] {
        // `searchText` is lazy and its first read isn't thread-safe.
        if name.isActive { staff.forEach { _ = $0.searchText } }
        return parallelFilter(staff, matches)
    }
}
