import StarshipCore

/// One of the "attribute at least / at most" rows in the filter window.
public struct AttrRule: Equatable {
    public static let noAttribute = "(attribute)"
    public static let operators = ["≥", "≤"]
    /// How many rows a filter starts with, and keeps after a reset.
    public static let startCount = 8
    /// How many rows "Add a rule" goes up to.
    public static let maxCount = 20

    public var attribute = AttrRule.noAttribute
    public var atLeast = true
    public var value = ""

    public init() {}

    /// "≥" or "≤", for binding to a two-item picker.
    public var operatorText: String {
        get { atLeast ? AttrRule.operators[0] : AttrRule.operators[1] }
        set { atLeast = newValue == AttrRule.operators[0] }
    }

    /// Leaves the operator alone, as the original does.
    public mutating func clear() {
        attribute = AttrRule.noAttribute
        value = ""
    }

    /// No attribute picked and nothing typed: a row a reset can take away.
    var isBlank: Bool { attribute == AttrRule.noAttribute && Net.trim(value).isEmpty }

    private func active(showHidden: Bool, hidden: Set<String>) -> (name: String, limit: Int)? {
        guard attribute != AttrRule.noAttribute, let limit = Net.int32(value) else { return nil }
        if !showHidden, hidden.contains(attribute) { return nil }
        return (attribute, limit)
    }

    func describe(showHidden: Bool, hidden: Set<String>) -> String? {
        guard let rule = active(showHidden: showHidden, hidden: hidden) else { return nil }
        return "\(rule.name) " + (atLeast ? "\(rule.limit)+" : "up to \(rule.limit)")
    }

    func test(showHidden: Bool, hidden: Set<String>, attributes: [String: Int]) -> RuleTest? {
        guard let rule = active(showHidden: showHidden, hidden: hidden) else { return nil }
        if let index = Names.personalityIndex[rule.name] {
            return RuleTest(isPersonality: true, index: index, atLeast: atLeast, limit: rule.limit)
        }
        guard let index = attributes[rule.name] else { return nil }
        return RuleTest(isPersonality: false, index: index, atLeast: atLeast, limit: rule.limit)
    }
}

/// A rule resolved to an attribute slot, so a search doesn't look names up for every row.
struct RuleTest {
    let isPersonality: Bool
    let index: Int
    let atLeast: Bool
    let limit: Int

    func passes(_ read: Int) -> Bool { atLeast ? !(read < limit) : !(read > limit) }
}
