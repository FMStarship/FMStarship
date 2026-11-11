import Foundation
@preconcurrency import StarshipAnalysis
import StarshipCore

/// The app's Players or Staff search as one of FM Starship's screens inside FM: what the search found, in FM's own
/// table, with the filters set in the app's Players or Staff screen, which a button opens over FM.
struct PeopleListView {
    let staff: Bool
    /// Its first `limit` people, in the search's order, with the engine's CA and PA where they're shown.
    let table: AnalysisTable
    let found: Int
    let filter: String

    /// Most people FM's table is given. FM's own long lists stream their rows from the game; ours are made up front.
    static let limit = 500

    init(people: [Person], staff: Bool, filter: String, display: DisplayOptions) {
        self.staff = staff
        self.filter = filter
        found = people.count
        var table = AnalysisTable(columns: ["Name", "CA", "PA"].map { TableColumn($0, 5) })
        table.rows = people.prefix(Self.limit).map { person in
            let ability = Self.ability(of: person)
            return TableRow(cells: [person.name, display.ability(ability.ca), display.ability(ability.pa)], person: person)
        }
        self.table = display.fit(table)
    }

    /// Players and staff each have a CA and PA of their own.
    private static func ability(of person: Person) -> (ca: Int, pa: Int) {
        if let player = person as? Player { return (player.ca, player.pa) }
        if let staff = person as? Staff { return (staff.ca, staff.pa) }
        return (0, 0)
    }

    var title: String { staff ? "Staff" : "Players" }

    /// How many were found and how many are shown.
    var count: String {
        let kind = staff ? "staff" : (found == 1 ? "player" : "players")
        guard found > Self.limit else { return "\(found.formatted()) \(kind) found." }
        return "The first \(Self.limit.formatted()) of \(found.formatted()) \(kind) found, in the search's order. Narrow the search with Filters to see the rest."
    }
}

/// The Players and Staff screens, made of FM's elements.
@MainActor
struct NativeSearch {
    typealias Pointer = IL2CPP.Pointer
    /// Puts one of FM's tables with a section's people in a container already in FM's tree, filling it.
    typealias AddTable = (_ section: TableSection, _ container: Pointer) throws -> Void

    let page: NativePage
    private var ui: FMElements { page.ui }

    /// FM's own columns for each kind of list, by their IDs in FM's factories.
    static let playerColumns = ["name", "age", "nation", "club", "scouted-best-position-and-role", "transfer-value", "wage",
                                "scout-opinion-current-ability", "scout-opinion-potential-ability"]
    static let staffColumns = ["portrait-name", "age", "nation-small", "club", "clubjob", "context-contract-wage-no-border",
                               "context-contract-expiry-date-small"]

    /// Returns the Filters button, which `editFilters` is called for when clicked, and while a search runs, the line
    /// that says how it's going.
    @discardableResult
    func build(into body: Pointer, list: PeopleListView, searching: String?, settings: Pointer, table: AddTable,
               editFilters: @escaping @MainActor () -> Void) throws -> (filters: Pointer, progress: Pointer?) {
        let tile = try page.tile()
        try ui.style(tile) { try $0.number("flexGrow", 1) }
        try ui.add(tile, to: body)

        // FM's table grows to fill the tile, and would squeeze the row above it.
        let top = try ui.box(["row-direction-normal", "align-items-center"])
        try ui.style(top) { try $0.number("flexShrink", 0) }
        let heading = try ui.box()
        try ui.style(heading) { try $0.number("flexGrow", 1) }
        try page.heading(list.title, note: list.filter.isEmpty ? "No filters." : list.filter, in: heading)
        try ui.add(heading, to: top)
        let button = try filtersButton()
        try ui.add(button, to: top)
        try ui.onClick(button) { editFilters() }
        try ui.add(settings, to: top)
        try ui.add(top, to: tile)

        var progress: Pointer?
        if let searching {
            let line = try ui.text(searching, ["body-md", "global-text-secondary"])
            try ui.add(line, to: tile)
            progress = line
        } else if list.table.rows.isEmpty {
            try ui.add(try ui.text("Nobody matches these filters.", ["body-md", "global-text-secondary"]), to: tile)
        } else {
            let columns = list.staff ? Self.staffColumns : Self.playerColumns
            try table(TableSection(title: list.title, table: list.table, fmColumns: columns, fmExtras: ["CA", "PA"],
                                   kind: list.staff ? .staff : .players), tile)
            try ui.add(try page.spaced(try ui.text(list.count, ["body-sm", "global-text-secondary"]), top: 8), to: tile)
        }
        return (button, progress)
    }

    /// A button like FM's own small ones, which opens the app's filters for the list.
    private func filtersButton() throws -> Pointer {
        let button = try ui.box(["sitext-hover-cursor", "row-direction-normal", "align-items-center"])
        try ui.style(button) { style in
            for side in ["Top", "Bottom"] { try style.length("padding\(side)", 6) }
            for side in ["Left", "Right"] { try style.length("padding\(side)", 14) }
            for side in ["Top", "Bottom", "Left", "Right"] {
                try style.color("border\(side)Color", page.look.border)
                try style.number("border\(side)Width", 1)
            }
            for corner in ["TopLeft", "TopRight", "BottomLeft", "BottomRight"] { try style.length("border\(corner)Radius", 6) }
            try style.color("backgroundColor", (1, 1, 1, 0.05))
        }
        try ui.add(try ui.text("Filters", ["body-md-strong", "global-text-primary", "sitext-hover-cursor"]), to: button)
        return button
    }
}
