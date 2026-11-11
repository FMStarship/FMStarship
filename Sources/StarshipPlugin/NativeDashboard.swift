import Foundation
@preconcurrency import StarshipAnalysis
import StarshipCore

/// The club dashboard as a screen of FM's own: the app's Dashboard, made of FM's elements and text classes, with its
/// lists of people in FM's own player table, so names open FM's profiles and FM's right-click menu works on them.
/// What it shows comes from ClubDashboard, which already leaves out what Hidden attributes hides.
@MainActor
struct NativeDashboard {
    typealias Pointer = IL2CPP.Pointer
    /// Puts one of FM's tables with a section's people in a container already in FM's tree, tall enough for so many
    /// rows, with these of FM's columns.
    typealias AddTable = (_ section: TableSection, _ columns: [String], _ container: Pointer, _ rows: Int) throws -> Void

    let page: NativePage
    private var ui: FMElements { page.ui }

    /// FM's columns for the club's own players: who they are, how old, and where and how they play.
    static let playerColumns = ["name", "age", "scouted-best-position-and-role"]

    /// `settings` go at the right of the club's name, in the screen's title row.
    func build(into body: Pointer, dashboard: ClubDashboard, settings: Pointer, table: AddTable) throws {
        let title = try ui.box(["row-direction-normal", "align-items-center"])
        let heading = try ui.box()
        try ui.style(heading) { try $0.number("flexGrow", 1) }
        try ui.add(try ui.text(dashboard.club, ["heading-xl", "global-text-primary"]), to: heading)
        try ui.add(try page.spaced(try ui.text(dashboard.line, ["body-md", "global-text-secondary"]), top: 4), to: heading)
        try ui.add(heading, to: title)
        try ui.add(settings, to: title)
        try ui.add(try page.spaced(title, bottom: 16), to: body)

        let facts = try ui.box(["row-direction-normal"])
        for fact in dashboard.facts {
            let tile = try page.tile(width: 200)
            try ui.add(try ui.text(fact.label, ["body-md-strong", "global-text-primary"]), to: tile)
            try ui.add(try page.spaced(try ui.text(fact.value, ["heading-xl", "brand-foundation-horizon-color"]), top: 6), to: tile)
            try ui.add(tile, to: facts)
        }
        try ui.add(facts, to: body)

        // The tables go in once their tiles are in FM's tree, which FM's tables need to bind.
        let columns = try ui.box(["row-direction-normal", "align-items-start"])
        try ui.add(columns, to: body)
        if dashboard.showsAbility { try talent(dashboard, in: columns, table: table) }
        try health(dashboard, in: columns, table: table)
    }

    /// A tile sharing the row with the one beside it.
    private func half(in row: Pointer) throws -> Pointer {
        let tile = try page.tile()
        try ui.style(tile) { style in
            try style.number("flexGrow", 1)
            try style.number("flexShrink", 1)
            try style.length("flexBasis", 0)
        }
        try ui.add(tile, to: row)
        return tile
    }

    /// Who's 23 or younger, by how good they're likely to get. Only there with Hidden attributes on.
    private func talent(_ dashboard: ClubDashboard, in row: Pointer, table: AddTable) throws {
        let tile = try half(in: row)
        try page.heading("Young talent", note: "Ability now, then likely peak.", in: tile)
        guard !dashboard.prospects.isEmpty else {
            try ui.add(try ui.text("Nobody at the club is 23 or younger.", ["body-md", "global-text-secondary"]), to: tile)
            return
        }
        let rows = dashboard.prospects.map { prospect in
            TableRow(cells: [prospect.player.name, prospect.path, prospect.verdict?.title ?? "", prospect.odds ?? ""],
                     person: prospect.player, tone: prospect.verdict?.tone, toneColumn: 2)
        }
        let analysis = AnalysisTable(columns: ["Name", "Now → peak", "Outlook", "Odds"].map { TableColumn($0, 5) }, rows: rows)
        try table(TableSection(title: "Young talent", table: analysis, fmColumns: Self.playerColumns,
                               fmExtras: ["Now → peak", "Outlook", "Odds"]), Self.playerColumns, tile, rows.count)
    }

    /// Who needs something done, worst first.
    private func health(_ dashboard: ClubDashboard, in row: Pointer, table: AddTable) throws {
        let tile = try half(in: row)
        try page.heading("Health check", note: "What wants acting on at the club.", in: tile)
        guard !dashboard.issues.isEmpty else {
            try ui.add(try ui.text("Nobody needs action.", ["body-md", "global-text-secondary"]), to: tile)
            return
        }
        let rows = dashboard.issues.compactMap { issue in
            issue.person.map { TableRow(cells: [issue.name, issue.issue, issue.detail], person: $0, tone: issue.tone, toneColumn: 1) }
        }
        if !rows.isEmpty {
            let analysis = AnalysisTable(columns: ["Name", "Issue", "Detail"].map { TableColumn($0, 5) }, rows: rows)
            try table(TableSection(title: "Health check", table: analysis, fmColumns: ["name", "age"], fmExtras: ["Issue", "Detail"]),
                      ["name", "age"], tile, rows.count)
        }
        // Anything that isn't about one person stays a line of text.
        for issue in dashboard.issues where issue.person == nil {
            let label = try ui.text("\(issue.name): \(issue.issue). \(issue.detail)", ["body-sm", "global-text-secondary"])
            try page.colour(label, issue.tone)
            try ui.add(try page.spaced(label, top: 6), to: tile)
        }
    }
}
