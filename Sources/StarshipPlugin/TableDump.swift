import Foundation

// Only in developer builds: `Scripts/install-plugin.sh --developer`.
#if STARSHIP_DEVELOPER
/// A developer's look at FM's own tables, such as the squad and the player database: each StreamedTable on the open
/// screen, with its elements, its fields, what feeds its rows, its columns and view, and FM's objects behind them a
/// few levels down, then the fields and methods of FM's classes among them. This is how FM Starship finds out whether
/// its lists can go in FM's tables, with FM's sorting, filters and links to people.
///
/// While `watchFile` exists, it writes the tables of each screen FM opens, a moment after it opens. It only reads.
@MainActor
final class TableDump {
    static let shared = TableDump()

    private typealias Pointer = IL2CPP.Pointer

    private static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/FM Starship", isDirectory: true)
    static let watchFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FMStarship/Plugin/watch-tables")

    /// UI Toolkit's own classes, which every element shares, so their fields are left out.
    private static let elementClasses: Set<String> = ["UnityEngine.UIElements.VisualElement", "UnityEngine.UIElements.Focusable",
                                                      "UnityEngine.UIElements.CallbackEventHandler"]

    private var timer: Timer?
    private var lastScreens = ""
    private var pending = 0

    // MARK: Watching

    func startWatchingIfAsked() {
        guard timer == nil, FileManager.default.fileExists(atPath: Self.watchFile.path) else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { TableDump.shared.check() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        PluginLog.write("Watching FM's screens for tables")
    }

    /// Writes once the screens FM shows have stayed the same for two seconds, so its tables have had time to fill.
    private func check() {
        guard let il2cpp = IL2CPP.shared, let ui = FMElements(il2cpp) else { return }
        let screens = il2cpp.withoutCollection { (try? visibleScreens(ui))?.map { ui.name(of: $0) }.joined(separator: ",") ?? "" }
        if screens != lastScreens {
            lastScreens = screens
            pending = 2
        } else if pending > 0 {
            pending -= 1
            if pending == 0, !screens.isEmpty { write() }
        }
    }

    /// The screens FM shows: its main area's, and the report cards it opens over them, such as the player database.
    private func visibleScreens(_ ui: FMElements) throws -> [Pointer] {
        guard let root = try ui.mainRoot() else { return [] }
        return ["MenuBody", "ReportBody"].compactMap { ui.query(root, $0) }.flatMap { body in
            ui.children(of: body).filter { ui.hasClass($0, "panel--visible") && ui.name(of: $0) != "FMStarshipScreen" }
        }
    }

    // MARK: Writing

    /// Writes the tables on the screens FM shows now, one file per screen.
    func write() {
        guard let il2cpp = IL2CPP.shared, let ui = FMElements(il2cpp) else { return }
        il2cpp.withoutCollection {
            do { try dump(il2cpp, ui) } catch { PluginLog.write("Table dump failed: \(error)") }
        }
    }

    private struct State {
        var lines: [String] = []
        var seen: Set<Pointer> = []
        var classes: [Pointer] = []
        var budget = 40_000
    }

    private func dump(_ il2cpp: IL2CPP, _ ui: FMElements) throws {
        guard let tableClass = il2cpp.findClass("SI.Bindable", "StreamedTable") else { throw IL2CPP.Failure("No StreamedTable in FM") }
        let linkClass = il2cpp.findClass("SI.Bindable", "NavigableLink")
        for screen in try visibleScreens(ui) {
            let started = Date()
            var tables: [(table: Pointer, path: [String])] = []
            var looked = 0
            find(tableClass, in: screen, path: [], into: &tables, looked: &looked, il2cpp, ui)
            var state = State()
            state.lines.append("Screen \(ui.name(of: screen)) \(il2cpp.summary(of: screen)): \(tables.count) table(s) in \(looked) elements")
            for (index, found) in tables.enumerated() {
                FMTable.keepAssets(from: found.table, ui)
                state.lines.append("")
                state.lines.append("==== Table \(index + 1): \(found.path.joined(separator: " > "))")
                state.lines.append("---- Elements")
                var budget = 1500
                tree(found.table, depth: 0, into: &state.lines, budget: &budget, il2cpp, ui)
                state.lines.append("---- Objects")
                explore(found.table, label: "table", depth: 0, maxDepth: 3, &state, il2cpp)
                if let row = ui.query(found.table, styleClass: "streamed-table__row") {
                    state.lines.append("---- First row")
                    explore(row, label: "row", depth: 0, maxDepth: 2, &state, il2cpp)
                    var links: [(table: Pointer, path: [String])] = []
                    var count = 0
                    if let linkClass { find(linkClass, in: row, path: [], into: &links, looked: &count, il2cpp, ui) }
                    for (number, link) in links.prefix(3).enumerated() {
                        state.lines.append("---- Link \(number + 1) in the first row: \(link.path.joined(separator: " > "))")
                        explore(link.table, label: "link", depth: 0, maxDepth: 2, &state, il2cpp)
                    }
                }
            }
            state.lines.append("")
            state.lines.append("==== FM's classes met above")
            var described: Set<Pointer> = []
            for klass in state.classes {
                var current: Pointer? = klass
                while let k = current, !described.contains(k), Self.isFMs(il2cpp.name(of: k)) {
                    described.insert(k)
                    state.lines.append(il2cpp.describe(k))
                    state.lines.append("")
                    current = il2cpp.parentClass(k)
                }
            }
            let name = ui.name(of: screen).isEmpty ? "screen" : ui.name(of: screen)
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try state.lines.joined(separator: "\n").write(to: Self.folder.appendingPathComponent("fm-tables-\(name).txt"), atomically: true,
                                                          encoding: .utf8)
            PluginLog.write("Tables of \(name): \(tables.count), \(state.lines.count) lines, in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        }
    }

    /// Elements of `klass` below `element`, with the names on the way to each. Not below one already found.
    private func find(_ klass: Pointer, in element: Pointer, path: [String], into found: inout [(table: Pointer, path: [String])],
                      looked: inout Int, _ il2cpp: IL2CPP, _ ui: FMElements) {
        guard looked < 60_000 else { return }
        looked += 1
        let name = ui.name(of: element)
        let here = name.isEmpty ? path : path + [name]
        if il2cpp.isSubclass(il2cpp.classOf(element), of: klass) {
            found.append((element, here))
            return
        }
        for child in ui.children(of: element) { find(klass, in: child, path: here, into: &found, looked: &looked, il2cpp, ui) }
    }

    /// The table's elements as the interface dump shows them: class, name, style classes, size and text.
    private func tree(_ element: Pointer, depth: Int, into lines: inout [String], budget: inout Int, _ il2cpp: IL2CPP, _ ui: FMElements) {
        guard budget > 0 else { return }
        budget -= 1
        var line = String(repeating: "  ", count: depth) + il2cpp.name(of: il2cpp.classOf(element))
        let name = ui.name(of: element)
        if !name.isEmpty { line += " #\(name)" }
        let classes = ui.classes(of: element)
        if !classes.isEmpty { line += " ." + classes.joined(separator: " .") }
        if let rect = ui.layout(element) {
            line += " [\(FMElements.whole(rect.x)),\(FMElements.whole(rect.y)) \(FMElements.whole(rect.width))x\(FMElements.whole(rect.height))]"
        }
        if il2cpp.isSubclass(il2cpp.classOf(element), of: il2cpp.findClass(FMElements.toolkit, "TextElement")),
           let text = il2cpp.text(try? il2cpp.call(element, "get_text")), !text.isEmpty {
            line += " \"\(text.prefix(100).replacingOccurrences(of: "\n", with: " "))\""
        }
        lines.append(line)
        for child in ui.children(of: element) { tree(child, depth: depth + 1, into: &lines, budget: &budget, il2cpp, ui) }
    }

    /// The object's fields, then the objects they point at, down to `maxDepth`. Lists and arrays show their first
    /// three items. Other elements aren't followed, since the element tree has them, and nor are .NET's and Unity's.
    private func explore(_ object: Pointer, label: String, depth: Int, maxDepth: Int, _ state: inout State, _ il2cpp: IL2CPP) {
        let indent = String(repeating: "    ", count: depth)
        guard state.budget > 0 else { return }
        guard !state.seen.contains(object) else {
            state.lines.append("\(indent)\(label) = \(il2cpp.summary(of: object)), above")
            return
        }
        state.seen.insert(object)
        if let klass = il2cpp.classOf(object), Self.isFMs(il2cpp.name(of: klass)), !state.classes.contains(klass) { state.classes.append(klass) }
        let described = il2cpp.describe(object: object, upTo: Self.elementClasses).split(separator: "\n")
        state.budget -= described.count
        state.lines.append("\(indent)\(label): \(described.first ?? "")")
        state.lines += described.dropFirst().map { "\(indent)\($0)" }
        guard depth < maxDepth else { return }
        let element = il2cpp.findClass(FMElements.toolkit, "VisualElement")
        for (name, value) in il2cpp.references(in: object, upTo: Self.elementClasses) {
            let className = il2cpp.name(of: il2cpp.classOf(value))
            if className.hasSuffix("[]") || className.hasPrefix("System.Collections.Generic.List`1") {
                for (index, item) in il2cpp.items(of: value).prefix(3).enumerated() where follows(item, element, il2cpp) {
                    explore(item, label: "\(name)[\(index)]", depth: depth + 1, maxDepth: maxDepth, &state, il2cpp)
                }
            } else if follows(value, element, il2cpp) {
                explore(value, label: name, depth: depth + 1, maxDepth: maxDepth, &state, il2cpp)
            }
        }
    }

    /// FM's objects, and the asset references that say which of FM's assets a table loads.
    private func follows(_ object: Pointer, _ element: Pointer?, _ il2cpp: IL2CPP) -> Bool {
        let klass = il2cpp.classOf(object)
        let name = il2cpp.name(of: klass)
        return (Self.isFMs(name) || name.hasPrefix("UnityEngine.AddressableAssets.")) && !il2cpp.isSubclass(klass, of: element)
    }

    /// FM's and Sports Interactive's own classes, rather than .NET's or Unity's.
    private static func isFMs(_ className: String) -> Bool {
        !["System", "UnityEngine", "Unity.", "Mono.", "TMPro", "Newtonsoft"].contains { className.hasPrefix($0) } && className != "null"
    }
}
#endif
