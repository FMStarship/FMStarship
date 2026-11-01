import Foundation
import StarshipCore

/// The backroom at a glance: every place the board allows, who fills it, and who'd do it better.
public final class StaffOverview: OverviewReport {
    public struct TrainingArea: Identifiable {
        public let id: Int
        public let name: String
        public let stars: Double
        public let coach: String
        public let rank: String
        public let standing: Standing

        public var starsText: String { stars > 0 ? StaffRoles.scoreText(stars, stars: true) : "-" }
    }

    public struct Places: Identifiable {
        public let name: String
        public let filled: Int
        public let allowed: Int
        public var id: String { name }
    }

    private struct Search {
        let role: StaffRole
        let level: Int
        let area: Int
        /// The rating someone has to clearly beat. Nil on an empty place.
        let beat: Double?
    }

    public static let groupNames = ["Leadership", "Coaching", "Medical", "Recruitment", "Analysis", "Youth and reserves"]
    /// Clearly better: half a star, or a point on FM's 1-20 scale.
    private static let starMargin = 0.5, scoreMargin = 1.0
    /// How far down a job's ranking to go before calling it: past this nobody's worth the wait.
    private static let deepest = 480
    private static let coachingStaff: Set<String> = ["Coach", "Assistant Manager", "Goalkeeping Coach", "Fitness Coach", "Set Piece Coach"]
    private static let setPieces = 8
    /// The areas that have no job of their own: goalkeeping, fitness and set pieces do.
    private static let generalAreas = 0..<6

    public let headline: String
    public let rows: [OverviewRow]
    public let areas: [TrainingArea]
    public let places: [Places]
    /// One coach carrying the training, when that's so.
    public let coachNote: String?
    public let footnote: String
    public let emptyPlaces: Int
    public var groups: [String] { Self.groupNames }
    public var placeTitle: String { "Job" }
    public var nowTitle: String { "In post" }
    public var exportTitle: String { "Staff overview" }

    private let session: AnalysisSession
    private let recommender: StaffRecommender
    private var searches: [String: Search] = [:]

    private static func group(_ entry: StaffReview.Entry) -> String {
        if entry.level > 0 { return "Youth and reserves" }
        switch entry.role.name {
        case "Director of Football", "Technical Director", "Assistant Manager": return "Leadership"
        case "Coach", "Goalkeeping Coach", "Fitness Coach", "Set Piece Coach": return "Coaching"
        case "Head Physio", "Physio", "Head of Sports Science", "Sports Scientist": return "Medical"
        case "Chief Scout", "Scout", "Recruitment Analyst", "Loan Manager": return "Recruitment"
        case "Head Performance Analyst", "Performance Analyst": return "Analysis"
        default: return "Youth and reserves"
        }
    }

    /// What a coach counts for in an area. A set piece coach only takes set pieces.
    private static func rating(_ staff: Staff, _ area: Int) -> Double {
        staff.job == "Set Piece Coach" && area != setPieces ? 0 : StaffRoles.star(staff, area)
    }

