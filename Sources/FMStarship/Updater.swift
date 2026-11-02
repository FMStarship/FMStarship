import Sparkle
import StarshipCore
import SwiftUI

/// Finds and installs new versions through Sparkle. Only releases have a feed, so a build of your own never checks.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = false

    var isAvailable: Bool { controller != nil }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    override init() {
        super.init()
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    func check() { controller?.checkForUpdates(nil) }

    /// Installing restarts FM Starship, which loses what was loaded, so nothing happens in the middle of a game.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard GameProcess.runningPID() != nil else { return }
        throw NSError(domain: "FMStarship.Updater", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Close Football Manager first, then check for updates.",
        ])
    }
}

/// Left out of builds with no feed, which have nothing to check.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if updater.isAvailable {
            Button("Check for Updates...") { updater.check() }
                .disabled(!updater.canCheck)
        }
    }
}
