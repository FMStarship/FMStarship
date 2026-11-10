import AppKit
@preconcurrency import StarshipAnalysis
@preconcurrency import StarshipCore
import StarshipSearch
import SwiftUI

/// What the settings and the menus need from the updater, which belongs to the app: Sparkle can't load inside FM.
@MainActor
package protocol UpdateChecking: ObservableObject {
    var isAvailable: Bool { get }
    var canCheck: Bool { get }
    var checksAutomatically: Bool { get set }
    func check()
}

/// Inside FM there's nothing to update this way.
package final class NoUpdates: UpdateChecking {
    package init() {}
    package var isAvailable: Bool { false }
    package var canCheck: Bool { false }
    package var checksAutomatically = false
    package func check() {}
}

/// FM Starship's windows, for the plugin, which shows them inside Football Manager without SwiftUI's scenes.
package enum StarshipWindow: Hashable {
    case main, profile(PersonRef?), compare([PersonRef]), compatibility, about, settings
}

/// What a key press in one of FM Starship's windows inside FM comes to.
package enum Shortcut {
    case handled, open(StarshipWindow), notOurs
}

extension AppModel {
    /// Shown in About inside FM, where the main bundle is the game's.
    package static var editionInsideGame: String?

    /// Whether this is the plugin, inside FM, where the screens' hints point at FM Starship's tab, not the app's toolbar.
    static var isInsideGame: Bool { editionInsideGame != nil }

    /// The model, with the settings it starts from. The same for the app and the plugin.
    package static func startUp() -> AppModel {
        // Before the model, which reads its starting state from the settings.
        StarshipSearch.Settings.load()
        Units.apply()
        return AppModel()
    }

    /// Inside FM there's no button to press first: the game is right there.
    package func loadSaveIfEmpty() {
        if database == nil, !loading { loadSave() }
    }

    /// Reads the save again, as Load Save does, for FM Starship's screens inside FM once FM may have loaded another.
    package func loadSaveAgain() { loadSave() }

    /// Whether the save is being read now.
    package var readingSave: Bool { loading }

    /// The loaded save's analysis, for FM Starship's screens inside FM's own interface.
    package var analysis: AnalysisSession? { session }

    /// Goes up each time the analysis changes, so a screen knows when to redraw.
    package var analysisRevision: Int { analysisVersion }

    /// What the model is doing or what went wrong, while there's no analysis to show.
    package var statusLine: String { status }

    /// Hidden attributes, as the eye in the toolbar shows and sets it, for the switch in FM Starship's tab inside FM.
    /// Setting it to what it already is changes nothing, where setting `showHidden` would search again.
    package var hiddenAttributes: Bool {
        get { showHidden }
        set { if newValue != showHidden { showHidden = newValue } }
    }

    /// Goes to the Players or Staff screen, which runs its search with that screen's filters, for FM Starship's
    /// screen inside FM to show what it finds.
    package func showListInsideGame(staff: Bool) {
        go(to: staff ? .staff : .players)
    }

    /// What the Players or Staff screen's search found, and what it's filtered by, while the app is on that screen.
    /// `version` goes up each time the rows change.
    package func listInsideGame(staff: Bool) -> (people: [Person], searching: Bool, filter: String, version: Int)? {
        guard screen == (staff ? .staff : .players) else { return nil }
        return (staff ? self.staff : players, searching, filterSummary, rowsVersion)
    }

    /// The app's window on the Players or Staff screen, with its filters open, over FM.
    package func editFiltersInsideGame(staff: Bool) {
        go(to: staff ? .staff : .players)
        openInsideGame?(.main)
        editingFilter = true
    }
    package func title(of window: StarshipWindow) -> String {
        switch window {
        case .main: return "FM Starship"
        case .profile: return "Profile"
        case .compare: return "Compare"
        case .compatibility: return "Compatibility"
        case .about: return "About FM Starship"
        case .settings: return "Settings"
        }
    }

    /// The app's default sizes.
    package func size(of window: StarshipWindow) -> CGSize {
        switch window {
        case .main: return CGSize(width: 1380, height: 860)
        case .profile: return CGSize(width: 1120, height: 860)
        case .compare: return CGSize(width: 820, height: 760)
        case .compatibility: return CGSize(width: 520, height: 620)
        case .about, .settings: return CGSize(width: 500, height: 420)
        }
    }

    package func view(of window: StarshipWindow) -> AnyView {
        switch window {
        case .main:
            // Narrower than this and the toolbar starts hiding things.
            return AnyView(MainWindow().themed(self).frame(minWidth: 1120, minHeight: 620))
        case .profile(let ref): return AnyView(ProfileWindow(ref: ref).themed(self))
        case .compare(let refs): return AnyView(CompareWindow(refs: refs).themed(self))
        case .compatibility: return AnyView(CompatibilityWindow().themed(self))
        case .about: return AnyView(AboutWindow().themed(self))
        case .settings: return AnyView(SettingsView(updater: NoUpdates()).themed(self))
        }
    }

    /// The app's menu shortcuts, for a window of ours inside FM. FM's menu bar carries none of them, and one there
    /// would also take the key from the game, where ⌘S saves the career.
    package func shortcut(_ event: NSEvent) -> Shortcut {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else { return .notOurs }
        let state = menuState.values
        switch (key, modifiers) {
        case (",", [.command]): return .open(.settings)
        case ("r", [.command]) where !state.loading: loadSave()
        case ("o", [.command]): openSnapshot()
        case ("o", [.command, .shift]) where state.hasData: chooseShortlistFile()
        case ("s", [.command]) where state.hasData: saveSnapshot()
        case ("s", [.command, .shift]) where state.hasData && state.isList: saveListAsShortlist()
        case ("e", [.command]) where state.hasData && state.isList: exportList()
        case ("f", [.command]) where state.hasData && state.isList: focusSearch += 1
        case ("1", [.command]): go(to: .players)
        case ("2", [.command]): go(to: .staff)
        case ("f", [.command, .option]) where state.hasData && state.isList: editingFilter = true
        case ("c", [.command, .option]) where state.isList: editingColumns = true
        case ("k", [.command, .shift]) where state.canCompare: compare(selection)
        default: return .notOurs
        }
        return .handled
    }
}
