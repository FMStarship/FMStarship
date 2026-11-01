import Foundation
import StarshipCore

/// The one question `GameRulesEngine.roleRows(player:team:)` can't answer: `RoleState.Table` rates a
/// player at a chosen position. An engine that can do that adopts this as well.
public protocol PositionalRoleEngine: AnyObject {
    func roleRows(player: Player, position: Int, team: Int64) -> [RoleRow]?
}

/// Side-by-side comparison of two or more people: `CompareForm`.
public struct CompareReport {
    public enum Value: Equatable {
        case none
        case text(String)
        case int(Int)
        case double(Double)

        fileprivate var number: Double? {
            switch self {
            case let .int(value): return Double(value)
            case let .double(value): return value
            default: return nil
            }
        }
    }

    public struct Row {
        public let label: String
        /// Nil on a section heading.
        public let values: [Value]?
        public let hidden: Bool
        public let compare: Bool
        public let lowIsBetter: Bool
        public let stars: Bool
        /// The cells as shown, one per person.
        public let cells: [String]
        /// Which cells are the best in the row: green and bold.
        public let best: [Bool]

        public var isSection: Bool { values == nil }
    }

    public static let rolePositionLabel = "Role stars at"
    public static let saveButton = "Save as FM shortlist"
    public static let shortlistName = "Compare"

    private static let lowBetter: Set<String> = ["Injury Proneness", "Dirtiness", "Controversy"]

    private let session: AnalysisSession
    public let people: [Person]

    public init(people: [Person], session: AnalysisSession) {
        self.people = people
        self.session = session
    }

    public var title: String { "Compare: " + people.map(\.name).joined(separator: " vs ") + " - FM Starship" }

    /// Role stars are only offered when everyone compared is a player.
    public var offersRoles: Bool { !people.isEmpty && people.allSatisfy { $0 is Player } }

    /// The position everyone suits best: the highest of each position's lowest rating.
    public var startingRolePosition: Int {
        var best = 0
        var rating = -1
        for i in 0..<15 {
            let lowest = people.compactMap { ($0 as? Player).map { Int($0.pos[i]) } }.min() ?? 0
            if lowest > rating {
                rating = lowest
                best = i
            }
        }
        return best
    }

    private func abilityValue(_ value: Int) -> Value {
        switch session.display.reveal {
        case .stars: return .double(session.display.abilityStars(value))
        case .hidden: return .text("-")
        case .numbers: return .int(value)
        }
    }

    private func cell(_ value: Value, label: String, stars: Bool) -> String {
        switch value {
        case .none: return ""
        case let .text(text): return text
        case let .int(number): return "\(number)"
        case let .double(number):
            if stars || (session.display.reveal == .stars && label.hasSuffix("ability")) {
                return NetFormat.fixed(number, min: 1, max: 1) + "★"
            }
            return NetFormat.fixed(number, min: 0, max: 1)
        }
    }

    private func makeRow(_ label: String, _ values: [Value]?, hidden: Bool = false, compare: Bool, lowIsBetter: Bool = false,
                         stars: Bool = false) -> Row {
        guard let values else {
            return Row(label: label, values: nil, hidden: hidden, compare: compare, lowIsBetter: lowIsBetter, stars: stars, cells: [], best: [])
        }
        var best = [Bool](repeating: false, count: values.count)
        if compare {
            let numbers = values.map(\.number)
            let known = numbers.compactMap { $0 }
            if known.count >= 2, Set(known).count >= 2, let top = lowIsBetter ? known.min() : known.max() {
                best = numbers.map { $0 == top }
            }
        }
        return Row(label: label, values: values, hidden: hidden, compare: compare, lowIsBetter: lowIsBetter, stars: stars,
                   cells: values.map { cell($0, label: label, stars: stars) }, best: best)
    }

    private func each(_ f: (Person) -> Value) -> [Value] { people.map(f) }

    private func eachPlayer(_ f: (Player) -> Value) -> [Value] {
        people.map { ($0 as? Player).map(f) ?? .none }
    }

    private func eachStaff(_ f: (Staff) -> Value) -> [Value] {
        people.map { ($0 as? Staff).map(f) ?? .none }
    }

    private func season(_ f: (SeasonStats) -> Value) -> [Value] {
        eachPlayer { $0.season.map(f) ?? .none }
    }

