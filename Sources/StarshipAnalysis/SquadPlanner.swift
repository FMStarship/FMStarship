import Foundation
import StarshipCore

/// Looks at the first team position by position, then finds signings who fill the gaps.
public enum SquadPlanner {
    public struct Group: Equatable {
        public let name: String
        public let positions: [Int]
        public let target: Int
    }

    public final class Line {
        public let group: Group
        /// How many a squad wants here: the usual number, or what the user's tactic asks for.
        public internal(set) var target: Int
        /// This position's places in the user's tactic.
        public internal(set) var slots: [TacticSlot] = []
        public internal(set) var players: [Player] = []
        public internal(set) var cover: [Player] = []
        public internal(set) var issues: [String] = []
        public internal(set) var priority = 0
        public internal(set) var wantCA = 0

        init(group: Group) {
            self.group = group
            target = group.target
        }

        public var starter: Player? { players.first }
    }

    public struct Pick {
        public let line: Line
        public let player: Player
        public let main: Bool
        public let loan: Bool
    }

    public static let groups: [Group] = [
        Group(name: "Goalkeeper", positions: [0], target: 2),
        Group(name: "Centre-back", positions: [3], target: 3),
        Group(name: "Right-back", positions: [4, 14], target: 2),
        Group(name: "Left-back", positions: [2, 13], target: 2),
        Group(name: "Defensive midfield", positions: [5], target: 2),
        Group(name: "Central midfield", positions: [7], target: 3),
        Group(name: "Right wing", positions: [8, 11], target: 2),
        Group(name: "Left wing", positions: [6, 9], target: 2),
        Group(name: "Attacking midfield", positions: [10], target: 2),
        Group(name: "Striker", positions: [12], target: 2),
    ]

    static func plays(_ player: Player, _ group: Group) -> Bool {
        group.positions.contains { player.pos[$0] >= 15 }
    }

    static func covers(_ player: Player, _ group: Group) -> Bool {
        group.positions.contains { player.pos[$0] >= 18 }
    }

    /// The group a player rates best in. On a tie a position the tactic uses wins, then the earlier group.
    static func main(_ player: Player, preferring used: [Group] = []) -> Group {
        var best = groups[0]
        var rating = -1
        for group in groups {
            let here = group.positions.map { Int(player.pos[$0]) }.max() ?? 0
            if here > rating || (here == rating && used.contains(group) && !used.contains(best)) {
                rating = here
                best = group
            }
        }
        return best
    }

    /// A sweeper has no group of their own, and stands with the centre-backs.
    static func group(of position: Int) -> Group? {
        groups.first { $0.positions.contains(Names.positions[position] == "SW" ? 3 : position) }
    }

