import Foundation
@preconcurrency import StarshipAnalysis
import StarshipCore

/// FM's own player table, a StreamedTable, holding FM Starship's players. FM draws the rows from its own
/// PlayerTableFactory, so they get FM's columns, sorting by a column's header, names that open FM's profiles and FM's
/// right-click menu. The rows stay in FM Starship's order until a column is chosen to sort by.
///
/// Each row is FM's reference to a person in its database, by the same index the reader reads. The table only shows
/// what FM shows for that person; nothing of FM's is changed.
@MainActor
struct FMTable {
    typealias Pointer = IL2CPP.Pointer
    let ui: FMElements
    private var il2cpp: IL2CPP { ui.il2cpp }

    // MARK: FM's assets

    /// What FM's player tables are made from, as FM's own asset references: the column factory, the row and header
    /// templates, and the right-click menu. In the order of the table's setters below.
    private static var assets: [IL2CPP.Handle]?
    private static let setters = ["set_FactoryAsset", "set_RowElementAsset", "set_HeaderCellAsset", "set_ContextMenuData"]
    private static let getters = ["get_FactoryAsset", "get_RowElementAsset", "get_HeaderCellAsset", "get_ContextMenuData"]
    private static let factoryName = "PlayerTableFactory"
    /// The GUIDs of those assets, kept from one start to the next, in FM Starship's own folder.
    private static let assetFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FMStarship/Plugin/fm-table-assets.json")
    /// The factory's column IDs, once a table of FM's has been seen with it loaded.
    private(set) static var knownColumns: Set<String> = []

    static var ready: Bool { assets != nil }

    /// Keeps the assets of FM's own player table, the first time one is seen with its factory loaded, and their
    /// GUIDs for the next start.
    static func keepAssets(from table: Pointer, _ ui: FMElements) {
        let il2cpp = ui.il2cpp
        guard let factory = il2cpp.fieldObject(table, "m_loadedFactoryAsset"),
              il2cpp.text(try? il2cpp.call(factory, "get_name")) == factoryName else { return }
        if knownColumns.isEmpty { writeColumns(factory, il2cpp) }
        guard assets == nil else { return }
        let references = getters.compactMap { try? il2cpp.call(table, $0) }
        let handles = references.compactMap { il2cpp.pin($0) }
        guard references.count == getters.count, handles.count == getters.count else {
            handles.forEach(il2cpp.unpin)
            PluginLog.write("FM's player table had \(references.count) of its \(getters.count) asset references")
            return
        }
        assets = handles
        let guids = references.map { il2cpp.text(try? il2cpp.call($0, "get_AssetGUID")) ?? "" }
        if !guids.contains(where: \.isEmpty), let data = try? JSONEncoder().encode(guids) { try? data.write(to: assetFile) }
        PluginLog.write("FM's player table assets kept: \(guids.joined(separator: " "))")
    }

    /// Looks through FM's screens, shown or not, for one of its player tables to take the assets from.
    static func lookForAssets(below roots: [Pointer], _ ui: FMElements) {
        guard assets == nil || knownColumns.isEmpty, let tableClass = ui.il2cpp.findClass("SI.Bindable", "StreamedTable") else { return }
        var queue = roots
        var looked = 0
        while !queue.isEmpty, looked < 40_000, assets == nil || knownColumns.isEmpty {
            let element = queue.removeFirst()
            looked += 1
            if ui.il2cpp.isSubclass(ui.il2cpp.classOf(element), of: tableClass) {
                keepAssets(from: element, ui)
                continue
            }
            queue += ui.children(of: element)
        }
    }

    /// The assets from the GUIDs kept last time, made into FM's asset references again.
    static func loadAssets(_ ui: FMElements) {
        let il2cpp = ui.il2cpp
        guard assets == nil, let data = try? Data(contentsOf: assetFile), let guids = try? JSONDecoder().decode([String].self, from: data),
              guids.count == setters.count, let tableClass = il2cpp.findClass("SI.Bindable", "StreamedTable") else { return }
        var handles: [IL2CPP.Handle] = []
        for (setter, guid) in zip(setters, guids) {
            do {
                guard let method = il2cpp.method(tableClass, setter, parameters: 1),
                      let referenceClass = il2cpp.klass(of: il2cpp.methodParameter(method, 0)) else {
                    throw IL2CPP.Failure("No \(setter) in FM's StreamedTable")
                }
                let reference = try il2cpp.new(referenceClass, [il2cpp.managedString(guid)], firstParameter: "System.String")
                guard let handle = il2cpp.pin(reference) else { throw IL2CPP.Failure("Couldn't hold \(setter)'s asset") }
                handles.append(handle)
            } catch {
                handles.forEach(il2cpp.unpin)
                PluginLog.write("FM's player table assets couldn't be made from last time's: \(error)")
                return
            }
        }
        assets = handles
        PluginLog.write("FM's player table assets made from last time's GUIDs")
    }

