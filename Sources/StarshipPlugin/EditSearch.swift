import Foundation
@preconcurrency import StarshipAnalysis
import StarshipCore

/// One thing a screen's search can be narrowed by, as FM's own Edit Search sets it: a dropdown or a switch.
struct Criterion: Equatable {
    enum Control: Equatable {
        case choice([String], selected: Int)
        case toggle(on: Bool, enabled: Bool)
    }

    let id: String
    let title: String
    let control: Control
    /// A line under it in small print, such as why it can't be changed.
    var note = ""
}

/// What the Recommended signings or Bargains search is set to, as its Edit Search page shows it, and how far that
/// is from the search the screen starts with.
protocol ScreenSearch {
    /// The dropdowns and switches beside the pitch, in order.
    var criteria: [Criterion] { get }
    /// Index into `Names.positions`, or -1 for any.
    var position: Int { get set }
    mutating func choose(_ id: String, _ index: Int)
    mutating func toggle(_ id: String)
    /// How many things differ from the starting search, which FM's Edit Search button counts in brackets.
    var changes: Int { get }
    /// Back to the starting search.
    mutating func clear()
}

extension ScreenSearch {
    /// Everything it's set to, for telling two apart, and for the log.
    var key: String {
        "position=\(position) " + criteria.map { criterion in
            switch criterion.control {
            case .choice(let labels, let selected): return "\(criterion.id)=\(labels.indices.contains(selected) ? labels[selected] : "")"
            case .toggle(let on, _): return "\(criterion.id)=\(on)"
            }
        }.joined(separator: " ")
    }

    /// FM's words on its button, with the count of what's changed.
    var buttonTitle: String { changes > 0 ? "Edit Search (\(changes))" : "Edit Search" }
}

/// The Recommended signings search: the app's options, set by FM's controls.
struct SigningSearch: ScreenSearch {
    private(set) var options: RecommendOptions
    private let units: MoneyUnits
    private let fees: FeeChoices

    /// `budget` is the transfer budget, offered among the fees, as the options take it.
    init(options: RecommendOptions = RecommendOptions(), units: MoneyUnits, budget: String = "") {
        self.options = options
        self.units = units
        fees = FeeChoices(units: units, budget: budget, current: options.maxFee)
    }

    var position: Int {
        get { options.position }
        set { options.position = newValue }
    }

    var criteria: [Criterion] {
        var fee = Criterion(id: "fee", title: SigningRecommender.maxFeeLabel,
                            control: .choice(fees.labels, selected: fees.index(of: options.maxFee)))
        // The engine's own limit for budget signings when none is set.
        if options.mode == .budget, options.maxFee.isEmpty { fee.note = "Budget signings cost up to \(units.moneyText(1_000_000))." }
        return [
            Criterion(id: "mode", title: "Looking for", control: .choice(RecommendOptions.Mode.allCases.map(\.title),
                                                                         selected: Self.index(options.mode))),
            Criterion(id: "show", title: SigningRecommender.showLabel, control: .choice(RecommendOptions.Show.allCases.map(\.title),
                                                                                        selected: Self.index(options.show))),
            fee,
            Criterion(id: "loans", title: SigningRecommender.loansLabel, control: .toggle(on: options.includeLoans, enabled: true)),
            Criterion(id: "upgrades", title: SigningRecommender.upgradesLabel, control: .toggle(on: options.upgradesOnly, enabled: true)),
        ]
    }

    mutating func choose(_ id: String, _ index: Int) {
        switch id {
        case "mode": if let mode = Self.item(RecommendOptions.Mode.allCases, index) { options.mode = mode }
        case "show": if let show = Self.item(RecommendOptions.Show.allCases, index) { options.show = show }
        case "fee": if fees.values.indices.contains(index) { options.maxFee = fees.values[index] }
        default: break
        }
    }

    mutating func toggle(_ id: String) {
        switch id {
        case "loans": options.includeLoans.toggle()
        case "upgrades": options.upgradesOnly.toggle()
        default: break
        }
    }

