import Foundation
import StarshipCore

/// The little text box above a grid column. Text columns search; numeric columns take "10-20", "<=5",
/// "<5", "=5", ">=5", or a bare number that means "at least". Commas count as decimal points.
public struct ColumnFilter {
    private enum Test {
        case contains(TextTest)
        case between(Double, Double)
        case atMost(Double)
        case below(Double)
        case equal(Double)
        case atLeast(Double)
    }

    private let test: Test

    private init(_ test: Test) { self.test = test }

    /// Nil when the text doesn't describe a filter: such a column is simply not filtered.
    public static func parse(_ text: String, numeric: Bool) -> ColumnFilter? {
        let text = Net.trim(text)
        guard !text.isEmpty else { return nil }
        guard numeric else { return ColumnFilter(.contains(TextTest(literal: text))) }

        func number(_ part: String) -> Double? { Net.double(Net.trim(part).replacingOccurrences(of: ",", with: ".")) }

        // The search for "-" starts at the second character so a leading minus sign isn't a range.
        let units = Array(text.utf16)
        if units.count > 1, let dash = units[1...].firstIndex(of: 45),
           let low = number(String(decoding: units[..<dash], as: UTF16.self)),
           let high = number(String(decoding: units[(dash + 1)...], as: UTF16.self)) {
            return ColumnFilter(.between(low, high))
        }
        if text.hasPrefix("<=") || text.hasPrefix("≤"), let limit = number(Net.trimStart(text, ["<", "=", "≤"])) {
            return ColumnFilter(.atMost(limit))
        }
        if text.hasPrefix("<"), let limit = number(String(text.dropFirst())) {
            return ColumnFilter(.below(limit))
        }
        if text.hasPrefix("="), let exact = number(String(text.dropFirst())) {
            return ColumnFilter(.equal(exact))
        }
        if let limit = number(Net.trimStart(text, [">", "=", "≥"])) {
            return ColumnFilter(.atLeast(limit))
        }
        return nil
    }

    public func matches(_ value: CellValue) -> Bool {
        if case .contains(let search) = test { return search.matches(value.plainText) }
        guard let number = value.filterNumber else { return false }
        switch test {
        case .contains: return false
        case .between(let low, let high): return !(number < low) && !(number > high)
        case .atMost(let limit): return !(number > limit)
        case .below(let limit): return number < limit
        case .equal(let exact): return number == exact
        case .atLeast(let limit): return !(number < limit)
        }
    }

    /// Every column filter on one person, as `MainForm.ApplyFilter` applies them.
    public static func matchesAll(_ filters: [(col: Col, filter: ColumnFilter)], _ person: Person) -> Bool {
        filters.allSatisfy { $0.filter.matches($0.col.get(person)) }
    }
}
