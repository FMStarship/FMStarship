import Foundation
import StarshipCore

/// The "My club" window: health check, set pieces, loan out, development and training.
public final class ClubReport {
    public enum Tab: Int, CaseIterable {
        case health, setPieces, loans, development, talent, training

        public var title: String {
            switch self {
            case .health: return "Health check"
            case .setPieces: return "Set pieces"
            case .loans: return "Loan out"
            case .development: return "Development"
            case .talent: return "Young talent"
            case .training: return "Training"
            }
        }
    }

    public static let sinceLabel = "Compared with"

    private let session: AnalysisSession
    private let store: DevelopmentStore
    private let club: String
    private let today: Date
    private let squad: [Player]
    private let firstTeam: [Player]
    private let level: Int
    private let myNation: String
    private var snaps: [DevelopmentStore.Snap]?

    public init(session: AnalysisSession, store: DevelopmentStore = DevelopmentStore()) {
        self.session = session
        self.store = store
        club = session.club.name
        today = session.today
        let name = session.club.name
        squad = session.db.players.filter { $0.clubFull == name && $0.block != 0 && $0.ca > 0 }
        firstTeam = squad.filter { $0.loanClub.isEmpty && ($0.squad == "First team" || $0.squad.isEmpty) }
        level = AnalysisSession.level(of: SquadPlanner.analysedSquad(session))
        myNation = squad.map(\.clubNation).first { !$0.isEmpty } ?? ""
    }

    public var title: String { "My club: \(club) - FM Starship" }

    private var showHidden: Bool { session.display.showHidden }
    private var display: DisplayOptions { session.display }
    private var units: MoneyUnits { session.display.units }

    private func ageText(_ age: Int) -> String { age >= 0 ? "\(age)" : "" }

    /// The window's tab change. `since` picks a date from `sinceChoices`.
    public func table(_ tab: Tab, since: Int = 0) -> AnalysisTable {
        guard !club.isEmpty else {
            return AnalysisTable(columns: [TableColumn("", 100)],
                                 head: "Pick your club first (Interest section on the left of the main window).")
        }
        switch tab {
        case .health: return health()
        case .setPieces: return setPieces()
        case .loans: return loans()
        case .development: return development(since: since)
        case .talent: return talent()
        case .training: return training()
        }
    }

    // MARK: Health check

    private struct Finding {
        let order: Int
        let player: Player
        let area: String
        let issue: String
        let detail: String
        let tone: Tone
    }

