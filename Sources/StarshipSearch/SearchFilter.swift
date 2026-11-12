import Foundation
import StarshipCore

/// Where a pick list gets its items.
public enum FilterChoices: Equatable {
    case fixed([String])
    case nations
    case leagues
    case regions
    case personalities
    case media
    case humanClubs
}

/// Hint text in an empty box. Money hints follow the current units.
public enum FilterPlaceholder: Equatable {
    case none
    case text(String)
    case moneyMillions
    case wageThousands

    public var text: String {
        switch self {
        case .none: return ""
        case .text(let text): return text
        case .moneyMillions: return "\(Units.money.symbol)M"
        case .wageThousands: return "\(Units.money.symbol)K \(Units.wageSuffix)"
        }
    }
}

/// A line of explanation, filled in by `RulesState.fill`.
public enum FilterNote {
    case playerInterest
    case staffInterest
    case joinLevels

    public var text: String {
        switch self {
        case .playerInterest: return RulesState.shared.interestNote
        case .staffInterest: return RulesState.shared.staffInterestNote
        case .joinLevels: return "Counts FM's Interested, Persuadable and Doubtful players. The less keen may want more money."
        }
    }
}

/// One row of a filter section, enough for a SwiftUI form to draw and bind it.
public struct FilterField<Filter> {
    public enum Kind {
        case text(WritableKeyPath<Filter, String>)
        /// Two small boxes with "to" between them.
        case range(min: WritableKeyPath<Filter, String>, max: WritableKeyPath<Filter, String>)
        /// `editable` lists also accept typed text with autocomplete; the rest are pick-only.
        case choice(WritableKeyPath<Filter, String>, FilterChoices, editable: Bool)
        case toggle(WritableKeyPath<Filter, Bool>)
        /// An index into `rules`, drawn as attribute, operator, value.
        case rule(Int)
        case note(FilterNote)
    }

    public let id: String
    /// Shown as "Label:" beside the control. Empty for toggles (where it is the checkbox text), rules and notes.
    public let label: String
    public let kind: Kind
    public let placeholder: FilterPlaceholder
    /// False for the club picker: it chooses context and doesn't mark the section as filtering.
    public let isFilter: Bool
    /// True for controls that need the live game: draw disabled unless `Filter.interestEnabled`.
    public let needsGame: Bool

    init(_ id: String, _ label: String, _ kind: Kind, placeholder: FilterPlaceholder = .none,
         isFilter: Bool = true, needsGame: Bool = false) {
        self.id = id
        self.label = label
        self.kind = kind
        self.placeholder = placeholder
        self.isFilter = isFilter
        self.needsGame = needsGame
    }
}

public struct FilterSection<Filter>: Identifiable {
    public let title: String
    public let tab: String
    /// Sections of attributes hidden in the game only show with "show hidden" on.
    public let hiddenOnly: Bool
    /// Sections on CA and PA only show while those do.
    public let abilityOnly: Bool
    public let fields: [FilterField<Filter>]

    public var id: String { title }

    /// The name on the section's button in the sidebar.
    public var chipTitle: String {
        if title == "Interested in joining you" { return "Would join you" }
        return title.components(separatedBy: " (")[0]
    }

    init(_ title: String, tab: String, hiddenOnly: Bool = false, abilityOnly: Bool = false, fields: [FilterField<Filter>]) {
        self.title = title
        self.tab = tab
        self.hiddenOnly = hiddenOnly
        self.abilityOnly = abilityOnly
        self.fields = fields
    }
}

/// The filter window's state and layout, shared by the player and staff searches. Text and pick-list state
/// is kept exactly as typed, so a half-typed "abc" in a number box means "no limit" as it did before.
public protocol SearchFilter {
    static var tabOrder: [String] { get }
    static var sections: [FilterSection<Self>] { get }
    /// All attributes a rule can pick, hidden ones included.
    static var ruleAttributes: [String] { get }
    static var hiddenRuleAttributes: Set<String> { get }
    static var interestEnabled: Bool { get }

    var region: String { get set }
    var rules: [AttrRule] { get set }
    var showHidden: Bool { get set }
    var showAbility: Bool { get }
    var defaults: [String: String] { get set }
}

extension SearchFilter {
    public static func sections(inTab tab: String) -> [FilterSection<Self>] { sections.filter { $0.tab == tab } }