    /// Writes the factory's column IDs to the log folder, to choose columns from, and keeps them.
    private static func writeColumns(_ factory: Pointer, _ il2cpp: IL2CPP) {
        guard let rows = il2cpp.fieldObject(factory, "m_rowData") else { return }
        var lines: [String] = []
        for row in il2cpp.items(of: rows) {
            guard let id = il2cpp.fieldObject(row, "m_id").flatMap(il2cpp.text) else { continue }
            let width = il2cpp.fieldOffset(il2cpp.classOf(row), "m_defaultWidth").map { row.load(fromByteOffset: $0, as: Float.self) } ?? 0
            defaultWidths[id] = width
            lines.append("\(id) \(FMElements.whole(width))")
        }
        knownColumns = Set(defaultWidths.keys)
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/FM Starship/fm-player-columns.txt")
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        PluginLog.write("FM's player table has \(lines.count) columns to choose from")
    }

    /// Each of the factory's columns' width before FM fits the table to the screen, which it does in proportion.
    private(set) static var defaultWidths: [String: Float] = [:]

    /// Takes the factory's columns from a table of ours once it has loaded it, when no table of FM's has been seen
    /// with it. True when that's new, so the table can be made again with columns chosen to fit.
    static func noteFactory(of table: Pointer, _ il2cpp: IL2CPP) -> Bool {
        guard defaultWidths.isEmpty, let factory = il2cpp.fieldObject(table, "m_loadedFactoryAsset") else { return false }
        writeColumns(factory, il2cpp)
        return !defaultWidths.isEmpty
    }

    // MARK: Making one

    /// A new table of FM's, set up with its player table assets but empty. Rows and columns go in once it's in FM's
    /// tree, with `fill`, since the table loads its factory when it's attached.
    func make(name: String) throws -> Pointer {
        guard let assets = Self.assets else { throw IL2CPP.Failure("FM's player table assets aren't known yet") }
        guard let tableClass = il2cpp.findClass("SI.Bindable", "StreamedTable") else { throw IL2CPP.Failure("No StreamedTable in FM") }
        let table = try il2cpp.new(tableClass)
        try il2cpp.call(table, "set_name", [il2cpp.managedString(name)])
        for name in ["streamed-list-view", "streamed-table", "figma-table", "flex-grow-class"] where !ui.hasClass(table, name) {
            try ui.addClass(table, name)
        }
        // No row template, as FM's player database has none: the squad table's wraps each row in FM's drag-and-drop,
        // and a player dropped on a table that isn't about a squad sends FM's game an event about nothing, which
        // closes FM.
        for (setter, handle) in zip(Self.setters, assets) where setter != "set_RowElementAsset" {
            guard let reference = il2cpp.target(of: handle) else { throw IL2CPP.Failure("\(setter)'s asset is gone") }
            try il2cpp.call(table, setter, [reference])
        }
        // Each row's height, as FM's own player tables set it, so the cells sit in the middle of their rows.
        var height = Self.rowHeight
        try withUnsafeMutablePointer(to: &height) { try il2cpp.call(table, "set_FixedElementSize", [Pointer($0)]) }
        return table
    }

    /// FM's recruitment table's row height, which leaves room for its two-line position and role.
    static var rowHeight: Float = 36
    /// Columns to try instead of a screen's own, set by the developer command `table columns`.
    static var columnOverride: [String]?

    /// The table's columns, from FM's factory by ID, and its rows, one per person, in this order.
    func fill(_ table: Pointer, people: [Person], columns: [String], own: [String: Float] = [:]) throws {
        let chosen = Self.knownColumns.isEmpty ? columns : columns.filter(Self.knownColumns.contains)
        try il2cpp.call(table, "UpdateStreamedTableView", [try view(chosen, own: own)])
        try il2cpp.call(table, "SetList", [try rows(people)])
    }

