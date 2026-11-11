import Foundation
import StarshipCore

/// What the Edit Search page's controls do when clicked.
struct EditSearchActions {
    /// A dropdown: its criterion, and the dropdown, for its list to open under.
    let open: @MainActor (_ id: String, _ dropdown: IL2CPP.Pointer) -> Void
    /// A switch: its criterion, and the switch, which may have changed itself already.
    let toggled: @MainActor (_ id: String, _ toggle: IL2CPP.Pointer) -> Void
    /// A position on the pitch, or -1 for any.
    let position: @MainActor (_ position: Int) -> Void
    let clearAll: @MainActor () -> Void
    let cancel: @MainActor () -> Void
    let apply: @MainActor () -> Void
}

/// FM's Edit Search, for the Recommended signings and Bargains screens, made of FM's elements and style classes as on
/// FM's own for its player database: a pitch to pick a position on, dropdowns and switches beside it, and Clear all,
/// Cancel and Apply below. Nothing is searched until Apply.
@MainActor
struct NativeEditSearch {
    typealias Pointer = IL2CPP.Pointer
    let page: NativePage
    private var ui: FMElements { page.ui }

    /// FM's buttons, by their style classes.
    enum Button: String {
        case primary = "buttons-button-primary-default"
        case secondary = "buttons-button-secondary-default"
        case base = "buttons-button-base-default"
    }

    /// The page's clickable elements, for forgetting their clicks when it goes, and its switches, to read back.
    struct Built {
        var clickable: [Pointer] = []
        var toggles: [(id: String, element: Pointer)] = []
    }

    /// FM's player database's buttons over its list, for a screen's table: Clear, while the search isn't the one
    /// the screen starts with, and Edit Search, counting what's changed.
    func searchButtons(_ search: any ScreenSearch, clear: @escaping @MainActor () -> Void,
                       edit: @escaping @MainActor () -> Void) throws -> (row: Pointer, clickable: [Pointer]) {
        let row = try ui.box(["row-direction-normal", "align-items-center"])
        try ui.style(row) { try $0.number("flexShrink", 0) }
        var clickable: [Pointer] = []
        if search.changes > 0 {
            let button = try button("Clear", .secondary)
            try ui.style(button) { try $0.length("marginRight", 8) }
            try ui.add(button, to: row)
            try ui.onClick(button, clear)
            clickable.append(button)
        }
        let button = try button(search.buttonTitle, .primary)
        try ui.add(button, to: row)
        try ui.onClick(button, edit)
        clickable.append(button)
        return (row, clickable)
    }

