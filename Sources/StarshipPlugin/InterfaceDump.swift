import Foundation

// Only in developer builds: `Scripts/install-plugin.sh --developer`.
#if STARSHIP_DEVELOPER
/// A developer's look at how FM builds its interface: the live tree with each element's classes, size, text and resolved
/// colours, and FM's navigation types and objects. Control-Option-D writes it to the log folder, which is how FM
/// Starship's own screens find the element names and style classes to use.
@MainActor
final class InterfaceDump {
    static let shared = InterfaceDump()

    private typealias Pointer = IL2CPP.Pointer
    private let toolkit = "UnityEngine.UIElements"

    private static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/FM Starship", isDirectory: true)

    /// Writes the tree, the types and the live objects to the log folder.
    func write() {
        guard let il2cpp = IL2CPP.shared else { return }
        let started = Date()
        do {
            try il2cpp.withoutCollection { try dumpPaused(il2cpp, started: started) }
        } catch {
            PluginLog.write("Dump failed: \(error)")
        }
    }

    private func dumpPaused(_ il2cpp: IL2CPP, started: Date) throws {
        var tree: [String] = []
        for (index, document) in try documents(il2cpp).enumerated() {
            tree.append("UIDocument \(index) \(il2cpp.summary(of: document.object)) sorting \(document.order)")
        }
        var budget = 40_000
        for root in try panelRoots(il2cpp) {
            tree.append("")
            tree.append("Panel root \(root)")
            try walk(root, depth: 0, into: &tree, budget: &budget, il2cpp: il2cpp)
        }
        try write(tree, to: "fm-interface.txt")

        var types: [String] = []
        for klass in navigationClasses(il2cpp) {
            types.append(il2cpp.describe(klass))
            types.append("")
        }
        try write(types, to: "fm-types.txt")
        try write(try liveObjects(il2cpp), to: "fm-objects.txt")
        PluginLog.write("Dumped FM's interface: \(tree.count) lines, \(types.count) type lines, in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }

    private struct Document {
        let object: Pointer
        let order: Float
        let root: Pointer?
    }

    private func documents(_ il2cpp: IL2CPP) throws -> [Document] {
        guard let documentClass = il2cpp.findClass(toolkit, "UIDocument") else { throw IL2CPP.Failure("No UIDocument") }
        return try findObjects(documentClass, il2cpp).map { document in
            Document(object: document,
                     order: il2cpp.unbox(try il2cpp.call(document, "get_sortingOrder"), as: Float.self) ?? 0,
                     root: try il2cpp.call(document, "get_rootVisualElement"))
        }
    }

    /// The top of each panel FM's documents are drawn in. Documents that share a panel share its root.
    private func panelRoots(_ il2cpp: IL2CPP) throws -> [Pointer] {
        var roots: [Pointer] = []
        for document in try documents(il2cpp).sorted(by: { $0.order > $1.order }) {
            guard var top = document.root else { continue }
            while let parent = try il2cpp.call(top, "get_parent") { top = parent }
            if !roots.contains(top) { roots.append(top) }
        }
        return roots
    }

    private func walk(_ element: Pointer, depth: Int, into lines: inout [String], budget: inout Int, il2cpp: IL2CPP) throws {
        guard budget > 0 else { return }
        budget -= 1
        let klass = il2cpp.classOf(element)
        var line = String(repeating: "  ", count: depth) + il2cpp.name(of: klass)
        if let name = il2cpp.text(try il2cpp.call(element, "get_name")), !name.isEmpty { line += " #\(name)" }
        let classes = il2cpp.strings(inList: try il2cpp.call(element, "GetClasses"))
        if !classes.isEmpty { line += " ." + classes.joined(separator: " .") }
        if let rect = il2cpp.unbox(try il2cpp.call(element, "get_layout"), as: (Float, Float, Float, Float).self) {
            line += " [\(FMElements.whole(rect.0)),\(FMElements.whole(rect.1)) \(FMElements.whole(rect.2))x\(FMElements.whole(rect.3))]"
        }
        if il2cpp.isSubclass(klass, of: il2cpp.findClass(toolkit, "TextElement")),
           let text = il2cpp.text(try il2cpp.call(element, "get_text")), !text.isEmpty {
            line += " \"\(text.prefix(80).replacingOccurrences(of: "\n", with: " "))\""
        }
        if let ui = FMElements(il2cpp) { line += colours(element, ui) }
        lines.append(line)
        let count = il2cpp.unbox(try il2cpp.call(element, "get_childCount"), as: Int32.self) ?? 0
        for index in 0..<count {
            var position = index
            let child = try withUnsafeMutablePointer(to: &position) { try il2cpp.call(element, "ElementAt", [Pointer($0)]) }
            if let child { try walk(child, depth: depth + 1, into: &lines, budget: &budget, il2cpp: il2cpp) }
        }
    }

    /// What FM's style sheets resolved for the element: background, border, corners, and text colour and size.
    private func colours(_ element: Pointer, _ ui: FMElements) -> String {
        func hex(_ c: (Float, Float, Float, Float)) -> String {
            func byte(_ value: Float) -> Int { value.isFinite ? Int(max(0, min(1, value)) * 255) : 0 }
            return String(format: "#%02X%02X%02X%02X", byte(c.0), byte(c.1), byte(c.2), byte(c.3))
        }
        var text = ""
        if let background = ui.resolvedColor(element, "backgroundColor"), background.3 > 0.01 { text += " bg \(hex(background))" }
        if let width = ui.resolvedNumber(element, "borderTopWidth"), width > 0, let colour = ui.resolvedColor(element, "borderTopColor") {
            text += " border \(width) \(hex(colour))"
        }
        if let radius = ui.resolvedNumber(element, "borderTopLeftRadius"), radius > 0 { text += " radius \(radius)" }
        if ui.il2cpp.isSubclass(ui.il2cpp.classOf(element), of: ui.il2cpp.findClass(toolkit, "TextElement")),
           let colour = ui.resolvedColor(element, "color"), let size = ui.resolvedNumber(element, "fontSize") {
            text += " text \(hex(colour)) \(size)"
        }
        return text
    }

    /// FM's classes for navigation, tabs and panels.
    private func navigationClasses(_ il2cpp: IL2CPP) -> [Pointer] {
        let words = ["Navigation", "MainTab", "Subtab", "SubTab", "PanelID", "PanelLayer", "TabGroup", "TabView", "OpenPanel",
                     "Sidebar", "NavBar", "Portal", "Bookmark"]
        var found: [Pointer] = []
        for image in ["FM.UI.dll", "SI.UI.dll", "SI.Bindable.dll", "FMGame.dll"] {
            found += il2cpp.classes(inImage: image).filter { klass in words.contains { il2cpp.name(of: klass).contains($0) } }
        }
        for (namespace, name) in [(toolkit, "UIDocument"), (toolkit, "PanelSettings"), (toolkit, "IStyle"), (toolkit, "StyleLength"),
                                  (toolkit, "Length"), (toolkit, "StyleColor"), (toolkit, "Clickable"), (toolkit, "Button")] {
            if let klass = il2cpp.findClass(namespace, name) { found.append(klass) }
        }
        return found
    }

    /// The live objects of FM's navigation classes: components in the scene, and loaded assets such as panel IDs.
    private func liveObjects(_ il2cpp: IL2CPP) throws -> [String] {
        guard let component = il2cpp.findClass("UnityEngine", "Component"),
              let scriptable = il2cpp.findClass("UnityEngine", "ScriptableObject") else { return [] }
        var lines: [String] = []
        for klass in navigationClasses(il2cpp) where !il2cpp.isGeneric(klass) {
            let objects: [Pointer]
            if il2cpp.isSubclass(klass, of: component) {
                objects = (try? findObjects(klass, il2cpp)) ?? []
            } else if il2cpp.isSubclass(klass, of: scriptable) {
                objects = (try? allLoaded(klass, il2cpp)) ?? []
            } else {
                continue
            }
            guard !objects.isEmpty else { continue }
            lines.append("== \(il2cpp.name(of: klass)): \(objects.count)")
            for object in objects.prefix(objects.count > 12 ? 4 : 12) { lines.append(il2cpp.describe(object: object)) }
            if objects.count > 12 { lines.append("names: " + objects.map { il2cpp.summary(of: $0) }.joined(separator: ", ")) }
            lines.append("")
        }
        return lines
    }

    private func findObjects(_ klass: Pointer, _ il2cpp: IL2CPP) throws -> [Pointer] {
        let find = il2cpp.method(il2cpp.findClass("UnityEngine", "Object"), "FindObjectsByType", parameters: 2, firstParameter: "System.Type")
        var sortMode: Int32 = 0
        let array = try withUnsafeMutablePointer(to: &sortMode) { try il2cpp.call(find, nil, [il2cpp.systemType(klass), Pointer($0)]) }
        return il2cpp.elements(array).compactMap { $0 }
    }

    private func allLoaded(_ klass: Pointer, _ il2cpp: IL2CPP) throws -> [Pointer] {
        let find = il2cpp.method(il2cpp.findClass("UnityEngine", "Resources"), "FindObjectsOfTypeAll", parameters: 1, firstParameter: "System.Type")
        return il2cpp.elements(try il2cpp.call(find, nil, [il2cpp.systemType(klass)])).compactMap { $0 }
    }

    /// Where each method of Sports Interactive's and FM's assemblies has its code in GameAssembly, by offset, sorted,
    /// so a disassembly of a method can be read with the names of the methods it calls. GameAssembly has no names.
    func writeMethodMap() {
        guard let il2cpp = IL2CPP.shared else { return }
        let started = Date()
        var lines: [String] = []
        for image in il2cpp.imageNames where image.hasPrefix("SI.") || image.hasPrefix("FM") {
            for klass in il2cpp.classes(inImage: image) {
                let className = il2cpp.name(of: klass)
                for method in il2cpp.codeOffsets(klass) {
                    lines.append(String(format: "%08x ", method.offset) + "\(className)::\(method.name)")
                }
            }
        }
        lines.sort()
        do {
            try write(lines, to: "fm-methods.txt")
            PluginLog.write("Method map: \(lines.count) methods, in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } catch {
            PluginLog.write("Method map failed: \(error)")
        }
    }

    private func write(_ lines: [String], to name: String) throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: Self.folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

}
#endif
