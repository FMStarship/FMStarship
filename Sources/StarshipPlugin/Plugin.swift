import AppKit
import FMStarshipUI
import SwiftUI

/// FM Starship running inside Football Manager instead of beside it: the app's own windows and screens, over the game.
/// Control-Option-S shows and hides it, and in windowed mode there's also an FM Starship menu in FM's menu bar.
@_cdecl("starship_plugin_start")
public func starshipPluginStart() {
    PluginLog.write("Loaded into FM, pid \(getpid())")
    // The constructor runs before FM's main(), so nothing in AppKit is up yet.
    NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { Plugin.shared.install() }
    }
}

@MainActor
final class Plugin: NSObject, NSWindowDelegate {
    static let shared = Plugin()

    private var model: AppModel?
    private var windows: [StarshipWindow: NSWindow] = [:]
    private var appearance: NSAppearance?

    func install() {
        guard model == nil else { return }
        AppModel.editionInsideGame = "preview, inside Football Manager"
        let model = AppModel.startUp()
        model.openInsideGame = { [weak self] window in self?.show(window) }
        model.applyAppearanceInsideGame = { [weak self] appearance in
            self?.appearance = appearance
            self?.windows.values.forEach { $0.appearance = appearance }
        }
        self.model = model
        FMInterface.shared.start(model: model)
        addMenu()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { Plugin.shared.handle(event) } ? nil : event
        }
        PluginLog.write("Menu and shortcut ready")
    }

    private func addMenu() {
        guard let bar = NSApp.mainMenu else { return }
        let menu = NSMenu(title: "FM Starship")
        // Only the toggle has a key here: anything else in FM's menu bar would take that key from the game.
        let show = NSMenuItem(title: "Show FM Starship", action: #selector(toggle), keyEquivalent: "s")
        show.keyEquivalentModifierMask = [.control, .option]
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        for (title, window) in [("Settings...", StarshipWindow.settings), ("Compatibility", .compatibility), ("About FM Starship", .about)] {
            let item = NSMenuItem(title: title, action: #selector(openFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = window
            menu.addItem(item)
        }
        let item = NSMenuItem(title: "FM Starship", action: nil, keyEquivalent: "")
        item.submenu = menu
        bar.addItem(item)
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        if let window = sender.representedObject as? StarshipWindow { show(window) }
    }

    @objc func toggle() {
        if let main = windows[.main], main.isVisible {
            windows.values.forEach { $0.orderOut(nil) }
        } else {
            show(.main)
            model?.loadSaveIfEmpty()
        }
    }

    /// Opens a window, or brings back the one already showing the same thing, as the app's scenes do.
    func show(_ kind: StarshipWindow) {
        guard let model else { return }
        let window = windows[kind] ?? makeWindow(kind, model: model)
        windows[kind] = window
        // Above FM's own window, whatever level its full screen mode uses.
        let ours = Set(windows.values.map(ObjectIdentifier.init))
        let gameLevel = NSApp.windows.filter { !ours.contains(ObjectIdentifier($0)) && $0.isVisible }.map(\.level.rawValue).max() ?? 0
        window.level = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, gameLevel + 1))
        window.makeKeyAndOrderFront(nil)
        PluginLog.write("Showing \(model.title(of: kind))")
    }

    private func makeWindow(_ kind: StarshipWindow, model: AppModel) -> NSWindow {
        let controller = NSHostingController(rootView: model.view(of: kind))
        // The screens' toolbars and titles, which SwiftUI otherwise only gives windows of its own.
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.title = model.title(of: kind)
        window.styleMask = kind == .about || kind == .settings ? [.titled, .closable] : [.titled, .closable, .resizable]
        window.setContentSize(model.size(of: kind))
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = true
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.appearance = appearance
        window.delegate = self
        window.center()
        return window
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let closing = notification.object as? NSWindow,
                  let kind = windows.first(where: { $0.value === closing })?.key, kind != .main else { return }
            // Profiles and comparisons are made again for the next person; the main window keeps its place.
            windows[kind] = nil
        }
    }

    /// Keys for FM Starship: the toggle anywhere, and in our own windows the app's shortcuts and the editing keys,
    /// which FM's menu bar doesn't carry. Everything else stays the game's.
    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == [.control, .option], event.keyCode == 1 {
            toggle()
            return true
        }
        // While FM Starship's screens are being built into FM's interface: write out how FM's interface is put together.
        if modifiers == [.control, .option], event.keyCode == 2 {
            InterfaceDump.shared.write()
            return true
        }
        guard let key = NSApp.keyWindow, windows.values.contains(where: { $0 === key }), let model else { return false }
        if let action = editingAction(event, modifiers) {
            return NSApp.sendAction(action, to: nil, from: nil)
        }
        if modifiers == [.command], event.charactersIgnoringModifiers == "w" {
            key.performClose(nil)
            return true
        }
        switch model.shortcut(event) {
        case .handled: return true
        case .open(let window):
            show(window)
            return true
        case .notOurs: return false
        }
    }

    private func editingAction(_ event: NSEvent, _ modifiers: NSEvent.ModifierFlags) -> Selector? {
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("x", [.command]): return #selector(NSText.cut(_:))
        case ("c", [.command]): return #selector(NSText.copy(_:))
        case ("v", [.command]): return #selector(NSText.paste(_:))
        case ("a", [.command]): return #selector(NSText.selectAll(_:))
        case ("z", [.command]): return Selector(("undo:"))
        case ("z", [.command, .shift]): return Selector(("redo:"))
        default: return nil
        }
    }
}

/// What the plugin did, for finding out why when something doesn't show up inside FM.
enum PluginLog {
    private static let queue = DispatchQueue(label: "FMStarship.PluginLog")
    private static let file: URL = {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/FM Starship", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("plugin.log")
    }()

    static func write(_ line: String) {
        let stamped = "\(Date().formatted(.iso8601)) \(line)\n"
        queue.async {
            guard let data = stamped.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: file)
            }
        }
    }
}
