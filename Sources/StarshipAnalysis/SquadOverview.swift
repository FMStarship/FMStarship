import Foundation
import StarshipCore

/// The first eleven at a glance: how each place compares with the league, who covers it, and who'd do it better.
public final class SquadOverview: OverviewReport {
    public struct Place: Identifiable {
        public let id: String
        public let slot: TacticSlot
        public let stars: Int
        public let cover: String
        public let standing: Standing
    }

    public static let groupNames = ["Goalkeeper", "Defence", "Midfield", "Attack"]
    /// Players past this rarely make sense as a signing to build around.
    private static let signingAges = 16...32
    private static let batchSize = 64
    /// How far down the ranking to go, and how many who'd join to weigh up for the role.
    private static let deepest = 640
    private static let enough = 6
    /// A stand-in a star and a half short of the starter isn't really cover.
    private static let coverGap = 3

    public let headline: String
    public let rows: [OverviewRow]
    public let places: [Place]
    public let footnote: String
    public var groups: [String] { Self.groupNames }
    public var placeTitle: String { "Position" }
    public var nowTitle: String { "Playing now" }
    public var exportTitle: String { "Squad overview" }

    private let session: AnalysisSession
    private let book: RoleBook
    private let level: Int
    private var slots: [String: (slot: TacticSlot, stars: Int, score: Int)] = [:]

    private static func group(_ position: Int) -> String {
        switch Tactic.line(position) {
        case 0: return "Goalkeeper"
        case 1: return "Defence"
        case 2, 3: return "Midfield"
        default: return "Attack"
        }
    }

