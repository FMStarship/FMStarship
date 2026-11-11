import Foundation
import StarshipCore

public struct BargainOptions {
    public enum Kind: Int, CaseIterable {
        case ending, free, clause, listed, wonderkid

        public var title: String {
            switch self {
            case .ending: return "Contracts ending"
            case .free: return "Free agents"
            case .clause: return "Release clauses"
            case .listed: return "Transfer-listed"
            case .wonderkid: return "Wonderkids"
            }
        }

        var shortlistName: String {
            switch self {
            case .ending: return "contracts ending"
            case .free: return "free agents"
            case .clause: return "release clauses"
            case .listed: return "transfer-listed"
            case .wonderkid: return "wonderkids"
            }
        }
    }

    public var kind: Kind
    /// Index into `Names.positions`, or -1 for "Any".
    public var position: Int
    /// The text boxes as typed; what doesn't parse is ignored.
    public var minCA: String
    public var maxAge: String
    public var maxFee: String
    public var onlyJoin: Bool

    public init(kind: Kind = .ending, position: Int = -1, minCA: String = "", maxAge: String = "", maxFee: String = "",
                onlyJoin: Bool = true) {
        self.kind = kind
        self.position = position
        self.minCA = minCA
        self.maxAge = maxAge
        self.maxFee = maxFee
        self.onlyJoin = onlyJoin
    }
}

/// Contracts running out, free agents, release clauses, the transfer list and wonderkids: `BargainForm`.
public struct BargainFinder {
    public static let positionChoices = ["Any"] + Names.positions
    public static let positionLabel = "Position"
    public static let minCALabel = "CA from"
    public static let maxAgeLabel = "Age up to"
    public static let maxFeeLabel = "Max fee"
    public static let onlyJoinLabel = "Only players who'd join"
    public static let saveButton = "Save as FM shortlist"

    private static let wanted = 25
    private static let unfiltered = 50
    private static let batchSize = 48

    private let session: AnalysisSession
    private let myNation: String
    public let seasonEnd: Date

    public init(session: AnalysisSession) {
        self.session = session
        myNation = session.db.players.first { $0.clubFull == session.club.name }?.clubNation ?? ""
        let calendar = GameDate.calendar
        let today = calendar.dateComponents([.year, .month], from: session.today)
        let year = (today.month ?? 1) <= 6 ? today.year : (today.year ?? 0) + 1
        seasonEnd = calendar.date(from: DateComponents(year: year, month: 6, day: 30)) ?? session.today
    }

    public var title: String { "Bargain finder for \(session.club.name) - FM Starship" }
    public var maxFeePlaceholder: String { session.display.units.symbol + "M" }
    /// "Only players who'd join" can only be ticked when this is true.
    public var onlyJoinEnabled: Bool { session.checks.canCheckInterest }

    /// The max-fee box starts at the transfer budget.
    public var startingMaxFee: String {
        guard let budget = session.budget?.transfer, budget > 0 else { return "" }
        return NetFormat.fixed(Double(budget) * session.display.units.perPound / 1_000_000, min: 0, max: 1, truncating: true)
    }

    public func shortlistName(_ options: BargainOptions) -> String { "Bargains - " + options.kind.shortlistName }

    public func columns(for kind: BargainOptions.Kind) -> [TableColumn] {
        let special: String
        switch kind {
        case .ending: special = "Contract ends"
        case .clause: special = "Release clause"
        case .listed: special = "Listed since"
        case .wonderkid: special = "Room to grow"
        case .free: special = "Last club"
        }
        let value = kind == .ending ? "Value now" : kind == .clause ? "Saving" : "Value"
        var columns = [
            TableColumn("Name", 17), TableColumn("Age", 5), TableColumn("Position", 11, order: .playerPosition), TableColumn("Club", 15),
            TableColumn("CA", 6), TableColumn("PA", 6), TableColumn(special, 11), TableColumn(value, 9),
            TableColumn("Wage", 9), TableColumn("Would join on", 10),
        ]
        if kind == .wonderkid {
            columns.insert(TableColumn(session.display.showHidden ? "Drive (hidden)" : "Personality", 22), at: 9)
        }
        return columns
    }