    /// Everything but the role stars, which take longer and come from `roleRows(position:)`.
    public func rows() -> [Row] {
        guard let first = people.first else { return [] }
        let checks = session.checks
        let units = session.display.units
        let showHidden = session.display.showHidden
        var rows: [Row] = []

        if GameRules.engine != nil {
            for p in people.compactMap({ $0 as? Player }) where checks.known(p) == nil { _ = checks.check(p) }
            checks.checkAllStaff(people.compactMap { $0 as? Staff })
        }

        func section(_ label: String) { rows.append(makeRow(label, nil, compare: true)) }
        func text(_ label: String, _ values: [Value]) { rows.append(makeRow(label, values, compare: false)) }
        func number(_ label: String, _ values: [Value], hidden: Bool = false) {
            rows.append(makeRow(label, values, hidden: hidden, compare: true, lowIsBetter: CompareReport.lowBetter.contains(label)))
        }
        func goodLow(_ label: String, _ values: [Value]) {
            rows.append(makeRow(label, values, compare: true, lowIsBetter: true))
        }
        func group(_ label: String, _ names: [String]) {
            section(label)
            for name in names { number(name, eachPlayer { .int($0.a(name)) }) }
        }
        func staffGroup(_ label: String, _ names: [String]) {
            section(label)
            for name in names {
                number(name.replacingOccurrences(of: "Coaching ", with: ""), eachStaff { .int($0.a(name)) })
            }
        }

        section("Facts")
        text("Age", each { $0.age >= 0 ? .int($0.age) : .none })
        text("Club", each {
            if $0.club.isEmpty { return .text("Free agent") }
            return .text($0.loanClub.isEmpty ? $0.club : "\($0.club) (on loan at \($0.loanClub))")
        })
        text("Nation", each { .text($0.nation) })

        if first is Player {
            text("Positions", eachPlayer { .text($0.bestPositions) })
            text("Height", eachPlayer { .text($0.height > 0 ? units.heightText($0.height) : "") })
            if session.display.showsAbility {
                number("Current ability", eachPlayer { abilityValue($0.ca) })
                number("Potential ability", eachPlayer { abilityValue($0.pa) })
            }
            text("Value", eachPlayer {
                .text($0.club.isEmpty ? "Free" : $0.notForSale ? "Not for sale" : units.money($0.value))
            })
            text("Interest", eachPlayer {
                let answer = checks.text($0)
                return .text(answer.isEmpty ? "-" : answer)
            })
            text("Injury", eachPlayer {
                guard $0.injury != nil else { return .text("Fit") }
                let days = checks.injuryKnown($0) ?? checks.injuryCheck($0)
                return .text($0.injuryText + (days.map { $0 > 0 ? " (\($0) days)" : "" } ?? ""))
            })
        } else {
            text("Job", eachStaff { .text($0.job) })
            if session.display.showsAbility {
                number("Current ability", eachStaff { abilityValue($0.ca) })
                number("Potential ability", eachStaff { abilityValue($0.pa) })
            }
            text("Interest", eachStaff {
                let answer = checks.staffText($0)
                return .text(answer.isEmpty ? "-" : answer)
            })
        }

        text("Wage", each { .text($0.wage > 0 ? units.wageText($0.wage, suffix: true) : "-") })
        text("Contract ends", each { .text($0.contractEnd.map(NetFormat.numericDate) ?? "-") })

        let clauses: [Int64] = people.map { [$0.releaseClause, $0.releaseForeign, $0.releaseDomestic].filter { $0 > 0 }.min() ?? 0 }
        if clauses.contains(where: { $0 > 0 }) {
            text("Release clause", clauses.map { .text($0 > 0 ? units.money($0) : "-") })
        }
        text("Personality", each { .text($0.personality) })

        if first is Player {
            let players = people.compactMap { $0 as? Player }
            for player in players { checks.ensureSeason(player) }
            let goalkeeper = players.contains { $0.pos[0] >= 10 }

            if players.contains(where: { $0.season != nil }) {
                section("This season (club)")
                text("Appearances", season { .text($0.appsText) })
                number("Minutes", season { .int($0.minutes) })
                number("Goals", season { .int($0.goals) })
                number("Assists", season { .int($0.assists) })
                number("Average rating", season { $0.rating > 0 ? .double($0.ratingShown) : .none })
                number("Player of the Match", season { .int($0.playerOfTheMatch) })
                number("Goals per 90", season { $0.minutes > 0 ? .double(roundedEven($0.per90($0.goals), digits: 2)) : .none })
                number("Expected goals", season { .double(roundedEven($0.xG, digits: 1)) })
                number("Expected assists", season { .double(roundedEven($0.xA, digits: 1)) })
                number("Pass completion %", season { .int($0.passPercent) })
                number("Tackles won", season { .int($0.tackles) })
                number("Dribbles", season { .int($0.dribbles) })
                if goalkeeper {
                    number("Clean sheets", season { .int($0.cleanSheets) })
                    goodLow("Goals conceded", season { .int($0.conceded) })
                }
                goodLow("Yellow cards", season { .int($0.yellow) })
                goodLow("Red cards", season { .int($0.red) })
                text("Form (last 5)", eachPlayer { .text($0.form.isEmpty ? "-" : $0.form) })
            }

            group("Technical", Names.technical)
            group("Mental", Names.mental)
            group("Physical", Names.physical + ["Left Foot", "Right Foot"])
            if goalkeeper { group("Goalkeeping", Names.goalkeeping) }

            if showHidden {
                section("Hidden")
                for name in Names.hidden { number(name, eachPlayer { .int($0.a(name)) }, hidden: true) }
                for name in Names.personality { number(name, each { .int($0.p(name)) }, hidden: true) }
            }
        } else {
            staffGroup("Coaching", [
                "Coaching Attacking", "Coaching Defending", "Coaching Fitness", "Coaching Goalkeepers", "GK Handling", "GK Distribution",
                "Coaching Possession", "Coaching Set Pieces", "Coaching Tactical", "Coaching Technical", "Working With Youngsters",
            ])
            staffGroup("Mental & knowledge", [
                "Determination", "Level Of Discipline", "Motivating", "Man Management", "Judging Player Ability",
                "Judging Player Potential", "Judging Staff Ability", "Tactical Knowledge", "Analysing Data", "Negotiating",
            ])
            staffGroup("Medical", ["Physiotherapy", "Sports Science"])
            section("Training areas (stars)")
            for area in 0..<9 {
                let stars: [Value] = eachStaff { StaffRoles.starText($0, area).map { .double($0) } ?? .none }
                rows.append(makeRow(Names.areasLong[area], stars, compare: true, stars: true))
            }
            if showHidden {
                section("Hidden")
                var seen = Set(Names.staffShown)
                for name in Names.staffAttrs where seen.insert(name).inserted && !name.hasPrefix("Unnamed") {
                    number(name, eachStaff { .int($0.a(name)) }, hidden: true)
                }
                for name in Names.personality { number(name, each { .int($0.p(name)) }, hidden: true) }
            }
        }
        return rows
    }

