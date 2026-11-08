import Foundation
@preconcurrency import StarshipAnalysis

/// The club dashboard as a screen of FM's own: the app's Dashboard, made of FM's elements and text classes.
/// What it shows comes from ClubDashboard, which already leaves out what Hidden attributes hides.
@MainActor
struct NativeDashboard {
    typealias Pointer = IL2CPP.Pointer
    let page: NativePage
    private var ui: FMElements { page.ui }

    func build(into body: Pointer, dashboard: ClubDashboard) throws {
        let heading = try ui.box()
        try ui.add(try ui.text(dashboard.club, ["heading-xl", "global-text-primary"]), to: heading)
        try ui.add(try page.spaced(try ui.text(dashboard.line, ["body-md", "global-text-secondary"]), top: 4), to: heading)
        try ui.add(try page.spaced(heading, bottom: 16), to: body)

        let facts = try ui.box(["row-direction-normal"])
        for fact in dashboard.facts {
            let tile = try page.tile(width: 200)
            try ui.add(try ui.text(fact.label, ["body-md-strong", "global-text-primary"]), to: tile)
            try ui.add(try page.spaced(try ui.text(fact.value, ["heading-xl", "brand-foundation-horizon-color"]), top: 6), to: tile)
            try ui.add(tile, to: facts)
        }
        try ui.add(facts, to: body)

        let columns = try ui.box(["row-direction-normal", "align-items-start"])
        if dashboard.showsAbility { try ui.add(try talent(dashboard), to: columns) }
        try ui.add(try health(dashboard), to: columns)
        try ui.add(columns, to: body)
    }

    /// Who's 23 or younger, by how good they're likely to get. Only there with Hidden attributes on.
    private func talent(_ dashboard: ClubDashboard) throws -> Pointer {
        let tile = try page.tile(width: 476)
        try page.heading("Young talent", note: "Ability now, then likely peak.", in: tile)
        if dashboard.prospects.isEmpty {
            try ui.add(try ui.text("Nobody at the club is 23 or younger.", ["body-md", "global-text-secondary"]), to: tile)
        }
        for prospect in dashboard.prospects {
            try ui.add(try page.divider(), to: tile)
            let row = try ui.box(["row-direction-normal", "align-items-center"])
            try ui.add(try ui.text(prospect.player.name, ["body-md-strong", "global-text-primary", "flex-grow-class"]), to: row)
            try ui.add(try ui.text(prospect.path, ["body-md", "global-text-secondary"]), to: row)
            try ui.add(try page.spaced(row, top: 8), to: tile)
            var parts = ["Age \(prospect.player.age)"]
            if let verdict = prospect.verdict { parts.append(verdict.title) }
            if let odds = prospect.odds { parts.append(odds) }
            let detail = try ui.text(parts.joined(separator: " · "), ["body-sm", "global-text-secondary"])
            if let tone = prospect.verdict?.tone { try page.colour(detail, tone) }
            try ui.add(try page.spaced(detail, top: 2, bottom: 8), to: tile)
        }
        return tile
    }

    /// Who needs something done, worst first.
    private func health(_ dashboard: ClubDashboard) throws -> Pointer {
        let tile = try page.tile(width: 476)
        try page.heading("Health check", note: "What wants acting on at the club.", in: tile)
        if dashboard.issues.isEmpty {
            try ui.add(try ui.text("Nobody needs action.", ["body-md", "global-text-secondary"]), to: tile)
        }
        for issue in dashboard.issues {
            try ui.add(try page.divider(), to: tile)
            let row = try ui.box(["row-direction-normal", "align-items-center"])
            try ui.add(try ui.text(issue.name, ["body-md-strong", "global-text-primary", "flex-grow-class"]), to: row)
            let label = try ui.text(issue.issue, ["body-sm-strong"])
            try page.colour(label, issue.tone)
            try ui.add(label, to: row)
            try ui.add(try page.spaced(row, top: 8), to: tile)
            try ui.add(try page.spaced(try ui.text(issue.detail, ["body-sm", "global-text-secondary"]), top: 2, bottom: 8), to: tile)
        }
        return tile
    }
}