    /// The cheapest clause that applies to a buyer from `nation`, or 0.
    static func clause(for person: Person, nation: String) -> Int64 {
        let domestic = !person.clubNation.isEmpty && person.clubNation == nation
        let local = domestic ? person.releaseDomestic : person.releaseForeign
        return [person.releaseClause, local].filter { $0 > 0 }.min() ?? 0
    }

    private func fee(_ player: Player, _ kind: BargainOptions.Kind) -> Int64 {
        if player.club.isEmpty { return 0 }
        return kind == .clause ? BargainFinder.clause(for: player, nation: myNation) : player.value
    }

    private func drive(_ player: Player) -> (text: String, score: Int) {
        guard session.display.showHidden else { return (player.personality, 0) }
        let professionalism = player.p("Professionalism"), ambition = player.p("Ambition")
        let determination = player.a("Determination")
        let score = (professionalism + ambition + determination) / 3
        let word = score >= 15 ? "likely" : score >= 11 ? "should develop" : "may fall short"
        return ("\(word): Pro \(professionalism) Amb \(ambition) Det \(determination)", score)
    }

    /// Nil when cancelled.
    public func find(_ options: BargainOptions, isCancelled: () -> Bool = { false },
                     status: (String) -> Void = { _ in }) -> AnalysisTable? {
        let kind = options.kind
        let showsAbility = session.display.showsAbility
        guard kind != .wonderkid || showsAbility else {
            return session.display.fit(AnalysisTable(columns: columns(for: kind),
                                                     head: "Wonderkids are picked on PA, which is off. \(session.display.abilityHint) to see them."))
        }
        let club = session.club.name
        let units = session.display.units
        let join = options.onlyJoin && onlyJoinEnabled
        let minCA = showsAbility ? parseInvariantInt(options.minCA) : nil
        let maxAge = parseInvariantInt(options.maxAge)
        let maxFee = units.feeLimit(options.maxFee)
        status(join ? "Finding bargains who'd join you..." : "Finding bargains...")

        var found = session.db.players.filter { $0.block != 0 && $0.ca > 0 && $0.clubFull != club && session.canSign($0) }
        if options.position >= 0 { found = found.filter { $0.isNatural(at: options.position) } }
        if let minCA { found = found.filter { $0.ca >= minCA } }
        if let maxAge {
            found = found.filter { $0.age >= 0 && $0.age <= maxAge }
        } else if kind == .wonderkid {
            found = found.filter { $0.age >= 0 && $0.age <= 21 }
        }

        switch kind {
        case .ending:
            found = found.filter {
                guard !$0.club.isEmpty, $0.loanClub.isEmpty, let end = $0.contractEnd else { return false }
                return end <= seasonEnd
            }
        case .free:
            found = found.filter { $0.club.isEmpty }
        case .clause:
            found = found.filter {
                guard !$0.club.isEmpty else { return false }
                let clause = BargainFinder.clause(for: $0, nation: myNation)
                return clause > 0 && ($0.notForSale || clause < $0.value)
            }
        case .wonderkid:
            found = found.filter { $0.pa > $0.ca }
        case .listed:
            found = found.filter { !$0.club.isEmpty && $0.transferListed }
        }

        if let maxFee, kind != .ending { found = found.filter { !(Double(fee($0, kind)) > maxFee) } }

        switch kind {
        case .clause:
            let saving: (Player) -> Int64 = {
                ($0.notForSale ? $0.value * 2 : $0.value) - BargainFinder.clause(for: $0, nation: myNation)
            }
            found = found.stableSorted { $0.ca != $1.ca ? $0.ca > $1.ca : saving($0) > saving($1) }
        case .wonderkid:
            found = found.stableSorted { $0.pa != $1.pa ? $0.pa > $1.pa : $0.ca > $1.ca }
        default:
            found = found.stableSorted { $0.ca != $1.ca ? $0.ca > $1.ca : $0.pa > $1.pa }
        }

        var shown: [Player] = []
        var interestChecked = true
        if join {
            var seen = 0
            for batch in found.chunked(BargainFinder.batchSize) {
                if isCancelled() { return nil }
                guard let answers = session.checks.check(batch: batch) else {
                    interestChecked = false
                    shown = Array(found.prefix(BargainFinder.unfiltered))
                    break
                }
                seen += batch.count
                for (index, player) in batch.enumerated() {
                    if shown.count >= BargainFinder.wanted { break }
                    if answers[index]?.transfer == true { shown.append(player) }
                }
                if shown.count >= BargainFinder.wanted { break }
                status("Checking who'd join \(club): \(NetFormat.grouped(seen)) players checked, \(shown.count) would join so far...")
            }
        } else {
            shown = Array(found.prefix(BargainFinder.unfiltered))
            interestChecked = !options.onlyJoin || onlyJoinEnabled
        }

        var table = AnalysisTable(columns: columns(for: kind), interestChecked: interestChecked)
        table.rows = shown.map { row($0, kind: kind) }

        let what: String
        switch kind {
        case .wonderkid: what = "wonderkids (" + (maxAge.map { "up to \($0)" } ?? "21 and under") + "), highest potential first"
        case .ending: what = "players whose contracts end by \(NetFormat.dayMonthYear(seasonEnd)) (free then, or cheap now)"
        case .free: what = "free agents"
        case .clause: what = "players with a release clause below their value (or the only way to buy them)"
        case .listed: what = "transfer-listed players"
        }
        table.status = shown.isEmpty
            ? "Nobody found with these settings - try another position\(showsAbility ? ", a lower CA" : "") or a higher max fee."
            : "\(shown.count) \(what)\(join && interestChecked ? " who'd join \(club)" : ""), best first. Double-click for the full profile."
        return session.display.fit(table)
    }

