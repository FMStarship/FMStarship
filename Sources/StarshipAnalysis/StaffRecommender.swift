import Foundation
import StarshipCore

public struct StaffSearchOptions {
    public var role: StaffRole
    /// The "For your" level, used by club-wide roles; a level tab overrides it.
    public var level: Int
    /// Index into `StaffRecommender.areaChoices`; 0 is "Best three areas". Only coaches use it.
    public var area: Int
    /// The boxes as typed: thousands in the shown wage period, and an age.
    public var maxWage: String
    public var maxAge: String
    /// Index into `StaffRecommender.keenChoices`.
    public var keen: Int
    public var onlyJoin: Bool

    public init(role: StaffRole = StaffRoles.all[0], level: Int = 0, area: Int = 0, maxWage: String = "", maxAge: String = "",
                keen: Int = 0, onlyJoin: Bool = true) {
        self.role = role
        self.level = level
        self.area = area
        self.maxWage = maxWage
        self.maxAge = maxAge
        self.keen = keen
        self.onlyJoin = onlyJoin
    }
}

/// The best people for one backroom job: `RecommendStaffForm`.
public struct StaffRecommender {
    public static let levelLabel = "For your"
    public static let areaLabel = "Area"
    public static let maxWageLabel = "Wage up to"
    public static let maxAgeLabel = "Age up to"
    public static let keenLabel = "Wants the job"
    public static let reviewButton = "Review my staff"
    public static let saveButton = "Save as FM shortlist"
    public static let keenChoices = ["Open to it (10+)", "Keen (15+)", "Favourite job", "Anyone"]
    public static let areaChoices = ["Best three areas"] + StaffRoles.outfield.map { Names.areasLong[$0] }

    private static let wanted = 25
    private static let unfiltered = 50
    private static let batchSize = 48
    private static let boardJobs: Set<String> = ["Chairperson", "Owner", "Director", "Managing Director", "President"]

    private let session: AnalysisSession
    public let limits: StaffLimits?
    public let levelNames: [String]

    public init(session: AnalysisSession) {
        self.session = session
        limits = StaffLimits.read(team: session.club.team)
        levelNames = StaffRoles.levelNames(limits)
    }

    public var title: String { "Recommended staff for \(session.club.name) - FM Starship" }
    public func shortlistName(_ role: StaffRole) -> String { "Staff - " + role.name }
    public var maxWagePlaceholder: String {
        let units = session.display.units
        return "\(units.symbol)K \(units.wageSuffix)"
    }

    /// The max-wage box starts at the wage room.
    public var startingMaxWage: String {
        guard let room = session.budget?.wageRoom, room > 0 else { return "" }
        let units = session.display.units
        return NetFormat.fixed(units.wageValue(room) * units.perPound / 1000, min: 0, max: 1)
    }

    public var keenEnabled: Bool { GameRules.engine != nil }
    public var onlyJoinEnabled: Bool { session.checks.canCheckStaffInterest }
    public var onlyJoinTitle: String {
        onlyJoinEnabled ? "Only staff who'd join" : "Only staff who'd join (needs you as the club's manager)"
    }

    /// One tab per role, leaving out team levels the club doesn't have.
    public var tabs: [(title: String, role: StaffRole)] {
        StaffRoles.all.compactMap { role in
            if role.level > 0, let limits, limits.teamFor(role.level) < 0 { return nil }
            return (role.level > 0 ? "\(levelNames[role.level]) \(role.name)" : role.name, role)
        }
    }

    /// The area box only shows for coaches.
    public func showsArea(_ role: StaffRole) -> Bool { role.name == "Coach" }

    /// The level box follows a level tab and can only be changed on club-wide roles.
    public func levelEnabled(_ role: StaffRole) -> Bool { role.level < 0 }

    /// `SelectRole`, as used when Review my staff sends someone here to look for a replacement.
    public func select(role: StaffRole, level: Int, in options: StaffSearchOptions) -> StaffSearchOptions {
        var options = options
        options.role = role
        if role.level < 0 { options.level = min(max(level, 0), 2) }
        return options
    }

    private func levelText(_ level: Int) -> String {
        level == 0 ? "first team" : levelNames[level]
    }

    private func free(_ places: Int) -> String {
        places <= 0 ? "no places free - you'd have to let someone go or ask the board for more staff" : "\(places) free"
    }

    private func boardNote(role: StaffRole, level: Int) -> String {
        if role.limitIndex >= 0, let limits {
            let allowed = limits.allowedCount(role.limitIndex), current = limits.currentCount(role.limitIndex)
            let who = allowed == 1 ? role.name.lowercased() : StaffRoles.plural(role.name)
            return " - the board allows \(allowed) \(who), \(current) in post (\(free(allowed - current)))"
        }
        guard role.teamJob >= 0, let limits else { return "" }
        let team = limits.teamFor(level)
        guard let places = limits.count(team: team, job: role.teamJob) else { return "" }
        let your = "your " + levelText(level)
        if !places.shared {
            let who = places.allowed == 1 ? role.name.lowercased() : StaffRoles.plural(role.name)
            return " - the board allows \(places.allowed) \(who) at \(your), \(places.current) in post (\(free(places.allowed - places.current)))"
        }
        let assistants = limits.count(team: team, job: StaffLimits.assistant)?.shared == true ? ", assistant managers" : ""
        return " - coaching places at \(your) (coaches, goalkeeping and fitness coaches\(assistants)): \(places.current) of \(places.allowed) filled (\(free(places.allowed - places.current)))"
    }

