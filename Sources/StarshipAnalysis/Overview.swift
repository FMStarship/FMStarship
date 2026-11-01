import Foundation
import StarshipCore

/// Where someone stands among the people doing the same thing at rival clubs.
public enum Standing: Int, Comparable {
    /// `developing` is someone not there yet who's likely to be: judged on where they're heading.
    case missing, poor, below, unknown, developing, good, strong

    public static func < (a: Standing, b: Standing) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .missing: return "Nobody there"
        case .poor: return "Not good enough"
        case .below: return "Below the league"
        case .unknown: return "No one to compare"
        case .developing: return "Developing"
        case .good: return "Good enough"
        case .strong: return "Among the best"
        }
    }

    public var tone: Tone {
        switch self {
        case .missing, .poor: return .bad
        case .below: return .fair
        case .unknown: return .muted
        case .developing: return .growth
        case .good: return .text
        case .strong: return .good
        }
    }

    /// Fewer than this say nothing about a league.
    private static let enoughToCompare = 3

    /// The quartiles of `others`, which must be sorted: the top one in four is strong, the bottom one poor.
    static func of(_ value: Double, against others: [Double]) -> Standing {
        guard others.count >= enoughToCompare else { return .unknown }
        let low = others[others.count / 4], middle = others[others.count / 2], high = others[others.count * 3 / 4]
        if value >= high, value > middle { return .strong }
        return value >= middle ? .good : value >= low ? .below : .poor
    }
}

/// One place at the club: who fills it and how well.
public struct OverviewRow: Identifiable {
    /// Where to look for more than the one name this row shows.
    public enum Lookup {
        case staff(role: StaffRole, level: Int, area: Int)
        case signing(position: Int)
    }

    public let id: String
    public let group: String
    public let place: String
    public let person: Person?
    public let name: String
    public let score: String
    public let detail: String
    /// Something about to go wrong, whatever the standing says.
    public let warning: String?
    public let standing: Standing
    public let lookup: Lookup
    /// False where the row is as good as it gets, so no search runs.
    public let searches: Bool
    /// Where this place is heading: a young starter's projection, or someone coming through.
    public var outlook: String? = nil
    /// What the outlook means for a signing here.
    public var advice: String? = nil
    /// Whether a young player is likely to live up to it, and how that reads.
    public var talent: String? = nil
    public var talentTone: Tone = .text

    public var needsWork: Bool { standing < .unknown || warning != nil }
}

public struct OverviewHire {
    public let person: Person
    public let name: String
    public let score: String
    public let gain: String
    public let detail: String
}

public enum OverviewResult {
    case hire(OverviewHire)
    case nobody(String)
}

/// A club seen one way, with the rows it needs someone for. `search` asks the game, so it blocks.
public protocol OverviewReport: AnyObject {
    var headline: String { get }
    var rows: [OverviewRow] { get }
    var groups: [String] { get }
    var placeTitle: String { get }
    var nowTitle: String { get }
    var footnote: String { get }
    var exportTitle: String { get }
    /// Places free at the club, for reports that have any.
    var emptyPlaces: Int { get }
    func search(_ row: OverviewRow, taken: inout Set<UInt32>, isCancelled: () -> Bool) -> OverviewResult?
}

extension OverviewReport {
    public var emptyPlaces: Int { 0 }

    /// The screen as a table, for export.
    public func table(hires: [String: OverviewResult]) -> AnalysisTable {
        var table = AnalysisTable(columns: [
            TableColumn(placeTitle, 18), TableColumn(nowTitle, 18), TableColumn("Rating", 7), TableColumn("Standing", 14), TableColumn("Notes", 30),
            TableColumn("Best who'd join", 18), TableColumn("Their rating", 7), TableColumn("Gain", 7), TableColumn("About them", 30),
        ], head: headline)
        for group in groups {
            for row in rows where row.group == group {
                var cells = [row.place, row.name, row.score, row.standing.title,
                             [row.detail, row.warning, row.outlook, row.talent, row.advice].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "; ")]
                switch hires[row.id] {
                case let .hire(hire): cells += [hire.name, hire.score, hire.gain, hire.detail]
                case let .nobody(reason): cells += [reason, "", "", ""]
                case nil: cells += ["", "", "", ""]
                }
                table.rows.append(TableRow(cells: cells, person: row.person))
            }
        }
        return table
    }
}
