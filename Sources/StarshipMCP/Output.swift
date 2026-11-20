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
        // The app's column says Listed or Unavailable under a Loan heading; on its own, Unavailable reads as injured.
        if col.name == "Loan status" {
            return person.loanListed ? "Listed for loan" : person.loanUnavailable ? "Not available for loan" : nil
        }
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

    /// One column of a list as it goes out: a name, and each person's value.
    struct Field {
        let name: String
        let value: (Person) -> JSON?
    }

    /// FM shows appearances as starts with sub appearances in brackets, "3 (2)". The catalogue's Appearances is the two
    /// added up, which reads as starts, so it goes out as the two numbers.
    static func starts(_ person: Person) -> JSON? { (person as? Player)?.season.map { .int($0.starts) } }
    static let startsName = "Starts"

    /// The columns of `catalogue` named in `names`, in that order, that may go out now.
    static func columns(_ names: [String], in catalogue: [Col], _ visibility: Visibility) -> [Field] {
        var fields: [Field] = []
        for name in names {
            guard let col = catalogue.first(where: { $0.name == name }), visibility.allows(col) else { continue }
            if col.name == "Appearances" {
                fields.append(Field(name: startsName, value: starts))
                if !names.contains("Sub appearances"), let subs = catalogue.first(where: { $0.name == "Sub appearances" }), visibility.allows(subs) {
                    fields.append(Field(name: subs.name) { value(subs, $0, visibility) })
                }
                continue
            }
            fields.append(Field(name: col.name) { value(col, $0, visibility) })
            // League names are FM's, in the game's language, and can be the same in two countries.
            if col.name == "League", !names.contains(clubNation.name) { fields.append(clubNation) }
        }
        return fields
    }

    /// The nation of the person's club, which says whose league a league is.
    static let clubNation = Field(name: "Club nation") { text($0.clubNation) }

    /// People as a list: `{"columns": ["uid", ...], "rows": [[uid, ...]]}`.
    static func rows(_ people: [Person], _ fields: [Field]) -> [(String, JSON)] {
        let titles: [JSON] = ["uid"] + fields.map { .string($0.name) }
        let rows: [JSON] = people.map { person in .array([.int(Int(person.uid))] + fields.map { $0.value(person) ?? .null }) }
        return [("columns", .array(titles)), ("rows", .array(rows))]
    }

    /// Sentences about the app's mouse, such as "Double-click for the full profile", which mean nothing to an agent.
    static func prose(_ text: String) -> String {
        let sentences = text.components(separatedBy: ". ")
        let kept = sentences.filter { $0.range(of: "click", options: .caseInsensitive) == nil }
        guard kept.count < sentences.count else { return isoDates(text) }
        var joined = kept.joined(separator: ". ")
        if !joined.isEmpty, !joined.hasSuffix("."), !joined.hasSuffix("!"), !joined.hasSuffix("?") { joined += "." }
        return isoDates(joined)
    }

    /// A table's cell: a whole number as a number, as in the lists, and anything else as its text.
    private static func cell(_ text: String) -> JSON {
        if let number = Int(text), String(number) == text { return .int(number) }
        return Self.text(text) ?? .null
    }

    /// One of the analysis screens' tables, as the screen shows it: they've already left out what the settings hide.
    static func table(_ table: AnalysisTable, dropping: Set<String> = [], withHead: Bool = true, limit: Int? = nil,
                      extra: [Field] = []) -> [(String, JSON)] {
        let kept = table.columns.indices.filter { !dropping.contains(table.columns[$0].title) }
        let titles: [JSON] = ["uid"] + kept.map { .string(table.columns[$0].title) } + extra.map { .string($0.name) }
        let rows: [JSON] = table.rows.prefix(limit ?? table.rows.count).map { row in
            let uid: JSON = row.person.map { .int(Int($0.uid)) } ?? .null
            return .array([uid] + kept.map { $0 < row.cells.count ? cell(row.cells[$0]) : .null }
                          + extra.map { field in row.person.flatMap(field.value) ?? .null })
        }
        var pairs: [(String, JSON)] = []
        if withHead, !table.head.isEmpty { pairs.append(("head", .string(prose(table.head)))) }
        if let limit, table.rows.count > limit { pairs += [("found", .int(table.rows.count)), ("shown", .int(limit))] }
        pairs += [("columns", .array(titles)), ("rows", .array(rows))]
        var status = prose(table.status)
        // The finder's own sentence counts every row it found, so a cut list says how many came back.
        if let limit, table.rows.count > limit {
            status += (status.isEmpty ? "" : " ") + (limit == 1 ? "Showing the first." : "Showing the first \(limit).")
        }
        if !status.isEmpty { pairs.append(("status", .string(status))) }
        return pairs
    }
}
