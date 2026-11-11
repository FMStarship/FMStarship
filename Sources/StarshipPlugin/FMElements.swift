import Foundation

/// Builds FM Starship's screens out of FM's own UI Toolkit elements and style classes, so they look like FM's.
@MainActor
struct FMElements {
    typealias Pointer = IL2CPP.Pointer
    static let toolkit = "UnityEngine.UIElements"
    let il2cpp: IL2CPP

    init?(_ il2cpp: IL2CPP?) {
        guard let il2cpp else { return nil }
        self.il2cpp = il2cpp
    }

    private func toolkitClass(_ name: String) throws -> Pointer {
        guard let klass = il2cpp.findClass(Self.toolkit, name) else { throw IL2CPP.Failure("No \(name) in FM") }
        return klass
    }

    // MARK: Making elements

    /// A plain element with FM's classes.
    func box(_ classes: [String] = [], name: String? = nil) throws -> Pointer {
        let element = try il2cpp.new(try toolkitClass("VisualElement"))
        try configure(element, classes: classes, name: name)
        return element
    }

    /// FM's own text element, with FM's text classes such as "body-md", which carry its fonts.
    func text(_ value: String, _ classes: [String], name: String? = nil) throws -> Pointer {
        var element: Pointer?
        if !Self.siTextFailed, let siText = il2cpp.findClass("SI.Bindable", "SIText") {
            do {
                let made = try il2cpp.new(siText)
                try setText(made, value)
                element = made
            } catch {
                // It may want FM's bindings behind it. UI Toolkit's own Label takes the same classes.
                Self.siTextFailed = true
                PluginLog.write("SIText didn't take text, using Label: \(error)")
            }
        }
        if element == nil {
            let label = try il2cpp.new(try toolkitClass("Label"))
            try setText(label, value)
            element = label
        }
        guard let element else { throw IL2CPP.Failure("No text element") }
        try configure(element, classes: ["sitext"] + classes, name: name)
        return element
    }

    private static var siTextFailed = false

    /// UI Toolkit's scroll view, which scrolls with the wheel and trackpad like FM's own lists.
    func scrollView(_ classes: [String] = [], name: String? = nil) throws -> Pointer {
        let element = try il2cpp.new(try toolkitClass("ScrollView"))
        try configure(element, classes: classes, name: name)
        return element
    }

    /// UI Toolkit's own toggle, which FM's switches are, with FM's classes: on or off, and greyed out when it can't be
    /// changed.
    func toggle(_ on: Bool, enabled: Bool, _ classes: [String]) throws -> Pointer {
        let element = try il2cpp.new(try toolkitClass("Toggle"))
        try configure(element, classes: classes, name: nil)
        try setToggle(element, on)
        if !enabled {
            var value = false
            try withUnsafeMutablePointer(to: &value) { _ = try il2cpp.call(element, "SetEnabled", [Pointer($0)]) }
        }
        return element
    }

    func setToggle(_ element: Pointer, _ on: Bool) throws {
        var value = on
        try withUnsafeMutablePointer(to: &value) { _ = try il2cpp.call(element, "SetValueWithoutNotify", [Pointer($0)]) }
    }

    func toggleValue(_ element: Pointer) -> Bool? {
        il2cpp.unbox(try? il2cpp.call(element, "get_value"), as: Bool.self)
    }

    /// Greys an element out, as FM's own are when they can't be used, and it takes no clicks.
    func disable(_ element: Pointer) throws {
        var value = false
        try withUnsafeMutablePointer(to: &value) { _ = try il2cpp.call(element, "SetEnabled", [Pointer($0)]) }
    }

    /// A scroll view without its vertical bar: it still scrolls with the wheel and trackpad.
    func hideScroller(_ scrollView: Pointer) throws {
        // ScrollerVisibility.Hidden
        var hidden: Int32 = 2
        try withUnsafeMutablePointer(to: &hidden) { _ = try il2cpp.call(scrollView, "set_verticalScrollerVisibility", [Pointer($0)]) }
    }