    /// A view of FM's, as FM keeps for each way of looking at a table, with these columns. Those holding FM
    /// Starship's own, in `own`, are as wide as given and don't sort when their header is clicked.
    private func view(_ columns: [String], own: [String: Float]) throws -> Pointer {
        guard let viewClass = il2cpp.findClass("SI.Bindable", "StreamedTableView"),
              let create = il2cpp.method(viewClass, "CreateFromTableConfig", parameters: 2),
              let listClass = il2cpp.klass(of: il2cpp.methodParameter(create, 0)),
              let add = il2cpp.method(listClass, "Add", parameters: 1),
              let configClass = il2cpp.klass(of: il2cpp.methodParameter(add, 0)) else {
            throw IL2CPP.Failure("FM's table views aren't as expected")
        }
        let view = try il2cpp.new(viewClass)
        let list = try il2cpp.new(listClass)
        for id in columns {
            var unused = false
            let config: Pointer
            if let width = own[id], let metadata = try? ownMetadata(configClass, width: width) {
                config = try withUnsafeMutablePointer(to: &unused) {
                    try il2cpp.new(configClass, [il2cpp.managedString(id), metadata, Pointer($0)], firstParameter: "System.String")
                }
            } else {
                config = try withUnsafeMutablePointer(to: &unused) {
                    try il2cpp.new(configClass, [il2cpp.managedString(id), Pointer($0)], firstParameter: "System.String")
                }
            }
            try il2cpp.call(add, list, [config])
        }
        var custom = false
        try withUnsafeMutablePointer(to: &custom) { try il2cpp.call(create, view, [list, Pointer($0)]) }
        return view
    }

    /// A column's settings, as FM's own views have them, for one holding FM Starship's values: its width, and no
    /// sorting by its header, which would sort by what FM keeps in it.
    private func ownMetadata(_ configClass: Pointer, width: Float) throws -> Pointer {
        guard let withMetadata = il2cpp.method(configClass, ".ctor", parameters: 3, firstParameter: "System.String", inherited: false),
              let metadataClass = il2cpp.klass(of: il2cpp.methodParameter(withMetadata, 1)),
              let sorting = il2cpp.fieldOffset(metadataClass, "m_sortingDisabled"),
              let widthOffset = il2cpp.fieldOffset(metadataClass, "m_widthOverride"),
              let minimum = il2cpp.fieldOffset(metadataClass, "m_minWidthOverride") else {
            throw IL2CPP.Failure("FM's column settings aren't as expected")
        }
        var required = false
        let metadata = try withUnsafeMutablePointer(to: &required) {
            try il2cpp.new(metadataClass, [Pointer($0)], firstParameter: "System.Boolean")
        }
        metadata.storeBytes(of: true, toByteOffset: sorting, as: Bool.self)
        switch Self.widths {
        case .none: break
        case .min:
            metadata.storeBytes(of: width, toByteOffset: minimum, as: Float.self)
        case .width:
            metadata.storeBytes(of: width, toByteOffset: widthOffset, as: Float.self)
            metadata.storeBytes(of: width, toByteOffset: minimum, as: Float.self)
        case .both:
            metadata.storeBytes(of: width, toByteOffset: widthOffset, as: Float.self)
            metadata.storeBytes(of: min(width, 60), toByteOffset: minimum, as: Float.self)
        }
        return metadata
    }

    /// How our columns' widths are given to FM. With only a minimum, FM still fits the table to the screen, with
    /// none of ours narrower than its heading or longest value. The developer command `table widths` changes it.
    enum Widths: String { case none, min, width, both }
    static var widths = Widths.none

    // MARK: FM Starship's own columns

    /// One of the engine's columns in FM's table: its values by person, in a column of FM's that shows nothing for
    /// them, under the engine's heading unless FM's own heading says the same.
    struct Extra {
        let host: String
        let title: String?
        let values: [Int32: String]
        /// Wide enough for the heading and the longest value, for the columns under the engine's headings.
        var width: Float {
            let longest = max(title?.count ?? 0, values.values.map(\.count).max() ?? 0)
            return min(220, max(70, Float(longest) * 8 + 24))
        }
    }