    private func keyAttributes(_ x: Staff, role: StaffRole) -> String {
        func v(_ name: String) -> Int { x.a(name) }
        let jpa = "JPA \(v("Judging Player Ability"))", jpp = "JPP \(v("Judging Player Potential"))"
        switch role.name {
        case "Coach":
            return StaffRoles.outfield.map { ($0, StaffRoles.star(x, $0)) }
                .stableSorted { $0.1 > $1.1 }.prefix(3)
                .map { "\(Names.areas[$0.0]) \(NetFormat.fixed($0.1, min: 1, max: 1))★" }
                .joined(separator: ", ")
        case "Set Piece Coach":
            let stars = NetFormat.fixed(StaffRoles.star(x, 8), min: 1, max: 1)
            return "Set Pieces \(stars)★, Discipline \(v("Level Of Discipline")), Motivating \(v("Motivating"))"
        case "Director of Football":
            return "\(jpa), \(jpp), Neg \(v("Negotiating")), JSA \(v("Judging Staff Ability"))"
        case "Technical Director":
            return "JSA \(v("Judging Staff Ability")), \(jpa), \(jpp)"
        case "Loan Manager":
            return "Neg \(v("Negotiating")), Man \(v("Man Management")), \(jpa), \(jpp)"
        case "Goalkeeping Coach", "Fitness Coach":
            return "Discipline \(v("Level Of Discipline")), Motivating \(v("Motivating"))"
        case "Manager":
            return "Tac \(v("Tactical Knowledge")), Man \(v("Man Management")), Mot \(v("Motivating")), Youngsters \(v("Working With Youngsters"))"
        case "Assistant Manager":
            return "Tac \(v("Tactical Knowledge")), Man \(v("Man Management")), \(jpa), Mot \(v("Motivating"))"
        case "Physio", "Head Physio":
            return "Physio \(v("Physiotherapy")), Sports Sci \(v("Sports Science"))"
        case "Sports Scientist", "Head of Sports Science":
            return "Sports Sci \(v("Sports Science")), Physio \(v("Physiotherapy"))"
        case "Scout", "Chief Scout", "Recruitment Analyst":
            return "\(jpa), \(jpp), Data \(v("Analysing Data"))"
        case "Performance Analyst", "Head Performance Analyst":
            return "Data \(v("Analysing Data")), Tac \(v("Tactical Knowledge"))"
        default:
            return "Youngsters \(v("Working With Youngsters")), \(jpp)"
        }
    }

    public func columns(for role: StaffRole) -> [TableColumn] {
        [
            TableColumn("Name", 18), TableColumn("Age", 5), TableColumn("Job now", 15), TableColumn("Club", 15),
            TableColumn(role.stars ? "Stars" : "Score", 7), TableColumn("FM stars", 7), TableColumn("Key attributes", 20),
            TableColumn("Wage", 8), TableColumn("Wants job", 12), TableColumn("Prefers", 15), TableColumn("Would join", 12),
            TableColumn("vs your best", 8),
        ]
    }

