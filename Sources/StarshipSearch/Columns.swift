import Foundation
import StarshipCore

/// What a column holds for one person. The original boxed these in `object`.
public enum CellValue: Equatable {
    case empty
    case text(String)
    case int(Int)
    case double(Double)
    case date(Date)

    /// `ColumnFilter.V`: the number a numeric column filter compares. Dates compare by year.
    var filterNumber: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .date(let value): return Double(Net.year(value))
        case .empty, .text: return nil
        }
    }

    /// The number numeric columns sort by.
    var sortNumber: Double {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .date(let value): return value.timeIntervalSinceReferenceDate
        case .empty, .text: return .nan
        }
    }

    /// `Convert.ToString(value) ?? ""`.
    var plainText: String {
        switch self {
        case .empty: return ""
        case .text(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return Columns.plain(value)
        case .date(let value): return Net.dayMonthYear(value)
        }
    }
}

/// The CA/PA display mode: the "Reveal" list on the toolbar.
public enum Reveal: Int, CaseIterable {
    case exact = 0
    case stars = 1
    case hidden = 2

    public var title: String {
        switch self {
        case .exact: return "Exact"
        case .stars: return "Stars"
        case .hidden: return "Off"
        }
    }

    /// Clamped like the saved setting is on load.
    public init(setting: Int) { self = Reveal(rawValue: min(max(setting, 0), 2)) ?? .exact }
}

/// Semantic text colours, standing in for the original's theme colours.
public enum CellTone: String {
    case standard
    case text
    case muted
    case good
    case fair
    case bad
}

/// A cell ready to draw.
public struct Cell: Equatable {
    public var text: String
    public var tone: CellTone
    public var bold: Bool
    /// True for "Days out" while the answer still has to come from the game: call
    /// `RulesState.shared.injuryCheck` and redraw. The cell shows "…" meanwhile.
    public var pending: Bool
}

public struct Col: Identifiable {
    public let name: String
    public let group: String
    public var shortName: String?
    public var format: ((CellValue) -> String)?
    public let get: (Person) -> CellValue
    public let isDefault: Bool
    public let numeric: Bool
    public let hidden: Bool
    public let ability: Bool
    public var width: Int
    public var visible: Bool

    public var id: String { name }
    public var header: String { shortName ?? name }
    public var toolTip: String { name + (hidden ? " (hidden in the game)" : "") }

    fileprivate init(_ name: String, _ group: String, _ get: @escaping (Person) -> CellValue, isDefault: Bool,
                     numeric: Bool, width: Int, hidden: Bool = false, ability: Bool = false,
                     short: String? = nil, format: ((CellValue) -> String)? = nil) {
        self.name = name
        self.group = group
        self.get = get
        self.isDefault = isDefault
        self.numeric = numeric
        self.width = width
        self.hidden = hidden
        self.ability = ability
        self.shortName = short
        self.format = format
        self.visible = isDefault
    }

    /// The grid's `CellValue` and `CellFormatting` handlers for one cell.
    public func cell(_ person: Person, reveal: Reveal = .exact) -> Cell {
        var value = get(person)

        if value == .empty, name == "Days out", let player = person as? Player, player.injury != nil,
           GameRules.engine?.supportsInjuryDays == true {
            return Cell(text: "…", tone: .standard, bold: false, pending: true)
        }
        if ability, case .int(let number) = value {
            switch reveal {
            case .stars: value = .text(Columns.abilityStars(number))
            case .hidden: value = .text("-")
            case .exact: break
            }
        }

        // Formatted cells reach the styling below as text, so they never get attribute colours.
        var shown = value
        if let format {
            shown = .text(format(value))
        } else if value == .empty {
            shown = .text("—")
        }
        let style = self.style(for: shown)
        return Cell(text: shown.plainText, tone: style.tone, bold: style.bold, pending: false)
    }

    private func style(for shown: CellValue) -> (tone: CellTone, bold: Bool) {
        var tone = CellTone.standard
        var bold = false

        if group == "Coaching stars", case .double(let stars) = shown {
            tone = stars >= 4.75 ? .good : stars >= 4.25 ? .fair : stars >= 3.75 ? .text : .muted
        } else if group == "Season stats" {
            if name == "Average rating", case .text(let text) = shown, let rating = Net.double(text) {
                tone = rating >= 7.3 ? .good : rating >= 6.8 ? .text : .muted
            }
        } else if numeric, case .int(let number) = shown, number <= 20, !ability, group != "General" {
            let lowerIsBetter = name == "Injury Proneness" || name == "Dirtiness" || name == "Controversy"
            if lowerIsBetter {
                tone = number <= 5 ? .good : number >= 15 ? .bad : .text
            } else {
                tone = number >= 16 ? .good : number <= 6 ? .muted : .text
                bold = number >= 16
            }
        }

        if group == "Coaching stars", case .text = shown { tone = .muted }
        return (tone, bold)
    }
}