    public func health() -> AnalysisTable {
        var findings: [Finding] = []
        let paid = firstTeam.filter { $0.wage > 0 }
        let wagesByLevel = paid.map(\.wage).sorted()

        for p in squad {
            func add(_ order: Int, _ area: String, _ issue: String, _ detail: String, _ tone: Tone) {
                findings.append(Finding(order: order, player: p, area: area, issue: issue, detail: detail, tone: tone))
            }

            let days = p.injury == nil ? 0 : session.checks.daysOut(p)
            if days >= 21 { add(0, "Fitness", "Long-term injury", "\(days) days out (\(p.injuryText))", .bad) }

            if let end = p.contractEnd, end <= today.addingOneYear {
                let young = p.age >= 0 && p.age <= 21
                let date = NetFormat.dayMonthYear(end)
                let average = "your best eleven average \(display.ability(level))"
                if p.ca >= level - 8, p.age <= 31 {
                    add(1, "Contract", "Renew soon", "A key player\(display.labelled("CA", p.ca).map { " (\($0), \(average))" } ?? ""); contract ends \(date)", .bad)
                } else if young, display.showsAbility, p.pa >= level - 10 {
                    add(1, "Contract", "Renew: a prospect",
                        (display.labelled("PA", p.pa).map { "\($0) (\(average)); contract" } ?? "Contract") + " ends \(date) - don't lose him for nothing", .bad)
                } else if !young, p.ca < level - 15 || p.age >= 32 {
                    add(6, "Contract", "Let it run out?", "Contract ends \(date); " + [display.labelled("CA", p.ca), "age \(p.age)"].compactMap { $0 }.joined(separator: ", "), .muted)
                }
            }

            if p.loanClub.isEmpty, p.wage > 0, paid.count >= 8 {
                let peers = paid.filter { $0 !== p && abs($0.ca - p.ca) <= 8 }.map(\.wage).sorted()
                if peers.count >= 3, Double(p.wage) >= Double(peers[peers.count / 2]) * 1.6,
                   p.wage >= wagesByLevel[paid.count / 2] {
                    add(4, "Money", "Overpaid",
                        units.money(Int64(p.wage)) + "; players of his level at your club earn about " + units.money(Int64(peers[peers.count / 2])), .fair)
                }
            }

            guard showHidden else { continue }
            let controversy = p.p("Controversy"), temperament = p.p("Temperament"), professionalism = p.p("Professionalism")
            let pressure = p.p("Pressure"), loyalty = p.p("Loyalty")
            if p.a("Injury Proneness") >= 14 {
                add(2, "Fitness", "Injury-prone", "Injury Proneness \(p.a("Injury Proneness")) (hidden): expect regular spells out", .fair)
            }
            if controversy >= 15 {
                add(3, "Dressing room", "Controversial", "Controversy \(controversy): may speak out in the media and unsettle others", .fair)
            }
            if professionalism <= 7 {
                add(3, "Dressing room", "Unprofessional", "Professionalism \(professionalism): trains poorly, a bad example to youngsters", .fair)
            }
            if temperament <= 6 {
                add(5, "Dressing room", "Short temper", "Temperament \(temperament): more bookings and bust-ups", .fair)
            }
            if pressure <= 6, p.ca >= level - 8 {
                add(5, "Big games", "Wilts under pressure", "Pressure \(pressure): may freeze in big matches", .fair)
            }
            if loyalty <= 5, let end = p.contractEnd, end <= today.addingEighteenMonths, p.ca >= level - 8 {
                add(5, "Contract", "May want to leave", "Loyalty \(loyalty), contract ends \(NetFormat.monthYear(end))", .fair)
            }
            if professionalism >= 17, p.a("Determination") >= 16, p.age >= 24 {
                add(7, "Dressing room", "Good influence",
                    "Professionalism \(professionalism), Determination \(p.a("Determination")): a good mentor for your youngsters", .good)
            }
        }

        var table = AnalysisTable(columns: [
            TableColumn("Player", 16), TableColumn("Squad", 8), TableColumn("Age", 5), TableColumn("Area", 11),
            TableColumn("Issue", 16), TableColumn("Detail", 44),
        ])
        table.rows = findings.stableSorted { $0.order != $1.order ? $0.order < $1.order : $0.player.ca > $1.player.ca }.map { f in
            let p = f.player
            return TableRow(cells: [p.name, p.loanClub.isEmpty ? p.squad : "On loan", ageText(p.age), f.area, f.issue, f.detail],
                            person: p, tone: f.tone, toneColumn: 4)
        }
        let action = findings.filter { $0.tone == .bad }.count
        let watching = findings.filter { $0.tone == .fair }.count
        let influences = findings.filter { $0.order == 7 }.count
        let hint = showHidden ? "" : " Switch on Hidden attributes (the eye in the toolbar) for the dressing-room and injury-proneness checks."
        table.head = "\(squad.count) players at \(club) checked: \(action) need action now, \(watching) worth watching, \(influences) good influences.\(hint)"
        table.status = "Double-click for the full profile; right-click to compare or add to a shortlist."
        return table
    }

    // MARK: Set pieces

    private func penalty(_ p: Player) -> Double {
        if showHidden {
            let sum = p.a("Penalty Taking") * 4 + p.a("Composure") * 2 + p.a("Technique") + p.a("Important Matches") * 2
                + p.a("Consistency") + p.p("Pressure")
            return Double(sum) / 11
        }
        return Double(p.a("Penalty Taking") * 4 + p.a("Composure") * 2 + p.a("Technique") + p.a("Finishing")) / 8
    }

