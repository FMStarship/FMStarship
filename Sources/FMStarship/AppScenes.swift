import StarshipCore
import StarshipFiles
import StarshipSearch
import SwiftUI

/// The app's windows. The app itself adds only its entry point, the updater and the menu that adds the plugin to FM,
/// so that the plugin can show the same screens inside Football Manager.
package struct StarshipScenes<Updates: UpdateChecking>: Scene {
    /// Not observed here: scenes would be rebuilt on every change. Views observe it themselves.
    private let model: AppModel
    private let updater: Updates

    package init(model: AppModel, updater: Updates) {
        self.model = model
        self.updater = updater
    }

    package var body: some Scene {
        Window("FM Starship", id: WindowID.main) {
            MainWindow()
                .themed(model)
                // Narrower than this and the toolbar starts hiding things.
                .frame(minWidth: 1120, minHeight: 620)
        }
        .defaultSize(width: 1380, height: 860)
        .commands { AppCommands(model: model, state: model.menuState, updater: updater) }

        WindowGroup("Profile", id: WindowID.profile, for: PersonRef.self) { $ref in
            ProfileWindow(ref: ref).themed(model)
        }
        .defaultSize(width: 1120, height: 860)
        .commandsRemoved()

        WindowGroup("Compare", id: WindowID.compare, for: [PersonRef].self) { $refs in
            CompareWindow(refs: refs ?? []).themed(model)
        }
        .defaultSize(width: 820, height: 760)
        .commandsRemoved()

        Window("Compatibility", id: WindowID.compatibility) {
            CompatibilityWindow().themed(model)
        }
        .defaultSize(width: 520, height: 620)
        .commandsRemoved()

        Window("About FM Starship", id: WindowID.about) {
            AboutWindow().themed(model)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        SwiftUI.Settings {
            SettingsView(updater: updater).themed(model)
        }
    }
}

extension View {
    func themed(_ model: AppModel) -> some View {
        modifier(Themed(model: model))
    }
}

/// Every window's root: the model, and the chosen palette.
private struct Themed: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .environmentObject(model)
            .environment(\.appColors, model.colors)
            .tint(model.colors.accent.map { Color(nsColor: $0) })
            .background(model.colors.ui.ground)
            .toolbarBackground(model.colors.ui.ground, for: .windowToolbar)
    }
}

struct AppCommands<Updates: UpdateChecking>: Commands {
    let model: AppModel
    @ObservedObject var state: MenuState
    let updater: Updates
    @Environment(\.openWindow) private var openWindow

    private var hasData: Bool { state.values.hasData }
    private var isList: Bool { state.values.isList }

    var body: some Commands {
        SidebarCommands()

        CommandGroup(replacing: .appInfo) {
            Button("About FM Starship") { openWindow(id: WindowID.about) }
            CheckForUpdatesButton(updater: updater)
        }

        CommandGroup(replacing: .newItem) {
            Button("Load Save") { model.loadSave() }
                .keyboardShortcut("r")
                .disabled(state.values.loading)
            Button("Open Snapshot...") { model.openSnapshot() }
                .keyboardShortcut("o")
            Button("Open FM Shortlist...") { model.chooseShortlistFile() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!hasData)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save Snapshot...") { model.saveSnapshot() }
                .keyboardShortcut("s")
                .disabled(!hasData)
            Button("Save as FM Shortlist...") { model.saveListAsShortlist() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!hasData || !isList)
            Button("Export...") { model.exportList() }
                .keyboardShortcut("e")
                .disabled(!hasData || !isList)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find...") { model.focusSearch += 1 }
                .keyboardShortcut("f")
                .disabled(!hasData || !isList)
        }

        CommandGroup(before: .sidebar) {
            Button("Players") { model.go(to: .players) }.keyboardShortcut("1")
            Button("Staff") { model.go(to: .staff) }.keyboardShortcut("2")
            Divider()
            Button("Filters...") { model.editingFilter = true }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(!hasData || !isList)
            Button("Columns...") { model.editingColumns = true }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!isList)
            Button("Reset Columns to Default") { model.resetColumns(staff: model.listIsStaff) }
                .disabled(!isList)
            Button("Compare") { model.compare(model.selection) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!state.values.canCompare)
            Divider()
        }

        CommandGroup(replacing: .help) {
            Button("Compatibility") { openWindow(id: WindowID.compatibility) }
            Button("About FM Starship") { openWindow(id: WindowID.about) }
        }
    }
}

/// Left out of builds with no feed, which have nothing to check.
struct CheckForUpdatesButton<Updates: UpdateChecking>: View {
    @ObservedObject var updater: Updates

    var body: some View {
        if updater.isAvailable {
            Button("Check for Updates...") { updater.check() }
                .disabled(!updater.canCheck)
        }
    }
}

package final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor package static weak var model: AppModel?

    override package init() { super.init() }

    package func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    package func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A file double-clicked in Finder or dropped on the Dock icon.
    @MainActor package func application(_ application: NSApplication, open urls: [URL]) {
        guard let model = Self.model, let url = urls.first else { return }
        switch url.pathExtension.lowercased() {
        case Storage.fileExtension: model.openSnapshot(at: url)
        case ShortlistFile.fileExtension where model.database != nil: model.openShortlistFile(url)
        default: break
        }
    }
}