    /// FM's columns that only FM's editor fills, so they're empty in a game: CA and PA keep FM's own headings for
    /// them, and the rest take the engine's headings, without FM's sorting, which would sort by something else.
    private static let abilityHosts = ["CA": "hidden-current-ability", "PA": "hidden-potential-ability"]
    /// Headings in FM's words where FM has its own for what the engine shows: FM calls whether a player would join
    /// his interest.
    private static let headings = ["Would join on": "Interest"]
    /// Whether FM's own CA and PA columns sort when their header is clicked, by FM's figures for them. FM has none
    /// for the players in our lists, so it doesn't sort; ours does instead. `table casort on` tries FM's again.
    static var abilitySortable = false
    static let spareHosts = ["hidden-wp-points", "hidden-is-newgen", "hidden-versatility", "hidden-adaptability"]

    /// FM's hidden columns we can hold our own in, widest first. FM fits a table to the screen by scaling every
    /// column's own width, so a column of ours is as wide as the one of FM's it's in.
    private static var sparesByWidth: [String] {
        let hidden = defaultWidths.keys.filter { $0.hasPrefix("hidden-") && !abilityHosts.values.contains($0) }
        guard !hidden.isEmpty else { return spareHosts }
        return hidden.sorted { (defaultWidths[$0] ?? 0, $1) > (defaultWidths[$1] ?? 0, $0) }
    }

    /// The engine's columns with these titles, as it shows them: while CA and PA are off it has none of them.
    static func extras(from table: AnalysisTable, titles: [String]) -> [Extra] {
        let found = titles.compactMap { title -> (title: String, values: [Int32: String])? in
            guard let column = table.columns.firstIndex(where: { $0.title == title }) else { return nil }
            var values: [Int32: String] = [:]
            for row in table.rows where column < row.cells.count {
                if let person = row.person { values[Int32(bitPattern: person.index)] = row.cells[column] }
            }
            return (headings[title] ?? title, values)
        }
        // The widest of FM's spare columns go to the columns with the longest headings or values.
        let needs = found.filter { abilityHosts[$0.title] == nil }
            .sorted { Extra(host: "", title: $0.title, values: $0.values).width > Extra(host: "", title: $1.title, values: $1.values).width }
        let hosts = Dictionary(uniqueKeysWithValues: zip(needs.map(\.title), sparesByWidth))
        return found.compactMap { item in
            guard let host = abilityHosts[item.title] ?? hosts[item.title] else { return nil }
            return Extra(host: host, title: abilityHosts[item.title] == nil ? item.title : nil, values: item.values)
        }
    }

    /// FM's columns for a list with the engine's own beside them: the engine's CA and PA in place of FM's scouts'
    /// opinion of them, and its other columns at the end.
    static func columns(_ columns: [String], with extras: [Extra]) -> [String] {
        let hosts = Set(extras.map(\.host))
        var chosen = columns.map { id -> String in
            switch id {
            case "scout-opinion-current-ability" where hosts.contains("hidden-current-ability"): return "hidden-current-ability"
            case "scout-opinion-potential-ability" where hosts.contains("hidden-potential-ability"): return "hidden-potential-ability"
            default: return id
            }
        }
        chosen += extras.map(\.host).filter { !chosen.contains($0) }
        return chosen
    }

    /// What the rows showed last time, so only rows FM has given another person are written again.
    final class Shown {
        var person: [Pointer: Int32] = [:]
        var cells: [Pointer: [Pointer]] = [:]
        var fitted: Set<Pointer> = []
        var hooked: Set<Pointer> = []
        var columns: [String] = []
    }

    /// Which of our columns the list is sorted by, and which way.
    struct Sort: Equatable {
        let host: String
        let descending: Bool
    }

