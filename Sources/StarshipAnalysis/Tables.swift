import Foundation
import StarshipCore

/// The colours the original forms pick from `Theme`.
public enum Tone {
    case text, muted, good, fair, bad, star, growth
}

public struct TableColumn: Equatable {
    public let title: String
    public let weight: Int
    public let order: Order

    /// How a column of positions sorts: in FM's order for its own Position column, not by its text.
    public enum Order: Equatable {
        case text
        /// Each row's player's positions: by the position they're rated best at, as FM sorts its Position column.
        case playerPosition
        /// A place, such as a tactic's DC (R), or the planner's Right-back: by the place the text names.
        case place
    }

    public init(_ title: String, _ weight: Int, order: Order = .text) {
        self.title = title
        self.weight = weight
        self.order = order
    }
}

extension TableColumn.Order {
    /// Where a row stands in FM's order of positions, or nil where the column sorts by its text or the row names no
    /// position. A row without a player goes by its text.
    public func rank(_ text: String, person: Person?) -> Int? {
        switch self {
        case .text: return nil
        case .playerPosition: return (person as? Player).flatMap(PositionOrder.rank(of:)) ?? PositionOrder.rank(text)
        case .place: return PositionOrder.rank(text)
        }
    }

    /// Whether one row goes before another in FM's order of positions, or nil where that doesn't decide, and the
    /// column's usual sort does. A row the order can't place goes after one it can, either way round.
    public func precedes(_ a: String, _ first: Person?, _ b: String, _ second: Person?, descending: Bool) -> Bool? {
        switch (rank(a, person: first), rank(b, person: second)) {
        case let (x?, y?): return x == y ? nil : descending ? x > y : x < y
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return nil
        }
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

    /// The rows' indices as a click on a column's heading sorts them: positions in FM's order for them, otherwise by
    /// the column's sort keys, with ties in the engine's order.
    public func sortedIndices(byColumn column: Int, descending: Bool) -> [Int] {
        let order = column < columns.count ? columns[column].order : .text
        func text(_ row: TableRow) -> String { column < row.cells.count ? row.cells[column] : "" }
        return rows.indices.sorted { a, b in
            if let first = order.precedes(text(rows[a]), rows[a].person, text(rows[b]), rows[b].person, descending: descending) {
                return first
            }
            let x = rows[a].sortKey(column: column), y = rows[b].sortKey(column: column)
            if x == y { return a < b }
            return descending ? y < x : x < y
        }
    }

    /// Columns that are CA or PA, or say what they are by the difference between two of them.
    static let abilityColumns: Set<String> = ["CA", "PA", "Likely peak", "Room to grow", "vs best", "vs your best"]

    /// A row coloured by a column that goes loses the colour too, since the colour says what the column did.
    func removing(_ titles: Set<String>) -> AnalysisTable {
        let kept = columns.indices.filter { !titles.contains(columns[$0].title) }
        guard kept.count < columns.count else { return self }
        var table = self
        table.columns = kept.map { columns[$0] }
        table.rows = rows.map { old in
            var row = old
            row.cells = kept.filter { $0 < old.cells.count }.map { old.cells[$0] }
            row.sortKeys = kept.filter { $0 < old.sortKeys.count }.map { old.sortKeys[$0] }
            row.toneColumn = old.toneColumn.flatMap { kept.firstIndex(of: $0) }
            row.quietColumn = old.quietColumn.flatMap { kept.firstIndex(of: $0) }
            if old.toneColumn != nil, row.toneColumn == nil { row.tone = nil }
            return row
        }
        return table
    }
}