    /// `head` is the line about the people you already have. Nil when cancelled.
    public func find(_ options: StaffSearchOptions, isCancelled: () -> Bool = { false },
                     status: (String) -> Void = { _ in }) -> AnalysisTable? {
        let role = options.role
        let club = session.club.name
        let checks = session.checks
        let units = session.display.units
        let area = options.area > 0 ? StaffRoles.outfield[options.area - 1] : -1
        let level = role.level >= 0 ? role.level : options.level
        let join = options.onlyJoin && onlyJoinEnabled
        let preference = StaffRoles.preferenceIndex(role.name)

        let mine = session.db.staff.filter {
            $0.clubFull == club && role.jobs.contains($0.job) && (role.level < 0 || $0.squad == levelNames[role.level])
        }
        let best = mine.map { role.score($0, area: area) }.max() ?? 0

        var table = AnalysisTable(columns: columns(for: role))
        let note = boardNote(role: role, level: level)
        if let first = mine.stableSorted(by: { role.score($0, area: area) > role.score($1, area: area) }).first {
            let who = mine.count == 1 ? role.name.lowercased() : StaffRoles.plural(role.name)
            let score = StaffRoles.scoreText(best, stars: role.stars)
            table.head = "You have \(mine.count) \(who)\(note); your best: \(first.name) (\(score)). Ranked by \(role.basis)."
        } else {
            table.head = "You have no \(role.name.lowercased())\(note). Ranked by \(role.basis)."
        }

        status(join ? "Finding staff who'd join you..." : "Finding staff...")
        guard let found = search(options, wanted: StaffRecommender.wanted, isCancelled: isCancelled) else { return nil }
        let shown = found.people
        table.interestChecked = found.interestChecked

        for x in shown {
            let score = role.score(x, area: area)
            let want = preference >= 0 ? checks.wantsJob(x, preference: preference) : nil
            table.rows.append(TableRow(cells: [
                x.name,
                x.age >= 0 ? "\(x.age)" : "",
                x.job.isEmpty ? "Unemployed" : x.job,
                x.club.isEmpty ? "-" : x.club,
                StaffRoles.scoreText(score, stars: role.stars),
                want.map { NetFormat.fixed(Double(Names.fmStars($0, x.ca)) / 2, min: 1, max: 1) + "★" } ?? "",
                keyAttributes(x, role: role),
                x.club.isEmpty ? "to agree" : units.wageText(x.wage),
                want.map { "\($0) - \(Names.keenness($0))" } ?? "",
                checks.preferredJob(x),
                checks.staffText(x),
                mine.isEmpty ? "new" : NetFormat.signedOneDecimal(score - best),
            ], person: x))
        }

        if shown.isEmpty {
            table.status = "Nobody found with these settings - try a higher wage, another team level, 'Anyone' for wanting the job, or untick 'Only staff who'd join'."
        } else {
            let team = role.level > 0 ? levelNames[role.level] + " " : ""
            var who = ""
            if join && found.interestChecked { who = role.level > 0 ? " who'd join you" : " who'd join your \(levelText(level))" }
            table.status = "The best \(shown.count) for \(team)\(role.name.lowercased())\(who), best first. Double-click for the full profile."
        }
        return table
    }

    /// The best people for a job, best first, who pass the options. Nil when cancelled. Only those scoring
    /// `atLeast` or more count, and nobody in `excluding`; `deepest` stops a job nobody wants reading the whole world.
    func search(_ options: StaffSearchOptions, wanted: Int, atLeast: Double? = nil, excluding: Set<UInt32> = [], deepest: Int? = nil,
                isCancelled: () -> Bool = { false }) -> (people: [Staff], interestChecked: Bool)? {
        let role = options.role
        let club = session.club.name
        let checks = session.checks
        let units = session.display.units
        let area = options.area > 0 ? StaffRoles.outfield[options.area - 1] : -1
        let level = role.level >= 0 ? role.level : options.level
        let join = options.onlyJoin && onlyJoinEnabled
        let maxWage = units.wageLimit(options.maxWage)
        let maxAge = parseInvariantInt(options.maxAge)
        let preference = StaffRoles.preferenceIndex(role.name)
        let minWant = keenEnabled && preference >= 0 ? [10, 15, 20, 0][min(max(options.keen, 0), 3)] : 0

        var pool = session.db.staff.filter {
            $0.block != 0 && $0.clubFull != club && !StaffRecommender.boardJobs.contains($0.job) && !excluding.contains($0.uid)
        }
        pool = pool.filter { role.inPool(job: $0.club.isEmpty ? "" : $0.job) }
        if let maxWage { pool = pool.filter { !(Double($0.wage) > maxWage) } }
        if let maxAge { pool = pool.filter { $0.age >= 0 && $0.age <= maxAge } }
        let scored: [(staff: Staff, score: Double)] = pool.map { ($0, role.score($0, area: area)) }
        var ranked = scored.filter { $0.score > 0 && $0.score >= atLeast ?? 0 }
            .stableSorted { a, b in a.score != b.score ? a.score > b.score : a.staff.ca > b.staff.ca }
            .map(\.staff)
        if let deepest { ranked = Array(ranked.prefix(deepest)) }
        // Lazy: asking the game how keen someone is costs real time, and only the top of the list gets read.
        let keen = ranked.lazy.filter { person in
            guard minWant > 0, let want = checks.wantsJob(person, preference: preference) else { return true }
            return want >= minWant
        }

        guard join else { return (Array(keen.prefix(max(wanted, StaffRecommender.unfiltered))), !options.onlyJoin || onlyJoinEnabled) }
        var shown: [Staff] = []
        for batch in keen.chunked(StaffRecommender.batchSize) {
            if isCancelled() { return nil }
            guard checks.checkStaff(batch: batch, isCancelled: isCancelled) else {
                return (Array(keen.prefix(StaffRecommender.unfiltered)), false)
            }
            for person in batch {
                if let answer = checks.staffKnown(person), answer.wouldJoin(level: level) {
                    shown.append(person)
                    if shown.count >= wanted { return (shown, true) }
                }
            }
        }
        return isCancelled() ? nil : (shown, true)
    }

    /// The options Recommended staff opens with, so an overview's pick is that screen's top row.
    func startingOptions(role: StaffRole, level: Int, area: Int = -1) -> StaffSearchOptions {
        let areaIndex = StaffRoles.outfield.firstIndex(of: area).map { $0 + 1 } ?? 0
        return StaffSearchOptions(role: role, level: level, area: areaIndex, maxWage: startingMaxWage)
    }
}