    /// Fits the rows FM has drawn to their height, then puts the engine's values in them, by the person each row
    /// holds, and the engine's headings on its columns. FM draws only the rows in view and reuses them as the list
    /// scrolls or sorts, so this runs again and again while the table is up.
    func refreshRows(_ table: Pointer, _ extras: [Extra], shown: Shown, sort: Sort?, onSort: @escaping @MainActor (String) -> Void) {
        guard let bindings = il2cpp.fieldObject(table, "m_bindings"), let rowList = il2cpp.fieldObject(table, "m_rows") else { return }
        let ids = il2cpp.strings(inList: il2cpp.fieldObject(table, "m_columnIDs"))
        if ids != shown.columns {
            // FM built its columns again, and the rows' cells with them.
            shown.person = [:]
            shown.cells = [:]
            shown.fitted = []
            shown.columns = ids
        }
        let placed = extras.compactMap { extra in ids.firstIndex(of: extra.host).map { (extra, $0) } }
        for row in il2cpp.structItems(of: rowList, size: 16) {
            guard let root = row.load(as: IL2CPP.Pointer?.self) else { continue }
            if !shown.fitted.contains(root) {
                fit(root)
                shown.fitted.insert(root)
            }
            guard !placed.isEmpty else { continue }
            let index = personIndex(of: root, bindings: bindings) ?? -1
            guard shown.person[root] != index else { continue }
            let cells = shown.cells[root] ?? self.cells(in: root)
            shown.cells[root] = cells
            for (extra, column) in placed where column < cells.count {
                setValue(extra.values[index] ?? "", in: cells[column])
            }
            shown.person[root] = index
        }
        guard let columns = il2cpp.fieldObject(table, "m_columns") else { return }
        for column in il2cpp.items(of: columns) {
            guard let id = il2cpp.fieldObject(column, "<ColumnID>k__BackingField").flatMap(il2cpp.text),
                  let extra = extras.first(where: { $0.host == id }),
                  let header = il2cpp.fieldObject(column, "m_header") else { continue }
            if let title = extra.title { heading(header, title) }
            if !shown.hooked.contains(header), let button = il2cpp.fieldObject(header, "m_button") {
                // FM can't sort by our values, so clicking the heading sorts the list by them here.
                try? ui.onButtonClick(button) { onSort(id) }
                shown.hooked.insert(header)
            }
            if let icon = il2cpp.fieldObject(header, "m_sortIcon") { sortIcon(icon, sort?.host == id ? sort?.descending : nil) }
        }
    }

    /// The engine's heading in place of FM's: a label of ours, in the style of FM's, with FM's hidden. FM writes
    /// its own heading into its label again whenever it binds the headings, and that no longer shows.
    private func heading(_ header: Pointer, _ title: String) {
        guard let label = il2cpp.fieldObject(header, "<TextLabel>k__BackingField"), let parent = ui.parent(of: label) else { return }
        if let ours = ui.query(parent, "FMStarshipHeading") {
            if il2cpp.text(try? il2cpp.call(ours, "get_text")) != title { try? ui.setText(ours, title) }
            return
        }
        guard let ours = try? ui.text(title, ui.classes(of: label), name: "FMStarshipHeading"),
              let index = ui.children(of: parent).firstIndex(of: label) else { return }
        try? ui.insert(ours, into: parent, at: index + 1)
        try? ui.style(label) { try $0.keyword("display", 1) }
    }

    /// FM's own sort arrow on a heading: down when sorted highest first, up the other way, hidden when not sorted.
    private func sortIcon(_ icon: Pointer, _ descending: Bool?) {
        let down = "game-concepts-sort-arrow-down_small", up = "game-concepts-sort-arrow-up_small", hidden = "sort-icon--hidden"
        let wanted: Set<String> = descending.map { [$0 ? down : up] } ?? [hidden]
        for name in [down, up, hidden] {
            let has = ui.hasClass(icon, name)
            if wanted.contains(name), !has { try? ui.addClass(icon, name) }
            if !wanted.contains(name), has { try? ui.removeClass(icon, name) }
        }
    }

    /// The list sorted by one of our columns: by the number a value starts with where it has one, such as CA's
    /// 153 or +15 (GK), otherwise alphabetically, with what has no value last.
    static func sorted(_ people: [Person], by extra: Extra, descending: Bool) -> [Person] {
        func number(_ text: String) -> Double? {
            let start = text.prefix { "+-0123456789.".contains($0) }
            return Double(start.hasPrefix("+") ? String(start.dropFirst()) : String(start))
        }
        return people.enumerated().sorted { left, right in
            let a = extra.values[Int32(bitPattern: left.element.index)] ?? "", b = extra.values[Int32(bitPattern: right.element.index)] ?? ""
            if a.isEmpty != b.isEmpty { return b.isEmpty }
            if let x = number(a), let y = number(b), x != y { return descending ? x > y : x < y }
            if number(a) == nil, number(b) == nil, a != b { return descending ? a > b : a < b }
            // Ties keep the engine's order.
            return left.offset < right.offset
        }.map(\.element)
    }