    var changes: Int {
        let start = RecommendOptions()
        return [options.mode != start.mode, options.position != start.position, options.maxFee != start.maxFee,
                options.show != start.show, options.includeLoans != start.includeLoans,
                options.upgradesOnly != start.upgradesOnly].filter { $0 }.count
    }

    mutating func clear() { options = RecommendOptions() }

    fileprivate static func index<T: Equatable & CaseIterable>(_ value: T) -> Int {
        Array(T.allCases).firstIndex(of: value) ?? 0
    }

    fileprivate static func item<T: Collection>(_ items: T, _ index: Int) -> T.Element? where T.Index == Int {
        items.indices.contains(index) ? items[index] : nil
    }
}

/// The Bargains search: the app's options, set by FM's controls. It starts, as the app's does, with the max fee at
/// the transfer budget.
struct BargainSearch: ScreenSearch {
    private(set) var options: BargainOptions
    let start: BargainOptions
    private let fees: FeeChoices
    private let showsAbility: Bool
    private let canCheckInterest: Bool

    static let abilities = Array(stride(from: 60, through: 190, by: 10))
    static let ages = Array(15...40)

    /// `keeping` is the search so far. As in the app, its max fee goes back to the budget each time the save is read,
    /// which `newSave` says, and stays as it was when only how things are shown has changed.
    init(keeping previous: BargainOptions? = nil, newSave: Bool = true, startingMaxFee: String, units: MoneyUnits, showsAbility: Bool,
         canCheckInterest: Bool) {
        var start = BargainOptions()
        start.maxFee = startingMaxFee
        self.start = start
        var options = previous ?? start
        if newSave { options.maxFee = startingMaxFee }
        self.options = options
        fees = FeeChoices(units: units, budget: startingMaxFee, current: options.maxFee)
        self.showsAbility = showsAbility
        self.canCheckInterest = canCheckInterest
    }

    var position: Int {
        get { options.position }
        set { options.position = newValue }
    }

    var criteria: [Criterion] {
        var list = [Criterion(id: "kind", title: "Looking for", control: .choice(BargainOptions.Kind.allCases.map(\.title),
                                                                                 selected: SigningSearch.index(options.kind)))]
        // CA is hidden with Hidden attributes off, so the choice goes too.
        if showsAbility {
            list.append(Criterion(id: "ca", title: BargainFinder.minCALabel,
                                  control: .choice(["Any"] + Self.abilities.map(String.init),
                                                   selected: Self.abilities.firstIndex(of: Int(options.minCA) ?? -1).map { $0 + 1 } ?? 0)))
        }
        list.append(Criterion(id: "age", title: BargainFinder.maxAgeLabel,
                              control: .choice(["Any"] + Self.ages.map(String.init),
                                               selected: Self.ages.firstIndex(of: Int(options.maxAge) ?? -1).map { $0 + 1 } ?? 0)))
        var fee = Criterion(id: "fee", title: BargainFinder.maxFeeLabel, control: .choice(fees.labels, selected: fees.index(of: options.maxFee)))
        // The engine leaves the fee out for contracts running out.
        if options.kind == .ending { fee.note = "Not used for contracts ending." }
        list.append(fee)
        var join = Criterion(id: "join", title: BargainFinder.onlyJoinLabel, control: .toggle(on: options.onlyJoin, enabled: canCheckInterest))
        if !canCheckInterest { join.note = "Needs the live game and your club." }
        list.append(join)
        return list
    }

    mutating func choose(_ id: String, _ index: Int) {
        switch id {
        case "kind": if let kind = SigningSearch.item(BargainOptions.Kind.allCases, index) { options.kind = kind }
        case "ca": options.minCA = SigningSearch.item(Self.abilities, index - 1).map(String.init) ?? ""
        case "age": options.maxAge = SigningSearch.item(Self.ages, index - 1).map(String.init) ?? ""
        case "fee": if fees.values.indices.contains(index) { options.maxFee = fees.values[index] }
        default: break
        }
    }

    mutating func toggle(_ id: String) {
        if id == "join", canCheckInterest { options.onlyJoin.toggle() }
    }