    /// The sections to draw in a tab, leaving out hidden-attribute ones when `showHidden` is off and ability ones when `showAbility` is.
    public func visibleSections(inTab tab: String) -> [FilterSection<Self>] {
        Self.sections(inTab: tab).filter { (showHidden || !$0.hiddenOnly) && (showAbility || !$0.abilityOnly) }
    }

    /// The items for a rule's attribute picker.
    public var ruleChoices: [String] {
        [AttrRule.noAttribute] + Self.ruleAttributes.filter { showHidden || !Self.hiddenRuleAttributes.contains($0) }
    }

    /// Call from `showHidden`'s `didSet`: a rule on an attribute that is no longer listed falls back to none.
    mutating func dropHiddenRules() {
        guard !showHidden else { return }
        for index in rules.indices where Self.hiddenRuleAttributes.contains(rules[index].attribute) {
            rules[index].attribute = AttrRule.noAttribute
        }
    }

    /// A pick list's value for comparison with its default: "Any" and blank are the same thing.
    private func choiceValue(_ text: String) -> String { text.isEmpty || text == "Any" ? "" : text }

    private func values(of field: FilterField<Self>) -> [(id: String, value: String)] {
        switch field.kind {
        case .text(let path):
            return [(field.id, Net.trim(self[keyPath: path]))]
        case .range(let min, let max):
            return [("\(field.id).min", Net.trim(self[keyPath: min])), ("\(field.id).max", Net.trim(self[keyPath: max]))]
        case .choice(let path, _, _):
            return [(field.id, choiceValue(self[keyPath: path]))]
        case .toggle(let path):
            return [(field.id, self[keyPath: path] ? "1" : "")]
        case .rule(let index):
            return [("\(field.id).attr", rules[index].attribute),
                    ("\(field.id).op", rules[index].operatorText),
                    ("\(field.id).value", Net.trim(rules[index].value))]
        case .note:
            return []
        }
    }

    /// Takes the current state as the baseline that sections are compared with.
    public mutating func markDefaults() {
        defaults = [:]
        for section in Self.sections {
            for field in section.fields {
                for entry in values(of: field) { defaults[entry.id] = entry.value }
            }
        }
    }

    /// True when a section differs from its defaults: the "●" on its button.
    public func isActive(_ section: FilterSection<Self>) -> Bool {
        section.fields.contains { field in
            guard field.isFilter, !field.needsGame || Self.interestEnabled else { return false }
            return values(of: field).contains { entry in defaults[entry.id].map { $0 != entry.value } ?? false }
        }
    }

    /// The "●" on a tab.
    public func isActive(tab: String) -> Bool { visibleSections(inTab: tab).contains { isActive($0) } }

    /// "Reset this tab" works section by section.
    public mutating func reset(tab: String) {
        for section in Self.sections(inTab: tab) { reset(section: section) }
    }

    public mutating func reset(section: FilterSection<Self>) {
        for field in section.fields where field.isFilter {
            switch field.kind {
            case .text(let path):
                if let value = defaults[field.id] { self[keyPath: path] = value }
            case .range(let min, let max):
                if let value = defaults["\(field.id).min"] { self[keyPath: min] = value }
                if let value = defaults["\(field.id).max"] { self[keyPath: max] = value }
            case .choice(let path, _, _):
                if let value = defaults[field.id] { self[keyPath: path] = value.isEmpty ? "Any" : value }
            case .toggle(let path):
                if let value = defaults[field.id] { self[keyPath: path] = value == "1" }
            case .rule(let index):
                if let value = defaults["\(field.id).attr"] { rules[index].attribute = value }
                if let value = defaults["\(field.id).op"] { rules[index].operatorText = value }
                if let value = defaults["\(field.id).value"] { rules[index].value = value }
            case .note:
                break
            }
        }
    }

    /// Call with fresh options after loading a save. Typed choices stay as they are, but a region that's no
    /// longer on the list goes back to "Any".
    public mutating func fill(_ options: SearchOptions) {
        if !options.regions.contains(region) { region = "Any" }
    }

    var activeRuleTexts: [String] {
        rules.compactMap { $0.describe(showHidden: showHidden, hidden: Self.hiddenRuleAttributes) }
    }

    func ruleTests(attributes: [String: Int]) -> [RuleTest] {
        rules.compactMap { $0.test(showHidden: showHidden, hidden: Self.hiddenRuleAttributes, attributes: attributes) }
    }
}

/// The phrases of the "what am I filtering by" summary line.
enum FilterText {
    private static func bare(_ text: String) -> String { Net.trimStart(Net.trim(text), ["="]) }

