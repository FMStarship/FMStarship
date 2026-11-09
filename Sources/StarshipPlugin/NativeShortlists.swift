import Foundation
@preconcurrency import StarshipAnalysis
import StarshipCore
import StarshipFiles

/// One of FM's player shortlist files as the Shortlists screen shows it: its players in the file's order, as the app's
/// Shortlists screen has them, without anyone already at your club, who stay in the file for other saves.
struct ShortlistView {
    let url: URL
    let name: String
    let modified: Date
    let table: AnalysisTable
    /// On the list but already at your club, so not shown.
    let atClub: Int
    /// On the list but not in this save's database, such as someone who has retired.
    let missing: Int

    var people: Int { table.rows.count }

    init(url: URL, name: String, modified: Date, uids: [UInt32], players: [UInt32: Player], club: String, display: DisplayOptions) {
        self.url = url
        self.name = name
        self.modified = modified
        var seen = Set<UInt32>()
        let found = uids.filter { seen.insert($0).inserted }.compactMap { players[$0] }
        missing = seen.count - found.count
        let shown = found.filter { $0.clubFull != club }
        atClub = found.count - shown.count
        var table = AnalysisTable(columns: ["Name", "CA", "PA"].map { TableColumn($0, 5) })
        table.rows = shown.map { TableRow(cells: [$0.name, display.ability($0.ca), display.ability($0.pa)], person: $0) }
        self.table = display.fit(table)
    }

    /// What's on the list but not shown, in a line under it.
    var left: String {
        var parts: [String] = []
        if atClub > 0 { parts.append("\(atClub) already at your club \(atClub == 1 ? "isn't" : "aren't") shown") }
        if missing > 0 { parts.append("\(missing) \(missing == 1 ? "isn't" : "aren't") in this save") }
        guard !parts.isEmpty else { return "" }
        return parts.joined(separator: ", and ") + ". They stay in the file, so the shortlist keeps working in other saves."
    }
}

/// The Shortlists screen, made of FM's elements: FM's player shortlist files on the left, and the one you chose in
/// FM's own player table. It only reads the files; FM's Shortlist screen and the app are where they're changed.
@MainActor
struct NativeShortlists {
    typealias Pointer = IL2CPP.Pointer
    /// Puts one of FM's tables with a section's people in a container already in FM's tree, filling it.
    typealias AddTable = (_ section: TableSection, _ container: Pointer) throws -> Void

    let page: NativePage
    private var ui: FMElements { page.ui }

    private static let dateFormat: DateFormatter = {
        let format = DateFormatter()
        format.dateStyle = .medium
        format.timeStyle = .none
        return format
    }()

    /// Returns the list's entries, which `choose` is called for when clicked.
    @discardableResult
    func build(into body: Pointer, lists: [ShortlistView], chosen: URL?, columns: [String], table: AddTable,
               choose: @escaping @MainActor (URL) -> Void) throws -> [Pointer] {
        guard let open = lists.first(where: { $0.url == chosen }) ?? lists.first else {
            try page.message("No player shortlists yet. FM Starship's own lists, opened with Control-Option-S, can put players on a new one.",
                             title: "Shortlists", in: body)
            return []
        }
        let row = try ui.box(["row-direction-normal"])
        try ui.style(row) { try $0.number("flexGrow", 1) }
        try ui.add(row, to: body)

        let side = try page.tile(width: 280)
        try page.heading("Player shortlists", note: "FM's own shortlist files.", in: side)
        try ui.add(side, to: row)
        var entries: [Pointer] = []
        for list in lists {
            let entry = try self.entry(list, chosen: list.url == open.url)
            try ui.add(entry, to: side)
            try ui.onClick(entry) { choose(list.url) }
            entries.append(entry)
        }

        let main = try page.tile()
        try ui.style(main) { style in
            try style.number("flexGrow", 1)
            try style.number("flexShrink", 1)
            try style.length("flexBasis", 0)
        }
        try page.heading(open.name, note: "\(open.people) \(open.people == 1 ? "player" : "players") · saved \(Self.dateFormat.string(from: open.modified))",
                         in: main)
        try ui.add(main, to: row)
        if open.people > 0 {
            try table(TableSection(title: open.name, table: open.table, fmColumns: columns, fmExtras: ["CA", "PA"]), main)
        } else {
            try ui.add(try ui.text("Nobody on this shortlist is shown here.", ["body-md", "global-text-secondary"]), to: main)
        }
        if !open.left.isEmpty {
            try ui.add(try page.spaced(try ui.text(open.left, ["body-sm", "global-text-secondary"]), top: 8), to: main)
        }
        return entries
    }

    /// A shortlist in the list on the left: its name, then how many and when, with the open one marked.
    private func entry(_ list: ShortlistView, chosen: Bool) throws -> Pointer {
        let entry = try ui.box(["sitext-hover-cursor"])
        try ui.style(entry) { style in
            for side in ["Top", "Bottom"] { try style.length("padding\(side)", 8) }
            for side in ["Left", "Right"] { try style.length("padding\(side)", 10) }
            for corner in ["TopLeft", "TopRight", "BottomLeft", "BottomRight"] { try style.length("border\(corner)Radius", 6) }
            try style.length("marginBottom", 2)
            if chosen { try style.color("backgroundColor", (1, 1, 1, 0.07)) }
        }
        let name = try ui.text(list.name, ["body-md-strong", chosen ? "brand-foundation-horizon-color" : "global-text-primary",
                                           "content-no-wrap", "content-ellipsis", "sitext-hover-cursor"])
        try ui.add(name, to: entry)
        let line = "\(list.people) \(list.people == 1 ? "player" : "players") · \(Self.dateFormat.string(from: list.modified))"
        try ui.add(try page.spaced(try ui.text(line, ["body-sm", "global-text-secondary", "sitext-hover-cursor"]), top: 2), to: entry)
        return entry
    }
}