    func build(into screen: Pointer, search: any ScreenSearch, actions: EditSearchActions) throws -> Built {
        var built = Built()
        let body = try page.fixedBody(in: screen)

        // FM's tab over its criteria, with its underline, which FM draws with an element of its own.
        let tab = try ui.box()
        try ui.style(tab) { style in
            try style.keyword("alignSelf", 1)
            try style.number("flexShrink", 0)
            try style.length("marginBottom", 16)
        }
        let title = try ui.text("Search Criteria", ["navigation-tab-default-default-text", "content-no-wrap"])
        // FM's size for it comes with its tab button.
        try ui.style(title) { try $0.length("fontSize", 16) }
        try ui.add(title, to: tab)
        let underline = try ui.box()
        try ui.style(underline) { style in
            try style.length("height", 2)
            try style.length("marginTop", 6)
            try style.color("backgroundColor", (0.92, 0.92, 0.93, 1))
        }
        try ui.add(underline, to: tab)
        try ui.add(tab, to: body)

        // The block FM's criteria sit in, its look read from FM's.
        let block = try ui.box()
        try ui.style(block) { style in
            try style.number("flexGrow", 1)
            for side in ["Top", "Bottom", "Left", "Right"] {
                try style.length("padding\(side)", 17)
                try style.color("border\(side)Color", (1, 1, 1, 0.24))
                try style.number("border\(side)Width", 1.142857)
            }
            for corner in ["TopLeft", "TopRight", "BottomLeft", "BottomRight"] { try style.length("border\(corner)Radius", 16) }
            try style.color("backgroundColor", (0.051, 0.055, 0.067, 0.75))
        }
        let row = try ui.box(["row-direction-normal", "align-items-start"])
        try ui.add(try pitch(search.position, actions: actions, built: &built), to: row)
        // As FM's: dropdowns in columns of three, then the switches.
        let criteria = search.criteria
        let choices = criteria.filter { if case .choice = $0.control { return true } else { return false } }
        let switches = criteria.filter { if case .toggle = $0.control { return true } else { return false } }
        for column in [Array(choices.prefix(3)), Array(choices.dropFirst(3)) + switches] where !column.isEmpty {
            let box = try ui.box(["align-items-start"])
            try ui.style(box) { style in
                try style.length("width", 285)
                try style.length("marginRight", 40)
            }
            for criterion in column { try ui.add(try self.criterion(criterion, actions: actions, built: &built), to: box) }
            try ui.add(box, to: row)
        }
        try ui.add(row, to: block)
        try ui.add(block, to: body)

        let bottom = try ui.box(["row-direction-normal", "align-items-center", "justify-content-space-between"])
        try ui.style(bottom) { style in
            try style.length("marginTop", 12)
            try style.number("flexShrink", 0)
        }
        let clearAll = try button("Clear all", .secondary)
        try ui.add(clearAll, to: bottom)
        try ui.onClick(clearAll, actions.clearAll)
        let right = try ui.box(["row-direction-normal", "align-items-center"])
        let cancel = try button("Cancel", .base)
        try ui.style(cancel) { try $0.length("marginRight", 8) }
        try ui.add(cancel, to: right)
        try ui.onClick(cancel, actions.cancel)
        let apply = try button("Apply", .primary)
        try ui.add(apply, to: right)
        try ui.onClick(apply, actions.apply)
        try ui.add(right, to: bottom)
        try ui.add(bottom, to: body)
        built.clickable += [clearAll, cancel, apply]
        return built
    }

    /// One criterion: its name over FM's dropdown or switch, and its note.
    private func criterion(_ criterion: Criterion, actions: EditSearchActions, built: inout Built) throws -> Pointer {
        let item = try ui.box(["align-items-start"])
        try ui.style(item) { try $0.length("marginBottom", 12) }
        try ui.add(try ui.text(criterion.title, ["body-md-strong", "content-no-wrap"]), to: item)
        let id = criterion.id
        switch criterion.control {
        case .choice(let choices, let selected):
            let dropdown = try dropdown(choices.indices.contains(selected) ? choices[selected] : "", width: 285)
            try ui.style(dropdown) { try $0.length("marginTop", 7) }
            try ui.add(dropdown, to: item)
            try ui.onClick(dropdown) { actions.open(id, dropdown) }
            built.clickable.append(dropdown)
        case .toggle(let on, let enabled):
            let toggle = try ui.toggle(on, enabled: enabled, ["sicheckbox", "inputs-switch-toggle-large-default-switch-true--type-default",
                                                              "align-items-stretch", "justify-content-start"])
            try ui.style(toggle) { try $0.length("marginTop", 7) }
            try ui.add(toggle, to: item)
            try ui.onClick(toggle) { actions.toggled(id, toggle) }
            built.clickable.append(toggle)
            built.toggles.append((id, toggle))
        }
        if !criterion.note.isEmpty {
            try ui.add(try page.spaced(try ui.text(criterion.note, ["body-sm", "global-text-secondary"]), top: 4), to: item)
        }
        return item
    }

