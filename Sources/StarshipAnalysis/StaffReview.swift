import Foundation
import StarshipCore

/// Every member of the backroom staff against the people doing the same job at rival clubs,
/// plus the places the board allows but nobody fills: `StaffReviewForm`.
public struct StaffReview {
    public static let columns = [
        TableColumn("Name", 16), TableColumn("Job", 15), TableColumn("Team", 8), TableColumn("Age", 5),
        TableColumn("Rating", 7), TableColumn("In the league", 17), TableColumn("League avg", 8), TableColumn("Verdict", 18),
        TableColumn("Contract ends", 9), TableColumn("Wage", 8),
    ]

    private static let reserve: Set<String> = ["Reserves", "B team", "U23", "U21", "II", "2nd team", "III", "U20"]
    private static let youth: Set<String> = ["U19", "U18", "Youths", "U19 B"]

    public struct Entry {
        public let row: TableRow
        /// What double-clicking looks for in Recommended staff. `staff` is nil on an empty place.
        public let role: StaffRole
        public let level: Int
        public let staff: Staff?
        public let standing: Standing
        /// The job's rating, nil on an empty place.
        public let score: Double?
        /// "2nd of 14", empty with nobody to compare with.
        public let rank: String
        /// How many places an empty row stands for.
        public let places: Int
        fileprivate let verdict: Int
    }

    public let title: String
    public let entries: [Entry]
    public let table: AnalysisTable
    public let league: String
    public let nation: String

    static func levelOf(_ squad: String) -> Int {
        reserve.contains(squad) ? 1 : youth.contains(squad) ? 2 : 0
    }

