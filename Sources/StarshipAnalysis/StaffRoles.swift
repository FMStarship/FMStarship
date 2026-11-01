import Foundation
import StarshipCore

/// A backroom job and how to rate someone for it: `RecommendStaffForm.Role`.
public struct StaffRole: Identifiable, Hashable {
    public let name: String
    public let jobs: [String]
    /// True when the score is a star rating.
    public let stars: Bool
    /// Index into `StaffLimits.allowed`, or -1.
    public let limitIndex: Int
    /// What the ranking is based on, in words.
    public let basis: String
    /// Job index for `StaffLimits.count`, or -1.
    public let teamJob: Int
    /// -1 for a club-wide job, otherwise the team level this tab is for.
    public let level: Int

    private let rate: (Staff, Int) -> Double
    private let inPool: (String) -> Bool

    fileprivate init(_ name: String, stars: Bool = false, limitIndex: Int = -1, basis: String, teamJob: Int = -1, level: Int = -1,
                     pool: @escaping (String) -> Bool, score: @escaping (Staff, Int) -> Double) {
        self.name = name
        jobs = [name]
        self.stars = stars
        self.limitIndex = limitIndex
        self.basis = basis
        self.teamJob = teamJob
        self.level = level
        inPool = pool
        rate = score
    }

    public var id: String { "\(name)|\(level)" }

    public static func == (a: StaffRole, b: StaffRole) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// `area` is a training area, or -1 for a coach's best three.
    public func score(_ staff: Staff, area: Int = -1) -> Double { rate(staff, area) }

    /// Whether someone in `job` is worth considering. Someone out of work has job "".
    public func inPool(job: String) -> Bool { inPool(job) }

    fileprivate func at(level: Int) -> StaffRole {
        StaffRole(name, stars: stars, limitIndex: limitIndex, basis: basis, teamJob: teamJob, level: level, pool: inPool, score: rate)
    }
}

public enum StaffRoles {
    /// The training areas an outfield coach takes.
    public static let outfield = [0, 1, 2, 3, 4, 5, 8]

    private static func a(_ staff: Staff, _ name: String) -> Double { Double(staff.a(name)) }

    /// `Columns.StarText` as a number: goalkeeping and fitness coaches only rate in their own area.
    public static func star(_ staff: Staff, _ area: Int) -> Double {
        starText(staff, area) ?? 0
    }

    static func starText(_ staff: Staff, _ area: Int) -> Double? {
        if staff.job == "Goalkeeping Coach", area != 6 { return nil }
        if staff.job == "Fitness Coach", area != 7 { return nil }
        return staff.stars[area]
    }

    private static func coaching(_ job: String) -> Bool {
        job.isEmpty || job.contains("Coach") || job.contains("Head of Youth")
            || (job.contains("Manager") && !job.contains("Managing") && !job.contains("Loan"))
    }

    private static func medical(_ job: String) -> Bool {
        job.isEmpty || job.contains("Physio") || job.contains("Sports Scien") || job.contains("Doctor")
    }

    private static func recruiting(_ job: String) -> Bool {
        job.isEmpty || job.contains("Scout") || job.contains("Recruitment") || job.contains("Director of Football")
            || job.contains("Technical Director") || job.contains("Loan Manager")
    }

    private static func analysis(_ job: String) -> Bool {
        job.isEmpty || job.contains("Analyst")
    }

    private static func manager(level: Int) -> StaffRole {
        StaffRole("Manager", basis: "tactics, man management, motivating, working with youngsters", teamJob: 0, level: level, pool: coaching) { s, _ in
            (a(s, "Tactical Knowledge") + a(s, "Man Management") + a(s, "Motivating") + a(s, "Working With Youngsters")) / 4
        }
    }

