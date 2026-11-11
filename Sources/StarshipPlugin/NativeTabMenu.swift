import Foundation

/// The arrow beside FM STARSHIP in FM's top bar, and the menu of FM Starship's screens it opens, as FM's own tabs have.
/// Both are plain elements with FM's classes: FM's own dropdown needs FM's data behind it.
@MainActor
struct NativeTabMenu {
    typealias Pointer = IL2CPP.Pointer
    let ui: FMElements

    /// FM's arrow after a tab's name: FM's chevron, in boxes with the names, classes and size of FM's. Returns the
    /// arrow, for the tab's frame, and the box that takes the click.
    func arrow() throws -> (frame: Pointer, arrow: Pointer) {
        let frame = try ui.box(["justify-content-center"], name: "DropdownVisible")
        let remapper = try ui.box(["justify-content-center", "navigation-tab-dropdown-large"])
        // FM's pointing hand over the arrow, as over our subtabs' names.
        let arrow = try ui.box(["navigation-tab-dropdown", "flex-grow-class", "navigatable-no-cursor", "sitext-hover-cursor"],
                               name: "FMStarshipTabDropdown")
        let chevron = try ui.box(["ui-concepts-chevron-down_small", "portal-image", "sitext-hover-cursor"], name: "NavTabDropdownIndicator")
        // FM's sizes for them, which FM's dropdown may set itself.
        for element in [frame, remapper] {
            try ui.style(element) { style in
                try style.length("width", 20)
                try style.length("height", 25)
                try style.number("flexShrink", 0)
            }
        }
        try ui.style(chevron) { style in
            try style.length("width", 16)
            try style.length("height", 16)
            try style.number("flexShrink", 0)
        }
        try ui.add(chevron, to: arrow)
        try ui.add(arrow, to: remapper)
        try ui.add(remapper, to: frame)
        return (frame, arrow)
    }

    /// The menu, under the tab, at the end of FM's main document, so it draws over FM's screens, its report cards and
    /// its floating layer. FM's own menu goes in its floating layer, but FM only makes that while a menu of its own is
    /// open, and takes it away again with it. Its look is that of FM's open menus, which FM's floating element draws, so
    /// it's set here. Returns the menu and its rows, which can be clicked, or nil if the tab isn't laid out.
    func menu(_ entries: [String], current: Int?, under tab: Pointer, in root: Pointer,
              choose: @escaping @MainActor (Int) -> Void) throws -> (menu: Pointer, rows: [Pointer], dim: Pointer)? {
        guard let spot = ui.worldBound(tab), let area = ui.worldBound(root), spot.width > 0, spot.height > 0 else { return nil }
        let origin = Self.origin(under: spot, in: area)
        // FM dims its screen while one of its tab menus is up, below its title bar with the tabs and subtabs, which stay
        // as they are. The pointer passes through it to FM.
        let below = ui.query(root, "OverviewTitleBar").flatMap { ui.worldBound($0) }.flatMap { $0.height > 0 ? $0.y + $0.height : nil }
            ?? spot.y + spot.height
        let dim = try ui.box(name: "FMStarshipTabMenuDim")
        try ui.style(dim) { style in
            try style.keyword("position", 1)
            try style.length("left", 0)
            try style.length("top", max(0, below - area.y))
            try style.percent("width", 100)
            try style.length("bottom", 0)
            try style.color("backgroundColor", Self.dimColour)
        }
        try ui.ignorePointer(dim)
        let menu = try ui.box(name: "FMStarshipTabMenu")
        try ui.style(menu) { style in
            try style.keyword("position", 1)
            try style.length("left", origin.left)
            try style.length("top", origin.top)
            for side in ["Top", "Bottom", "Left", "Right"] {
                try style.color("border\(side)Color", (1, 1, 1, 0.2))
                try style.number("border\(side)Width", 1.142857)
            }
            for corner in ["TopLeft", "TopRight", "BottomLeft", "BottomRight"] { try style.length("border\(corner)Radius", 4) }
            try style.color("backgroundColor", (0.180, 0.192, 0.220, 1))
        }
        var rows: [Pointer] = []
        do {
            for (index, entry) in entries.enumerated() {
                let row = try self.row(entry, current: index == current, first: index == 0, last: index == entries.count - 1)
                try ui.add(row, to: menu)
                try ui.onClick(row) { choose(index) }
                rows.append(row)
            }
            try ui.add(dim, to: root)
            try ui.add(menu, to: root)
        } catch {
            // Nothing of it is in FM's interface, so its rows' clicks go with it.
            for row in rows { ClickActions.actions[row] = nil }
            try? ui.remove(dim)
            throw error
        }
        return (menu, rows, dim)
    }

    /// How much FM's screen darkens under an open tab menu.
    static let dimColour: (Float, Float, Float, Float) = (0, 0, 0, 0.2)

    /// Where the menu goes in FM's main document: just under the tab, from its left edge.
    nonisolated static func origin(under tab: (x: Float, y: Float, width: Float, height: Float),
                                   in area: (x: Float, y: Float, width: Float, height: Float)) -> (left: Float, top: Float) {
        (max(0, tab.x - area.x), max(0, tab.y + tab.height + 2 - area.y))
    }

    /// One of FM's menu rows: an indicator on each side, as FM's have, and the screen's name between them. Every row
    /// looks the same, the current screen's too, as in FM's own menus.
    private func row(_ entry: String, current: Bool, first: Bool, last: Bool) throws -> Pointer {
        let row = try ui.box(["sub-dropdown-content-container", "streamed-list-view-item", "streamed-list-view__row--interactable",
                              "virtualised-list__item", "navigatable-no-cursor", "row-direction-normal", "align-items-center",
                              "sitext-hover-cursor"]
                             + (first ? ["virtualised-list__item--first"] : []) + (last ? ["virtualised-list__item--last"] : []))
        try ui.style(row) { style in
            try style.length("height", 30)
            try style.length("paddingLeft", 4)
            try style.length("paddingRight", 4)
            try style.number("flexShrink", 0)
        }
        try ui.add(try indicator("LeftIconIndicator"), to: row)
        let lit = try ui.box(["flex-grow-class"])
        try ui.style(lit) { style in
            try style.number("flexGrow", 1)
            try style.length("marginLeft", 4)
            try style.length("marginRight", 4)
        }
        let item = try ui.box(["navigation-_navigation-dropdown-menu_item_base-default", "flex-grow-class", "row-direction-normal",
                               "justify-content-space-between", "no-margin", "align-items-center"])
        try ui.add(try ui.text(entry, ["body-md", "secondary-navigation-tab-text", "content-no-wrap", "sitext-hover-cursor"], name: "NavEntry"),
                   to: item)
        try ui.add(item, to: lit)
        try ui.add(lit, to: row)
        try ui.add(try indicator("RightIconIndicator"), to: row)
        return row
    }

    private func indicator(_ name: String) throws -> Pointer {
        let box = try ui.box(["indicator", "justify-content-center", "align-items-center"], name: name)
        try ui.style(box) { style in
            try style.length("width", 16)
            try style.length("height", 16)
            try style.number("flexShrink", 0)
        }
        return box
    }
}