    static func ordinal(_ value: Int) -> String {
        let suffix: String
        if (11...13).contains(value % 100) {
            suffix = "th"
        } else {
            switch value % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(value)\(suffix)"
    }

    private static func role(named name: String, level: Int) -> StaffRole? {
        StaffRoles.all.first { $0.name == name && $0.level == level } ?? StaffRoles.all.first { $0.name == name && $0.level < 0 }
    }

    public init(session: AnalysisSession, limits: StaffLimits?, levelNames: [String]?) {
        let club = session.club.name
        let db = session.db
        let units = session.display.units
        let mine = db.staff.filter { $0.clubFull == club }
        let league = (mine.map(\.league) + db.players.filter { $0.clubFull == club }.map(\.league)).first { !$0.isEmpty } ?? ""
        let nation = mine.map(\.clubNation).first { !$0.isEmpty } ?? ""
        let inLeague: (Staff) -> Bool = { !league.isEmpty && $0.league == league && $0.clubNation == nation }
        let clubsInLeague = Set(db.staff.filter(inLeague).map(\.clubFull)).count

        func ratings(_ role: StaffRole, level: Int, sameLevel: Bool, where wanted: (Staff) -> Bool) -> [Double] {
            db.staff.filter {
                $0.clubFull != club && role.jobs.contains($0.job) && (!sameLevel || StaffReview.levelOf($0.squad) == level) && wanted($0)
            }.map { role.score($0) }.filter { $0 > 0 }
        }

        var peerCache: [String: (ratings: [Double], label: String)] = [:]
        func peers(_ role: StaffRole, level: Int) -> (ratings: [Double], label: String) {
            let key = "\(role.id)|\(level)"
            if let cached = peerCache[key] { return cached }
            let levelName = level > 0 ? levelNames.map { $0[level] + " " } ?? "" : ""
            var found: (ratings: [Double], label: String)
            let sameLevel = ratings(role, level: level, sameLevel: true, where: inLeague)
            if sameLevel.count >= 6 {
                found = (sameLevel, league + " " + levelName)
            } else {
                let anyLevel = ratings(role, level: level, sameLevel: false, where: inLeague)
                if anyLevel.count >= 6 {
                    found = (anyLevel, league + " ")
                } else {
                    found = (ratings(role, level: level, sameLevel: false, where: { $0.clubNation == nation }), nation + " ")
                }
            }
            found.ratings.sort()
            peerCache[key] = found
            return found
        }

        var entries: [Entry] = []
        var notGoodEnough = 0
        var belowStandard = 0
        for x in mine {
            let level = StaffReview.levelOf(x.squad)
            let found = StaffRoles.all.first { $0.level > 0 && $0.level == level && $0.jobs.contains(x.job) }
                ?? StaffRoles.all.first { $0.level < 0 && $0.jobs.contains(x.job) }
            guard let role = found else { continue }
            let value = role.score(x)
            let (others, label) = peers(role, level: level)
            var place = ""
            var rank = ""
            var average = ""
            var verdict = "No one to compare with"
            var tone = Tone.muted
            var order = 5
            let standing = Standing.of(value, against: others)
            if !others.isEmpty {
                let ahead = others.filter { $0 > value }.count
                rank = "\(StaffReview.ordinal(ahead + 1)) of \(others.count + 1)"
                place = "\(rank) \(label)\(StaffRoles.plural(role.name))"
                average = StaffRoles.scoreText(others[others.count / 2], stars: role.stars)
                switch standing {
                case .strong: (verdict, tone, order) = ("One of the best in the league", .good, 4)
                case .good: (verdict, tone, order) = ("Good enough", .text, 3)
                case .below:
                    (verdict, tone, order) = ("Below the league standard", .fair, 1)
                    belowStandard += 1
                case .unknown: break
                default:
                    (verdict, tone, order) = ("Not good enough for your club", .bad, 0)
                    notGoodEnough += 1
                }
            }
            let row = TableRow(cells: [
                x.name, x.job, x.squad, x.age >= 0 ? "\(x.age)" : "", StaffRoles.scoreText(value, stars: role.stars), place, average,
                verdict, x.contractEnd.map(NetFormat.monthYear) ?? "", units.wageText(x.wage),
            ], person: x, tone: tone, toneColumn: 7)
            entries.append(Entry(row: row, role: role, level: max(0, level), staff: x, standing: standing, score: value, rank: rank, places: 0, verdict: order))
        }

        var freePlaces = 0
        func place(_ label: String, level: Int, count: Int, role: StaffRole?) {
            guard count > 0, let role else { return }
            freePlaces += count
            let team = levelNames.flatMap { level < $0.count ? $0[level] : nil } ?? ""
            let row = TableRow(cells: [
                count == 1 ? "(empty place)" : "(\(count) empty places)", label, team, "", "", "", "",
                "Place free - the board allows it", "", "",
            ], tone: .star, toneColumn: 7)
            entries.append(Entry(row: row, role: role, level: level, staff: nil, standing: .missing, score: nil, rank: "", places: count, verdict: 2))
        }

        if let limits {
            for role in StaffRoles.base where role.limitIndex >= 0 {
                place(role.name, level: 0, count: limits.allowedCount(role.limitIndex) - limits.currentCount(role.limitIndex), role: role)
            }
            for level in 0..<3 {
                let team = limits.teamFor(level)
                guard team >= 0 else { continue }
                func free(_ job: Int) -> Int {
                    guard let places = limits.count(team: team, job: job) else { return 0 }
                    return places.allowed - places.current
                }
                let shared = limits.count(team: team, job: StaffLimits.assistant)?.shared ?? false
                place(shared ? "Coach / GK / fitness / assistant" : "Coach / GK / fitness coach", level: level,
                      count: free(StaffLimits.coach), role: StaffReview.role(named: "Coach", level: level))
                if !shared {
                    place("Assistant Manager", level: level, count: free(StaffLimits.assistant),
                          role: StaffReview.role(named: "Assistant Manager", level: level))
                }
                if level > 0 {
                    place("Manager", level: level, count: free(StaffLimits.manager), role: StaffReview.role(named: "Manager", level: level))
                }
                place("Performance Analyst", level: level, count: free(StaffLimits.analyst),
                      role: StaffReview.role(named: "Performance Analyst", level: level))
                place("Physio", level: level, count: free(StaffLimits.physio), role: StaffReview.role(named: "Physio", level: -1))
                place("Sports Scientist", level: level, count: free(StaffLimits.sportsScience),
                      role: StaffReview.role(named: "Sports Scientist", level: -1))
            }
        }

        let roleOrder = Dictionary(uniqueKeysWithValues: StaffRoles.all.enumerated().map { ($1.id, $0) })
        self.entries = entries.stableSorted { a, b in
            if a.verdict != b.verdict { return a.verdict < b.verdict }
            return (roleOrder[a.role.id] ?? -1) < (roleOrder[b.role.id] ?? -1)
        }

        var head = "Your backroom staff, each compared with the people doing the same job at the other "
        head += league.isEmpty ? "clubs" : "\(league) clubs"
        if clubsInLeague > 1 { head += " (\(clubsInLeague - 1))" }
        head += ", using Recommended staff's rating for the job.\n"
        head += notGoodEnough != 0
            ? "\(notGoodEnough) \(notGoodEnough == 1 ? "isn't" : "aren't") good enough for your club"
            : "Everyone is good enough for your club"
        head += belowStandard != 0
            ? ", \(belowStandard) \(belowStandard == 1 ? "is" : "are") below the league standard"
            : ", no one is below the league standard"
        head += ", and \(freePlaces) \(freePlaces == 1 ? "place is" : "places are") free."

        self.league = league
        self.nation = nation
        title = "Staff review for \(club) - FM Starship"
        table = AnalysisTable(columns: StaffReview.columns, rows: self.entries.map(\.row), head: head,
                              status: "Coaches are rated in FM's stars out of 5, everyone else out of 20 on what the job needs. Double-click anyone (or an empty place) to look for a replacement in Recommended staff.")
    }
}
