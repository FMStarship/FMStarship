import Foundation
import StarshipCore

/// The club at a glance, the first thing after Load Save: what you have to work with, who's coming through, and
/// what the health check wants done now.
public struct ClubDashboard {
    public struct Fact: Identifiable {
        public let label: String
        public let value: String
        public var id: String { label }
    }

    /// A young player's whole story. The numbers are nil while ability is hidden.
    public struct Prospect: Identifiable {
        public let player: Player
        public let now: Int
        public let peak: Int
        public let potential: Int
        public let verdict: DevelopmentCurve.Talent.Verdict?
        public let odds: String?
        /// "117 → 147", in whatever way ability is being shown.
        public let path: String
        public var id: UInt32 { player.uid }
    }

    public struct Issue: Identifiable {
        public let id: Int
        public let person: Person?
        public let name: String
        public let issue: String
        public let detail: String
        public let tone: Tone
    }

    /// Enough to fill a panel without it taking over.
    private static let prospectsShown = 6
    private static let issuesShown = 5
    private static let oldestProspect = 23

    public let club: String
    public let line: String
    public let facts: [Fact]
    public let prospects: [Prospect]
    /// What every `RangeBar` is drawn against, so one player's bar can be read against the next.
    public let scale: ClosedRange<Int>
    public let showsAbility: Bool
    public let issues: [Issue]
    /// How many the health check wants acted on, of which `issues` shows the first few.
    public let actions: Int

    public init(session: AnalysisSession) {
        let name = session.club.name
        let display = session.display
        let units = display.units
        let squad = session.db.players.filter { $0.clubFull == name && $0.block != 0 && $0.ca > 0 }
        let firstTeam = squad.filter { $0.loanClub.isEmpty && ($0.squad == "First team" || $0.squad.isEmpty) }
        club = name

        let league = firstTeam.first?.league ?? squad.first?.league ?? ""
        line = [league, NetFormat.dayMonthYear(session.today)].filter { !$0.isEmpty }.joined(separator: " · ")

        var facts: [Fact] = []
        if let budget = session.budget {
            facts.append(Fact(label: "Transfer budget", value: units.moneyText(Double(budget.transfer))))
            facts.append(Fact(label: "Wage room", value: units.wageText(budget.wageRoom, suffix: true)))
        }
        if !firstTeam.isEmpty {
            facts.append(Fact(label: "First team", value: "\(firstTeam.count) players"))
            let aged = firstTeam.filter { $0.age >= 0 }
            if !aged.isEmpty {
                let average = Double(aged.reduce(0) { $0 + $1.age }) / Double(aged.count)
                facts.append(Fact(label: "Average age", value: NetFormat.fixed(average, min: 1, max: 1)))
            }
            if display.reveal != .hidden {
                facts.append(Fact(label: "Best eleven", value: "CA \(display.ability(AnalysisSession.level(of: SquadPlanner.analysedSquad(session))))"))
            }
        }
        self.facts = facts

        let curve = session.development
        showsAbility = display.reveal != .hidden
        let young = squad.filter { $0.age >= 0 && $0.age <= Self.oldestProspect }.stableSorted { curve.peak($0) > curve.peak($1) }.prefix(Self.prospectsShown)
        prospects = young.map { player in
            let peak = curve.peak(player)
            let talent = curve.talent(player)
            return Prospect(player: player, now: display.shown(player.ca), peak: display.shown(peak), potential: display.shown(player.pa), verdict: talent?.verdict, odds: talent?.odds,
                            path: "\(display.ability(player.ca)) → \(display.ability(peak))")
        }
        let bottom = (young.map { display.shown($0.ca) }.min() ?? 0) - 15
        scale = max(0, bottom)...max(max(0, bottom) + 1, young.map { display.shown($0.pa) }.max() ?? 200)

        let health = ClubReport(session: session).health()
        let wanted = health.rows.indices.filter { [Tone.bad, .fair].contains(health.rows[$0].tone) }
        actions = wanted.filter { health.rows[$0].tone == .bad }.count
        // The ones to act on come first in the report already.
        issues = wanted.prefix(Self.issuesShown).map { index in
            let row = health.rows[index]
            return Issue(id: index, person: row.person, name: row.cells[0], issue: row.cells[4], detail: row.cells[5], tone: row.tone ?? .text)
        }
    }

    /// One sentence on what needs you. Nil rows are reports that haven't arrived yet, or need the live game.
    public static func headline(team: [OverviewRow]?, emptyPlaces: Int, actions: Int) -> String {
        var parts: [String] = []
        if let team {
            let count = team.filter(\.needsWork).count
            if count > 0 { parts.append(count == 1 ? "1 place in your team needs work" : "\(count) places in your team need work") }
        }
        if emptyPlaces > 0 { parts.append(emptyPlaces == 1 ? "1 backroom place is empty" : "\(emptyPlaces) backroom places are empty") }
        if actions > 0 { parts.append(actions == 1 ? "1 player needs action now" : "\(actions) players need action now") }
        guard let last = parts.popLast() else { return "Nothing needs you right now." }
        return (parts.isEmpty ? last : parts.joined(separator: ", ") + " and " + last) + "."
    }
}
