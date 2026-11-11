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
    /// Which of FM's tables: its players', or the one it lists other people in, such as staff.
    var kind = Kind.players
    private var il2cpp: IL2CPP { ui.il2cpp }

    init(ui: FMElements, kind: Kind = .players) {
        self.ui = ui
        self.kind = kind
    }

    // MARK: FM's assets

    /// FM's two kinds of people table, by the column factory each is made from.
    enum Kind: CaseIterable {
        case players, staff

        var factoryName: String { self == .players ? "PlayerTableFactory" : "NonPlayerTableFactory" }
        var name: String { self == .players ? "player" : "staff" }
        /// The GUIDs of its assets, kept from one start to the next, in FM Starship's own folder.
        var assetFile: URL {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support/FMStarship/Plugin/\(self == .players ? "fm-table-assets.json" : "fm-staff-table-assets.json")")
        }
        /// FM's column for a hidden value only FM's editor fills, empty in a game, which ours are copies of.
        var spareColumn: String { self == .players ? "hidden-asking-price" : Self.staffSpareColumn }
        /// Set from the staff factory's columns once they're known.
        static var staffSpareColumn = ""
    }

    /// What FM's tables of each kind are made from, as FM's own asset references: the column factory, the row and
    /// header templates, and the right-click menu, in the order of the table's setters below. FM's staff tables
    /// have no row template or menu of their own.
    private static var assets: [Kind: [IL2CPP.Handle?]] = [:]
    private static let setters = ["set_FactoryAsset", "set_RowElementAsset", "set_HeaderCellAsset", "set_ContextMenuData"]
    private static let getters = ["get_FactoryAsset", "get_RowElementAsset", "get_HeaderCellAsset", "get_ContextMenuData"]
    /// The ones a table can't be made without: the factory and the header.
    private static let needed: Set<Int> = [0, 2]
    /// Each factory's column IDs, once a table of FM's has been seen with it loaded.
    private(set) static var knownColumns: [Kind: Set<String>] = [:]

    static var ready: Bool { ready(.players) }
    static func ready(_ kind: Kind) -> Bool { assets[kind] != nil }

    /// Keeps the assets of one of FM's own people tables, the first time one of each kind is seen with its factory
    /// loaded, and their GUIDs for the next start.
    static func keepAssets(from table: Pointer, _ ui: FMElements) {
        let il2cpp = ui.il2cpp
        guard let factory = il2cpp.fieldObject(table, "m_loadedFactoryAsset"),
              let kind = Kind.allCases.first(where: { il2cpp.text(try? il2cpp.call(factory, "get_name")) == $0.factoryName }) else { return }
        if knownColumns[kind] == nil { writeColumns(factory, kind, il2cpp) }
        guard assets[kind] == nil else { return }
        let references = getters.map { (try? il2cpp.call(table, $0)) ?? nil }
        guard needed.allSatisfy({ references[$0] != nil }) else {
            PluginLog.write("FM's \(kind.name) table had \(references.compactMap { $0 }.count) of its \(getters.count) asset references")
            return
        }
        assets[kind] = references.map { $0.flatMap { il2cpp.pin($0) } }
        let guids = references.map { $0.flatMap { il2cpp.text(try? il2cpp.call($0, "get_AssetGUID")) } ?? "" }
        if needed.allSatisfy({ !guids[$0].isEmpty }), let build = fmBuild,
           let data = try? JSONEncoder().encode(SavedAssets(build: build, guids: guids)) { try? data.write(to: kind.assetFile) }
        PluginLog.write("FM's \(kind.name) table assets kept: \(guids.joined(separator: " "))")
    }

    /// An asset file: the GUIDs, and the build of FM they were kept on.
    struct SavedAssets: Codable {
        let build: String
        let guids: [String]
    }

    /// The GUIDs in an asset file, if it was kept on this build of FM. After a patch a GUID may be gone, or point at
    /// something else, so they're taken from one of FM's own tables again instead.
    nonisolated static func savedGUIDs(_ data: Data, build: String?) -> [String]? {
        guard let build, let saved = try? JSONDecoder().decode(SavedAssets.self, from: data), saved.build == build else { return nil }
        return saved.guids
    }

    /// Which build of FM this is: its version, and GameAssembly's UUID, which a patch changes. Nil if the UUID can't be
    /// read, and then no GUIDs are kept or used.
    static var fmBuild: String? {
        guard let uuid = IL2CPP.gameAssemblyUUID() else { return nil }
        return "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") \(uuid)"
    }

    /// Looks through FM's screens, shown or not, for its people tables to take the assets from.
    static func lookForAssets(below roots: [Pointer], _ ui: FMElements) {
        let wanted = { Kind.allCases.contains { assets[$0] == nil || knownColumns[$0] == nil } }
        guard wanted(), let tableClass = ui.il2cpp.findClass("SI.Bindable", "StreamedTable") else { return }
        var queue = roots
        var looked = 0
        while !queue.isEmpty, looked < 40_000, wanted() {
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
        for kind in Kind.allCases { loadAssets(kind, ui) }
    }

    private static func loadAssets(_ kind: Kind, _ ui: FMElements) {
        let il2cpp = ui.il2cpp
        guard assets[kind] == nil, let data = try? Data(contentsOf: kind.assetFile) else { return }
        guard let guids = savedGUIDs(data, build: fmBuild), guids.count == setters.count else {
            PluginLog.write("FM's \(kind.name) table assets weren't kept on this build of FM, so they'll be taken from FM's own table")
            return
        }
        guard let tableClass = il2cpp.findClass("SI.Bindable", "StreamedTable") else { return }
        var handles: [IL2CPP.Handle?] = []
        for (setter, guid) in zip(setters, guids) {
            guard !guid.isEmpty else {
                handles.append(nil)
                continue
            }
            do {
                guard let method = il2cpp.method(tableClass, setter, parameters: 1),
                      let referenceClass = il2cpp.klass(of: il2cpp.methodParameter(method, 0)) else {
                    throw IL2CPP.Failure("No \(setter) in FM's StreamedTable")
                }
                let reference = try il2cpp.new(referenceClass, [il2cpp.managedString(guid)], firstParameter: "System.String")
                guard let handle = il2cpp.pin(reference) else { throw IL2CPP.Failure("Couldn't hold \(setter)'s asset") }
                handles.append(handle)
            } catch {
                handles.compactMap { $0 }.forEach(il2cpp.unpin)
                PluginLog.write("FM's \(kind.name) table assets couldn't be made from last time's: \(error)")
                return
            }
        }
        assets[kind] = handles
        PluginLog.write("FM's \(kind.name) table assets made from last time's GUIDs")
    }

    /// Writes the factory's column IDs to the log folder, to choose columns from, and keeps them.
    private static func writeColumns(_ factory: Pointer, _ kind: Kind, _ il2cpp: IL2CPP) {
        guard let rows = il2cpp.fieldObject(factory, "m_rowData") else { return }
        var lines: [String] = []
        var widths: [String: Float] = [:]
        for row in il2cpp.items(of: rows) {
            guard let id = il2cpp.fieldObject(row, "m_id").flatMap(il2cpp.text) else { continue }
            let width = il2cpp.value(row, "m_defaultWidth", as: Float.self) ?? 0
            widths[id] = width
            lines.append("\(id) \(FMElements.whole(width))")
        }
        defaultWidths[kind] = widths
        knownColumns[kind] = Set(widths.keys)
        if kind == .staff { Kind.staffSpareColumn = Self.spare(among: Array(widths.keys)) ?? "" }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/FM Starship/fm-\(kind.name)-columns.txt")
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        PluginLog.write("FM's \(kind.name) table has \(lines.count) columns to choose from")
    }

    /// Of a factory's columns, one for a hidden value that only FM's editor fills, for our own to copy.
    nonisolated static func spare(among columns: [String]) -> String? {
        columns.filter { $0.hasPrefix("hidden-") && !abilityHosts.values.contains($0) }.sorted().first
    }

    /// Each factory's columns' widths before FM fits the table to the screen, which it does in proportion.
    private(set) static var defaultWidths: [Kind: [String: Float]] = [:]

    /// Takes the factory's columns from a table of ours once it has loaded it, when no table of FM's has been seen
    /// with it. True when that's new, so the table can be made again with columns chosen to fit.
    static func noteFactory(of table: Pointer, _ kind: Kind, _ il2cpp: IL2CPP) -> Bool {
        guard defaultWidths[kind] == nil, let factory = il2cpp.fieldObject(table, "m_loadedFactoryAsset") else { return false }
        writeColumns(factory, kind, il2cpp)
        return defaultWidths[kind] != nil
    }

    // MARK: Making one

    /// A new table of FM's, set up with its player table assets but empty. Rows and columns go in once it's in FM's
    /// tree, with `fill`, since the table loads its factory when it's attached.
    func make(name: String) throws -> Pointer {
        guard let assets = Self.assets[kind] else { throw IL2CPP.Failure("FM's \(kind.name) table assets aren't known yet") }
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
            guard let handle else { continue }
            guard let reference = il2cpp.target(of: handle) else { throw IL2CPP.Failure("\(setter)'s asset is gone") }
            try il2cpp.call(table, setter, [reference])
        }
        // Each row's height, as FM's own player tables set it, so the cells sit in the middle of their rows.
        var height = Self.rowHeight
        _ = try withUnsafeMutablePointer(to: &height) { try il2cpp.call(table, "set_FixedElementSize", [Pointer($0)]) }
        return table
    }

    /// FM's recruitment table's row height, which leaves room for its two-line position and role.
    static var rowHeight: Float = 36
    /// Columns to try instead of a screen's own, set by the developer command `table columns`.
    static var columnOverride: [String]?

    /// The table's columns, from FM's factory by ID, and its rows, one per person, in this order.
    /// Columns wait for FM's factory, which the table loads once it's in FM's tree; until then only the rows go in.
    func fill(_ table: Pointer, people: [Person], columns: [String], own: [String: Float] = [:], extras: [Extra] = []) throws {
        if let factory = il2cpp.fieldObject(table, "m_loadedFactoryAsset") {
            // FM's own column IDs first, so the choice of columns below knows them.
            if Self.defaultWidths[kind] == nil { Self.writeColumns(factory, kind, il2cpp) }
            addOwnColumns(extras, to: factory)
            let (chosen, dropped) = Self.available(columns, known: Self.knownColumns[kind] ?? [])
            for id in dropped { PluginLog.write("FM's \(kind.name) table has no column \(id) on this build of FM, so it's left out") }
            let starred = Set(extras.filter(Self.showsStars).map(\.host)).intersection(chosen)
            if !starred.isEmpty {
                PluginLog.write("FM's stars go in \(starred.sorted().joined(separator: " and ")), as wide as FM's own star columns, \(FMElements.whole(Self.starsWidth))")
            }
            try il2cpp.call(table, "UpdateStreamedTableView", [try view(chosen, own: own, starred: starred)])
        }
        try il2cpp.call(table, "SetList", [try rows(people)])
    }

    /// Of the columns asked for, those FM's factory has, and those it hasn't, which are left out. Until the factory's
    /// columns are known, all of them are kept.
    nonisolated static func available(_ columns: [String], known: Set<String>) -> (kept: [String], dropped: [String]) {
        guard !known.isEmpty else { return (columns, []) }
        return (columns.filter(known.contains), columns.filter { !known.contains($0) })
    }

    /// A view of FM's, as FM keeps for each way of looking at a table, with these columns. Those holding FM
    /// Starship's own, in `own`, are as wide as given and don't sort when their header is clicked. Those in `starred`
    /// show FM's stars, and take the share of the table FM gives its own star columns.
    private func view(_ columns: [String], own: [String: Float], starred: Set<String> = []) throws -> Pointer {
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
            if let width = own[id], let metadata = try? ownMetadata(configClass, width: width, stars: starred.contains(id)) {
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
        _ = try withUnsafeMutablePointer(to: &custom) { try il2cpp.call(create, view, [list, Pointer($0)]) }
        return view
    }

    /// A column's settings, as FM's own views have them, for one holding FM Starship's values: its width, and no
    /// sorting by its header, which would sort by what FM keeps in it.
    private func ownMetadata(_ configClass: Pointer, width: Float, stars: Bool = false) throws -> Pointer {
        guard let withMetadata = il2cpp.method(configClass, ".ctor", parameters: 3, firstParameter: "System.String", inherited: false),
              let metadataClass = il2cpp.klass(of: il2cpp.methodParameter(withMetadata, 1)) else {
            throw IL2CPP.Failure("FM's column settings aren't as expected")
        }
        var required = false
        let metadata = try withUnsafeMutablePointer(to: &required) {
            try il2cpp.new(metadataClass, [Pointer($0)], firstParameter: "System.Boolean")
        }
        // Through IL2CPP, which refuses a field that's no longer the size of the value.
        try il2cpp.setField(metadata, "m_sortingDisabled", true)
        switch Self.widths {
        case .none: break
        case .min:
            try il2cpp.setField(metadata, "m_minWidthOverride", width)
        case .width:
            try il2cpp.setField(metadata, "m_widthOverride", width)
            try il2cpp.setField(metadata, "m_minWidthOverride", width)
        case .both:
            try il2cpp.setField(metadata, "m_widthOverride", width)
            try il2cpp.setField(metadata, "m_minWidthOverride", min(width, 60))
        }
        return metadata
    }

    /// The width FM gives its own Ability and Potential columns before it fits a table, which its stars fill.
    static var starsWidth: Float { (defaultWidths[.players]?["scout-opinion-current-ability"] ?? 90) * starsWiden }

    /// How much wider than FM's own star columns ours are asked to be. FM shares a table's width out in proportion to its
    /// columns' widths, so on a table with many columns the stars' cell comes out narrower than asked, and the fifth star
    /// is cut off. Once a cell is seen too narrow, this grows so the next table has the room.
    static var starsWiden: Float = 1
    /// Set when the stars' columns are to be wider, so the screen's tables are made again with it.
    static var starsRemake = false

    /// How much more to ask for, given the room the stars need and the cell they got. Nil if they fit, or if asking
    /// for more has gone as far as it should.
    nonisolated static func widen(by current: Float, need: Float, got: Float) -> Float? {
        guard need.isFinite, got.isFinite, got > 0, need > got, current < 2.5 else { return nil }
        return min(2.5, current * need / got * 1.02)
    }

    /// How our columns' widths are given to FM. With only a minimum, FM still fits the table to the screen, with
    /// none of ours narrower than its heading or longest value. The developer command `table widths` changes it.
    enum Widths: String { case none, min, width, both }
    static var widths = Widths.none

    // MARK: FM Starship's own columns

    /// One of the engine's columns in FM's table: its values by person, and the tone each is shown in, if any. CA and
    /// PA go in FM's own columns for them, which only FM's editor fills, under FM's headings; the rest in columns of
    /// our own, under the engine's.
    struct Extra {
        let host: String
        let title: String?
        let values: [Int32: String]
        var tones: [Int32: Tone] = [:]
        /// A note beside the main values, in FM's small print, as the engine shows it.
        var quiet = false
        /// Positions sort in FM's order for them, as the engine's column says.
        var order = TableColumn.Order.text
        /// For CA and PA in FM's columns for them, a heading in place of FM's: in Stars mode, FM's names for its own
        /// star columns. Nil keeps FM's.
        var heading: String?
        /// FM's columns this one takes the place of: CA and PA drawn as FM's stars go in columns of our own, as FM's
        /// hidden CA and PA columns are only ever as wide as FM made them, so they stand in for those and FM's scouts' ones.
        var replaces: [String] = []
        /// At least this wide, for FM's stars, which need more room than their text.
        var starWidth: Float = 0
        /// Wide enough for the heading and the longest value. FM fits a table to the screen in proportion to its
        /// columns' own widths, so this is the column's share as much as its width.
        var width: Float {
            let longest = max((title ?? heading)?.count ?? 0, values.values.map(\.count).max() ?? 0)
            return max(starWidth, min(360, max(70, Float(longest) * 7 + 24)))
        }
    }

    nonisolated private static let abilityHosts = ["CA": "hidden-current-ability", "PA": "hidden-potential-ability"]
    /// FM's headings for its own Ability and Potential columns, which show stars, for ours in Stars mode.
    nonisolated private static let starHeadings = ["CA": "Ability", "PA": "Potential"]
    /// FM's scouts' Ability and Potential columns, which ours stand in for.
    nonisolated private static let scoutColumns = ["CA": "scout-opinion-current-ability", "PA": "scout-opinion-potential-ability"]
    /// Headings in FM's words where FM has its own for what the engine shows: FM calls whether a player would join
    /// his interest.
    nonisolated private static let headings = ["Would join on": "Interest"]
    /// Whether FM's own CA and PA columns sort when their header is clicked, by FM's figures for them. FM has none
    /// for the players in our lists, so it doesn't sort; ours does instead. `table casort on` tries FM's again.
    static var abilitySortable = false
    /// CA and PA in Stars mode as FM's own star graphic, the yellow stars of its Ability and Potential columns, in
    /// place of text such as 3.5★, and the stars FM gives a player in a role, in place of ★★★½. CA and PA are still
    /// ours, on our scale, where CA 200 is five stars, and all of them sort by our columns' headings as before. Seen
    /// right in FM on 27.0.1 (11 November), so on; the developer command `stars text` shows the text, to compare.
    static var nativeStars = true
    /// Set once FM's stars couldn't be made, or FM's style didn't reach them, after which they're text again.
    static var starsFailed = false
    /// When the first of FM's stars went into one of our tables, to check them once they're laid out.
    static var firstStars: Date?
    static var starsChecked = false

    /// Whether one of the engine's columns holds stars FM's star graphic can show: CA or PA in Stars mode, in FM's
    /// columns for them, or a column of our own with nothing but stars in it, such as a role's. One with words beside
    /// its stars, such as the planner's best fit, stays text.
    nonisolated static func holdsStars(_ extra: Extra) -> Bool {
        if extra.title == nil { return extra.values.values.contains { FMElements.halfStars($0) != nil } }
        // A role FM gives no stars shows a dash, and a player with no role nothing.
        let rated = extra.values.values.filter { !$0.isEmpty && $0 != "-" }
        return !rated.isEmpty && rated.allSatisfy { FMElements.halfStars($0) != nil }
    }

    /// Whether one of the engine's columns shows FM's stars.
    static func showsStars(_ extra: Extra) -> Bool {
        nativeStars && !starsFailed && holdsStars(extra)
    }

    /// The ID of our own column for one of the engine's, from its title.
    nonisolated static func ownID(_ title: String) -> String {
        "fmstarship-" + title.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }

    /// The engine's columns with these titles, as it shows them: while CA and PA are off it has none of them. A row's
    /// tone colours its value in the column the tone is for, or in every column when the tone is for the whole row.
    static func extras(from table: AnalysisTable, titles: [String]) -> [Extra] {
        titles.compactMap { title in
            guard let column = table.columns.firstIndex(where: { $0.title == title }) else { return nil }
            var values: [Int32: String] = [:]
            var tones: [Int32: Tone] = [:]
            for row in table.rows where column < row.cells.count {
                guard let person = row.person else { continue }
                let index = Int32(bitPattern: person.index)
                values[index] = row.cells[column]
                if let tone = row.tone, row.toneColumn == nil || row.toneColumn == column { tones[index] = tone }
            }
            let heading = headings[title] ?? title
            let quiet = table.rows.contains { $0.quietColumn == column }
            if let host = abilityHosts[title] {
                var extra = Extra(host: host, title: nil, values: values, tones: tones, quiet: quiet)
                // In Stars mode, as its values show, under FM's names for its star columns; in Exact, FM's CA and PA.
                if holdsStars(extra) { extra.heading = starHeadings[title] }
                // Drawn as FM's stars, in a column of our own that can be as wide as they need.
                if showsStars(extra), let star = starHeadings[title] {
                    var own = Extra(host: ownID(star), title: star, values: values, tones: tones, quiet: quiet)
                    own.replaces = [host, scoutColumns[title] ?? ""].filter { !$0.isEmpty }
                    own.starWidth = starsWidth
                    return own
                }
                return extra
            }
            var extra = Extra(host: ownID(heading), title: heading, values: values, tones: tones, quiet: quiet, order: table.columns[column].order)
            if showsStars(extra) { extra.starWidth = starsWidth }
            return extra
        }
    }

    /// FM's columns for a whole engine table, in the engine's order: FM's own where `fm` names one for the engine's
    /// column, such as FM's name column for the engine's player, and the engine's own for the rest, which are the
    /// extras to show.
    nonisolated static func layout(of table: AnalysisTable, fm: [String: String]) -> (columns: [String], extras: [String]) {
        var columns: [String] = []
        var extras: [String] = []
        for title in table.columns.map(\.title) {
            if let id = fm[title] {
                if !columns.contains(id) { columns.append(id) }
            } else {
                columns.append(abilityHosts[title] ?? ownID(headings[title] ?? title))
                extras.append(title)
            }
        }
        return (columns, extras)
    }

    /// Our own columns in FM's table: copies of FM's column for a hidden value, such as a player's asking price,
    /// which only FM's editor fills, under IDs of ours and as wide as our values need. They go in the factory's lookup for as long as FM
    /// keeps the factory loaded; FM's own tables never ask for them.
    func addOwnColumns(_ extras: [Extra], to factory: Pointer) {
        guard let lookup = il2cpp.fieldObject(factory, "m_rowDataLookup") else { return }
        // A column of ours FM already has keeps the width it was made with, unless it holds FM's stars, whose room
        // can grow once they're seen cut off.
        for extra in extras where extra.title != nil && extra.starWidth > 0 {
            guard il2cpp.unbox(try? il2cpp.call(lookup, "ContainsKey", [il2cpp.managedString(extra.host)]), as: Bool.self) == true,
                  let column = try? il2cpp.call(lookup, "get_Item", [il2cpp.managedString(extra.host)]) else { continue }
            do { try il2cpp.setField(column, "m_defaultWidth", extra.width) } catch {
                PluginLog.write("Our column \(extra.host) couldn't be made wider for FM's stars: \(error)")
            }
        }
        let wanted = extras.filter { extra in
            extra.title != nil && il2cpp.unbox(try? il2cpp.call(lookup, "ContainsKey", [il2cpp.managedString(extra.host)]), as: Bool.self) == false
        }
        guard !wanted.isEmpty, let rows = il2cpp.fieldObject(factory, "m_rowData"),
              let source = il2cpp.items(of: rows).first(where: { il2cpp.fieldObject($0, "m_id").flatMap(il2cpp.text) == kind.spareColumn }),
              let rowClass = il2cpp.classOf(source) else { return }
        for extra in wanted {
            do {
                let column = try il2cpp.new(rowClass)
                il2cpp.copyFields(from: source, to: column)
                try il2cpp.setField(column, "m_id", il2cpp.managedString(extra.host))
                try il2cpp.setField(column, "m_defaultWidth", extra.width)
                try il2cpp.setField(column, "m_minimumWidth", Float(48))
                try il2cpp.call(lookup, "set_Item", [il2cpp.managedString(extra.host), column])
                Self.knownColumns[kind, default: []].insert(extra.host)
            } catch {
                PluginLog.write("Our column \(extra.host) couldn't go in FM's table: \(error)")
            }
        }
    }

    /// FM's columns for a list with the engine's own beside them: the engine's CA and PA in place of FM's scouts'
    /// opinion of them, and its other columns at the end.
    static func columns(_ columns: [String], with extras: [Extra]) -> [String] {
        let hosts = Set(extras.map(\.host))
        var chosen: [String] = []
        for id in columns {
            // Ours drawn as FM's stars, in place of FM's hidden or scouts' column for the same, once.
            if let standIn = extras.first(where: { $0.replaces.contains(id) }) {
                if !chosen.contains(standIn.host) { chosen.append(standIn.host) }
                continue
            }
            chosen.append(id)
        }
        chosen = chosen.map { id -> String in
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
        /// The rows and cells kept above by their addresses, held through GC handles: one FM let go of could otherwise be
        /// collected, and a new one made at its address taken for it.
        var pinned: [Pointer: IL2CPP.Handle] = [:]
        /// The headings' buttons whose clicks are ours.
        var buttons: [Pointer] = []
        /// FM's headers, and the sort, when our headings and sort arrows were last put on them, and when that was.
        var headers: [Pointer?] = []
        var headedSort: Sort?
        var headedAt: Date?
        /// Whether any of its cells show FM's stars.
        var stars = false
        /// The columns whose values are stars, worked out once, since a table's values don't change while it's up.
        var starColumns: Set<String>?
        /// FM's columns whose heading ours couldn't replace, which keep FM's.
        var fmHeadings: Set<String> = []

        /// Forgets the rows and headings, and lets go of them, when the table goes or FM builds its columns again.
        @MainActor
        func forget(_ il2cpp: IL2CPP?) {
            for handle in pinned.values { il2cpp?.unpin(handle) }
            for button in buttons { ClickActions.actions[button] = nil }
            stars = false
            fmHeadings = []
            person = [:]
            cells = [:]
            fitted = []
            hooked = []
            pinned = [:]
            buttons = []
            headers = []
            headedSort = nil
            headedAt = nil
        }

        /// Whether the headings need putting on again: FM has made its headers again, the sort has changed, or it's been
        /// a second, in case FM has set its sort arrows back on its own.
        func needsHeadings(_ headers: [Pointer?], sort: Sort?, now: Date) -> Bool {
            guard let headedAt, headers == self.headers, sort == headedSort else { return true }
            return now.timeIntervalSince(headedAt) >= 1
        }

        @MainActor
        fileprivate func pin(_ element: Pointer, _ il2cpp: IL2CPP) {
            if pinned[element] == nil, let handle = il2cpp.pin(element) { pinned[element] = handle }
        }
    }

    /// Set once FM's rows have been found not to be as expected, so that's logged only once.
    private static var rowsUnreadable = false
    /// Set once one of FM's headings couldn't be changed, so that's logged only once.
    private static var fmHeadingsFailed = false

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
        // FM keeps each row as a 16-byte pair: the row's BindingRoot, which has its key and its cells, and an element.
        // The BindingRoot is found by its type. If it isn't there, or the pair has changed size, our values are off.
        let rowOffset = il2cpp.findClass("SI.Bindable", "BindingRoot").flatMap { il2cpp.offset(of: $0, inStructsOf: rowList) }
        let rows = rowOffset == nil ? [] : il2cpp.structItems(of: rowList, size: 16)
        if rows.isEmpty, (il2cpp.value(rowList, "_size", as: Int32.self) ?? 0) > 0, !Self.rowsUnreadable {
            PluginLog.write("FM's table rows aren't as expected on this build of FM, so our values are off")
            Self.rowsUnreadable = true
        }
        let ids = il2cpp.strings(inList: il2cpp.fieldObject(table, "m_columnIDs"))
        if ids != shown.columns {
            // FM built its columns again, and the rows' cells and headings with them.
            shown.forget(il2cpp)
            shown.columns = ids
        }
        let placed = extras.compactMap { extra in ids.firstIndex(of: extra.host).map { (extra, $0) } }
        if shown.starColumns == nil { shown.starColumns = Set(extras.filter(Self.holdsStars).map(\.host)) }
        let starColumns = Self.nativeStars && !Self.starsFailed ? shown.starColumns ?? [] : []
        if Self.starsFailed, shown.stars {
            // FM's stars are off since they went in, so every row is written again, as text.
            shown.stars = false
            shown.person = [:]
        }
        for row in rows {
            guard let rowOffset, let root = row.load(fromByteOffset: rowOffset, as: IL2CPP.Pointer?.self) else { continue }
            shown.pin(root, il2cpp)
            if !shown.fitted.contains(root) {
                fit(root)
                shown.fitted.insert(root)
            }
            guard !placed.isEmpty else { continue }
            let index = personIndex(of: root, bindings: bindings) ?? -1
            guard shown.person[root] != index else { continue }
            let cells = shown.cells[root] ?? self.cells(in: root)
            if shown.cells[root] == nil { cells.forEach { shown.pin($0, il2cpp) } }
            shown.cells[root] = cells
            for (extra, column) in placed where column < cells.count {
                let value = extra.values[index] ?? ""
                if starColumns.contains(extra.host), let halves = FMElements.halfStars(value), setStars(halves, in: cells[column]) {
                    shown.stars = true
                    continue
                }
                setValue(value, tone: extra.tones[index], quiet: extra.quiet, in: cells[column])
            }
            shown.person[root] = index
        }
        if Self.nativeStars, !Self.starsChecked, let first = Self.firstStars, Date().timeIntervalSince(first) >= 1 {
            checkStars(in: table, since: first)
        }
        guard let columns = il2cpp.fieldObject(table, "m_columns") else { return }
        let fmColumns = il2cpp.items(of: columns)
        let headers = fmColumns.map { il2cpp.fieldObject($0, "m_header") }
        let now = Date()
        guard shown.needsHeadings(headers, sort: sort, now: now) else { return }
        var complete = true
        for column in fmColumns {
            guard let id = il2cpp.fieldObject(column, "<ColumnID>k__BackingField").flatMap(il2cpp.text),
                  let extra = extras.first(where: { $0.host == id }),
                  let header = il2cpp.fieldObject(column, "m_header") else { continue }
            // Kept by its address until the table goes, so a header FM makes in its place can't be taken for it.
            shown.pin(header, il2cpp)
            if let title = extra.title, (try? heading(header, title)) != true { complete = false }
            if extra.title == nil, let title = extra.heading, !shown.fmHeadings.contains(id) {
                // CA and PA under FM's names for its star columns. If ours can't go on, FM's CA and PA stay.
                do {
                    if try !heading(header, title) { complete = false }
                } catch {
                    shown.fmHeadings.insert(id)
                    if !Self.fmHeadingsFailed {
                        PluginLog.write("FM's heading for \(id) couldn't be changed to \(title), so it's left as FM's: \(error)")
                    }
                    Self.fmHeadingsFailed = true
                }
            }
            if !shown.hooked.contains(header), let button = il2cpp.fieldObject(header, "m_button") {
                // FM can't sort by our values, so clicking the heading sorts the list by them here.
                try? ui.onButtonClick(button) { onSort(id) }
                shown.hooked.insert(header)
                shown.buttons.append(button)
            }
            if let icon = il2cpp.fieldObject(header, "m_sortIcon") {
                sortIcon(icon, sort?.host == id ? sort?.descending : nil)
            } else {
                complete = false
            }
        }
        // Until every heading is on, such as while FM is still filling a new header, it's tried again each time.
        guard complete else { return }
        shown.headers = headers
        shown.headedSort = sort
        shown.headedAt = now
    }

    /// The engine's heading in place of FM's: a label of ours, in the style of FM's, with FM's hidden. FM writes
    /// its own heading into its label again whenever it binds the headings, and that no longer shows. False if ours
    /// couldn't go on yet, such as while FM is still filling the header; throws if it couldn't be made or put on.
    private func heading(_ header: Pointer, _ title: String) throws -> Bool {
        guard il2cpp.fieldOffset(il2cpp.classOf(header), "<TextLabel>k__BackingField") != nil else {
            throw IL2CPP.Failure("FM's table headers have no TextLabel on this build of FM")
        }
        guard let label = il2cpp.fieldObject(header, "<TextLabel>k__BackingField"), let parent = ui.parent(of: label) else { return false }
        if let ours = ui.query(parent, "FMStarshipHeading") {
            if il2cpp.text(try? il2cpp.call(ours, "get_text")) != title { try ui.setText(ours, title) }
            return true
        }
        guard let index = ui.children(of: parent).firstIndex(of: label) else { return false }
        let ours = try ui.text(title, ui.classes(of: label), name: "FMStarshipHeading")
        try ui.insert(ours, into: parent, at: index + 1)
        try? ui.style(label) { try $0.keyword("display", 1) }
        return true
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

    /// The list sorted by one of our columns: positions in FM's order for them, otherwise by the number a value starts
    /// with where it has one, such as CA's 153 or +15 (GK), otherwise alphabetically, with what has no value last.
    static func sorted(_ people: [Person], by extra: Extra, descending: Bool) -> [Person] {
        // A column of stars sorts by how many, whichever way they're written, with a role FM gives none (a dash) as none.
        let stars = holdsStars(extra)
        func number(_ text: String) -> Double? {
            if stars, let halves = FMElements.halfStars(text) { return Double(halves) / 2 }
            if stars, text == "-" { return 0 }
            let start = text.prefix { "+-0123456789.".contains($0) }
            return Double(start.hasPrefix("+") ? String(start.dropFirst()) : String(start))
        }
        return people.enumerated().sorted { left, right in
            let a = extra.values[Int32(bitPattern: left.element.index)] ?? "", b = extra.values[Int32(bitPattern: right.element.index)] ?? ""
            if a.isEmpty != b.isEmpty { return b.isEmpty }
            if let first = extra.order.precedes(a, left.element, b, right.element, descending: descending) { return first }
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
            _ = try withUnsafeMutablePointer(to: &index) { index in
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

    /// Our value in one of FM's cells, in FM's text style, in the middle of the cell, in its tone's colour if it has
    /// one. A note is in small print, and wraps onto a second line where it needs one.
    private func setValue(_ value: String, tone: Tone? = nil, quiet: Bool = false, in cell: Pointer) {
        // A cell that showed FM's stars before, or nearly did, shows the text instead.
        if Self.firstStars != nil || Self.starsFailed {
            if let stars = ui.query(cell, "FMStarshipStars") { try? ui.style(stars) { try $0.keyword("display", 1) } }
            if let box = ui.query(cell, "FMStarshipValue") { try? ui.style(box) { try $0.keyword("display", 0) } }
        }
        let label: Pointer
        if let existing = ui.query(cell, "FMStarshipValueText") {
            label = existing
        } else {
            guard let box = try? ui.box(name: "FMStarshipValue"),
                  let made = try? ui.text(value, quiet ? ["body-sm", "global-text-secondary", "content-ellipsis"]
                                                       : ["body-md", "global-text-primary", "content-no-wrap", "content-ellipsis"],
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
            // A note wraps onto a second line in the row's height, and ends in an ellipsis if there's more.
            if quiet {
                try? ui.style(made) { style in
                    try style.keyword("whiteSpace", 0)
                    try style.keyword("overflow", 1)
                    try style.length("maxHeight", 32)
                }
            }
            try? ui.add(made, to: box)
            try? ui.add(box, to: cell)
            label = made
        }
        if il2cpp.text(try? il2cpp.call(label, "get_text")) != value { try? ui.setText(label, value) }
        try? ui.style(label) { style in
            if let colour = tone.flatMap(NativePage.colour(of:)) { try style.color("color", colour) } else { try style.clearColor("color") }
        }
    }

    /// FM's stars for one of our values in one of FM's cells, in place of the text, at the left of the cell and in the
    /// middle of its height, as in FM's own star cells. False if they couldn't go in, and from then on stars go in
    /// as text.
    private func setStars(_ halves: Int, in cell: Pointer) -> Bool {
        do {
            if let rating = ui.query(cell, "FMStarshipStarRating") {
                try ui.setStars(rating, halves)
                if let box = ui.parent(of: rating) { try ui.style(box) { try $0.keyword("display", 0) } }
                if let text = ui.query(cell, "FMStarshipValue") { try ui.style(text) { try $0.keyword("display", 1) } }
                return true
            }
            let box = try ui.box(name: "FMStarshipStars")
            try ui.style(box) { style in
                try style.keyword("position", 1)
                for side in ["left", "top", "right", "bottom"] { try style.length(side, 0) }
                try style.length("paddingLeft", 4)
                try style.keyword("flexDirection", 2)
                try style.keyword("alignItems", 2)
                try style.keyword("justifyContent", 0)
            }
            let rating = try ui.stars(halves, name: "FMStarshipStarRating")
            // A row, whatever FM's style sheets say, so the stars never stack if they say nothing.
            try ui.style(rating) { style in
                try style.keyword("flexDirection", 2)
                try style.number("flexShrink", 0)
            }
            try ui.add(rating, to: box)
            // What FM itself shows in the column, and our text if the cell had it, make way for the stars.
            for child in ui.children(of: cell) { try ui.style(child) { try $0.keyword("display", 1) } }
            try ui.add(box, to: cell)
            if Self.firstStars == nil { Self.firstStars = Date() }
            return true
        } catch {
            Self.starsFailed = true
            PluginLog.write("FM's stars couldn't go in our columns, so they show as text: \(error)")
            return false
        }
    }

    /// Whether FM's style reached the stars in our cells, once one has been laid out: each star is then FM's size, or,
    /// if FM's style sheets don't reach them, nothing at all, and they go back to text. Checked once, and given up
    /// on if no stars have been seen laid out after a few seconds.
    private func checkStars(in table: Pointer, since first: Date) {
        guard let rating = ui.query(table, "FMStarshipStarRating"), let box = ui.parent(of: rating), let cell = ui.parent(of: box),
              let star = ui.children(of: rating).first,
              let room = ui.layout(box), room.width.isFinite, room.width > 0,
              let size = ui.layout(star), size.width.isFinite, size.height.isFinite,
              let row = ui.layout(rating), row.width.isFinite else {
            if Date().timeIntervalSince(first) > 10 {
                Self.starsChecked = true
                PluginLog.write("FM's stars in our columns weren't seen laid out, so they weren't checked")
            }
            return
        }
        Self.starsChecked = true
        let width = ui.layout(cell).map { FMElements.whole($0.width) } ?? "?"
        // Five stars, and the 4 points of room our cells start with, and a little to spare.
        if size.width > 0, size.height > 0, let got = ui.layout(cell)?.width,
           let wider = Self.widen(by: Self.starsWiden, need: row.width + 8, got: got) {
            Self.starsWiden = wider
            Self.starsChecked = false
            Self.firstStars = nil
            Self.starsRemake = true
            PluginLog.write("FM's stars need \(FMElements.whole(row.width + 8)) in a cell \(width) wide, so their columns are asked for "
                + "\(FMElements.whole(Self.starsWidth)) and the tables made again")
            return
        }
        if size.width > 0, size.height > 0 {
            PluginLog.write("FM's stars are up in our columns: each star \(FMElements.whole(size.width))x\(FMElements.whole(size.height)), "
                + "the five \(FMElements.whole(row.width)) wide in a cell \(width) wide")
        } else {
            Self.starsFailed = true
            PluginLog.write("FM's style didn't reach the stars in our columns (a star is \(FMElements.whole(size.width))x\(FMElements.whole(size.height))), so they show as text")
        }
    }

    /// Set once a row's key has been found not to be as expected, so that's logged only once.
    private static var keysUnreadable = false
    /// Where a row keeps its person, under its key, as the characters `Bindings.Get` reads.
    private static let bindingPath = Array("binding".utf16)

    /// The database index of the person in a row FM has drawn: the reference FM put in the row's key as "binding".
    private func personIndex(of row: Pointer, bindings: Pointer) -> Int32? {
        guard let get = il2cpp.method(il2cpp.classOf(bindings), "Get", parameters: 2, firstParameter: "SI.Bindable.Bindings.Key&"),
              il2cpp.valueSize(il2cpp.methodParameter(get, 1)) == 16,
              let getKey = il2cpp.method(il2cpp.classOf(row), "get_Key", parameters: 0) else { return nil }
        // The key is read as the 8 bytes it is now. If it grows, its first 8 would find another person's values.
        guard il2cpp.valueSize(il2cpp.returnType(getKey)) == 8 else {
            if !Self.keysUnreadable { PluginLog.write("FM's row keys aren't as expected on this build of FM, so our values are off") }
            Self.keysUnreadable = true
            return nil
        }
        guard let key = il2cpp.unbox(try? il2cpp.call(getKey, row), as: UInt64.self), key != 0 else { return nil }
        var rowKey = key
        let value: Pointer? = Self.bindingPath.withUnsafeBufferPointer { chars in
            guard let start = chars.baseAddress else { return nil }
            // ReadOnlySpan<char>: where the characters are, then how many.
            var span: (UnsafeRawPointer, Int32) = (UnsafeRawPointer(start), Int32(chars.count))
            return withUnsafeMutablePointer(to: &rowKey) { keyPointer in
                withUnsafeMutablePointer(to: &span) { (try? il2cpp.call(get, bindings, [Pointer(keyPointer), Pointer($0)])) ?? nil }
            }
        }
        guard let value, let reference = il2cpp.fieldObject(value, "m_value") else { return nil }
        return il2cpp.value(reference, "m_index", as: Int32.self)
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
                _ = try withUnsafeMutablePointer(to: &property) { property in
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