    public func setPieces() -> AnalysisTable {
        let takers = firstTeam.filter { p in
            guard p.pos[0] < 15 else { return false }
            return p.injury == nil || session.checks.daysOut(p) <= 7
        }
        let duties: [(String, (Player) -> Double, String)] = [
            ("Penalties", penalty,
             showHidden ? "Penalty Taking, Composure, Technique + hidden Important Matches, Consistency, Pressure"
                        : "Penalty Taking, Composure, Technique, Finishing"),
            ("Direct free kicks", { Double($0.a("Free Kicks") * 4 + $0.a("Technique") * 2 + $0.a("Long Shots") + $0.a("Composure")) / 8 },
             "Free Kicks, Technique, Long Shots, Composure"),
            ("Corners", { Double($0.a("Corners") * 4 + $0.a("Crossing") * 2 + $0.a("Technique") + $0.a("Vision")) / 8 },
             "Corners, Crossing, Technique, Vision"),
            ("Long throws", { Double($0.a("Long Throws") * 4 + $0.a("Strength")) / 5 },
             "Long Throws, Strength (worth using from about 14)"),
            ("Aerial targets", { Double($0.a("Heading") * 2 + $0.a("Jumping Reach") * 2 + $0.a("Strength") + $0.a("Bravery")) / 6 },
             "Heading, Jumping Reach, Strength, Bravery"),
        ]

        var table = AnalysisTable(columns: [
            TableColumn("Duty", 14), TableColumn("1st", 22), TableColumn("2nd", 22), TableColumn("3rd", 22), TableColumn("Based on", 30),
        ])
        for (duty, score, basis) in duties {
            let best = Array(takers.map { ($0, score($0)) }.stableSorted { $0.1 > $1.1 }.prefix(3))
            func cell(_ i: Int) -> String {
                i < best.count ? "\(best[i].0.name)  \(NetFormat.fixed(best[i].1, min: 1, max: 1))" : ""
            }
            table.rows.append(TableRow(cells: [duty, cell(0), cell(1), cell(2), basis], person: best.first?.0))
        }
        table.head = "The best takers in your first team (fit outfield players), scored out of 20 from the attributes that matter."
            + (showHidden ? "" : " Switch on Hidden attributes (the eye in the toolbar) to weigh penalties by big-match temperament too.")
        table.status = "Set these in FM under Tactics > Set Pieces."
        return table
    }

    // MARK: Loan out

    public func loans() -> AnalysisTable {
        var table = AnalysisTable(columns: [
            TableColumn("Player", 15), TableColumn("Age", 5), TableColumn("Position", 9), TableColumn("CA", 5), TableColumn("PA", 5),
            TableColumn("This season", 10), TableColumn("Why", 25), TableColumn("Clubs where he'd likely start", 36),
        ])
        let young = Array(squad.filter {
            $0.loanClub.isEmpty && $0.age >= 16 && $0.age <= 21 && $0.ca < level - 12
                && (!display.showsAbility || $0.pa >= level - 10 || $0.pa >= $0.ca + 20)
        }.stableSorted { display.showsAbility ? $0.pa > $1.pa : $0.age > $1.age }.prefix(15))
        guard !young.isEmpty else {
            table.head = "No youngsters who need a loan: everyone under 22 is either ready or not worth a loan yet."
            return display.fit(table)
        }

        // Keeps clubs in the order they are first met, as GroupBy does.
        var order: [String] = []
        var byClub: [String: [Player]] = [:]
        for p in session.db.players where !p.club.isEmpty && p.loanClub.isEmpty && p.ca > 0 && session.canSign(p) {
            if byClub[p.clubFull] == nil { order.append(p.clubFull) }
            byClub[p.clubFull, default: []].append(p)
        }
        let clubs: [(name: String, nation: String, level: Double)] = order.compactMap { name in
            guard name != club, let players = byClub[name] else { return nil }
            let best = players.map(\.ca).sorted(by: >).prefix(11)
            return (name, players[0].clubNation, Double(best.reduce(0, +)) / Double(best.count))
        }

        for p in young {
            let matches = clubs.filter { $0.level >= Double(p.ca - 8) && $0.level <= Double(p.ca + 4) }
            let target = Double(p.ca - 2)
            let suggested = matches.stableSorted { a, b in
                let foreignA = a.nation == myNation ? 0 : 1, foreignB = b.nation == myNation ? 0 : 1
                return foreignA != foreignB ? foreignA < foreignB : abs(a.level - target) < abs(b.level - target)
            }.prefix(4)
            table.rows.append(TableRow(cells: [
                p.name, "\(p.age)", p.bestPositions, display.ability(p.ca), display.ability(p.pa),
                p.season.map { "\($0.apps) apps, \($0.minutes) min" } ?? "no games",
                display.labelled("CA", p.ca).map { "\($0) vs your level \(display.ability(level)); PA \(display.ability(p.pa))" } ?? "Not ready for your first team",
                suggested.isEmpty ? "(no club at his level found)"
                    : suggested.map { club in display.reveal == .hidden ? club.name : "\(club.name) (\(display.ability(Int(club.level.rounded()))))" }.joined(separator: ", "),
            ], person: p))
        }
        table.head = "Young players who aren't ready for your first team\(display.labelled("CA", level).map { " (best eleven average \($0)) but have a future" } ?? "") - a loan gets them minutes. Suggested clubs are a level match: \(display.showsAbility ? "their best eleven (in brackets) is about his CA, so he'd likely start" : "he'd likely start there")."
        table.status = "In FM: offer him for loan (Transfer > Offer to clubs) and pick the offers from clubs like these. Right-click to add to a shortlist."
        return display.fit(table)
    }