    /// FM's star graphic, the yellow stars of its Ability and Potential columns, with `halves` half stars of five in
    /// gold. It's made as FM's own star cells make it, a row of five plain elements, from the same style classes, so
    /// FM's style sheets draw it; none of FM's code runs.
    func stars(_ halves: Int, name: String? = nil) throws -> Pointer {
        let rating = try box([Self.starRating], name: name)
        for _ in 0..<5 { try add(try box(), to: rating) }
        try setStars(rating, halves)
        return rating
    }

    /// A star graphic's stars, gold for `halves` half stars, 0 to 10, and empty after.
    func setStars(_ rating: Pointer, _ halves: Int) throws {
        let stars = children(of: rating)
        guard stars.count == 5 else { throw IL2CPP.Failure("A star graphic has \(stars.count) stars, not 5") }
        for (star, wanted) in zip(stars, Self.starClasses(halves)) {
            for name in Self.everyStarClass {
                let has = hasClass(star, name)
                if wanted.contains(name), !has { try addClass(star, name) }
                if !wanted.contains(name), has { try removeClass(star, name) }
            }
        }
    }

    /// The classes of FM's star graphic, from FM's star rating settings for players who aren't youth players, as its
    /// star cells show them: the row, a gold star, a gold half and an empty half, an empty star, and the gap after each
    /// star but the last.
    nonisolated static let starRating = "fm-star-rating-container"
    nonisolated static let goldStar = "ability-max-potential-level-fullfilled-youth-false"
    nonisolated static let halfStar = "ability-half-potential-level-none-youth-false"
    nonisolated static let emptyStar = "ability-minimum-potential-level-none-youth-false"
    nonisolated static let starGap = "fm-star-rating-star"
    nonisolated static let lastStar = "fm-star-rating-star-no-margin"
    nonisolated private static let everyStarClass = [goldStar, halfStar, emptyStar, starGap, lastStar]

    /// Each of the five stars' classes for `halves` half stars, as FM's star cells work them out: a whole star in gold
    /// for every two, then half a gold star for one left over, then empty stars.
    nonisolated static func starClasses(_ halves: Int) -> [Set<String>] {
        (0..<5).map { star in
            let fill = halves >= 2 * star + 2 ? goldStar : halves == 2 * star + 1 ? halfStar : emptyStar
            return [fill, star == 4 ? lastStar : starGap]
        }
    }

    /// The half stars, 0 to 10, in a number of stars as FM Starship writes them for CA and PA in Stars mode, such as
    /// 3.5★. Nil for anything else, such as a number or nothing.
    nonisolated static func halfStars(_ text: String) -> Int? {
        guard text.hasSuffix("★") else { return nil }
        let number = text.dropLast()
        guard !number.isEmpty, number.allSatisfy({ "0123456789.".contains($0) }), let stars = Double(number),
              stars.isFinite, stars >= 0, stars <= 5 else { return nil }
        return Int((stars * 2).rounded())
    }

    func setText(_ element: Pointer, _ value: String) throws {
        try il2cpp.call(element, "set_text", [il2cpp.managedString(value)])
    }

    /// What one of FM's text elements shows. Nil for any other element, or no text.
    func shownText(_ element: Pointer) -> String? {
        guard il2cpp.isSubclass(il2cpp.classOf(element), of: il2cpp.findClass(Self.toolkit, "TextElement")),
              let text = il2cpp.text(try? il2cpp.call(element, "get_text")), !text.isEmpty else { return nil }
        return text
    }

    private func configure(_ element: Pointer, classes: [String], name: String?) throws {
        if let name { try il2cpp.call(element, "set_name", [il2cpp.managedString(name)]) }
        for name in classes { try addClass(element, name) }
    }

    // MARK: The tree

    func addClass(_ element: Pointer, _ name: String) throws {
        try il2cpp.call(element, "AddToClassList", [il2cpp.managedString(name)])
    }

    func removeClass(_ element: Pointer, _ name: String) throws {
        try il2cpp.call(element, "RemoveFromClassList", [il2cpp.managedString(name)])
    }