    private func row(_ p: Player, kind: BargainOptions.Kind) -> TableRow {
        let units = session.display.units
        let joinOn = joinText(session.checks.known(p))
        let clause = BargainFinder.clause(for: p, nation: myNation)

        var special = ""
        var specialKey = SortKey.text("")
        switch kind {
        case .ending:
            special = p.contractEnd.map(NetFormat.numericDate) ?? ""
            specialKey = .date(p.contractEnd ?? .distantFuture)
        case .clause:
            special = units.money(clause)
            specialKey = .number(clause)
        case .listed:
            special = p.listedDate.map(NetFormat.numericDate) ?? ""
            specialKey = .date(p.listedDate ?? .distantFuture)
        case .wonderkid:
            special = "+\(p.pa - p.ca)"
            specialKey = .number(Int64(p.pa - p.ca))
        case .free:
            break
        }

        let onlyViaClause = kind == .clause && p.notForSale
        let saving = kind == .clause && !p.notForSale ? p.value - clause : p.value
        let valueText: String
        if kind == .clause {
            valueText = p.notForSale ? "only via clause" : units.money(saving)
        } else {
            valueText = p.club.isEmpty ? "—" : p.notForSale ? "Not for sale" : units.money(p.value)
        }

        var cells = [
            p.name, p.age >= 0 ? "\(p.age)" : "", p.bestPositions, p.club.isEmpty ? "Free agent" : p.club,
            session.display.ability(p.ca), session.display.ability(p.pa), special, valueText,
            p.club.isEmpty ? "to agree" : units.wageText(p.wage), joinOn,
        ]
        var keys: [SortKey] = [
            .text(p.name), .number(Int64(p.age)), .text(p.bestPositions), .text(p.club), .number(Int64(p.ca)),
            .number(Int64(p.pa)), specialKey, .number(onlyViaClause ? Int64.max : saving), .number(Int64(p.wage)), .text(joinOn),
        ]
        if kind == .wonderkid {
            let (text, score) = drive(p)
            cells.insert(text, at: 9)
            keys.insert(.number(Int64(score)), at: 9)
        }
        return TableRow(cells: cells, sortKeys: keys, person: p)
    }

    private func joinText(_ answer: JoinAnswer?) -> String {
        guard let answer else { return "" }
        if answer.transfer { return answer.loan ? "Transfer or loan" : "Transfer" }
        return answer.loan ? "Loan" : "No"
    }
}