    /// Nil without the live game: the stars, the tactic and who'd join all come from it.
    public init?(session: AnalysisSession) {
        guard let tactic = session.db.tactics[session.club.team], let book = RoleBook(session) else { return nil }
        self.session = session
        self.book = book
        let squad = SquadPlanner.analysedSquad(session)
        level = AnalysisSession.level(of: squad)
        let today = session.today
        let display = session.display
        let units = display.units
        let fit = squad.filter { $0.injury == nil || session.checks.daysOut($0) < 21 }
        let starters = Set(tactic.slots.compactMap { $0.player?.uid })
        let rivals = TacticOptimizer.rivals(session, squad: squad)
        let league = squad.first?.league ?? ""
        let curve = session.development
        // Anyone at the club counts here, on loan or in the youth teams: they're who a signing would block.
        var comingThrough = session.db.players.filter { $0.clubFull == session.club.name && !starters.contains($0.uid) && curve.isProspect($0) }
            .stableSorted { curve.peak($0) > curve.peak($1) }

        let ordered = tactic.slots.enumerated().sorted { a, b in
            a.element.pitchOrder != b.element.pitchOrder ? a.element.pitchOrder < b.element.pitchOrder : a.offset < b.offset
        }.map(\.element)
        var rows: [OverviewRow] = []
        var places: [Place] = []
        var slots: [String: (slot: TacticSlot, stars: Int, score: Int)] = [:]
        var alongside: [String: Int] = [:]
        var noCover = 0, weak = 0, growing = 0
        let standIns = book.secondEleven(ordered, squad: fit, excluding: starters)

        for (index, slot) in ordered.enumerated() {
            let id = "\(slot.position)|\(slot.side)|\(rows.count)"
            let group = SquadPlanner.group(of: slot.position)
            let groupName = group?.name ?? Names.positions[slot.position]
            let depth = alongside[groupName, default: 0]
            alongside[groupName] = depth + 1
            let rated = slot.player.flatMap { book.rate($0, in: slot) }
            let stars = rated?.combined ?? 0
            let cover = standIns[index]
            let coverText = cover.map { "\($0.player.name) \(RoleBook.stars($0.stars))" } ?? "Nobody"
            let lacksCover = cover.map { $0.stars + Self.coverGap <= stars } ?? true

            // The second centre-back is measured against second centre-backs.
            let others = rivals.compactMap { club -> Double? in
                let here = club.filter { candidate in group?.positions.contains { candidate.pos[$0] >= 15 } ?? false }.map(\.ca).sorted(by: >)
                return depth < here.count ? Double(here[depth]) : nil
            }.sorted()
            func place(_ ability: Int) -> String { StaffReview.ordinal(others.filter { $0 > Double(ability) }.count + 1) }
            let middle = others.isEmpty ? 0 : Int(others[others.count / 2])

            var standing = Standing.missing
            var rank = ""
            var warnings: [String] = []
            var outlook: String?
            var advice: String?
            var talent: DevelopmentCurve.Talent?
            if let player = slot.player {
                standing = .of(Double(player.ca), against: others)
                if !others.isEmpty { rank = "\(place(player.ca)) of \(others.count + 1)" }
                if display.showsAbility, standing != .strong, curve.isProspect(player), Standing.of(Double(curve.peak(player)), against: others) >= .good {
                    standing = .developing
                    growing += 1
                    let soon = min(player.age + 2, DevelopmentCurve.peakAge)
                    outlook = "On course for \(place(curve.expected(player, atAge: soon))) of \(others.count + 1) by \(soon), \(place(curve.peak(player))) at peak"
                    if display.reveal == .numbers { outlook? += " (CA \(player.ca), PA \(player.pa))" }
                    talent = curve.talent(player)
                    advice = Self.advice(for: player, star: Standing.of(Double(curve.peak(player)), against: others) == .strong, talent: talent, passing: middle, curve: curve)
                }

                let out = player.injury == nil ? 0 : session.checks.daysOut(player)
                if out >= 21 { warnings.append("Out for \(out) days") }
                if player.pos[slot.position] < 15 { warnings.append("Not a natural here") }
                if player.age >= 32 { warnings.append("Age \(player.age)") }
                if !player.loanClub.isEmpty {
                    let until = player.loanEnd.map { " until \(NetFormat.monthYear($0))" } ?? ""
                    warnings.append("On loan from \(player.club)\(until)")
                } else if let end = player.contractEnd, end <= today.addingOneYear {
                    warnings.append("Contract ends \(NetFormat.monthYear(end))")
                }
            }
            if lacksCover {
                warnings.append("No real cover")
                noCover += 1
            }
            if standing < .unknown { weak += 1 }
            // Only a future star is worth planning around: anyone less wouldn't be blocked by a signing.
            let star = !display.showsAbility ? nil : comingThrough.first {
                Self.fits($0, group) && curve.peak($0) > slot.player?.ca ?? 0 && Standing.of(Double(curve.peak($0)), against: others) == .strong
                    && curve.talent($0)?.verdict != .unlikely
            }
            if outlook == nil, let star {
                comingThrough.removeAll { $0.uid == star.uid }
                let name = Self.surname(star)
                let at = star.loanClub.isEmpty ? "" : ", on loan at \(star.loanClub)"
                outlook = "Coming through: \(name) (\(star.age)\(at)), heading for \(place(curve.peak(star))) of \(others.count + 1)"
                advice = "With \(name) coming through, think short term."
                talent = curve.talent(star)
            }

            let detail = [slot.player.map { $0.age >= 0 ? "Age \($0.age)" : "" } ?? "", rank, "Cover: \(coverText)"].filter { !$0.isEmpty }.joined(separator: " · ")
            rows.append(OverviewRow(id: id, group: Self.group(slot.position), place: slot.label, person: slot.player, name: slot.player?.name ?? "Nobody picked",
                                    score: stars > 0 ? RoleBook.stars(stars) : "", detail: detail, warning: warnings.isEmpty ? nil : warnings.joined(separator: " · "),
                                    standing: standing, lookup: .signing(position: slot.position), searches: standing != .strong || !warnings.isEmpty,
                                    outlook: outlook, advice: advice, talent: talent.map(Self.talentText), talentTone: talent?.verdict.tone ?? .text))
            places.append(Place(id: id, slot: slot, stars: stars, cover: coverText, standing: standing))
            slots[id] = (slot, stars, rated?.score ?? 0)
        }
        self.rows = rows
        self.places = places
        self.slots = slots

        let name = league.isEmpty ? "the league" : league
        let work = rows.filter(\.needsWork).count
        let standard = weak == 0 ? "none below \(name)'s standard" : weak == work ? "all below \(name)'s standard" : "\(weak) below \(name)'s standard"
        let summary = work == 0 ? "Every place stands up to \(name)" : work == 1 ? "1 place needs work (\(weak == 1 ? "below \(name)'s standard" : "still up to \(name)'s standard"))" : "\(work) places need work, \(standard)"
        var parts: [String] = []
        if growing > 0 { parts.append(growing == 1 ? "1 young player is still developing" : "\(growing) young players are still developing") }
        parts.append(noCover == 0 ? "every place has its own cover" : noCover == 1 ? "1 has no real cover" : "\(noCover) have no real cover")
        var headline = summary + ". " + parts.joined(separator: " and ").capitalizedFirst + "."
        if let budget = session.budget {
            headline += " \(units.moneyText(Double(budget.transfer))) to spend, \(units.wageText(budget.wageRoom, suffix: true)) wage room."
        }
        self.headline = headline
        footnote = "Ranked by ability against the same place at the other \(league.isEmpty ? "league" : league) clubs. Stars are FM's. Cover is your best second eleven.\(display.showsAbility ? " Projections and odds come from how players of the same age, PA and mentality have turned out across this save: PA is a ceiling, not a promise, and it takes minutes to get there." : "") Each pick fits your budget on the wage they earn now."
    }

