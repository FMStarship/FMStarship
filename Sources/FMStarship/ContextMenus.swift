import AppKit

/// An entry in a right-click menu.
struct MenuEntry {
    enum Kind {
        case action(() -> Void)
        /// Built when it opens, because it reads the shortlist files.
        case submenu(() -> [MenuEntry])
        case separator
    }

    var title: String
    var kind: Kind
    var enabled: Bool

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void = {}) {
        self.title = title
        self.kind = .action(action)
        self.enabled = enabled
    }

    init(_ title: String, enabled: Bool = true, submenu: @escaping () -> [MenuEntry]) {
        self.title = title
        self.kind = .submenu(submenu)
        self.enabled = enabled
    }

    static let separator = MenuEntry(kind: .separator)

    private init(kind: Kind) {
        self.title = ""
        self.kind = kind
        self.enabled = true
    }
}

/// Turns `MenuEntry` values into an `NSMenu`. Keeps the closures alive for as long as the menu is up.
final class MenuBuilder: NSObject, NSMenuDelegate {
    private final class Box {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }

    private var lazyMenus: [ObjectIdentifier: () -> [MenuEntry]] = [:]

    func fill(_ menu: NSMenu, with entries: [MenuEntry]) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry.kind {
            case .separator:
                menu.addItem(.separator())
            case .action(let action):
                let item = NSMenuItem(title: entry.title, action: #selector(chosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = Box(action)
                item.isEnabled = entry.enabled
                menu.addItem(item)
            case .submenu(let build):
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: entry.title)
                submenu.delegate = self
                lazyMenus[ObjectIdentifier(submenu)] = build
                item.submenu = submenu
                item.isEnabled = entry.enabled
                menu.addItem(item)
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let build = lazyMenus[ObjectIdentifier(menu)] { fill(menu, with: build()) }
    }

    @objc private func chosen(_ item: NSMenuItem) {
        (item.representedObject as? Box)?.action()
    }

    /// Pops up where the mouse is, for the buttons that open the same menu as a right-click.
    func popUp(_ entries: [MenuEntry]) {
        let menu = NSMenu()
        fill(menu, with: entries)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