    /// FM's pitch for choosing a position, as on its Edit Search: the chosen one lit, and clicking it again for any.
    private func pitch(_ position: Int, actions: EditSearchActions, built: inout Built) throws -> Pointer {
        let column = try ui.box(["align-items-start"])
        try ui.style(column) { style in
            try style.length("width", 285)
            try style.length("marginRight", 40)
        }
        let title = try ui.box(["row-direction-normal", "align-items-center"])
        let label = try ui.text("Position", ["body-md-strong", "content-no-wrap"])
        try ui.style(label) { try $0.length("marginRight", 8) }
        try ui.add(label, to: title)
        try ui.add(try ui.text(PitchSpot.name(of: position), ["body-md", "content-no-wrap", "content-ellipsis"]), to: title)
        try ui.add(title, to: column)

        let field = try ui.box(["data_display-pitch_perspective-thematic", "player-search-pitch", "data_display-pitch_perspective-thematic-small"],
                               name: "TacticsPanel")
        try ui.style(field) { style in
            try style.length("width", 249)
            try style.length("height", 160)
            try style.length("marginTop", 12)
            try style.length("marginLeft", 18)
        }
        let mask = try ui.box(name: "PitchMask")
        let ground = try ui.box(name: "Pitch")
        for element in [mask, ground] { try fill(element) }
        try ui.add(ground, to: mask)
        try ui.add(mask, to: field)

        // Where FM puts its positions on a pitch this size.
        let centres: [Float] = [61, 125, 188]
        let tops: [Float] = [3, 29, 56, 83, 109, 135]
        for spot in PitchSpot.spots {
            let active = spot.position == position
            let mode = active ? "mixed" : "light"
            let chip = try ui.box(["input-squad-planner-data-point-regular-type-ability-mode-\(mode)-active-\(active)", "sitext-hover-cursor"],
                                  name: "input-squad-planner-data-point-regular")
            try ui.style(chip) { style in
                try style.keyword("position", 1)
                try style.length("left", centres[spot.column] - 25)
                try style.length("top", tops[spot.row])
                try style.length("width", 50)
                try style.length("height", 20)
            }
            let frame = try ui.box(["input-squad-planner-data-point-upper-frame-backgroud", "flex-grow-class", "align-self-stretch",
                                    "justify-content-center", "align-items-center"], name: "Frame")
            try ui.add(try ui.text(spot.name, ["body-md-strong", "content-no-wrap", active ? "global-text-primary" : "global-text-secondary",
                                               "sitext-hover-cursor"], name: "PositionText"), to: frame)
            try ui.add(frame, to: chip)
            try ui.add(chip, to: field)
            let chosen = active ? -1 : spot.position
            try ui.onClick(chip) { actions.position(chosen) }
            built.clickable.append(chip)
        }
        try ui.add(field, to: column)
        return column
    }

    /// A dropdown's list, opened under it as FM's are, over the rest of the screen, with a clear layer behind it
    /// that closes it when clicked. Returns the two, to take away again, and what can be clicked: nothing, if the
    /// dropdown isn't laid out.
    func list(_ choices: [String], selected: Int, under dropdown: Pointer, in screen: Pointer,
              choose: @escaping @MainActor (Int) -> Void,
              close: @escaping @MainActor () -> Void) throws -> (elements: [Pointer], clickable: [Pointer]) {
        guard let spot = ui.worldBound(dropdown), let area = ui.worldBound(screen), spot.width > 0 else { return ([], []) }
        let backdrop = try ui.box(name: "FMStarshipDropdownBackdrop")
        try ui.style(backdrop) { style in
            try style.keyword("position", 1)
            try style.length("left", 0)
            try style.length("top", 0)
            try style.percent("width", 100)
            try style.percent("height", 100)
        }
        try ui.add(backdrop, to: screen)
        try ui.onClick(backdrop, close)

        let rowHeight: Float = 30
        let top = Self.listTop(under: spot.y + spot.height, screenTop: area.y)
        // No taller than FM's, and like FM's, scrolled with the wheel and trackpad without a bar.
        let height = min(Float(choices.count) * rowHeight + 3, 600, max(area.height - top - 16, rowHeight * 4))
        let list = try ui.scrollView(["siscrollview"], name: "FMStarshipDropdownList")
        try ui.hideScroller(list)
        // FM's floating lists' look.
        try ui.style(list) { style in
            try style.keyword("position", 1)
            try style.length("left", spot.x - area.x)
            try style.length("top", top)
            try style.length("width", max(spot.width, 200))
            try style.length("height", height)
            for side in ["Top", "Bottom", "Left", "Right"] {
                try style.color("border\(side)Color", (1, 1, 1, 0.2))
                try style.number("border\(side)Width", 1.142857)
            }
            for corner in ["TopLeft", "TopRight", "BottomLeft", "BottomRight"] { try style.length("border\(corner)Radius", 4) }
            try style.color("backgroundColor", (0.180, 0.192, 0.220, 1))
        }
        var clickable = [backdrop]
        for (index, choice) in choices.enumerated() {
            let current = index == selected
            let row = try ui.box(["row-direction-normal", "align-items-center", "streamed-list-view-item", "streamed-list-view__row--interactable",
                                  "virtualised-list__item", "sitext-hover-cursor"] + (current ? ["virtualised-list__item--selected"] : []))
            try ui.style(row) { style in
                try style.length("height", rowHeight)
                try style.length("paddingLeft", 32)
                try style.length("paddingRight", 12)
                try style.number("flexShrink", 0)
            }
            try ui.add(try ui.text(choice, [current ? "body-md-strong" : "body-md", "content-no-wrap", "content-ellipsis", "sitext-hover-cursor"]),
                       to: row)
            try ui.add(row, to: list)
            try ui.onClick(row) { choose(index) }
            clickable.append(row)
        }
        try ui.add(list, to: screen)
        return ([backdrop, list], clickable)
    }