    /// A pick list.
    static func pick(_ text: String, _ prefix: String) -> String? {
        text.isEmpty || text == "Any" ? nil : prefix + bare(text)
    }

    /// A text box.
    static func typed(_ text: String, _ prefix: String) -> String? {
        Net.trim(text).isEmpty ? nil : prefix + bare(text)
    }

    /// `SearchBase.D`: a decimal box that tolerates a currency sign and a decimal comma.
    static func decimal(_ text: String) -> Double? {
        let bare = Net.trimStart(Net.trim(text), ["£", "$", "€", "¥", " "])
        return Net.double(bare.replacingOccurrences(of: ",", with: "."))
    }

    static func range(_ label: String, _ low: String, _ high: String, suffix: String = "") -> String? {
        switch (Net.int32(low), Net.int32(high)) {
        case let (low?, high?): return "\(label) \(low)-\(high)\(suffix)"
        case let (low?, nil): return "\(label) \(low)+\(suffix)"
        case let (nil, high?): return "\(label) up to \(high)\(suffix)"
        case (nil, nil): return nil
        }
    }
}

/// Filters in parallel and keeps the input order, like `AsParallel().AsOrdered()` in the original.
func parallelFilter<Item>(_ items: [Item], _ test: (Item) -> Bool) -> [Item] {
    guard items.count >= 2048 else { return items.filter(test) }

    let chunks = max(1, ProcessInfo.processInfo.activeProcessorCount)
    let size = (items.count + chunks - 1) / chunks
    var keep = [Bool](repeating: false, count: items.count)
    keep.withUnsafeMutableBufferPointer { flags in
        let flags = flags
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let start = chunk * size
            for index in start..<min(start + size, items.count) { flags[index] = test(items[index]) }
        }
    }
    return items.indices.compactMap { keep[$0] ? items[$0] : nil }
}

/// The item lists behind `FilterChoices`, built from the loaded database.
public struct SearchOptions {
    public var nations = ["Any"]
    public var leagues = ["Any"]
    /// Each continent followed by its regions, which are indented four spaces. The indent is how the
    /// search tells the two kinds apart, so keep it in the stored value.
    public var regions = ["Any"]
    public var personalities = ["Any"]
    public var media = ["Any"]

    public init() {}

    public init<Row: Person>(_ people: [Row]) {
        nations = Self.list(people.map(\.nation))
        leagues = Self.list(people.map(\.league))
        personalities = Self.list(people.map(\.personality))
        media = Self.list(people.map(\.media))

        var areas: [String: [String]] = [:]
        for person in people where !person.region.isEmpty { areas[person.region, default: []].append(person.area) }
        regions = ["Any"]
        for region in Net.cultureSorted(Array(areas.keys)) {
            regions.append(region)
            let names = Net.distinct((areas[region] ?? []).filter { !$0.isEmpty })
            regions += Net.cultureSorted(names).map { "    \($0)" }
        }
    }

    private static func list(_ values: [String]) -> [String] {
        ["Any"] + Net.cultureSorted(Net.distinct(values.filter { !$0.isEmpty }))
    }

    public func choices(_ source: FilterChoices) -> [String] {
        switch source {
        case .fixed(let items): return items
        case .nations: return nations
        case .leagues: return leagues
        case .regions: return regions
        case .personalities: return personalities
        case .media: return media
        case .humanClubs: return RulesState.shared.clubs
        }
    }
}

/// `SearchBase.RegionTest`: an indented item is a region, an unindented one a continent, "Any" no test.
struct RegionTest {
    private let continent: String?
    private let area: String?

    init(_ selected: String) {
        if selected == "Any" || selected.isEmpty {
            (continent, area) = (nil, nil)
        } else if selected.utf16.first == 32 {
            (continent, area) = (nil, Net.trim(selected))
        } else {
            (continent, area) = (selected, nil)
        }
    }

    func matches(_ person: Person) -> Bool {
        if let continent { return person.region == continent }
        if let area { return person.area == area }
        return true
    }
}

extension Names {
    /// Traits alphabetically, for the trait pickers.
    public static let traitList: [String] = Net.cultureSorted(traits.compactMap { $0 })

    /// Every role with its phase, alphabetically, for the role picker.
    public static let roleList: [String] = Net.cultureSorted(
        rolesIp.compactMap { $0.map { "\($0) (IP)" } } + rolesOop.compactMap { $0.map { "\($0) (OOP)" } }
    )
}