    /// The same table's rows in a new order. FM's SetList puts back the sort FM remembers for the table, by one of
    /// its own columns, so that's cleared after, and FM's view of the list set back to the list's order and drawn.
    func setRows(_ table: Pointer, _ people: [Person]) throws {
        // FM keeps the column it last sorted by among its interface settings, and sorts each new list by it again.
        try forgetSort(table)
        try il2cpp.call(table, "SetList", [try rows(people)])
        try il2cpp.call(table, "SetNoSorting")
        try il2cpp.call(table, "ResetIndices")
        try il2cpp.call(table, "Rebuild")
    }

    /// Clears the column FM remembers sorting this table by, first and second, as sorting by none would.
    private func forgetSort(_ table: Pointer) throws {
        guard let update = il2cpp.method(il2cpp.classOf(table), "UpdatePersistedColumnSortingData", parameters: 3) else {
            throw IL2CPP.Failure("FM's tables don't remember their sorting as expected")
        }
        for slot in [Int32(0), 1] {
            var index = slot, ascending = true
            try withUnsafeMutablePointer(to: &index) { index in
                try withUnsafeMutablePointer(to: &ascending) {
                    try il2cpp.call(update, table, [Pointer(index), il2cpp.managedString(""), Pointer($0)])
                }
            }
        }
    }

    /// Whether FM shows one of its own columns sorted: its sort arrow on that column's heading.
    func sortedByFM(_ table: Pointer, besides extras: [Extra]) -> Bool {
        guard let columns = il2cpp.fieldObject(table, "m_columns") else { return false }
        let ours = Set(extras.map(\.host))
        return il2cpp.items(of: columns).contains { column in
            guard let id = il2cpp.fieldObject(column, "<ColumnID>k__BackingField").flatMap(il2cpp.text), !ours.contains(id),
                  let icon = il2cpp.fieldObject(column, "m_header").flatMap({ il2cpp.fieldObject($0, "m_sortIcon") }) else { return false }
            return !ui.hasClass(icon, "sort-icon--hidden")
        }
    }

    /// The player row template FM's squad table uses wraps its cells in an element that grows to its tallest cell,
    /// the two-line position, so every cell centres below the row's middle. Held to the row's height, they centre in
    /// the row, and the position spills over its cell evenly, as it does in FM's own player database.
    private func fit(_ row: Pointer) {
        guard let wrapper = ui.children(of: row).first, ui.hasClass(wrapper, "fmc-spacious-row") else { return }
        for element in [wrapper, ui.query(row, "DragObject")].compactMap({ $0 }) {
            try? ui.style(element) { try $0.percent("height", 100) }
        }
    }

    /// A row's cells, in column order.
    private func cells(in row: Pointer) -> [Pointer] {
        var found: [Pointer] = []
        var queue = ui.children(of: row)
        var looked = 0
        while !queue.isEmpty, looked < 200 {
            let element = queue.removeFirst()
            looked += 1
            if ui.hasClass(element, "streamed-table__cell") {
                found.append(element)
            } else {
                queue = ui.children(of: element) + queue
            }
        }
        return found
    }

    /// Our value in one of FM's cells, in FM's text style, in the middle of the cell.
    private func setValue(_ value: String, in cell: Pointer) {
        let label: Pointer
        if let existing = ui.query(cell, "FMStarshipValueText") {
            label = existing
        } else {
            guard let box = try? ui.box(name: "FMStarshipValue"),
                  let made = try? ui.text(value, ["body-md", "global-text-primary", "content-no-wrap", "content-ellipsis"],
                                          name: "FMStarshipValueText") else { return }
            // What FM itself shows in the column, where it shows anything, makes way for ours.
            for child in ui.children(of: cell) { try? ui.style(child) { try $0.keyword("display", 1) } }
            // Filling the cell, a row with the text in the middle of its height and at its left, like FM's text cells.
            try? ui.style(box) { style in
                try style.keyword("position", 1)
                for side in ["left", "top", "right", "bottom"] { try style.length(side, 0) }
                try style.length("paddingLeft", 4)
                try style.keyword("flexDirection", 2)
                try style.keyword("alignItems", 2)
                try style.keyword("justifyContent", 0)
            }
            try? ui.add(made, to: box)
            try? ui.add(box, to: cell)
            label = made
        }
        if il2cpp.text(try? il2cpp.call(label, "get_text")) != value { try? ui.setText(label, value) }
    }

