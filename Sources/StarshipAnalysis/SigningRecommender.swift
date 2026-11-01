import Foundation
import StarshipCore

public struct RecommendOptions {
    public enum Mode: Int, CaseIterable {
        case best, young, budget

        public var title: String {
            switch self {
            case .best: return "Best in class"
            case .young: return "Youngsters with promise"
            case .budget: return "Budget"
            }
        }

        var shortlistName: String {
            switch self {
            case .best: return "Best signings"
            case .young: return "Youngsters"
            case .budget: return "Budget signings"
            }
        }
    }

    public enum Show: Int, CaseIterable {
        case all, freeAgentsOnly, noFreeAgents

        public var title: String {
            switch self {
            case .all: return "All players"
            case .freeAgentsOnly: return "Free agents only"
            case .noFreeAgents: return "No free agents"
            }
        }
    }

    public var mode: Mode
    /// Index into `Names.positions`, or -1 for "Any".
    public var position: Int
    /// As typed: millions, with or without the currency symbol.
    public var maxFee: String
    public var show: Show
    public var includeLoans: Bool
    public var upgradesOnly: Bool

    public init(mode: Mode = .best, position: Int = -1, maxFee: String = "", show: Show = .all,
                includeLoans: Bool = false, upgradesOnly: Bool = true) {
        self.mode = mode
        self.position = position
        self.maxFee = maxFee
        self.show = show
        self.includeLoans = includeLoans
        self.upgradesOnly = upgradesOnly
    }
}

/// The ten best players who would actually join: `RecommendForm`.
public struct SigningRecommender {
    public static let columns = [
        TableColumn("#", 4), TableColumn("Name", 18), TableColumn("Age", 5), TableColumn("Position", 11),
        TableColumn("Club", 16), TableColumn("CA", 6), TableColumn("PA", 6), TableColumn("Value", 9),
        TableColumn("Wage", 9), TableColumn("Would join on", 10), TableColumn("vs your best", 9),
    ]
    public static let positionChoices = ["Any"] + Names.positions
    public static let positionLabel = "Position"
    public static let maxFeeLabel = "Max fee"
    public static let showLabel = "Show"
    public static let loansLabel = "Include loans"
    public static let upgradesLabel = "Upgrades only"
    public static let saveButton = "Save as FM shortlist"

    private static let wanted = 10
    private static let batchSize = 64

    private let session: AnalysisSession
    /// The highest CA at the club at each position, among those who play there.
    public let bestAt: [Int]

    public init(session: AnalysisSession) {
        self.session = session
        let club = session.club.name
        let squad = session.db.players.filter { $0.clubFull == club || $0.loanClubFull == club }
        bestAt = (0..<15).map { i in squad.filter { $0.pos[i] >= 15 }.map(\.ca).max() ?? 0 }
    }

    /// Youngsters are ranked on what they'll likely become, not on a PA most never reach.
    public static let youngColumns = [
        TableColumn("#", 4), TableColumn("Name", 17), TableColumn("Age", 4), TableColumn("Position", 10), TableColumn("Club", 14),
        TableColumn("CA", 5), TableColumn("PA", 5), TableColumn("Likely peak", 6), TableColumn("Odds", 13), TableColumn("Value", 8),
        TableColumn("Wage", 8), TableColumn("Would join on", 9), TableColumn("vs your best", 8),
    ]

    public var title: String { "Recommended signings for \(session.club.name) - FM Starship" }
    public var maxFeePlaceholder: String { session.display.units.symbol + "M" }

    public func shortlistName(_ options: RecommendOptions) -> String {
        options.mode.shortlistName + (options.position >= 0 ? " " + Names.positions[options.position] : "")
    }

    private func bestPosition(_ player: Player, _ options: RecommendOptions) -> Int {
        if options.position >= 0 { return options.position }
        let top = player.pos.max() ?? 0
        return player.pos.firstIndex(of: top) ?? 0
    }