    // MARK: Development

    private var snapshots: [DevelopmentStore.Snap] {
        if let snaps, !snaps.isEmpty { return snaps }
        let day = today.startOfGameDay
        let loaded = store.load(db: session.db, club: club).filter { $0.gameDate < day }.stableSorted { $0.gameDate < $1.gameDate }
        snaps = loaded
        return loaded
    }

    /// The "Compared with" dates.
    public var sinceChoices: [String] { snapshots.map { NetFormat.dayMonthYear($0.gameDate) } }

    public func development(since: Int = 0) -> AnalysisTable {
        var table = AnalysisTable(columns: [
            TableColumn("Player", 16), TableColumn("Age", 5), TableColumn("CA", 9), TableColumn("PA", 8), TableColumn("Gained", 26),
            TableColumn("Lost", 20), TableColumn("Verdict", 12),
        ])
        let snaps = snapshots
        guard !snaps.isEmpty else {
            table.head = "Nothing to compare with yet: FM Starship keeps a snapshot of your squad at every Load Save (one per in-game day). Load your save again after a few in-game weeks to see who's improving."
            return display.fit(table, also: ["Verdict"])
        }
        let snap = snaps[min(max(0, since), snaps.count - 1)]
        let hidden = Set(Names.hidden.compactMap { Names.playerIndex[$0] })
        let exact = display.reveal == .numbers
        var changed: [(ca: Int, row: TableRow, pa: Int)] = []

        for p in squad {
            guard let old = snap.players[p.uid] else { continue }
            let ca = p.ca - old.ca, pa = p.pa - old.pa
            let changes = (0..<min(old.attr.count, 54))
                .filter { showHidden || !hidden.contains($0) }
                .map { (Names.playerAttrs[$0], p.attribute(at: $0) - Int(old.attr[$0])) }
                .filter { $0.1 != 0 }
            func gains(up: Bool) -> String {
                changes.filter { up ? $0.1 > 0 : $0.1 < 0 }
                    .stableSorted { abs($0.1) > abs($1.1) }.prefix(6)
                    .map { "\($0.0) \(NetFormat.signedNoZero($0.1))" }
                    .joined(separator: ", ")
            }
            let verdict = ca >= 5 ? "improving fast" : ca > 0 ? "improving" : ca == 0 ? "no change" : "declining"
            let tone: Tone = ca >= 5 ? .good : ca > 0 ? .text : ca == 0 ? .muted : .bad
            let row = TableRow(cells: [
                p.name, "\(p.age)", exact ? "\(old.ca) → \(p.ca) (\(NetFormat.signed(ca)))" : display.reveal == .hidden ? "-" : "\(display.ability(old.ca)) → \(display.ability(p.ca))",
                exact && pa != 0 ? "\(p.pa) (\(NetFormat.signedNoZero(pa)))" : display.ability(p.pa),
                gains(up: true), gains(up: false), verdict,
            ], person: p, tone: tone, toneColumn: 6)
            // With CA off, the order comes from the attributes in the row, which anyone can see.
            changed.append((display.showsAbility ? ca : changes.reduce(0) { $0 + $1.1 }, row, display.showsAbility ? p.pa : 0))
        }
        table.rows = changed.stableSorted { $0.ca != $1.ca ? $0.ca > $1.ca : $0.pa > $1.pa }.map(\.row)

        let daysAgo = Int(today.startOfGameDay.timeIntervalSince(snap.gameDate) / 86400)
        let improving = changed.filter { $0.ca > 0 }.count
        let same = changed.filter { $0.ca == 0 }.count
        let declining = changed.filter { $0.ca < 0 }.count
        table.head = "Your squad now against \(NetFormat.dayMonthYear(snap.gameDate)) (\(daysAgo) days ago in the game)\(display.showsAbility ? ": \(improving) improving, \(same) unchanged, \(declining) declining." : ", with the most attributes gained first.")\(exact ? " CA changes are exact - FM never shows them." : "")"
        table.status = "\(snaps.count + 1) snapshots so far (one per in-game day you pressed Load Save); pick another date above."
        return display.fit(table, also: ["Verdict"])
    }