    /// The database index of the person in a row FM has drawn: the reference FM put in the row's key as "binding".
    private func personIndex(of row: Pointer, bindings: Pointer) -> Int32? {
        guard let get = il2cpp.method(il2cpp.classOf(bindings), "Get", parameters: 2, firstParameter: "SI.Bindable.Bindings.Key&"),
              il2cpp.valueSize(il2cpp.methodParameter(get, 1)) == 16,
              let key = il2cpp.unbox(try? il2cpp.call(row, "get_Key"), as: UInt64.self), key != 0 else { return nil }
        var rowKey = key
        let path = Array("binding".utf16)
        let value: Pointer? = path.withUnsafeBufferPointer { chars in
            guard let start = chars.baseAddress else { return nil }
            // ReadOnlySpan<char>: where the characters are, then how many.
            var span: (UnsafeRawPointer, Int32) = (UnsafeRawPointer(start), Int32(chars.count))
            return withUnsafeMutablePointer(to: &rowKey) { keyPointer in
                withUnsafeMutablePointer(to: &span) { (try? il2cpp.call(get, bindings, [Pointer(keyPointer), Pointer($0)])) ?? nil }
            }
        }
        guard let value, let reference = il2cpp.fieldObject(value, "m_value"),
              let offset = il2cpp.fieldOffset(il2cpp.classOf(reference), "m_index") else { return nil }
        return reference.load(fromByteOffset: offset, as: Int32.self)
    }

    /// FM's tables take a list of TypedValues, each holding FM's reference to a person in its database.
    private func rows(_ people: [Person]) throws -> Pointer {
        guard let tableClass = il2cpp.findClass("SI.Bindable", "StreamedTable"),
              let selected = il2cpp.method(tableClass, "GetSelectedItemsContextValues", parameters: 2),
              let listClass = il2cpp.klass(of: il2cpp.methodParameter(selected, 0)),
              let add = il2cpp.method(listClass, "Add", parameters: 1),
              let pooled = il2cpp.method(il2cpp.findClass("SI.Core", "TypedValue"), "GetReferenceTypedValue", parameters: 0),
              let personClass = il2cpp.findClass("FM.UI", "PersonReference") else {
            throw IL2CPP.Failure("FM's table rows aren't as expected")
        }
        let list = try il2cpp.new(listClass)
        let uidProperty = il2cpp.constant(personClass, "UID", as: UInt32.self)
        for person in people {
            var index = Int32(bitPattern: person.index)
            var reference = try withUnsafeMutablePointer(to: &index) {
                try il2cpp.new(personClass, [Pointer($0)], firstParameter: "System.Int32")
            }
            if Self.withUID, var property = uidProperty {
                // FM's own references carry the person's unique ID beside the index. Made again from all its IDs, the
                // reference works out its hash from them, as FM's do.
                var uid = Int32(bitPattern: person.uid)
                try withUnsafeMutablePointer(to: &property) { property in
                    try withUnsafeMutablePointer(to: &uid) { try il2cpp.call(reference, "SetValue", [Pointer(property), Pointer($0)]) }
                }
                if let ids = il2cpp.fieldObject(reference, "m_id") {
                    reference = try il2cpp.new(personClass, [ids], firstParameter: "System.Collections.Generic.List<SI.Interop.InteropReference.Pair>")
                }
            }
            guard let value = try il2cpp.call(pooled, nil) else { throw IL2CPP.Failure("No TypedValue from FM's pool") }
            try il2cpp.call(value, "set_Value", [reference])
            try il2cpp.call(add, list, [value])
        }
        return list
    }

    // MARK: Starting it

    /// A BindingRoot of its own around the table. Off: the table binds within the scope of FM's screen it's in,
    /// where FM's cells find the game, the manager and the team. `table root on` puts it back, from the next table.
    static var wrapInRoot = false
    /// FM binds the tables in its screens; ours is asked to bind itself, before its rows go in, so each row gets its
    /// own key under the table's. `table bind off` leaves it to FM.
    static var bindIfIdle = true
    /// Each row's reference carries the person's unique ID too, as FM's own do. `table refs index` leaves it out.
    static var withUID = true

    /// Whether the table has bound itself: it has the key its rows go under.
    func isBound(_ table: Pointer) -> Bool {
        guard let offset = il2cpp.fieldOffset(il2cpp.classOf(table), "m_itemsContainerKey") else { return false }
        return table.load(fromByteOffset: offset, as: UInt64.self) != 0
    }