    public static func analyse(_ session: AnalysisSession) -> [Line] {
        let squad = analysedSquad(session)
        let level = AnalysisSession.level(of: squad)
        let today = session.today
        let showHidden = session.display.showHidden
        let tactic = session.db.tactics[session.club.team]
        let used = (tactic?.slots ?? []).compactMap { group(of: $0.position) }
        // Whoever the user plays somewhere counts there, whatever else they're good at.
        var picked: [UInt32: Group] = [:]
        for slot in tactic?.slots ?? [] {
            if let uid = slot.player?.uid, let group = group(of: slot.position) { picked[uid] = group }
        }
        let mainGroups = squad.map { picked[$0.uid] ?? main($0, preferring: used) }
        var lines: [Line] = []

        for group in groups {
            let line = Line(group: group)
            let here = zip(squad, mainGroups)
            line.players = here.filter { $0.1 == group && (plays($0.0, group) || picked[$0.0.uid] != nil) }.map(\.0).stableSorted {
                let (first, second) = (picked[$0.uid] != nil, picked[$1.uid] != nil)
                return first != second ? first : $0.ca > $1.ca
            }
            line.cover = here.filter { $0.1 != group && covers($0.0, group) }.map(\.0).stableSorted { $0.ca > $1.ca }

            if let tactic {
                line.slots = tactic.slots.filter { Self.group(of: $0.position) == group }
                line.target = line.slots.count + (line.slots.count + 1) / 2
                // A position the tactic doesn't use has no gap to fill.
                if line.slots.isEmpty {
                    lines.append(line)
                    continue
                }
            }

            let starter = line.starter
            var weakStarter = false
            let good = line.players.filter { $0.ca >= level - 20 }
            let others = line.players.count - good.count
            let missing = line.target - good.count

            if let starter {
                if missing > 0 {
                    var issue = "only \(good.count) of \(line.target) near first-team level"
                    if others > 0 { issue += " (+\(others) younger/weaker)" }
                    if !line.cover.isEmpty { issue += ", \(line.cover.count) can cover" }
                    line.issues.append(issue)
                    line.priority += (line.cover.count >= missing ? 12 : 30) * missing
                }

                let injured = good.filter { $0.injury != nil }.map { ($0, session.checks.daysOut($0)) }
                let longTerm = injured.filter { $0.1 >= 21 }.count
                if longTerm > 0, good.count - longTerm < line.target {
                    line.issues.append(longTerm != good.count ? "\(longTerm) of \(good.count) out for 3+ weeks"
                                                              : "all \(longTerm) out for 3+ weeks")
                    line.priority += 10 * longTerm
                } else if !injured.isEmpty {
                    let names = injured.map(\.0.name).joined(separator: ", ")
                    line.issues.append(names + " injured (" + injured.map { "\($0.1) days" }.joined(separator: ", ") + ")")
                }

                if showHidden, starter.a("Injury Proneness") >= 14 {
                    line.issues.append("\(starter.name) is injury-prone (hidden: \(starter.a("Injury Proneness")))")
                    line.priority += 15
                }
                if starter.ca < level - 8, session.development.isProspect(starter), session.development.peak(starter) >= level - 8 {
                    // Buying over someone who'll be good enough costs them the minutes that get them there.
                    line.issues.append("\(starter.name) is still developing")
                } else if starter.ca < level - 8 {
                    weakStarter = true
                    line.issues.append(session.display.labelled("CA", starter.ca).map { "best is \($0), your first XI averages \(session.display.ability(level))" } ?? "weakest in your first XI")
                    line.priority += 2 * (level - starter.ca)
                }
                if starter.age >= 32 {
                    line.issues.append("\(starter.name) is \(starter.age)")
                    line.priority += 15
                }
                if !starter.loanClub.isEmpty {
                    // Their contract is with the parent club, and they go back whatever it says.
                    let until = starter.loanEnd.map { " until \(NetFormat.monthYear($0))" } ?? ""
                    line.issues.append("\(starter.name) is on loan from \(starter.club)\(until)")
                    line.priority += 10
                } else if let end = starter.contractEnd, end <= today.addingOneYear {
                    line.issues.append("\(starter.name)'s contract ends \(NetFormat.monthYear(end))")
                    line.priority += 10
                }
            } else if line.cover.isEmpty {
                line.issues.append("nobody plays here")
                line.priority += 120
            } else {
                line.issues.append("nobody plays here mainly, \(line.cover[0].name) can cover")
                line.priority += 60
            }

            if let starter, missing <= 0 {
                line.wantCA = weakStarter ? max(starter.ca + 3, level - 8) : max(1, min(starter.ca, level) - 6)
            } else {
                line.wantCA = max(1, level - 12)
            }
            lines.append(line)
        }
        return lines
    }

    /// Fills the gaps in priority order, spending the budget on each main pick. Handed one line,
    /// it lists more alternatives for just that position.
    public static func suggest(_ session: AnalysisSession, lines: [Line], budget: Int64, wages: Int, includeLoans: Bool,
                               isCancelled: () -> Bool = { false }, status: (String) -> Void = { _ in }) -> (picks: [Pick], interestChecked: Bool) {
        let club = session.club.name
        var picks: [Pick] = []
        var taken = Set<UInt32>()
        var money = budget
        var wageRoom = wages
        var interestChecked = true
        let wanted = lines.count == 1 ? 10 : 3
        let gaps = lines.count == 1 ? lines : lines.filter { $0.priority > 0 }.stableSorted { $0.priority > $1.priority }

        for line in gaps {
            if isCancelled() { break }
            let group = line.group.name.lowercased()
            status("Looking for \(group.first.map { "aeiou".contains($0) } == true ? "an" : "a") \(group)...")

            let candidates = session.db.players.filter {
                $0.block != 0 && $0.clubFull != club && $0.loanClubFull != club && !$0.notForSale && $0.ca >= line.wantCA
                    && (16...30).contains($0.age) && plays($0, line.group) && !taken.contains($0.uid)
            }.stableSorted { $0.ca != $1.ca ? $0.ca > $1.ca : $0.pa > $1.pa }

            var found: [(player: Player, loan: Bool)] = []
            for batch in candidates.chunked(32) {
                if isCancelled() { break }
                let answers = session.checks.check(batch: batch)
                if answers == nil { interestChecked = false }
                for (index, player) in batch.enumerated() {
                    if found.count >= wanted { break }
                    // With no answer from the game everyone is treated as a transfer, the dearer case.
                    let answer = answers == nil ? JoinAnswer(transfer: true, loan: false) : answers?[index]
                    guard let answer, answer.transfer || (includeLoans && answer.loan) else { continue }
                    let loan = !answer.transfer
                    let fee = loan || player.club.isEmpty ? 0 : player.value
                    if fee <= money, player.wage <= wageRoom { found.append((player, loan)) }
                }
                if found.count >= wanted { break }
            }

            for (index, choice) in found.enumerated() {
                picks.append(Pick(line: line, player: choice.player, main: index == 0, loan: choice.loan))
                taken.insert(choice.player.uid)
                if index == 0 {
                    money -= choice.loan || choice.player.club.isEmpty ? 0 : choice.player.value
                    wageRoom -= choice.player.wage
                }
            }
        }
        return (picks, interestChecked)
    }