    static func surname(_ player: Player) -> String {
        player.name.split(separator: " ").last.map(String.init) ?? player.name
    }

    private static func fits(_ player: Player, _ group: SquadPlanner.Group?) -> Bool {
        group.map { SquadPlanner.main(player) == $0 } ?? false
    }

    private static func talentText(_ talent: DevelopmentCurve.Talent) -> String {
        "\(talent.verdict.title): \(talent.mentality)\(talent.injuryProne ? ", injury-prone" : ""). \(talent.odds) like this get close to their PA."
    }

    /// Wait or buy. Only a future star is worth waiting for, and then it depends how soon they pass the league's middle.
    private static func advice(for player: Player, star: Bool, talent: DevelopmentCurve.Talent?, passing middle: Int, curve: DevelopmentCurve) -> String {
        let name = surname(player)
        if talent?.verdict == .unlikely, player.ca < middle { return "The PA looks better than the odds. Don't hold a place for \(name)." }
        guard star else {
            return player.ca >= middle ? "Good enough and still improving." : "Likely mid-table here at peak, so buying better is fine."
        }
        if player.ca >= middle { return "Already good enough and still improving. Keep \(name) in the team." }
        let ages = (player.age + 1)...max(player.age + 1, DevelopmentCurve.peakAge)
        guard let age = ages.first(where: { curve.expected(player, atAge: $0) >= middle }) else { return "Keep \(name) in the team." }
        if age <= player.age + 2 { return "Keep \(name) in the team: on course to pass the league's middle by \(age)." }
        return "\(name) may need until \(age) to pass the league's middle, so a stop-gap could help."
    }

    public func search(_ row: OverviewRow, taken: inout Set<UInt32>, isCancelled: () -> Bool) -> OverviewResult? {
        guard let entry = slots[row.id] else { return .nobody("") }
        guard session.checks.canCheckInterest, let budget = session.budget else { return .nobody("The game couldn't say who'd join") }
        let slot = entry.slot
        let club = session.club.name
        let floor = slot.player?.ca ?? max(1, level - 12)
        let excluded = taken
        let candidates = session.db.players.filter {
            $0.block != 0 && $0.clubFull != club && $0.loanClubFull != club && !$0.notForSale && $0.ca >= floor && Self.signingAges.contains($0.age)
                && $0.pos[slot.position] >= 15 && $0.wage <= budget.wageRoom && !excluded.contains($0.uid)
        }.stableSorted { $0.ca != $1.ca ? $0.ca > $1.ca : $0.pa > $1.pa }

        var found: [(player: Player, rating: RoleBook.Rating, loan: Bool)] = []
        for batch in candidates.prefix(Self.deepest).chunked(Self.batchSize) {
            if isCancelled() { return nil }
            guard let answers = session.checks.check(batch: batch) else { return .nobody("The game couldn't say who'd join") }
            for (index, player) in batch.enumerated() {
                guard let answer = answers[index] else { continue }
                let fee = player.club.isEmpty ? 0 : player.value
                let transfer = answer.transfer && fee <= budget.transfer
                guard transfer || answer.loan, let rating = book.rate(player, in: slot) else { continue }
                if rating.score > entry.score, rating.combined >= entry.stars { found.append((player, rating, !transfer)) }
            }
            if found.count >= Self.enough { break }
        }
        guard let best = found.max(by: { $0.rating.score < $1.rating.score }) else { return .nobody("Nobody better would join within budget") }
        taken.insert(best.player.uid)

        let player = best.player
        let display = session.display
        let units = display.units
        let halves = best.rating.combined - entry.stars
        let gain = entry.stars == 0 ? "New" : halves > 0 ? "+" + NetFormat.fixed(Double(halves) / 2, min: 0, max: 1) + "★" : "Better fit"
        let price = best.loan ? "Loan" : player.club.isEmpty ? "" : units.money(player.value)
        // A free agent has no wage to read, so what they'd ask for is anyone's guess.
        let wage = player.club.isEmpty ? "Wage to agree" : units.wageText(player.wage, suffix: true)
        let details = [player.club.isEmpty ? "Free agent" : player.club, player.age >= 0 ? "Age \(player.age)" : "",
                       display.showsAbility ? "CA \(display.ability(player.ca)), PA \(display.ability(player.pa))" : "", price, wage]
        return .hire(OverviewHire(person: player, name: player.name, score: RoleBook.stars(best.rating.combined), gain: gain,
                                  detail: details.filter { !$0.isEmpty }.joined(separator: " · ")))
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
