import Foundation
import StarshipCore

/// The colours the original forms pick from `Theme`.
public enum Tone {
    case text, muted, good, fair, bad, star, growth
}

public struct TableColumn: Equatable {
    public let title: String
    public let weight: Int

    public init(_ title: String, _ weight: Int) {
        self.title = title
        self.weight = weight
    }
}

/// What a column sorts on when it differs from the text shown.
public enum SortKey: Comparable {
    case number(Int64)
    case date(Date)
    case text(String)

    private var rank: Int {
        switch self {
        case .number: return 0
        case .date: return 1
        case .text: return 2
        }
    }

    public static func < (a: SortKey, b: SortKey) -> Bool {
        switch (a, b) {
        case let (.number(x), .number(y)): return x < y
        case let (.date(x), .date(y)): return x < y
        case let (.text(x), .text(y)):
            return x.compare(y, options: [.caseInsensitive, .numeric], locale: Locale(identifier: "en_GB")) == .orderedAscending
        default: return a.rank < b.rank
        }
    }
}

public struct TableRow {
    public var cells: [String]
    /// One per column, or empty when the columns sort on their text.
    public var sortKeys: [SortKey]
    public var person: Person?
    /// `tone` colours the cell at `toneColumn`, or the whole row when `toneColumn` is nil.
    public var tone: Tone?
    public var toneColumn: Int?
    /// Small print: the reason behind a status, say.
    public var quietColumn: Int?
    public var bold: Bool

    public init(cells: [String], sortKeys: [SortKey] = [], person: Person? = nil, tone: Tone? = nil,
                toneColumn: Int? = nil, quietColumn: Int? = nil, bold: Bool = false) {
        self.cells = cells
        self.sortKeys = sortKeys
        self.person = person
        self.tone = tone
        self.toneColumn = toneColumn
        self.quietColumn = quietColumn
        self.bold = bold
    }

    public func sortKey(column: Int) -> SortKey {
        if column < sortKeys.count { return sortKeys[column] }
        return .text(column < cells.count ? cells[column] : "")
    }
}

/// What every screen comes down to: a grid, the line above it and the status line below it.
public struct AnalysisTable {
    public var columns: [TableColumn]
    public var rows: [TableRow]
    public var head: String
    public var status: String
    /// False when the list could not be narrowed by the game's own interest check, so the UI can say so.
    public var interestChecked: Bool

    public init(columns: [TableColumn] = [], rows: [TableRow] = [], head: String = "", status: String = "",
                interestChecked: Bool = true) {
        self.columns = columns
        self.rows = rows
        self.head = head
        self.status = status
        self.interestChecked = interestChecked
    }

    /// The people listed, in row order: what "Save as FM shortlist" saves.
    public var people: [Person] { rows.compactMap(\.person) }
}