    /// Text of the budget and wage boxes as `PlannerForm` fills them in.
    public static func startingBudget(_ session: AnalysisSession) -> (budget: String, wageRoom: String) {
        let units = session.display.units
        // Dictionary order means nothing here, so "the first budget" is taken in human-club order.
        let any = session.db.humanClubs.lazy.compactMap { session.db.budgets[$0.team] }.first ?? session.db.budgets.values.first
        let budget = session.budget ?? any ?? (0, 0)
        return (units.moneyText(Double(budget.transfer)), units.wageText(budget.wageRoom, suffix: true))
    }

    /// `PlannerForm.ParseMoney`: "40M", "£75K", "75,000 p/w".
    public static func parseMoney(_ text: String, units: MoneyUnits) -> Int64? {
        var s = units.trimmedSymbol(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("p/w") || s.hasSuffix("p/m") || s.hasSuffix("p/a") {
            s = String(s.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var factor = 1.0
        if s.lowercased().hasSuffix("b") {
            factor = 1_000_000_000
            s.removeLast()
        } else if s.lowercased().hasSuffix("m") {
            factor = 1_000_000
            s.removeLast()
        } else if s.lowercased().hasSuffix("k") {
            factor = 1000
            s.removeLast()
        }
        guard let value = parseInvariantDouble(s.replacingOccurrences(of: ",", with: "")) else { return nil }
        return clampedInt64(value * factor)
    }

    public static let squadColumns = [
        TableColumn("Position", 14), TableColumn("Have / want", 15), TableColumn("Best", 18), TableColumn("CA", 5),
        TableColumn("What's missing", 40),
    ]

    public static let slotColumns = [
        TableColumn("Position", 7), TableColumn("With the ball", 17), TableColumn("Without the ball", 17), TableColumn("Player", 16),
        TableColumn("Stars", 6), TableColumn("CA", 4), TableColumn("Best fit", 26), TableColumn("Cover", 19),
        TableColumn("Have / want", 8), TableColumn("Status", 6), TableColumn("What's missing", 28),
    ]

    public static let pickColumns = [
        TableColumn("For", 13), TableColumn("Name", 17), TableColumn("Age", 5), TableColumn("Club", 14),
        TableColumn("CA", 5), TableColumn("PA", 5), TableColumn("Value", 8), TableColumn("Wage", 8),
        TableColumn("Deal", 7), TableColumn("vs best", 7),
    ]

    public static let budgetLabel = "Transfer budget"
    public static let wageLabel = "Wage room"
    public static let loansLabel = "Include loans"
    public static let findButton = "Find signings"
    public static let positionButton = "Just this position"
    public static let saveButton = "Save plan as FM shortlist"
    public static let shortlistName = "Squad plan"
    public static let squadTitle = "Your first team"
    public static let picksTitle = "Suggested signings (the plan's pick first, then alternatives)"
    public static let haveWantTip = "Players whose main position this is / how many a squad wants there. (+N) = players from other positions who can cover it well (rated 18+ there)."
    public static let noPositionChosen = "Click a position on the left first."
    public static func title(_ session: AnalysisSession) -> String { "Squad planner for \(session.club.name) - FM Starship" }

    private static func have(_ line: Line) -> String {
        line.cover.isEmpty ? "\(line.players.count) / \(line.target)" : "\(line.players.count) (+\(line.cover.count)) / \(line.target)"
    }

    private static func tone(_ line: Line) -> Tone {
        line.priority > 0 ? (line.priority >= 30 ? .bad : .fair) : .good
    }

    private static func status(_ line: Line) -> String {
        switch tone(line) {
        case .bad: return "Gap"
        case .fair: return "Watch"
        default: return "Fine"
        }
    }

    /// The first-team grid, the line each of its rows belongs to, and a sentence about each row's player.
    public static func squadView(_ lines: [Line], session: AnalysisSession) -> (table: AnalysisTable, rows: [Line], notes: [String]) {
        guard let tactic = session.db.tactics[session.club.team] else { return (squadTable(lines, session: session), lines, []) }
        return tacticTable(tactic, lines: lines, session: session)
    }

    /// One row for each of the eleven places, so a pair of centre-backs is two rows with their own roles.
    private static func tacticTable(_ tactic: Tactic, lines: [Line], session: AnalysisSession) -> (table: AnalysisTable, rows: [Line], notes: [String]) {
        var table = AnalysisTable(columns: slotColumns)
        let with = tactic.shape(in: session.library), without = tactic.shapeWithoutBall(in: session.library)
        let shape = with == without ? "\(with) with and without the ball" : "\(with) with the ball, \(without) without it"
        table.head = "\(shape). Stars are FM's own, for the role in each place."
        let book = RoleBook(session)
        // Cover has to be able to play: nobody who's out for weeks themselves.
        let squad = analysedSquad(session).filter { $0.injury == nil || session.checks.daysOut($0) < 21 }
        var rows: [Line] = []
        var notes: [String] = []
        var saidIssues = Set<String>()

        for slot in tactic.slots.stableSorted(by: { $0.pitchOrder < $1.pitchOrder }) {
            guard let line = lines.first(where: { $0.group == group(of: slot.position) }) else { continue }
            rows.append(line)
            let rated = slot.player.flatMap { player in book?.rate(player, in: slot) }
            let issues = saidIssues.insert(line.group.name).inserted ? line.issues.joined(separator: "; ") : ""
            let cover = book?.cover(for: slot, squad: squad, excluding: Set(tactic.slots.compactMap { $0.player?.uid }))
            let advice = slot.player.flatMap { player in book?.advice(player, in: slot) }
            notes.append(advice?.sentence ?? "")
            let shown = slot.position == slot.positionWithoutBall ? slot.roleNameWithoutBall
                                                                  : "\(Names.positions[slot.positionWithoutBall]): \(slot.roleNameWithoutBall)"
            table.rows.append(TableRow(cells: [
                slot.label, slot.roleName, shown, slot.player?.name ?? "nobody picked",
                rated.map { RoleBook.stars($0.combined) } ?? "",
                slot.player.map { session.display.ability($0.ca) } ?? "",
                advice?.short ?? "",
                cover.map { "\($0.player.name) \(RoleBook.stars($0.stars))" } ?? "",
                have(line),
                issues.isEmpty ? "Fine" : status(line),
                issues,
            ], person: slot.player, tone: issues.isEmpty ? .good : tone(line), toneColumn: 9, quietColumn: 10))
        }
        return (session.display.fit(table), rows, notes)
    }

    /// The squad the planner looks at: the first team, without anyone out on loan, then anyone on loan here.
    /// They stay last because a loan in carries the parent club's league, and the rivals are read off the first player.
    static func analysedSquad(_ session: AnalysisSession) -> [Player] {
        let club = session.club.name
        return session.db.players.filter { $0.clubFull == club && $0.loanClub.isEmpty && ($0.squad == "First team" || $0.squad.isEmpty) }
            + session.db.players.filter { $0.clubFull != club && $0.loanClubFull == club }
    }

    /// The left-hand grid. `person` is the line's starter.
    public static func squadTable(_ lines: [Line], session: AnalysisSession) -> AnalysisTable {
        var table = AnalysisTable(columns: squadColumns)
        for line in lines {
            let starter = line.starter
            let have = line.cover.isEmpty ? "\(line.players.count) / \(line.target)"
                                          : "\(line.players.count) (+\(line.cover.count) cover) / \(line.target)"
            let tone = tone(line)
            table.rows.append(TableRow(cells: [
                line.group.name, have, starter?.name ?? "-",
                starter.map { session.display.ability($0.ca) } ?? "",
                line.issues.isEmpty ? "fine" : line.issues.joined(separator: "; "),
            ], person: starter, tone: tone, toneColumn: 4))
        }
        return session.display.fit(table)
    }

    public struct Plan {
        public var table: AnalysisTable
        public var picks: [Pick]
        /// The main picks: what "Save plan as FM shortlist" saves.
        public var shortlist: [Player]
        public var canSaveShortlist: Bool { !shortlist.isEmpty }
    }

    /// `PlannerForm.Find`. `only` is the "Just this position" line. Nil when cancelled.
    /// To the nearest pound, not down: the save holds whole pounds, and a figure shown in another currency has to come back to the same one.
    static func poundsFor(budget: Int64, wages: Int64, units: MoneyUnits) -> (budget: Int64, wages: Int) {
        (clampedInt64(units.toPounds(Double(budget)).rounded()), clampedInt32(units.toWeeklyPounds(Double(wages)).rounded()))
    }

    public static func plan(_ session: AnalysisSession, lines: [Line], only: Line? = nil, budget budgetText: String,
                            wageRoom wageText: String, includeLoans: Bool,
                            isCancelled: () -> Bool = { false }, status: (String) -> Void = { _ in }) -> Plan? {
        let units = session.display.units
        var table = AnalysisTable(columns: pickColumns)
        guard let budgetInput = parseMoney(budgetText, units: units), let wageInput = parseMoney(wageText, units: units) else {
            table.status = "Type a transfer budget and wage room, e.g. 40M and 75K."
            return Plan(table: session.display.fit(table), picks: [], shortlist: [])
        }
        let (budget, wages) = poundsFor(budget: budgetInput, wages: wageInput, units: units)

        let (found, interestChecked) = suggest(session, lines: only.map { [$0] } ?? lines, budget: budget, wages: wages,
                                               includeLoans: includeLoans, isCancelled: isCancelled, status: status)
        if isCancelled() { return nil }
        table.interestChecked = interestChecked

        for pick in found {
            let p = pick.player
            let starter = pick.line.starter
            let free = p.club.isEmpty
            table.rows.append(TableRow(cells: [
                pick.main ? pick.line.group.name : "  or",
                p.name,
                p.age >= 0 ? "\(p.age)" : "",
                free ? "Free agent" : p.club,
                session.display.ability(p.ca),
                session.display.ability(p.pa),
                pick.loan ? "Loan" : free ? "Free" : units.money(p.value),
                free ? "to agree" : units.wageText(p.wage),
                pick.loan ? "Loan" : "Transfer",
                starter.map { NetFormat.signed(p.ca - $0.ca) } ?? "new",
            ], person: p, tone: pick.main ? nil : .muted, bold: pick.main))
        }

        let mainPicks = found.filter(\.main)
        let fee: (Pick) -> Int64 = { $0.loan || $0.player.club.isEmpty ? 0 : $0.player.value }
        let moneyLeft = units.money(budget - mainPicks.reduce(0) { $0 + fee($1) }) + " left"
        let wagesLeft = units.wageText(wages - mainPicks.reduce(0) { $0 + $1.player.wage }) + " left"
        let gaps = lines.filter { $0.priority > 0 }
        for line in only.map({ [$0] }) ?? gaps where !found.contains(where: { $0.line === line }) {
            let nobody = interestChecked ? "nobody who'd join fits" : "nobody fits"
            table.rows.append(TableRow(cells: [line.group.name, nobody, "", "", "", "", moneyLeft, wagesLeft, "", ""], tone: .muted))
        }

        let spent = mainPicks.reduce(0) { $0 + fee($1) }
        let wagesSpent = mainPicks.reduce(0) { $0 + $1.player.wage }
        let filled = gaps.filter { line in mainPicks.contains { $0.line === line } }.count
        if let only {
            let who = interestChecked ? "who'd join and fit" : "who fit"
            table.status = "The best \(found.count) for \(only.group.name.lowercased()) \(who) the whole budget (the first is bold). Find signings goes back to the whole plan."
        } else if gaps.isEmpty {
            table.status = "No gaps found - your first team covers every position."
        } else {
            let moneySpent = spent > 0 ? units.money(spent) : "nothing"
            let wagesAdded = wagesSpent > 0 ? units.wageText(wagesSpent, suffix: true) : "nothing"
            table.status = "\(filled) of \(gaps.count) gaps filled. The plan spends \(moneySpent) of \(units.money(budget)) and \(wagesAdded) of \(units.wageText(wages, suffix: true)) wage room."
        }
        return Plan(table: session.display.fit(table), picks: found, shortlist: mainPicks.map(\.player))
    }
}