    var changes: Int {
        [options.kind != start.kind, options.position != start.position, showsAbility && options.minCA != start.minCA,
         options.maxAge != start.maxAge, options.maxFee != start.maxFee, options.onlyJoin != start.onlyJoin].filter { $0 }.count
    }

    mutating func clear() { options = start }
}

/// The Max fee dropdown's choices, as the options take them: millions in the currency shown, "" for any. Round sums
/// from about £100K to £200M in that currency, with the transfer budget among them.
struct FeeChoices {
    let values: [String]
    let labels: [String]

    init(units: MoneyUnits, budget: String = "", current: String = "") {
        let low = 0.1 * units.perPound, high = 200 * units.perPound
        var sums: [(millions: Double, budget: Bool)] = []
        var step = pow(10, (log10(low)).rounded(.down))
        while step <= high * 1.001 {
            for factor in [1.0, 2, 5] where step * factor >= low * 0.999 && step * factor <= high * 1.001 {
                sums.append((step * factor, false))
            }
            step *= 10
        }
        if let budget = Double(budget), budget > 0 { sums.append((budget, true)) }
        if let current = Double(current), current > 0 { sums.append((current, false)) }
        sums.sort { $0.millions < $1.millions || ($0.millions == $1.millions && $0.budget) }
        var kept: [(millions: Double, budget: Bool)] = []
        for sum in sums where !kept.contains(where: { abs($0.millions - sum.millions) < 0.000_001 }) { kept.append(sum) }
        values = [""] + kept.map { Self.text($0.millions) }
        labels = ["Any"] + kept.map { units.moneyText($0.millions * 1_000_000 / units.perPound) + ($0.budget ? " (budget)" : "") }
    }

    func index(of value: String) -> Int {
        guard let wanted = Double(value) else { return 0 }
        return values.firstIndex { Double($0).map { abs($0 - wanted) < 0.000_001 } ?? false } ?? 0
    }

    /// Millions as the options take them: "0.5", "2", "9.1".
    static func text(_ millions: Double) -> String {
        if millions == millions.rounded() { return String(Int(millions)) }
        var text = String(format: "%.2f", millions)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// The positions on FM's Edit Search pitch, where they sit, and FM's names for them.
enum PitchSpot {
    private static let places: [String: (column: Int, row: Int, short: String, long: String)] = [
        "ST": (1, 0, "ST (C)", "Striker (Centre)"),
        "AML": (0, 1, "AM (L)", "Attacking Midfielder (Left)"),
        "AMC": (1, 1, "AM (C)", "Attacking Midfielder (Centre)"),
        "AMR": (2, 1, "AM (R)", "Attacking Midfielder (Right)"),
        "ML": (0, 2, "M (L)", "Midfielder (Left)"),
        "MC": (1, 2, "M (C)", "Midfielder (Centre)"),
        "MR": (2, 2, "M (R)", "Midfielder (Right)"),
        "WBL": (0, 3, "WB (L)", "Wing-Back (Left)"),
        "DM": (1, 3, "DM", "Defensive Midfielder"),
        "WBR": (2, 3, "WB (R)", "Wing-Back (Right)"),
        "DL": (0, 4, "D (L)", "Defender (Left)"),
        "DC": (1, 4, "D (C)", "Defender (Centre)"),
        "DR": (2, 4, "D (R)", "Defender (Right)"),
        "GK": (1, 5, "GK", "Goalkeeper"),
    ]

    /// Each position on the pitch, by its index in `Names.positions`, in columns from left to right and rows from
    /// the strikers' down to the keeper's. FM27's pitch has no sweeper.
    static var spots: [(position: Int, column: Int, row: Int, name: String)] {
        Names.positions.enumerated().compactMap { index, code in places[code].map { (index, $0.column, $0.row, $0.short) } }
    }

    /// FM's full name for a position, or "Any".
    static func name(of position: Int) -> String {
        guard Names.positions.indices.contains(position) else { return "Any" }
        let code = Names.positions[position]
        return places[code]?.long ?? (code == "SW" ? "Sweeper" : code)
    }
}
