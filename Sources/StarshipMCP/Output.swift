import Foundation
import StarshipAnalysis
import StarshipCore
import StarshipSearch

/// People and tables as compact JSON: column names once, then one array per row with the uid first.
enum Output {
    static func iso(_ date: Date) -> String {
        let parts = GameDate.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let numeric = try? NSRegularExpression(pattern: #"\b(\d{2})/(\d{2})/(\d{4})\b"#)
    private static let written = try? NSRegularExpression(pattern: #"\b(\d{1,2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\d{4})\b"#)

    /// The analysis writes days as 31/12/2027 or 31 Dec 2027. Every day sent out is 2027-12-31.
    static func isoDates(_ text: String) -> String {
        guard text.contains(where: \.isNumber) else { return text }
        var result = text
        if let numeric {
            result = numeric.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$3-$2-$1")
        }
        if let written {
            let range = NSRange(result.startIndex..., in: result)
            for match in written.matches(in: result, range: range).reversed() {
                guard let whole = Range(match.range, in: result), let day = Range(match.range(at: 1), in: result),
                      let month = Range(match.range(at: 2), in: result), let year = Range(match.range(at: 3), in: result),
                      let number = months.firstIndex(of: String(result[month])), let dayNumber = Int(result[day]) else { continue }
                result.replaceSubrange(whole, with: String(format: "%@-%02d-%02d", String(result[year]), number + 1, dayNumber))
            }
        }
        return result
    }

    /// Text as JSON, with nothing for no text.
    static func text(_ value: String) -> JSON? { value.isEmpty ? nil : .string(isoDates(value)) }

    /// One person's value in one column, or nil when there isn't one. Ability shows as the user has it: a number, or
    /// stars. The caller has already left out what the user hides; this never sees such a column.
    static func value(_ col: Col, _ person: Person, _ visibility: Visibility) -> JSON? {
        if col.name == "Date of birth" { return person.birth.map { .string(iso($0)) } }
        let raw = col.get(person)
        if col.ability, case .int(let number) = raw {
            return visibility.reveal == .stars ? .string(Columns.abilityStars(number)) : .int(number)
        }
        switch raw {
        case .empty:
            // "Value" is empty for a player the club won't sell, which its format says.
            if let format = col.format { return text(format(raw)) }
            return nil
        case .date(let date): return .string(iso(date))
        case .text(let text): return Self.text(text)
        case .int(let number):
            if let format = col.format { return text(format(raw)) }
            return .int(number)
        case .double(let number):
            if let format = col.format {
                let shown = format(raw)
                return Double(shown).map { .double($0) } ?? text(shown)
            }
            return .double((number * 100).rounded() / 100)
        }
    }

    /// The columns of `catalogue` named in `names`, in that order, that may go out now.
    static func columns(_ names: [String], in catalogue: [Col], _ visibility: Visibility) -> [Col] {
        names.compactMap { name in catalogue.first { $0.name == name } }.filter(visibility.allows)
    }

    /// People as a list: `{"columns": ["uid", ...], "rows": [[uid, ...]]}`.
    static func rows(_ people: [Person], _ columns: [Col], _ visibility: Visibility,
                     extra: [(title: String, value: (Person) -> JSON?)] = []) -> [(String, JSON)] {
        let titles: [JSON] = ["uid"] + columns.map { .string($0.name) } + extra.map { .string($0.title) }
        let rows: [JSON] = people.map { person in
            .array([.int(Int(person.uid))] + columns.map { value($0, person, visibility) ?? .null } + extra.map { $0.value(person) ?? .null })
        }
        return [("columns", .array(titles)), ("rows", .array(rows))]
    }

    /// A table's cell: a whole number as a number, as in the lists, and anything else as its text.
    private static func cell(_ text: String) -> JSON {
        if let number = Int(text), String(number) == text { return .int(number) }
        return Self.text(text) ?? .null
    }

    /// One of the analysis screens' tables, as the screen shows it: they've already left out what the settings hide.
    static func table(_ table: AnalysisTable, dropping: Set<String> = [], withHead: Bool = true) -> [(String, JSON)] {
        let kept = table.columns.indices.filter { !dropping.contains(table.columns[$0].title) }
        let titles: [JSON] = ["uid"] + kept.map { .string(table.columns[$0].title) }
        let rows: [JSON] = table.rows.map { row in
            let uid: JSON = row.person.map { .int(Int($0.uid)) } ?? .null
            return .array([uid] + kept.map { $0 < row.cells.count ? cell(row.cells[$0]) : .null })
        }
        var pairs: [(String, JSON)] = []
        if withHead, let head = text(table.head) { pairs.append(("head", head)) }
        pairs += [("columns", .array(titles)), ("rows", .array(rows))]
        if let status = text(table.status) { pairs.append(("status", status)) }
        return pairs
    }
}