    /// The first few rows' references as FM sends them to the game: database index, type, hash and each ID pair.
    func describeReferences(in table: Pointer, count: Int = 3) -> [String] {
        guard let source = il2cpp.fieldObject(table, "<SourceData>k__BackingField"),
              let personClass = il2cpp.findClass("FM.UI", "PersonReference"),
              let byIDs = il2cpp.method(personClass, ".ctor", parameters: 1,
                                         firstParameter: "System.Collections.Generic.List<SI.Interop.InteropReference.Pair>", inherited: false),
              let pairList = il2cpp.klass(of: il2cpp.methodParameter(byIDs, 0)),
              let add = il2cpp.method(pairList, "Add", parameters: 1),
              let pairClass = il2cpp.klass(of: il2cpp.methodParameter(add, 0)),
              let idOffset = il2cpp.fieldOffset(pairClass, "m_id", inStruct: true),
              let valueOffset = il2cpp.fieldOffset(pairClass, "m_value", inStruct: true) else { return ["References can't be read"] }
        let size = il2cpp.valueSize(il2cpp.methodParameter(add, 0))
        return il2cpp.items(of: source).prefix(count).map { value in
            guard let reference = il2cpp.fieldObject(value, "m_value") else { return "  no reference" }
            let index = il2cpp.fieldOffset(il2cpp.classOf(reference), "m_index").map { reference.load(fromByteOffset: $0, as: Int32.self) } ?? -1
            let hash = il2cpp.fieldOffset(il2cpp.classOf(reference), "m_idHash").map { reference.load(fromByteOffset: $0, as: Int32.self) } ?? -1
            let pairs = il2cpp.fieldObject(reference, "m_id").map { list in
                il2cpp.structItems(of: list, size: size).map { "\($0.load(fromByteOffset: idOffset, as: UInt32.self))=\($0.load(fromByteOffset: valueOffset, as: Int32.self))" }
            } ?? []
            return "  \(il2cpp.name(of: il2cpp.classOf(reference))) index \(index), hash \(hash), ids \(pairs.joined(separator: " "))"
        }
    }

    func wrap(_ table: Pointer) throws -> Pointer {
        guard let rootClass = il2cpp.findClass("SI.Bindable", "BindingRoot") else { throw IL2CPP.Failure("No BindingRoot in FM") }
        let root = try il2cpp.new(rootClass)
        try ui.addClass(root, "flex-grow-class")
        try ui.style(root) { try $0.number("flexGrow", 1) }
        try ui.add(table, to: root)
        return root
    }

    func factoryLoaded(_ table: Pointer) -> Bool { il2cpp.fieldObject(table, "m_loadedFactoryAsset") != nil }

    /// Calls one of the table's methods that takes nothing, to try out how it starts, and says what came back.
    func call(_ table: Pointer, _ method: String) -> String {
        do {
            let result = try il2cpp.call(table, method)
            return "\(method): \(result.map { il2cpp.summary(of: $0) } ?? "nothing back")"
        } catch {
            return "\(method): \(error)"
        }
    }

    /// What the table made of it, for the log: columns built, rows it holds, its factory, view and size, whether it
    /// thinks it can build, and whether a row has been drawn.
    func report(_ table: Pointer) -> String {
        let columns = il2cpp.fieldObject(table, "m_columns").map { il2cpp.items(of: $0).count } ?? -1
        let source = il2cpp.fieldObject(table, "<SourceData>k__BackingField").map { il2cpp.items(of: $0).count } ?? -1
        let factory = il2cpp.fieldObject(table, "m_loadedFactoryAsset").map { il2cpp.summary(of: $0) } ?? "not loaded"
        let view = il2cpp.fieldObject(table, "m_streamedTableView") != nil
        let canBuild = il2cpp.unbox(try? il2cpp.call(table, "CanBuild"), as: Bool.self).map { "\($0)" } ?? "?"
        let size = ui.layout(table).map { "\(FMElements.whole($0.width))x\(FMElements.whole($0.height))" } ?? "?"
        let drawn = ui.query(table, styleClass: "streamed-table__row") != nil
        return "\(columns) columns, \(source) rows, factory \(factory), view \(view), can build \(canBuild), \(size), a row drawn: \(drawn)"
    }

    func columnCount(_ table: Pointer) -> Int {
        il2cpp.fieldObject(table, "m_columns").map { il2cpp.items(of: $0).count } ?? 0
    }
}
