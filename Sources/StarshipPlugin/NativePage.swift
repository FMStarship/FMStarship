import Foundation
@preconcurrency import StarshipAnalysis

/// FM Starship's screens inside FM, under its own subtabs.
enum StarshipScreen: CaseIterable {
    case dashboard, signings, planner, bargains, shortlists, players, staff

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .signings: return "Recommended signings"
        case .planner: return "Squad planner"
        case .bargains: return "Bargains"
        case .shortlists: return "Shortlists"
        case .players: return "Players"
        case .staff: return "Staff"
        }
    }

    /// What the screen says while its work runs, the app's own words.
    var working: String {
        switch self {
        case .dashboard: return "Going through your club..."
        case .signings: return "Finding players who'd join you..."
        case .planner: return "Going through your first team..."
        case .bargains: return "Finding bargains..."
        case .shortlists: return "Reading your shortlists..."
        case .players, .staff: return "Searching..."
        }
    }

    /// For the app's Players and Staff searches: whether the list is staff. Nil for the other screens.
    var listsStaff: Bool? {
        switch self {
        case .players: return false
        case .staff: return true
        default: return nil
        }
    }
}

/// What a screen shows once its work is done.
enum ScreenContent {
    case dashboard(ClubDashboard)
    case tables([TableSection])
    case shortlists([ShortlistView])
}

/// One of the engine's tables on a screen, with a heading over it.
struct TableSection {
    let title: String
    let table: AnalysisTable
    var notes: [String] = []
    /// When set, the list goes in FM's own player table with these of FM's columns, instead of the engine's columns.
    var fmColumns: [String]?
    /// The engine's columns to keep beside FM's, by title, where the engine has them.
    var fmExtras: [String] = []
    /// Which of FM's tables the list goes in: its players', or its other people's, such as staff.
    var kind = FMTable.Kind.players
}

extension TableSection {
    /// Whether anybody in the list is for a table. FM's table with nobody in it would stand empty, with no word of why.
    var hasPeople: Bool { table.rows.contains { $0.person != nil } }

    /// The small print under the list's heading: the engine's line over the list, while there's a table under it.
    var headingNote: String { hasPeople ? table.head : "" }

    /// What a list with nobody in it says where its table would be, in the screen's own size of text: the engine's
    /// line over the list, such as why youngsters need Hidden attributes. Without one, the lines under the list say
    /// why, and without those either, that there's nobody. Nil while there's somebody to show.
    var inPlaceOfTable: String? {
        guard !hasPeople else { return nil }
        if !table.head.isEmpty { return table.head }
        let below = table.rows.contains { $0.cells.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
            || !NativePage.withoutAppHints(table.status).isEmpty || notes.contains { !$0.isEmpty }
        return below ? nil : "Nobody to show."
    }
}

/// The pieces FM Starship's screens are made of, from FM's elements and style classes.
@MainActor
struct NativePage {
    typealias Pointer = IL2CPP.Pointer
    let ui: FMElements
    let look: TileLook

    /// Most rows a table shows. FM's own long lists scroll through thousands lazily; these are built whole.
    static let rowLimit = 60

    /// The page's scrolling body, filling the screen, with room at the edges like FM's screens.
    func body(in screen: Pointer) throws -> Pointer {
        let scroll = try ui.scrollView(["siscrollview"], name: "FMStarshipScroll")
        try ui.style(scroll) { try $0.number("flexGrow", 1) }
        try ui.add(scroll, to: screen)
        let page = try ui.box(name: "FMStarshipPage")
        try ui.style(page) { style in
            try style.length("paddingLeft", 28)
            try style.length("paddingRight", 28)
            try style.length("paddingTop", 20)
            try style.length("paddingBottom", 28)
        }
        try ui.add(page, to: scroll)
        return page
    }

    /// A page that doesn't scroll, for one of FM's own lists, which scrolls itself and fills the screen like FM's.
    func fixedBody(in screen: Pointer) throws -> Pointer {
        let page = try ui.box(name: "FMStarshipPage")
        try ui.style(page) { style in
            try style.number("flexGrow", 1)
            try style.length("paddingLeft", 28)
            try style.length("paddingRight", 28)
            try style.length("paddingTop", 20)
            try style.length("paddingBottom", 12)
        }
        try ui.add(page, to: screen)
        return page
    }

    /// A tile like FM's: its background, border and corners, with room inside and below. Without a width it
    /// stretches across the page.
    func tile(width: Float? = nil) throws -> Pointer {
        let tile = try ui.box(["si-tile"])
        try ui.style(tile) { style in
            if let width { try style.length("width", width) }
            try style.length("marginRight", 16)
            try style.length("marginBottom", 16)
            for side in ["Top", "Bottom", "Left", "Right"] {
                try style.length("padding\(side)", 16)
                try style.color("border\(side)Color", look.border)
                try style.number("border\(side)Width", look.borderWidth)
            }
            for corner in ["TopLeft", "TopRight", "BottomLeft", "BottomRight"] { try style.length("border\(corner)Radius", look.radius) }
            try style.color("backgroundColor", look.background)
        }
        return tile
    }

    /// A tile's heading in FM's capitals, and a line under it in small print.
    func heading(_ title: String, note: String = "", in tile: Pointer) throws {
        try ui.add(try ui.text(title.uppercased(), ["thematic-sm", "global-text-primary"]), to: tile)
        if !note.isEmpty {
            try ui.add(try spaced(try ui.text(note, ["body-sm", "global-text-secondary"]), top: 2), to: tile)
        }
        try ui.add(try spaced(try ui.box(), bottom: 8), to: tile)
    }