    public static let base: [StaffRole] = [
        StaffRole("Director of Football", limitIndex: StaffLimits.Club.directorOfFootball, basis: "judging ability and potential, negotiating, judging staff", pool: recruiting) { s, _ in
            (a(s, "Judging Player Ability") + a(s, "Judging Player Potential") + a(s, "Negotiating") + a(s, "Judging Staff Ability")) / 4
        },
        StaffRole("Technical Director", limitIndex: StaffLimits.Club.technicalDirector, basis: "judging staff, judging ability and potential", pool: recruiting) { s, _ in
            (a(s, "Judging Staff Ability") * 2 + a(s, "Judging Player Ability") + a(s, "Judging Player Potential")) / 4
        },
        StaffRole("Head of Youth Development", limitIndex: StaffLimits.Club.headOfYouth, basis: "working with youngsters, judging potential", pool: coaching) { s, _ in
            (a(s, "Working With Youngsters") * 2 + a(s, "Judging Player Potential")) / 3
        },
        StaffRole("Assistant Manager", basis: "tactics, man management, judging ability, motivating", teamJob: 1, pool: coaching) { s, _ in
            (a(s, "Tactical Knowledge") + a(s, "Man Management") + a(s, "Judging Player Ability") + a(s, "Motivating")) / 4
        },
        StaffRole("Coach", stars: true, basis: "training stars", teamJob: 2, pool: coaching) { s, area in
            if area >= 0 { return star(s, area) }
            let best = outfield.map { star(s, $0) }.sorted(by: >).prefix(3)
            return best.reduce(0, +) / Double(best.count)
        },
        StaffRole("Goalkeeping Coach", stars: true, basis: "goalkeeping stars", teamJob: 3, pool: coaching) { s, _ in star(s, 6) },
        StaffRole("Fitness Coach", stars: true, basis: "fitness stars", teamJob: 4, pool: coaching) { s, _ in star(s, 7) },
        StaffRole("Head Physio", limitIndex: StaffLimits.Club.headPhysio, basis: "physiotherapy", pool: medical) { s, _ in a(s, "Physiotherapy") },
        StaffRole("Physio", basis: "physiotherapy", teamJob: 6, pool: medical) { s, _ in a(s, "Physiotherapy") },
        StaffRole("Chief Scout", limitIndex: StaffLimits.Club.chiefScout, basis: "judging ability and potential", pool: recruiting) { s, _ in
            (a(s, "Judging Player Ability") + a(s, "Judging Player Potential")) / 2
        },
        StaffRole("Scout", limitIndex: StaffLimits.Club.scouts, basis: "judging ability and potential", pool: recruiting) { s, _ in
            (a(s, "Judging Player Ability") + a(s, "Judging Player Potential")) / 2
        },
        StaffRole("Head of Sports Science", limitIndex: StaffLimits.Club.headOfSportsScience, basis: "sports science", pool: medical) { s, _ in a(s, "Sports Science") },
        StaffRole("Sports Scientist", basis: "sports science", teamJob: 7, pool: medical) { s, _ in a(s, "Sports Science") },
        StaffRole("Recruitment Analyst", limitIndex: StaffLimits.Club.recruitmentAnalysts, basis: "judging ability and potential, analysing data", pool: recruiting) { s, _ in
            (a(s, "Judging Player Ability") + a(s, "Judging Player Potential") + a(s, "Analysing Data")) / 3
        },
        StaffRole("Loan Manager", limitIndex: StaffLimits.Club.loanManager, basis: "negotiating, man management, judging ability and potential", pool: recruiting) { s, _ in
            (a(s, "Negotiating") + a(s, "Man Management") + a(s, "Judging Player Ability") + a(s, "Judging Player Potential")) / 4
        },
        StaffRole("Head Performance Analyst", limitIndex: StaffLimits.Club.headPerformanceAnalyst, basis: "analysing data, tactical knowledge", pool: analysis) { s, _ in
            (a(s, "Analysing Data") * 2 + a(s, "Tactical Knowledge")) / 3
        },
        StaffRole("Performance Analyst", basis: "analysing data, tactical knowledge", teamJob: 5, pool: analysis) { s, _ in
            (a(s, "Analysing Data") * 2 + a(s, "Tactical Knowledge")) / 3
        },
        StaffRole("Set Piece Coach", stars: true, limitIndex: StaffLimits.Club.setPieceCoach, basis: "set piece stars", pool: coaching) { s, _ in star(s, 8) },
    ]

    private static func baseRole(_ name: String) -> StaffRole {
        base.first { $0.name == name }!
    }

    /// The club-wide roles, then the jobs that repeat at reserve and youth teams.
    public static let all: [StaffRole] = base + [1, 2].flatMap { level in
        [manager(level: level), baseRole("Assistant Manager").at(level: level),
         baseRole("Coach").at(level: level), baseRole("Performance Analyst").at(level: level)]
    }

    public static func levelNames(_ limits: StaffLimits?) -> [String] {
        func name(_ level: Int, _ fallback: String) -> String {
            guard let limits else { return fallback }
            let team = limits.teamFor(level)
            return team < 0 ? fallback : Names.squadName(limits.teams[team].type)
        }
        return [name(0, "First team"), name(1, "Reserves"), name(2, "Youth team")]
    }

    /// `Names.PrefIndex`: where a job sits in a staff member's job preferences, or -1.
    public static func preferenceIndex(_ job: String) -> Int {
        switch job {
        case "Recruitment Analyst", "Head Performance Analyst": return 12
        case "Chief Scout": return 4
        case "Head Physio": return 3
        case "Head of Sports Science": return 13
        default:
            let key = Names.jobs.first { $0.value == job }?.key ?? 0
            return Names.prefJobs.firstIndex(of: key) ?? -1
        }
    }

    public static func plural(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.hasPrefix("head of ") { return "heads" + lower.dropFirst(4) }
        if lower == "director of football" { return "directors of football" }
        return lower.hasSuffix("coach") ? lower + "es" : lower + "s"
    }

    static func scoreText(_ value: Double, stars: Bool) -> String {
        NetFormat.fixed(value, min: 1, max: 1) + (stars ? "★" : "")
    }
}
