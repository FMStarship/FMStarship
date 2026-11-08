import FMStarshipUI
import SwiftUI

@main
struct FMStarshipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// Not observed here: scenes would be rebuilt on every change. Views observe it themselves.
    private let model: AppModel
    private let updater = Updater()

    init() {
        // A reopened profile window would have no save loaded to show.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        model = AppModel.startUp()
        AppDelegate.model = model
    }

    var body: some Scene {
        StarshipScenes(model: model, updater: updater)
    }
}