    func hasClass(_ element: Pointer, _ name: String) -> Bool {
        il2cpp.unbox(try? il2cpp.call(element, "ClassListContains", [il2cpp.managedString(name)]), as: Bool.self) ?? false
    }

    func name(of element: Pointer) -> String { il2cpp.text(try? il2cpp.call(element, "get_name")) ?? "" }

    func classes(of element: Pointer) -> [String] { il2cpp.strings(inList: try? il2cpp.call(element, "GetClasses")) }

    func parent(of element: Pointer) -> Pointer? { try? il2cpp.call(element, "get_parent") }

    func children(of element: Pointer) -> [Pointer] {
        let count = il2cpp.unbox(try? il2cpp.call(element, "get_childCount"), as: Int32.self) ?? 0
        return (0..<count).compactMap { index in
            var position = index
            return try? withUnsafeMutablePointer(to: &position) { try il2cpp.call(element, "ElementAt", [Pointer($0)]) }
        }
    }

    func add(_ child: Pointer, to parent: Pointer) throws { try il2cpp.call(parent, "Add", [child]) }

    func insert(_ child: Pointer, into parent: Pointer, at index: Int) throws {
        var position = Int32(index)
        _ = try withUnsafeMutablePointer(to: &position) { try il2cpp.call(parent, "Insert", [Pointer($0), child]) }
    }

    func remove(_ element: Pointer) throws { try il2cpp.call(element, "RemoveFromHierarchy") }

    /// The first element below `root` with this name.
    func query(_ root: Pointer, _ name: String) -> Pointer? {
        let q = il2cpp.method(il2cpp.findClass(Self.toolkit, "UQueryExtensions"), "Q", parameters: 3,
                              parameterTypes: ["UnityEngine.UIElements.VisualElement", "System.String", "System.String"])
        return try? il2cpp.call(q, nil, [root, il2cpp.managedString(name), nil])
    }

    /// The first element below `root` with this style class.
    func query(_ root: Pointer, styleClass: String) -> Pointer? {
        let q = il2cpp.method(il2cpp.findClass(Self.toolkit, "UQueryExtensions"), "Q", parameters: 3,
                              parameterTypes: ["UnityEngine.UIElements.VisualElement", "System.String", "System.String"])
        return try? il2cpp.call(q, nil, [root, nil, il2cpp.managedString(styleClass)])
    }

    /// The root of FM's main document, where its navigation bar and screens are. It's kept for as long as it's still in
    /// FM's interface, since finding it asks Unity for every UIDocument, and the timers and clicks want it often.
    func mainRoot() throws -> Pointer? {
        if let kept = Self.root.flatMap(il2cpp.target), isAttached(kept) { return kept }
        if let handle = Self.root { il2cpp.unpin(handle) }
        Self.root = nil
        for document in try findObjects(try toolkitClass("UIDocument")) where il2cpp.text(try il2cpp.call(document, "get_name")) == "MainUIDocument" {
            let root = try il2cpp.call(document, "get_rootVisualElement")
            Self.root = root.flatMap(il2cpp.pin)
            return root
        }
        return nil
    }

    private static var root: IL2CPP.Handle?

    /// Whether an element is in a panel Unity draws. One FM has taken out of its interface, as when it builds its bar
    /// again, isn't.
    func isAttached(_ element: Pointer) -> Bool { (try? il2cpp.call(element, "get_panel")) != nil }

    func findObjects(_ klass: Pointer) throws -> [Pointer] {
        let find = il2cpp.method(il2cpp.findClass("UnityEngine", "Object"), "FindObjectsByType", parameters: 2, firstParameter: "System.Type")
        var sortMode: Int32 = 0
        let array = try withUnsafeMutablePointer(to: &sortMode) { try il2cpp.call(find, nil, [il2cpp.systemType(klass), Pointer($0)]) }
        return il2cpp.elements(array).compactMap { $0 }
    }

    // MARK: Styles

    /// Inline styles, through IStyle.
    func style(_ element: Pointer, _ body: (StyleSetter) throws -> Void) throws {
        guard let style = try il2cpp.call(element, "get_style") else { throw IL2CPP.Failure("No style") }
        try body(StyleSetter(style: style, il2cpp: il2cpp, styleClass: il2cpp.findClass(Self.toolkit, "IStyle")))
    }