    // MARK: Training

    /// `HashSet<int>` as .NET enumerates it, which decides the order the hill climb tries moves in:
    /// insertion order, with a removed slot reused first.
    private struct AreaSet {
        private var slots: [Int?] = []
        private var freed: [Int] = []

        var values: [Int] { slots.compactMap { $0 } }
        var count: Int { slots.count - freed.count }
        func contains(_ area: Int) -> Bool { slots.contains(area) }

        mutating func insert(_ area: Int) {
            guard !contains(area) else { return }
            if let slot = freed.popLast() {
                slots[slot] = area
            } else {
                slots.append(area)
            }
        }

        mutating func remove(_ area: Int) {
            guard let slot = slots.firstIndex(of: area) else { return }
            slots[slot] = nil
            freed.append(slot)
        }
    }

    private static func allowedAreas(_ coach: Staff) -> [Int] {
        switch coach.job {
        case "Goalkeeping Coach": return [6]
        case "Fitness Coach": return [7]
        case "Set Piece Coach": return [8]
        default: return Array(0..<9)
        }
    }

    /// Everyone at the club still growing, sorted by what they're likely to become rather than by their PA.
    public func talent() -> AnalysisTable {
        var table = AnalysisTable(columns: [
            TableColumn("Player", 17), TableColumn("Age", 4), TableColumn("Position", 9), TableColumn("Team", 9), TableColumn("CA", 5), TableColumn("PA", 5),
            TableColumn("Likely peak", 6), TableColumn("Outlook", 15), TableColumn("Odds", 6), TableColumn("Pro", 4), TableColumn("Det", 4), TableColumn("Amb", 4),
            TableColumn("Injury prone", 5), TableColumn("Personality", 13),
        ])
        let curve = session.development
        let display = session.display
        guard showHidden, display.showsAbility else {
            table.head = "This needs CA, PA and mentality, which are off. \(display.abilityHint) to see who's likely to live up to their PA."
            return display.fit(table)
        }
        let young = squad.filter { $0.age >= 0 && $0.age <= 23 }.stableSorted { curve.peak($0) > curve.peak($1) }
        var likely = 0, unlikely = 0
        for p in young {
            let talent = curve.talent(p)
            if talent?.verdict == .likely { likely += 1 }
            if talent?.verdict == .unlikely { unlikely += 1 }
            let team = p.loanClub.isEmpty ? p.squad : "On loan: \(p.loanClub)"
            table.rows.append(TableRow(cells: [
                p.name, "\(p.age)", p.bestPositions, team, display.ability(p.ca), display.ability(p.pa), display.ability(curve.peak(p)),
                talent?.verdict.title ?? "", talent?.odds ?? "", talent.map { "\($0.professionalism)" } ?? "", talent.map { "\($0.determination)" } ?? "",
                talent.map { "\($0.ambition)" } ?? "", talent.map { "\($0.injuryProneness)" } ?? "", p.personality,
            ], person: p, tone: talent?.verdict.tone, toneColumn: 7))
        }
        table.head = young.isEmpty ? "Nobody at the club is 23 or younger."
            : "Your players aged 23 and under, by the peak they're likely to reach. Likely peak and odds come from how players of the same age, PA and mentality have turned out across this save: \(likely) look likely to live up to their PA and \(unlikely) don't."
        return table
    }