/// The column catalogue for the player and staff lists.
public enum Columns {
    private static let playerDefaults: Set<String> = [
        "Pace", "Acceleration", "Dribbling", "Finishing", "Passing", "Technique", "Vision", "Decisions", "Flair",
        "Determination", "Consistency", "Important Matches", "Injury Proneness",
    ]

    private static func player(_ person: Person) -> Player { unsafeDowncast(person, to: Player.self) }
    private static func staff(_ person: Person) -> Staff { unsafeDowncast(person, to: Staff.self) }

    /// `Convert.ToString` on a double: 4 not "4.0".
    static func plain(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    static func short(_ name: String) -> String {
        switch name {
        case "Punching (Tendency)": return "Pun"
        case "Off The Ball": return "OtB"
        case "Long Shots": return "Lon"
        case "Long Throws": return "L Th"
        case "Free Kicks": return "Fre"
        case "First Touch": return "Fir"
        case "Penalty Taking": return "Pen"
        case "Jumping Reach": return "Jum"
        case "Natural Fitness": return "Nat"
        case "Work Rate": return "Wor"
        case "Aerial Reach": return "Aer"
        case "Command Of Area": return "Cmd"
        case "One On Ones": return "1v1"
        case "Rushing Out": return "Rus"
        case "Important Matches": return "Imp"
        case "Injury Proneness": return "Inj"
        case "Left Foot": return "Left"
        case "Right Foot": return "Right"
        default: return name.utf16.count > 4 ? String(name.prefix(3)) : name
        }
    }

    private static func age(_ person: Person) -> CellValue { person.age >= 0 ? .int(person.age) : .empty }

    private static func birthText(_ person: Person) -> CellValue {
        person.birth.map { .text(Net.dayMonthYear($0)) } ?? .empty
    }

    private static func dayMonthYear(_ value: CellValue) -> String {
        if case .date(let date) = value { return Net.dayMonthYear(date) }
        return ""
    }

    public static func forPlayers() -> [Col] {
        var cols: [Col] = [
            Col("Name", "General", { .text($0.name) }, isDefault: true, numeric: false, width: 150),
            Col("Age", "General", age, isDefault: true, numeric: true, width: 36),
            Col("Nation", "General", { .text($0.nation) }, isDefault: true, numeric: false, width: 90),
            Col("Club", "General", { .text($0.club) }, isDefault: true, numeric: false, width: 110),
            Col("League", "General", { .text($0.league) }, isDefault: false, numeric: false, width: 120),
            // The data model's region is a continent and its area a region.
            Col("Continent", "General", { .text($0.region) }, isDefault: false, numeric: false, width: 90),
            Col("Region", "General", { .text($0.area) }, isDefault: false, numeric: false, width: 130),
            Col("Squad", "General", { .text($0.squad) }, isDefault: false, numeric: false, width: 80),
            Col("On loan at", "General", { .text($0.loanClub) }, isDefault: false, numeric: false, width: 110),
            Col("Club (full)", "General", { .text($0.clubFull) }, isDefault: false, numeric: false, width: 160),
            Col("Position", "General", { .text(player($0).bestPositions) }, isDefault: true, numeric: false, width: 90),
            Col("Traits", "General", { .text(player($0).traits) }, isDefault: false, numeric: false, width: 220),
            Col("Best role", "General", { .text(player($0).bestRoleIp) }, isDefault: false, numeric: false, width: 150),
            Col("Height", "General", { player($0).height > 0 ? .int(player($0).height) : .empty },
                isDefault: false, numeric: true, width: 50, format: { value in
                    if case .int(let height) = value { return Units.heightText(height) }
                    return ""
                }),
            Col("Injury", "General", { .text(player($0).injuryText) }, isDefault: false, numeric: false, width: 170),
            Col("Days out", "General", { person in
                guard player(person).injury != nil else { return .empty }
                return RulesState.shared.injuryKnown(player(person)).map { .int($0) } ?? .empty
            }, isDefault: false, numeric: true, width: 60),
            Col("Best role (OOP)", "General", { .text(player($0).bestRoleOop) }, isDefault: false, numeric: false, width: 170),
            Col("Date of birth", "General", birthText, isDefault: false, numeric: false, width: 80),
            Col("Unique ID", "General", { .int(Int($0.uid)) }, isDefault: false, numeric: true, width: 80),
            Col("CA", "Ability", { .int(player($0).ca) }, isDefault: true, numeric: true, width: 38, ability: true),
            Col("PA", "Ability", { .int(player($0).pa) }, isDefault: true, numeric: true, width: 38, ability: true),
            Col("Growth room", "Ability", { .int(player($0).pa - player($0).ca) }, isDefault: false, numeric: true,
                width: 50, ability: true),
        ]

        cols += contract(players: true)
        cols += season()

        let groups: [(title: String, names: [String], hidden: Bool)] = [
            ("Technical", Names.technical, false),
            ("Mental", Names.mental, false),
            ("Physical", Names.physical, false),
            ("Goalkeeping", Names.goalkeeping, false),
            ("Hidden", Names.hidden, true),
        ]
        for group in groups {
            for attribute in group.names {
                let index = Names.playerIndex[attribute]!
                cols.append(Col(attribute, group.title, { .int(player($0).attribute(at: index)) },
                                isDefault: playerDefaults.contains(attribute), numeric: true, width: 34,
                                hidden: group.hidden, short: short(attribute)))
            }
        }

        cols.append(Col("Left Foot", "Physical", { .int(player($0).a("Left Foot")) }, isDefault: false, numeric: true,
                        width: 34, short: "Left"))
        cols.append(Col("Right Foot", "Physical", { .int(player($0).a("Right Foot")) }, isDefault: false, numeric: true,
                        width: 34, short: "Right"))

        for position in 0..<15 {
            cols.append(Col(Names.positions[position], "Positions", { .int(Int(player($0).pos[position])) },
                            isDefault: false, numeric: true, width: 34))
        }

        cols.append(Col("Personality", "Personality", { .text($0.personality) }, isDefault: true, numeric: false, width: 120))
        cols.append(Col("Media handling", "Personality", { .text($0.media) }, isDefault: false, numeric: false, width: 140))
        for trait in Names.personality {
            cols.append(Col(trait, "Personality", { .int($0.p(trait)) }, isDefault: false, numeric: true, width: 40,
                            hidden: true, short: String(trait.prefix(3))))
        }
        return cols
    }

    public static func forStaff() -> [Col] {
        var cols: [Col] = [
            Col("Name", "General", { .text($0.name) }, isDefault: true, numeric: false, width: 150),
            Col("Job", "General", { .text(staff($0).job) }, isDefault: true, numeric: false, width: 130),
            Col("Interest", "General", { .text(RulesState.shared.staffText(staff($0))) }, isDefault: false, numeric: false,
                width: 110),
            Col("Age", "General", age, isDefault: true, numeric: true, width: 36),
            Col("Nation", "General", { .text($0.nation) }, isDefault: true, numeric: false, width: 90),
            Col("Club", "General", { .text($0.club) }, isDefault: true, numeric: false, width: 110),
            Col("League", "General", { .text($0.league) }, isDefault: false, numeric: false, width: 120),
            Col("Continent", "General", { .text($0.region) }, isDefault: false, numeric: false, width: 90),
            Col("Region", "General", { .text($0.area) }, isDefault: false, numeric: false, width: 130),
            Col("Squad", "General", { .text($0.squad) }, isDefault: true, numeric: false, width: 80),
            Col("Date of birth", "General", birthText, isDefault: false, numeric: false, width: 80),
            Col("CA", "Ability", { .int(staff($0).ca) }, isDefault: true, numeric: true, width: 38, ability: true),
            Col("PA", "Ability", { .int(staff($0).pa) }, isDefault: true, numeric: true, width: 38, ability: true),
            Col("World rep.", "Ability", { .int(staff($0).repWorld) }, isDefault: false, numeric: true, width: 60),
        ]

        cols += contract(players: false)

        for area in 0..<9 {
            cols.append(Col(Names.areas[area], "Coaching stars", { person in
                starText(staff(person), area).map { .double($0) } ?? .empty
            }, isDefault: true, numeric: true, width: 48))
        }

        let shownByDefault: Set<String> = [
            "Determination", "Level Of Discipline", "Motivating", "Working With Youngsters",
            "Judging Player Ability", "Judging Player Potential",
        ]
        for attribute in Names.staffShown {
            cols.append(Col(attribute, "Attributes", { .int(staff($0).a(attribute)) },
                            isDefault: shownByDefault.contains(attribute), numeric: true, width: 40))
        }
        for attribute in hiddenStaffAttributes where !attribute.hasPrefix("Unnamed") {
            cols.append(Col(attribute, "Hidden", { .int(staff($0).a(attribute)) }, isDefault: false, numeric: true,
                            width: 40, hidden: true))
        }

        cols.append(Col("Personality", "Personality", { .text($0.personality) }, isDefault: false, numeric: false, width: 120))
        cols.append(Col("Media handling", "Personality", { .text($0.media) }, isDefault: false, numeric: false, width: 140))
        for trait in Names.personality {
            cols.append(Col(trait, "Personality", { .int($0.p(trait)) }, isDefault: false, numeric: true, width: 40,
                            hidden: true))
        }
        return cols
    }

    /// `Names.StaffAttrs.Except(Names.StaffShown)`.
    static var hiddenStaffAttributes: [String] {
        let shown = Set(Names.staffShown)
        return Net.distinct(Names.staffAttrs.filter { !shown.contains($0) })
    }

    public static func money(_ pounds: Int64) -> String { Units.moneyText(Double(pounds)) }
    public static func money(wage weeklyPounds: Int) -> String { Units.wageText(weeklyPounds, withSuffix: false) }

    private static func clauseText(_ value: CellValue) -> String {
        if case .int(let pounds) = value { return money(Int64(pounds)) }
        return ""
    }

    private static func clause(_ pounds: Int64) -> CellValue { pounds > 0 ? .int(Int(pounds)) : .empty }

    private static func contract(players: Bool) -> [Col] {
        var cols: [Col] = []
        if players {
            cols.append(Col("Value", "Contract", { player($0).notForSale ? .empty : .int(Int(player($0).value)) },
                            isDefault: true, numeric: true, width: 70, format: { value in
                                if case .int(let pounds) = value { return money(Int64(pounds)) }
                                return "Not for sale"
                            }))
        }
        cols.append(Col("Wage", "Contract", { .int($0.wage) }, isDefault: players, numeric: true, width: 80,
                        short: "Wage \(Units.wageSuffix)", format: { value in
                            if case .int(let wage) = value { return money(wage: wage) }
                            return ""
                        }))
        cols.append(Col("Contract end", "Contract", { $0.contractEnd.map { .date($0) } ?? .empty },
                        isDefault: players, numeric: true, width: 80, format: dayMonthYear))
        if players {
            cols.append(Col("Loan end", "Contract", { $0.loanEnd.map { .date($0) } ?? .empty },
                            isDefault: false, numeric: true, width: 80, format: dayMonthYear))
            cols.append(Col("Transfer status", "Contract", { .text($0.transferStatus) }, isDefault: false, numeric: false,
                            width: 70, short: "Transfer"))
            cols.append(Col("Loan status", "Contract", { .text($0.loanStatus) }, isDefault: false, numeric: false,
                            width: 80, short: "Loan"))
            cols.append(Col("Interest", "Contract", { .text(RulesState.shared.text(player($0))) }, isDefault: false,
                            numeric: false, width: 90))
        }
        cols.append(Col("Release clause", "Contract", { clause($0.releaseClause) }, isDefault: false, numeric: true,
                        width: 80, format: clauseText))
        cols.append(Col("Release (foreign)", "Contract", { clause($0.releaseForeign) }, isDefault: false, numeric: true,
                        width: 80, format: clauseText))
        cols.append(Col("Release (domestic)", "Contract", { clause($0.releaseDomestic) }, isDefault: false, numeric: true,
                        width: 80, format: clauseText))
        return cols
    }

    private static func twoDecimals(_ value: CellValue) -> String {
        if case .double(let number) = value { return Net.fixed(number, min: 2, max: 2) }
        return ""
    }

    private static func oneDecimal(_ value: CellValue) -> String {
        if case .double(let number) = value { return Net.fixed(number, min: 1, max: 1) }
        return ""
    }

    private static func season() -> [Col] {
        func stat(_ name: String, _ short: String, isDefault: Bool = false, width: Int = 40,
                  format: ((CellValue) -> String)? = nil, _ read: @escaping (SeasonStats) -> CellValue) -> Col {
            Col(name, "Season stats", { person in
                guard let stats = player(person).season else { return .empty }
                return read(stats)
            }, isDefault: isDefault, numeric: true, width: width, short: short, format: format)
        }

        return [
            stat("Appearances", "Apps", isDefault: true) { .int($0.apps) },
            stat("Sub appearances", "Sub") { .int($0.subs) },
            stat("Minutes", "Mins", width: 50) { .int($0.minutes) },
            stat("Goals", "Gls", isDefault: true) { .int($0.goals) },
            stat("Assists", "Ast", isDefault: true) { .int($0.assists) },
            stat("Average rating", "Av Rat", isDefault: true, width: 48, format: twoDecimals) {
                $0.rating > 0 ? .double($0.ratingShown) : .empty
            },
            stat("Player of the Match", "PoM") { .int($0.playerOfTheMatch) },
            stat("Yellow cards", "Yel") { .int($0.yellow) },
            stat("Red cards", "Red") { .int($0.red) },
            stat("Goals per 90", "Gls/90", width: 48, format: twoDecimals) {
                $0.minutes > 0 ? .double($0.per90($0.goals)) : .empty
            },
            stat("Expected goals", "xG", width: 44, format: oneDecimal) { .double($0.xG) },
            stat("Expected assists", "xA", width: 44, format: oneDecimal) { .double($0.xA) },
            stat("Pass completion %", "Pas %") { .int($0.passPercent) },
            stat("Shots on target %", "ShT %") { .int($0.shotsOnTargetPercent) },
            stat("Tackles won", "Tck") { .int($0.tackles) },
            stat("Tackle success %", "Tck %") { .int($0.tacklePercent) },
            stat("Dribbles", "Drb") { .int($0.dribbles) },
            stat("Clean sheets", "CS") { .int($0.cleanSheets) },
            stat("Goals conceded", "Conc") { .int($0.conceded) },
            Col("Form (last 5 ratings)", "Season stats", { .text(player($0).form) }, isDefault: false, numeric: false,
                width: 120, short: "Form"),
        ]
    }

    /// A coach's stars in an area. Specialists only have a meaningful rating in their own area.
    public static func starText(_ staff: Staff, _ area: Int) -> Double? {
        if staff.job == "Goalkeeping Coach", area != 6 { return nil }
        if staff.job == "Fitness Coach", area != 7 { return nil }
        return staff.stars[area]
    }

    /// CA or PA as stars, for `Reveal.stars`.
    public static func abilityStars(_ value: Int) -> String {
        let stars = (Double(value) / 200.0 * 10.0).rounded(.toNearestOrEven) / 2.0
        return Net.fixed(stars, min: 1, max: 1) + "★"
    }

    // MARK: Sorting

    /// `MainForm.SortRows`. Numeric columns put rows with no value last when ascending but first when
    /// descending. Text columns compare by culture, ignoring case.
    public static func sortRows<Row: Person>(_ rows: [Row], by col: Col, descending: Bool) -> [Row] {
        if col.numeric {
            let keys = rows.map { row -> Double in
                let number = col.get(row).sortNumber
                if number.isNaN { return descending ? -.infinity : .infinity }
                return descending ? -number : number
            }
            return rows.indices.sorted { keys[$0] < keys[$1] }.map { rows[$0] }
        }

        // Comparing by culture is the slow part, and most columns repeat their values.
        let texts = rows.map { col.get($0).plainText }
        let unique = Array(Set(texts)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var rank: [String: Int] = [:]
        var current = 0
        for (index, text) in unique.enumerated() {
            if index > 0, text.localizedCaseInsensitiveCompare(unique[index - 1]) != .orderedSame { current += 1 }
            rank[text] = current
        }
        let keys = texts.map { rank[$0]! }
        let sorted = rows.indices.sorted { keys[$0] < keys[$1] }.map { rows[$0] }
        return descending ? sorted.reversed() : sorted
    }

    /// Columns whose values only exist after the game has been asked: `MainForm.ApplyFilter` first lists the
    /// rows in the default order, runs the checks, then sorts.
    public static func sortsAfterChecks(_ col: Col?) -> Bool { col?.name == "Interest" || col?.name == "Days out" }

    /// The order of a player search: the sorted column, or highest CA first. An order would give CA away while it's off,
    /// so then it's highest value first, with "not for sale" last because its value is only a placeholder.
    public static func ordered(players rows: [Player], sortBy col: Col?, descending: Bool, byAbility: Bool = true) -> [Player] {
        if let col, !sortsAfterChecks(col) { return sortRows(rows, by: col, descending: descending) }
        if byAbility { return rows.sorted { $0.ca > $1.ca } }
        return rows.sorted { ($0.notForSale ? -1 : $0.value) > ($1.notForSale ? -1 : $1.value) }
    }

    /// The order of a staff search: the sorted column, then the stars of `StaffFilter.rankArea`, or as read.
    public static func ordered(staff rows: [Staff], sortBy col: Col?, descending: Bool, rankArea: Int) -> [Staff] {
        if let col, !sortsAfterChecks(col) { return sortRows(rows, by: col, descending: descending) }
        guard rankArea >= 0 else { return rows }
        let keys = rows.map { starText($0, rankArea) ?? -1.0 }
        return rows.indices.sorted { keys[$0] > keys[$1] }.map { rows[$0] }
    }

    // MARK: Layout

    /// `MainForm.RebuildColumns`.
    public static func shown(_ cols: [Col], showHidden: Bool, showAbility: Bool) -> [Col] {
        cols.filter { $0.visible && allowed($0, showHidden: showHidden, showAbility: showAbility) }
    }

    /// Whether a column may be shown or exported at all, whoever asks for it.
    public static func allowed(_ col: Col, showHidden: Bool, showAbility: Bool) -> Bool {
        (showHidden || !col.hidden) && (showAbility || !col.ability)
    }

    /// The "Select default" button and "Reset layout".
    public static func resetToDefault(_ cols: inout [Col]) {
        for index in cols.indices { cols[index].visible = cols[index].isDefault }
    }

    /// Applies saved visibility, as on startup.
    public static func restoreVisibility(_ cols: inout [Col], saved: [ColState]?) {
        guard let saved else { return }
        for index in cols.indices {
            if let state = saved.first(where: { $0.name == cols[index].name }) { cols[index].visible = state.visible }
        }
    }

    /// `RestoreColumnLayout`: the shown columns in saved order, with saved widths above 20 applied. Columns
    /// with no saved position go last, in catalogue order.
    public static func restoreLayout(shown: [Col], all: [Col], saved: [ColState]?, restoreWidths: Bool) -> [Col] {
        guard let saved else { return shown }
        let keyed = shown.map { col -> (col: Col, order: Int) in
            var col = col
            let state = saved.first { $0.name == col.name }
            if restoreWidths, let width = state?.width, width > 20 { col.width = width }
            let order = state?.order ?? -1
            return (col, order >= 0 ? order : 10_000 + (all.firstIndex { $0.name == col.name } ?? -1))
        }
        return keyed.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element.col)
    }

    /// `CaptureColumns`: `shown` is in display order and carries current widths. The shown columns take over each
    /// other's places in the saved layout, so one that's switched off comes back where it was.
    public static func capture(all: [Col], shown: [Col], saved: [ColState]?) -> [ColState] {
        let placed = all.filter { col in col.visible || (saved?.first { $0.name == col.name }?.order ?? -1) >= 0 }
        let shownNames = Set(shown.map(\.name))
        var waiting = shown[...]
        var layout = restoreLayout(shown: placed, all: all, saved: saved, restoreWidths: false).map { col in
            shownNames.contains(col.name) ? waiting.popFirst()?.name ?? col.name : col.name
        }
        layout += waiting.map(\.name)
        return all.map { col in
            let previous = saved?.first { $0.name == col.name }
            var state = ColState()
            state.name = col.name
            state.visible = col.visible
            state.order = layout.firstIndex(of: col.name) ?? -1
            state.width = shown.first { $0.name == col.name }?.width ?? previous?.width ?? 0
            return state
        }
    }
}

extension SeasonStats {
    public func per90(_ value: Int) -> Double {
        minutes > 0 ? Double(value) * 90.0 / Double(minutes) : 0.0
    }

    public var ratingShown: Double { ((rating * 100.0) + 0.001).rounded(.down) / 100.0 }

    public var ratingText: String { rating > 0 ? Net.fixed(ratingShown, min: 2, max: 2) : "-" }

    public var appsText: String { subs > 0 ? "\(starts) (\(subs))" : String(apps) }
}