    /// An enum property's inline value, such as display, as the value and its keyword, so it can be put back later.
    func inlineEnum(_ element: Pointer, _ property: String) throws -> (Int32, Int32) {
        guard let style = try il2cpp.call(element, "get_style"),
              let getter = il2cpp.method(il2cpp.findClass(Self.toolkit, "IStyle"), "get_\(property)", parameters: 0),
              il2cpp.valueSize(il2cpp.returnType(getter)) == 8,
              let value = il2cpp.unbox(try il2cpp.call(getter, style), as: (Int32, Int32).self) else {
            throw IL2CPP.Failure("Couldn't read the inline \(property)")
        }
        return value
    }

    /// A colour as FM resolved it, after its style sheets: red, green, blue, alpha.
    func resolvedColor(_ element: Pointer, _ property: String) -> (Float, Float, Float, Float)? {
        guard let resolved = try? il2cpp.call(element, "get_resolvedStyle"),
              let getter = il2cpp.method(il2cpp.findClass(Self.toolkit, "IResolvedStyle"), "get_\(property)", parameters: 0) else { return nil }
        return il2cpp.unbox(try? il2cpp.call(getter, resolved), as: (Float, Float, Float, Float).self)
    }

    func resolvedNumber(_ element: Pointer, _ property: String) -> Float? {
        guard let resolved = try? il2cpp.call(element, "get_resolvedStyle"),
              let getter = il2cpp.method(il2cpp.findClass(Self.toolkit, "IResolvedStyle"), "get_\(property)", parameters: 0) else { return nil }
        return il2cpp.unbox(try? il2cpp.call(getter, resolved), as: Float.self)
    }

    /// A layout value in whole points, for the logs. FM's layout is NaN until FM has worked it out, which Int can't
    /// hold: converting it stops the process, and FM with it.
    nonisolated static func whole(_ value: Float) -> String { value.isFinite ? String(Int(value)) : "?" }

    /// Whether a point on FM's panel, in the panel's own units from its top left, is inside the element.
    func contains(_ element: Pointer, x: Float, y: Float) -> Bool {
        guard let rect = il2cpp.unbox(try? il2cpp.call(element, "get_worldBound"), as: (Float, Float, Float, Float).self) else { return false }
        return x >= rect.0 && x < rect.0 + rect.2 && y >= rect.1 && y < rect.1 + rect.3
    }

    /// Where the element is on FM's panel, in the panel's units from its top left, and its size. Nil until it's laid out.
    func worldBound(_ element: Pointer) -> (x: Float, y: Float, width: Float, height: Float)? {
        guard let rect = il2cpp.unbox(try? il2cpp.call(element, "get_worldBound"), as: (Float, Float, Float, Float).self),
              rect.0.isFinite, rect.1.isFinite, rect.2.isFinite, rect.3.isFinite else { return nil }
        return (rect.0, rect.1, rect.2, rect.3)
    }

    /// Where the element sits in its parent, and its size.
    func layout(_ element: Pointer) -> (x: Float, y: Float, width: Float, height: Float)? {
        guard let rect = il2cpp.unbox(try? il2cpp.call(element, "get_layout"), as: (Float, Float, Float, Float).self) else { return nil }
        return (rect.0, rect.1, rect.2, rect.3)
    }

    // MARK: Clicks

    /// Calls `action` when the element is clicked, through UI Toolkit's own Clickable, as FM's buttons are.
    func onClick(_ element: Pointer, _ action: @escaping @MainActor () -> Void) throws {
        guard let actionClass = il2cpp.findClass("System", "Action") else { throw IL2CPP.Failure("No System.Action") }
        let handler = try il2cpp.delegate(actionClass, target: element, callback: elementClicked)
        let clickable = try il2cpp.new(try toolkitClass("Clickable"), [handler], firstParameter: "System.Action")
        let addManipulator = il2cpp.method(il2cpp.findClass(Self.toolkit, "VisualElementExtensions"), "AddManipulator", parameters: 2)
        try il2cpp.call(addManipulator, nil, [element, clickable])
        ClickActions.actions[element] = action
    }