    /// Nil when cancelled.
    public func find(_ options: RecommendOptions, isCancelled: () -> Bool = { false },
                     status: (String) -> Void = { _ in }) -> AnalysisTable? {
        status("Finding players who'd join you...")
        let club = session.club.name
        let units = session.display.units
        let position = options.position
        var fee = units.feeLimit(options.maxFee)
        if options.mode == .budget, fee == nil { fee = 1_000_000 }
        let curve = session.development

        var candidates = session.db.players.filter { $0.block != 0 && $0.clubFull != club && $0.loanClubFull != club && !$0.notForSale && $0.ca > 0 }
        if let fee { candidates = candidates.filter { !(Double($0.value) > fee) } }
        switch options.show {
        case .freeAgentsOnly: candidates = candidates.filter { $0.club.isEmpty }
        case .noFreeAgents: candidates = candidates.filter { !$0.club.isEmpty }
        case .all: break
        }
        if position >= 0 { candidates = candidates.filter { $0.pos[position] >= 15 } }
        if options.upgradesOnly {
            candidates = candidates.filter {
                let best = bestAt[bestPosition($0, options)]
                return $0.ca > best || (options.mode == .young && curve.peak($0) > best)
            }
        }
        if options.mode == .young {
            candidates = candidates.filter { $0.age >= 0 && $0.age <= 21 }
                .map { (player: $0, peak: curve.peak($0)) }
                .stableSorted { $0.peak != $1.peak ? $0.peak > $1.peak : $0.player.ca > $1.player.ca }
                .map(\.player)
        } else {
            candidates = candidates.stableSorted { $0.ca != $1.ca ? $0.ca > $1.ca : $0.pa > $1.pa }
        }

        var picks: [Player] = []
        var checked = 0
        var interestChecked = true
        for batch in candidates.chunked(SigningRecommender.batchSize) {
            if isCancelled() { return nil }
            guard let answers = session.checks.check(batch: batch) else {
                interestChecked = false
                break
            }
            checked += batch.count
            for (index, player) in batch.enumerated() {
                if picks.count >= SigningRecommender.wanted { break }
                if let answer = answers[index], answer.transfer || (options.includeLoans && answer.loan) {
                    picks.append(player)
                }
            }
            if picks.count >= SigningRecommender.wanted { break }
            if checked % 640 == 0 {
                status("Checked \(NetFormat.grouped(checked)) players, \(picks.count) would join so far...")
            }
        }
        if !interestChecked { picks = Array(candidates.prefix(SigningRecommender.wanted)) }

        let young = options.mode == .young
        var table = AnalysisTable(columns: young ? SigningRecommender.youngColumns : SigningRecommender.columns, interestChecked: interestChecked)
        for (index, p) in picks.enumerated() {
            let at = bestPosition(p, options)
            let joinOn = joinText(session.checks.known(p), includeLoans: options.includeLoans)
            let best = bestAt[at]
            let peak = curve.peak(p)
            let talent = curve.talent(p)
            let scouted = young ? [session.display.ability(peak), talent.map { "\($0.odds), \($0.verdict.title.lowercased())" } ?? ""] : []
            let cells = [
                "\(index + 1)",
                p.name,
                p.age >= 0 ? "\(p.age)" : "",
                p.bestPositions,
                p.club.isEmpty ? "Free agent" : p.club,
                session.display.ability(p.ca),
                session.display.ability(p.pa),
            ] + scouted + [
                p.club.isEmpty ? "Free" : p.value <= 0 ? "—" : units.money(p.value),
                units.wageText(p.wage),
                joinOn,
                best <= 0 ? "new" : "\(NetFormat.signed(p.ca - best)) (\(Names.positions[at]))",
            ]
            let scoutedKeys: [SortKey] = young ? [.number(Int64(peak)), .number(Int64(talent?.chance ?? 0))] : []
            let keys: [SortKey] = [
                .number(Int64(index + 1)), .text(p.name), .number(Int64(p.age)), .text(p.bestPositions), .text(p.club),
                .number(Int64(p.ca)), .number(Int64(p.pa)),
            ] + scoutedKeys + [
                .number(p.club.isEmpty ? 0 : p.value), .number(Int64(p.wage)), .text(joinOn), .number(Int64(p.ca - best)),
            ]
            table.rows.append(TableRow(cells: cells, sortKeys: keys, person: p))
        }

        if picks.isEmpty {
            table.status = "Nobody found who would join you with these settings - try a higher max fee, another position, or include loans."
        } else if interestChecked {
            table.status = "Top \(picks.count) who would join \(club). Double-click a player for the full profile."
        } else {
            table.status = "Top \(picks.count) for \(club). Whether they would join could not be checked. Double-click a player for the full profile."
        }
        return table
    }

    private func joinText(_ answer: JoinAnswer?, includeLoans: Bool) -> String {
        guard let answer else { return "" }
        guard includeLoans else { return "Transfer" }
        if answer.transfer { return answer.loan ? "Transfer or loan" : "Transfer" }
        return "Loan"
    }
}