    /// Where a dropdown's list starts, down from the top of the screen it opens over: just under the dropdown, but never
    /// above the screen, as it would be under a dropdown outside it.
    nonisolated static func listTop(under dropdownBottom: Float, screenTop: Float) -> Float {
        max(0, dropdownBottom + 2 - screenTop)
    }

    /// One of FM's buttons, with its label.
    func button(_ title: String, _ style: Button) throws -> Pointer {
        let button = try ui.box(["sibutton", "navigatable", style.rawValue, "button-size-medium", "row-direction-normal", "align-items-center",
                                 "sitext-hover-cursor"])
        try ui.style(button) { style in
            try style.length("height", 32)
            try style.length("paddingLeft", 8)
            try style.length("paddingRight", 8)
            try style.number("flexShrink", 0)
        }
        try ui.add(try ui.text(title, ["label-md", "global-text-primary", "content-no-wrap", "sitext-hover-cursor"]), to: button)
        return button
    }

    /// A dropdown like FM's: what's chosen, and FM's chevron. One that can't be changed is greyed out, as FM's are.
    func dropdown(_ text: String, width: Float, height: Float = 32, enabled: Bool = true) throws -> Pointer {
        let box = try ui.box(["inputs-combobox-default-default-base", "navigatable-no-cursor", "row-direction-normal", "align-items-center"]
                             + (enabled ? ["sitext-hover-cursor"] : []))
        // FM draws its dropdown's box with the dropdown, so the box's look, read from FM's, is set here.
        try ui.style(box) { style in
            try style.length("width", width)
            try style.length("height", height)
            try style.length("paddingLeft", 17)
            try style.length("paddingRight", 9)
            for side in ["Top", "Bottom", "Left", "Right"] {
                try style.color("border\(side)Color", (1, 1, 1, 0.2))
                try style.number("border\(side)Width", 1.142857)
            }
            for corner in ["TopLeft", "TopRight", "BottomLeft", "BottomRight"] { try style.length("border\(corner)Radius", 4) }
            try style.color("backgroundColor", (1, 1, 1, 0.137))
        }
        let label = try ui.text(text, ["body-md", "content-no-wrap", "content-ellipsis"]
                                + (enabled ? ["sitext-hover-cursor"] : ["global-text-secondary"]))
        try ui.style(label) { try $0.number("flexGrow", 1) }
        try ui.add(label, to: box)
        let chevron = try ui.box(["ui-concepts-chevron-down_small"])
        try ui.style(chevron) { style in
            try style.length("width", 16)
            try style.length("height", 16)
            try style.number("flexShrink", 0)
        }
        try ui.add(chevron, to: box)
        if !enabled { try ui.disable(box) }
        return box
    }

    /// Fills its parent, over what's there.
    private func fill(_ element: Pointer) throws {
        try ui.style(element) { style in
            try style.keyword("position", 1)
            try style.length("left", 0)
            try style.length("top", 0)
            try style.percent("width", 100)
            try style.percent("height", 100)
        }
    }
}