    public func training() -> AnalysisTable {
        var table = AnalysisTable(columns: [
            TableColumn("Training area", 16), TableColumn("Coach(es)", 30), TableColumn("Stars with this plan", 12),
            TableColumn("His stars on this area alone", 14),
        ])
        let jobs: Set<String> = ["Coach", "Assistant Manager", "Goalkeeping Coach", "Fitness Coach", "Set Piece Coach"]
        let coaches = session.db.staff.filter { $0.clubFull == club && $0.squad == "First team" && jobs.contains($0.job) }
        guard !coaches.isEmpty else {
            table.head = "No first-team coaches found at your club."
            return table
        }

        let ratings = coaches.map { coach in (0..<9).map { Rules.coachRating(coach, area: $0) } }
        var plan = [AreaSet](repeating: AreaSet(), count: coaches.count)

        func areaStars(_ area: Int) -> (stars: Double, coach: Int) {
            var best = 0.0
            var who = -1
            for c in coaches.indices where plan[c].contains(area) {
                let stars = Rules.stars(Rules.sharedRating(ratings[c][area], share: 100 / plan[c].count))
                if stars > best {
                    best = stars
                    who = c
                }
            }
            return (best, who)
        }

        func score() -> Double {
            var total = 0.0
            var worst = 99.0
            for area in 0..<9 {
                let stars = areaStars(area).stars
                total += stars
                worst = min(worst, stars)
            }
            return total + 2 * worst - 0.01 * Double(plan.reduce(0) { $0 + $1.count })
        }

        for c in coaches.indices {
            let areas = ClubReport.allowedAreas(coaches[c])
            var first = areas[0]
            for area in areas where ratings[c][area] > ratings[c][first] { first = area }
            plan[c].insert(first)
        }

        var improved = true
        while improved {
            improved = false
            var current = score()
            for c in coaches.indices {
                for area in ClubReport.allowedAreas(coaches[c]) {
                    let had = plan[c].contains(area)
                    if had, plan[c].count == 1 { continue }
                    if had { plan[c].remove(area) } else { plan[c].insert(area) }
                    let tried = score()
                    if tried > current + 1e-09 {
                        current = tried
                        improved = true
                    } else if had {
                        plan[c].insert(area)
                    } else {
                        plan[c].remove(area)
                    }
                }
            }
            for c in coaches.indices {
                for area in plan[c].values {
                    for other in coaches.indices {
                        if other == c || plan[c].count == 1 || plan[other].contains(area)
                            || !ClubReport.allowedAreas(coaches[other]).contains(area) { continue }
                        plan[c].remove(area)
                        plan[other].insert(area)
                        let tried = score()
                        if tried > current + 1e-09 {
                            current = tried
                            improved = true
                            break
                        }
                        plan[other].remove(area)
                        plan[c].insert(area)
                    }
                }
            }
        }

        var total = 0.0
        var covered = 0
        for area in 0..<9 {
            let (stars, who) = areaStars(area)
            total += stars
            if who >= 0 { covered += 1 }
            let names = coaches.indices.filter { plan[$0].contains(area) }.map { coaches[$0].name }
            let tone: Tone = stars >= 4 ? .good : stars >= 3 ? .text : .fair
            table.rows.append(TableRow(cells: [
                Names.areasLong[area],
                names.isEmpty ? "(nobody)" : names.joined(separator: ", "),
                stars > 0 ? NetFormat.fixed(stars, min: 1, max: 1) + "★" : "—",
                who < 0 ? "" : NetFormat.fixed(Rules.stars(ratings[who][area]), min: 1, max: 1) + "★",
            ], person: who >= 0 ? coaches[who] : nil, tone: tone, toneColumn: 2))
        }

        let summary = coaches.indices.map { c in
            coaches[c].name + ": " + plan[c].values.sorted().map { Names.areas[$0] }.joined(separator: ", ")
        }.joined(separator: "  ·  ")
        table.head = "A training plan for your \(coaches.count) first-team coaches: \(covered) of 9 areas covered, \(NetFormat.fixed(total / 9, min: 1, max: 1))★ on average. \(summary)"
        table.status = "From FM's own coaching formula: a coach covering several areas loses part of his rating in each. Assumes your training spreads its time evenly over the areas."
        return table
    }
}