    /// The status line when people are compared without role stars.
    public static let staffStatus = "Green = the best in that row. Double-click a name for the full profile."

    /// `RoleState.Table`, sorted as it sorts: in possession first, then by stars.
    private func table(_ player: Player, position: Int) -> [RoleRow]? {
        guard let engine = GameRules.engine else { return nil }
        let team = session.club.team != 0 ? session.club.team : session.db.humanClubs.first?.team ?? 0
        var rows: [RoleRow]?
        if let positional = engine as? PositionalRoleEngine {
            rows = positional.roleRows(player: player, position: position, team: team)
        } else if bestPosition(player) == position {
            rows = engine.roleRows(player: player, team: team)
        }
        return rows?.stableSorted { a, b in
            a.outOfPossession != b.outOfPossession ? !a.outOfPossession : a.maxHalfStars > b.maxHalfStars
        }
    }

    private func bestPosition(_ player: Player) -> Int {
        var best = 0
        for i in 1..<15 where player.pos[i] > player.pos[best] { best = i }
        return best
    }

    /// The "Roles at ..." rows for one position, and the status line to show with them.
    public func roleRows(position: Int) -> (rows: [Row], status: String) {
        guard GameRules.engine != nil else {
            return ([], "Role stars need the live game (press Load Save). Green = the best in that row.")
        }
        let tables = people.compactMap { $0 as? Player }.map { table($0, position: position) }
        guard tables.contains(where: { $0 != nil }) else { return ([], "Role stars couldn't be worked out here.") }

        var rows: [Row] = []
        for outOfPossession in [false, true] {
            let side = outOfPossession ? "out of possession" : "in possession"
            rows.append(makeRow("Roles at \(Names.positions[position]) - \(side)", nil, compare: true))

            var order: [String] = []
            var most: [String: Int] = [:]
            for row in tables.compactMap({ $0 }).joined() where row.outOfPossession == outOfPossession {
                if most[row.role] == nil { order.append(row.role) }
                most[row.role] = max(most[row.role] ?? 0, row.maxHalfStars)
            }
            for role in order.stableSorted(by: { (most[$0] ?? 0) > (most[$1] ?? 0) }) {
                let values: [Value] = tables.map { table in
                    table?.first { $0.role == role && $0.outOfPossession == outOfPossession }
                        .map { .double(Double($0.maxHalfStars) / 2) } ?? .none
                }
                rows.append(makeRow(role, values, compare: true, stars: true))
            }
        }
        return (rows, "Green = the best in that row. Role stars are the game's own. Double-click a name for the full profile.")
    }
}