    /// Calls `action` when one of FM's buttons is clicked, in place of what the button did.
    func onButtonClick(_ button: Pointer, _ action: @escaping @MainActor () -> Void) throws {
        guard let actionClass = il2cpp.findClass("System", "Action") else { throw IL2CPP.Failure("No System.Action") }
        let handler = try il2cpp.delegate(actionClass, target: button, callback: elementClicked)
        let clickable = try il2cpp.new(try toolkitClass("Clickable"), [handler], firstParameter: "System.Action")
        try il2cpp.call(button, "set_clickable", [clickable])
        ClickActions.actions[button] = action
    }
}

/// What each clickable element of ours does. FM calls one function for all of them, with the element as its target.
@MainActor
enum ClickActions {
    static var actions: [IL2CPP.Pointer: () -> Void] = [:]
}

private let elementClicked: @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void = { target, _ in
    guard let target else { return }
    MainActor.assumeIsolated {
        guard let action = ClickActions.actions[target] else { return }
        IL2CPP.shared?.withoutCollection { action() }
    }
}

/// Sets one inline style property at a time. Each value is the struct UI Toolkit expects, built by hand, so its size
/// is checked against FM's first.
@MainActor
struct StyleSetter {
    let style: IL2CPP.Pointer
    let il2cpp: IL2CPP
    let styleClass: IL2CPP.Pointer?

    /// StyleLength: Length (value, unit 0 = pixels), then the keyword (0 = none).
    func length(_ property: String, _ pixels: Float) throws {
        var value: (Float, Int32, Int32) = (pixels, 0, 0)
        try set(property, &value, size: 12)
    }

    /// StyleLength in percent (unit 1).
    func percent(_ property: String, _ percent: Float) throws {
        var value: (Float, Int32, Int32) = (percent, 1, 0)
        try set(property, &value, size: 12)
    }

    /// StyleEnum<T>: the value, then the keyword.
    func keyword(_ property: String, _ enumValue: Int32) throws {
        var value: (Int32, Int32) = (enumValue, 0)
        try set(property, &value, size: 8)
    }

    /// Takes our inline value for an enum property away again (keyword 1 = null), back to FM's own style sheets.
    func clearKeyword(_ property: String) throws {
        var value: (Int32, Int32) = (0, 1)
        try set(property, &value, size: 8)
    }

    /// Puts back an enum property's inline value and keyword, as read by `FMElements.inlineEnum`.
    func setEnum(_ property: String, _ saved: (Int32, Int32)) throws {
        var value = saved
        try set(property, &value, size: 8)
    }

    /// StyleFloat: the value, then the keyword.
    func number(_ property: String, _ number: Float) throws {
        var value: (Float, Int32) = (number, 0)
        try set(property, &value, size: 8)
    }

    /// StyleColor: Color, then the keyword.
    func color(_ property: String, _ color: (Float, Float, Float, Float)) throws {
        var value: (Float, Float, Float, Float, Int32) = (color.0, color.1, color.2, color.3, 0)
        try set(property, &value, size: 20)
    }

    /// Takes our inline colour away again (keyword 1 = null), back to FM's style sheets.
    func clearColor(_ property: String) throws {
        var value: (Float, Float, Float, Float, Int32) = (0, 0, 0, 0, 1)
        try set(property, &value, size: 20)
    }

    private func set<T>(_ property: String, _ value: inout T, size: Int) throws {
        guard let setter = il2cpp.method(styleClass, "set_\(property)", parameters: 1) else {
            throw IL2CPP.Failure("IStyle.\(property) not found")
        }
        let actual = il2cpp.valueSize(il2cpp.methodParameter(setter, 0))
        guard actual == size else { throw IL2CPP.Failure("IStyle.\(property) takes \(actual) bytes, not \(size)") }
        _ = try withUnsafeMutablePointer(to: &value) { try il2cpp.call(setter, style, [IL2CPP.Pointer($0)]) }
    }
}