    /// What's happening, or why there's nothing to show, in a tile of its own.
    func message(_ text: String, title: String, in page: Pointer) throws {
        let tile = try tile(width: 520)
        try heading(title, in: tile)
        try ui.add(try ui.text(text, ["body-md", "global-text-secondary"]), to: tile)
        try ui.add(tile, to: page)
    }

    func divider() throws -> Pointer {
        try ui.box(["layout-layout-divider-solid-horizontal"])
    }

    func spaced(_ element: Pointer, top: Float = 0, bottom: Float = 0) throws -> Pointer {
        try ui.style(element) { style in
            if top > 0 { try style.length("marginTop", top) }
            if bottom > 0 { try style.length("marginBottom", bottom) }
        }
        return element
    }

    /// The app's tones in colours close to FM's own greens, ambers and reds. Plain text has none of its own.
    nonisolated static func colour(of tone: Tone) -> (Float, Float, Float, Float)? {
        switch tone {
        case .good, .growth, .star: return (0.42, 0.84, 0.55, 1)
        case .fair: return (0.96, 0.76, 0.30, 1)
        case .bad: return (0.95, 0.43, 0.43, 1)
        case .muted: return (0.62, 0.64, 0.72, 1)
        case .text: return nil
        }
    }

    func colour(_ element: Pointer, _ tone: Tone) throws {
        guard let colour = Self.colour(of: tone) else { return }
        try ui.style(element) { try $0.color("color", colour) }
    }

    // MARK: Tables

    /// An engine table as FM's rows: the line above it, a header in small print, a row per entry between dividers,
    /// and the status line below. Columns share the width by the engine's own weights. `hint` is a line between the
    /// heading and the rows.
    func table(_ section: TableSection, in page: Pointer, hint: String? = nil) throws {
        let tile = try tile()
        try heading(section.title, note: section.headingNote, in: tile)
        if let hint { try self.hint(hint, in: tile) }
        if let line = section.inPlaceOfTable { try ui.add(try ui.text(line, ["body-md", "global-text-secondary"]), to: tile) }
        try rows(of: section, in: tile)
        try ui.add(tile, to: page)
    }

    /// A line over a list, such as `tableHint`.
    func hint(_ text: String, in tile: Pointer) throws {
        try ui.add(try spaced(try ui.text(text, ["body-sm", "global-text-secondary"]), bottom: 8), to: tile)
    }

    /// What a list says when it's in plain rows because FM's own table of its kind isn't known yet: the tables are
    /// taken from one of FM's own lists, so opening one gets them.
    nonisolated static func tableHint(_ kind: FMTable.Kind) -> String {
        switch kind {
        case .players:
            return "Open one of FM's own player lists, such as your Squad, then come back here to get FM's tables, with sorting and right-click."
        case .staff:
            return "Open one of FM's own staff lists, such as Club > Staff, then come back here to get FM's tables, with sorting and right-click."
        }
    }

    /// An engine table's header, rows and status line, in a tile that has its heading already.
    func rows(of section: TableSection, in tile: Pointer) throws {
        let table = section.table
        let total = Float(max(1, table.columns.reduce(0) { $0 + $1.weight }))
        let widths = table.columns.map { Float($0.weight) / total * 100 }

        if !table.rows.isEmpty {
            let header = try ui.box(["row-direction-normal", "align-items-center"])
            for (index, column) in table.columns.enumerated() {
                try ui.add(try cell(column.title, width: widths[index], classes: ["body-sm-strong", "global-text-secondary"]), to: header)
            }
            try ui.add(try spaced(header, bottom: 6), to: tile)
        }
        for row in table.rows.prefix(Self.rowLimit) {
            try ui.add(try divider(), to: tile)
            let line = try ui.box(["row-direction-normal", "align-items-center"])
            try ui.style(line) { style in
                try style.length("paddingTop", 6)
                try style.length("paddingBottom", 6)
            }
            for (index, text) in row.cells.enumerated() where index < widths.count {
                let quiet = row.quietColumn == index
                let classes = quiet ? ["body-sm", "global-text-secondary"]
                    : [row.bold ? "body-md-strong" : "body-md", "global-text-primary", "content-no-wrap", "content-ellipsis"]
                let element = try cell(text, width: widths[index], classes: classes)
                if let tone = row.tone, row.toneColumn == nil || row.toneColumn == index { try colour(element, tone) }
                try ui.add(element, to: line)
            }
            try ui.add(line, to: tile)
        }
        var status = Self.withoutAppHints(table.status)
        if table.rows.count > Self.rowLimit {
            status = ["The first \(Self.rowLimit) of \(table.rows.count) are shown.", status].filter { !$0.isEmpty }.joined(separator: " ")
        }
        if !status.isEmpty {
            try ui.add(try spaced(try ui.text(status, ["body-sm", "global-text-secondary"]), top: 10), to: tile)
        }
        for note in section.notes where !note.isEmpty {
            try ui.add(try spaced(try ui.text(note, ["body-sm", "global-text-secondary"]), top: 4), to: tile)
        }
    }

    /// The engine's status lines end with the app's hints, such as double-clicking for the full profile, which these
    /// screens can't do yet. Those sentences are left out.
    nonisolated static func withoutAppHints(_ status: String) -> String {
        let sentences = status.components(separatedBy: ". ")
        let kept = sentences.filter { !$0.hasPrefix("Double-click") }
        guard kept.count < sentences.count else { return status }
        var line = kept.joined(separator: ". ")
        if !line.isEmpty, !line.hasSuffix(".") { line += "." }
        return line
    }

    private func cell(_ text: String, width: Float, classes: [String]) throws -> Pointer {
        let element = try ui.text(text, classes)
        try ui.style(element) { style in
            try style.percent("width", width)
            try style.length("paddingRight", 8)
        }
        return element
    }
}