    public init(session: AnalysisSession) {
        self.session = session
        let recommender = StaffRecommender(session: session)
        self.recommender = recommender
        let review = StaffReview(session: session, limits: recommender.limits, levelNames: recommender.levelNames)
        let today = session.today
        let soon = GameDate.calendar.date(byAdding: .month, value: 6, to: today) ?? today
        let units = session.display.units
        var rows: [OverviewRow] = []
        var searches: [String: Search] = [:]

        for entry in review.entries {
            let role = entry.role
            let level = entry.level
            let job = entry.staff == nil ? entry.row.cells[1] : role.name
            let place = level > 0 ? "\(recommender.levelNames[level]) \(job)" : job
            let lookup = OverviewRow.Lookup.staff(role: role, level: level, area: -1)
            if let staff = entry.staff, let score = entry.score {
                let id = "\(role.id)|\(level)|\(staff.uid)"
                let end = staff.contractEnd
                let leaving = end.flatMap { $0 <= soon ? "Contract ends \(NetFormat.monthYear($0))" : nil }
                let detail = [staff.age >= 0 ? "Age \(staff.age)" : "", entry.rank, units.wageText(staff.wage, suffix: true)]
                rows.append(OverviewRow(id: id, group: Self.group(entry), place: place, person: staff, name: staff.name,
                                        score: StaffRoles.scoreText(score, stars: role.stars), detail: detail.filter { !$0.isEmpty }.joined(separator: " · "),
                                        warning: leaving, standing: entry.standing, lookup: lookup, searches: entry.standing != .strong || leaving != nil))
                searches[id] = Search(role: role, level: level, area: -1, beat: score)
            } else {
                let id = "\(role.id)|\(level)|free|\(job)"
                rows.append(OverviewRow(id: id, group: Self.group(entry), place: place, person: nil,
                                        name: entry.places == 1 ? "Nobody in post" : "\(entry.places) places free", score: "",
                                        detail: "The board allows it", warning: nil, standing: .missing, lookup: lookup, searches: true))
                searches[id] = Search(role: role, level: level, area: -1, beat: nil)
            }
        }

        // MARK: Training cover

        let db = session.db
        let club = session.club.name
        func trains(_ staff: Staff) -> Bool { Self.coachingStaff.contains(staff.job) && StaffReview.levelOf(staff.squad) == 0 }
        let mine = db.staff.filter { $0.clubFull == club && trains($0) }
        let rivals = Dictionary(grouping: db.staff.filter {
            !review.league.isEmpty && $0.league == review.league && $0.clubNation == review.nation && $0.clubFull != club && trains($0)
        }, by: \.clubFull).values

        var areas: [TrainingArea] = []
        var bestIn: [UInt32: Int] = [:]
        for (index, name) in Names.areasLong.enumerated() {
            let best = mine.max { Self.rating($0, index) < Self.rating($1, index) }
            let stars = best.map { Self.rating($0, index) } ?? 0
            if stars > 0, let best { bestIn[best.uid, default: 0] += 1 }
            let others = rivals.map { $0.map { Self.rating($0, index) }.max() ?? 0 }.sorted()
            let standing: Standing = stars > 0 ? .of(stars, against: others) : .missing
            let rank = others.isEmpty ? "" : "\(StaffReview.ordinal(others.filter { $0 > stars }.count + 1)) of \(others.count + 1)"
            areas.append(TrainingArea(id: index, name: name, stars: stars, coach: stars > 0 ? best?.name ?? "" : "", rank: rank, standing: standing))

            guard Self.generalAreas.contains(index), standing < .good, let coach = StaffRoles.base.first(where: { $0.name == "Coach" }) else { continue }
            let id = "area|\(index)"
            rows.append(OverviewRow(id: id, group: "Coaching", place: name, person: best, name: stars > 0 ? best?.name ?? "" : "No coach for this",
                                    score: stars > 0 ? StaffRoles.scoreText(stars, stars: true) : "",
                                    detail: stars > 0 ? "Your best here · \(rank)" : "Nobody at the club rates here", warning: nil, standing: standing,
                                    lookup: .staff(role: coach, level: 0, area: index), searches: true))
            searches[id] = Search(role: coach, level: 0, area: index, beat: stars > 0 ? stars : nil)
        }
        self.areas = areas
        self.searches = searches
        self.rows = rows.enumerated().sorted { a, b in
            a.element.standing != b.element.standing ? a.element.standing < b.element.standing : a.offset < b.offset
        }.map(\.element)

        coachNote = bestIn.max { $0.value < $1.value }.flatMap { uid, count in
            guard count >= 3, let coach = mine.first(where: { $0.uid == uid }) else { return nil }
            return "\(coach.name) is your best coach in \(count) of \(Names.areasLong.count) areas. A coach's stars fall when they take on more than one."
        }

        // MARK: Places

        var places: [Places] = []
        if let limits = recommender.limits {
            for role in StaffRoles.base where role.limitIndex >= 0 && limits.allowedCount(role.limitIndex) > 1 {
                let name = StaffRoles.plural(role.name)
                places.append(Places(name: name.prefix(1).uppercased() + name.dropFirst(), filled: limits.currentCount(role.limitIndex),
                                     allowed: limits.allowedCount(role.limitIndex)))
            }
            for level in 0..<3 {
                let team = limits.teamFor(level)
                guard team >= 0 else { continue }
                let label = recommender.levelNames[level]
                for (name, job) in [("coaches", StaffLimits.coach), ("physios", StaffLimits.physio),
                                    ("sports scientists", StaffLimits.sportsScience), ("analysts", StaffLimits.analyst)] {
                    guard let count = limits.count(team: team, job: job), count.allowed > 0 else { continue }
                    places.append(Places(name: "\(label) \(name)", filled: count.current, allowed: count.allowed))
                }
            }
        }
        self.places = places

        // MARK: Words

        let free = review.entries.filter { $0.staff == nil }.reduce(0) { $0 + $1.places }
        emptyPlaces = free
        let weak = review.entries.filter { $0.staff != nil && $0.standing < .unknown }.count
        var headline = free == 0 ? "Every place is filled" : free == 1 ? "1 place is empty" : "\(free) places are empty"
        headline += weak == 0 ? ", and nobody is below the league standard." : weak == 1 ? ", and 1 person is below the league standard."
                                                                                         : ", and \(weak) people are below the league standard."
        if let room = session.budget?.wageRoom { headline += " Wage room: \(units.wageText(room, suffix: true))." }
        self.headline = headline
        let against = review.league.isEmpty ? "rival clubs" : "the other \(review.league) clubs"
        footnote = "Ranked against \(against) with Recommended staff's ratings: coaches in FM's stars out of 5, everyone else out of 20 on what the job needs. Who'd join comes from the game: people open to the job, within your wage room."
    }

    public func search(_ row: OverviewRow, taken: inout Set<UInt32>, isCancelled: () -> Bool) -> OverviewResult? {
        guard let search = searches[row.id] else { return .nobody("") }
        guard session.checks.canCheckStaffInterest else { return .nobody("Needs you as the club's manager") }
        let role = search.role
        let margin = role.stars ? Self.starMargin : Self.scoreMargin
        let options = recommender.startingOptions(role: role, level: search.level, area: search.area)
        guard let found = recommender.search(options, wanted: 1, atLeast: search.beat.map { $0 + margin }, excluding: taken,
                                             deepest: Self.deepest, isCancelled: isCancelled) else { return nil }
        guard found.interestChecked else { return .nobody("The game couldn't say who'd join") }
        guard let person = found.people.first else {
            return .nobody(search.beat == nil ? "Nobody would join within your wage room" : "Nobody clearly better would join")
        }
        taken.insert(person.uid)
        let score = role.score(person, area: search.area)
        let units = session.display.units
        let details = [person.club.isEmpty ? "Out of work" : person.club, person.age >= 0 ? "Age \(person.age)" : "",
                       person.club.isEmpty ? "Wage to agree" : units.wageText(person.wage, suffix: true), person.club.isEmpty ? "" : person.job]
        let suffix = role.stars ? "★" : ""
        return .hire(OverviewHire(person: person, name: person.name, score: StaffRoles.scoreText(score, stars: role.stars),
                                  gain: search.beat.map { NetFormat.signedOneDecimal(score - $0) + suffix } ?? "New",
                                  detail: details.filter { !$0.isEmpty }.joined(separator: " · ")))
    }
}
