import AppKit
import FMStarshipUI
import StarshipCore
import SwiftUI

/// Adds FM Starship to FM and takes it out again, from the app's menu, and keeps the app's copies as new as the app.
/// Only the app does this: the plugin never changes its own files from inside FM.
@MainActor
final class PluginInstaller: ObservableObject {
    @Published private(set) var installed = InstalledPlugin.nothing
    private let folder = PluginFolder(home: PluginFolder.home)
    private let bundled = BundledPlugin(app: Bundle.main.bundleURL)
    private let copier = PluginCopier()
    private var marker: PluginMarker {
        PluginMarker(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                     build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
    }

    init() {
        look()
        // Someone may have run Scripts/install-plugin.sh, or removed the folder, while the app was in the background.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.look()
                self?.tellIfKeptOut()
            }
        }
    }

    private func look() { installed = folder.installed() }

    /// Once for each build of FM it's about: FM Starship isn't in FM, and why.
    private func tellIfKeptOut() {
        let status = PluginStatus.read(from: PluginStatus.file(home: PluginFolder.home))
        let fm = GameLauncher.gameApp.flatMap(FMBuild.installed)
        guard let notice = PluginNotice.notice(installed: installed, status: status, installedFM: fm),
              PluginNotice.shouldShow(notice, defaults: .standard) else { return }
        PluginNotice.markShown(notice, defaults: .standard)
        AppLog.write("Plugin: told the player \"\(notice.title)\" (\(notice.key))")
        inform(notice.title, notice.message)
    }

    /// At start, and so after an update: refreshes the app's own copies if an older build put them there. Safe while FM
    /// runs, which keeps the copy it has and gets this one at its next start from Steam.
    func keepCurrent() {
        let installed = folder.installed()
        let marker = marker
        guard PluginFolder.stepAtStart(installed, appBuild: marker.build, carried: bundled.isThere) == .copy else { return }
        let (folder, bundled, copier) = (folder, bundled, copier)
        let was = if case .fromApp(let build) = installed { build ?? "unknown" } else { "unknown" }
        Task.detached(priority: .utility) {
            do {
                try await copier.add(to: folder, from: bundled, marker: marker)
                AppLog.write("Plugin: refreshed the copies in \(folder.url.path) from build \(was) to build \(marker.build), \(marker.version)")
            } catch {
                AppLog.write("Plugin: couldn't refresh the copies in \(folder.url.path): \(error)")
            }
        }
    }

    func add() {
        switch PluginFolder.stepToAdd(folder.installed()) {
        case .ask:
            let alert = NSAlert()
            alert.messageText = "Replace your own build of the plugin?"
            alert.informativeText = """
                FM Starship is in FM already, built by Scripts/install-plugin.sh. The copy in this app replaces it, and \
                the app then keeps it up to date. Developer tools you built in go with it. FM's table files stay.
                """
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            present(alert) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.copyIn() }
            }
        case .copy, .leave:
            copyIn()
        }
    }

    /// The copy and its check off the main thread, as at start, and what follows back on it.
    private func copyIn() {
        let (folder, bundled, marker) = (folder, bundled, marker)
        Task {
            defer { look() }
            do {
                try await copier.add(to: folder, from: bundled, marker: marker)
                AppLog.write("Plugin: added build \(marker.build), \(marker.version), to \(folder.url.path)")
            } catch {
                AppLog.write("Plugin: couldn't add it to \(folder.url.path): \(error)")
                inform("FM Starship couldn't be added to FM", Self.say(error))
                return
            }
            showLaunchOption()
        }
    }

    /// Steam doesn't let other apps set a game's launch options, so the player pastes this in once.
    private func showLaunchOption() {
        let host = NSHostingController(rootView: LaunchOptionSheet(option: folder.launchOption) {})
        host.sizingOptions = .preferredContentSize
        let sheet = NSWindow(contentViewController: host)
        sheet.styleMask.remove(.resizable)
        host.rootView = LaunchOptionSheet(option: folder.launchOption) { [weak sheet] in
            guard let sheet else { return }
            if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.close() }
        }
        // Sized before it's shown: a sheet begun at zero size dims its window and can't be seen or closed.
        host.view.layoutSubtreeIfNeeded()
        sheet.setContentSize(host.view.fittingSize)
        // After the alert that may have led here has gone, so the sheet lands on the app's window, not on the closing alert.
        DispatchQueue.main.async { [weak self] in
            if let window = self?.appWindow {
                window.beginSheet(sheet)
            } else {
                sheet.center()
                sheet.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// The app's own window. While an alert sheet is up, it's the key window, so take the window it's attached to.
    private var appWindow: NSWindow? {
        (NSApp.mainWindow ?? NSApp.keyWindow).map { $0.sheetParent ?? $0 }
    }

    /// The launcher stays, so FM still starts from Steam with the launch option left in, and the player can clear it
    /// after. Clearing it is still best: Steam then starts FM itself, and doesn't need FM Starship's folder to.
    func remove() {
        let alert = NSAlert()
        alert.messageText = "Remove FM Starship from FM?"
        alert.informativeText = """
            The next time FM starts, it starts without FM Starship. Clear FM's launch option as well: in Steam, open \
            Football Manager 27 > Properties > General > Launch Options, and delete what's there. Until you do, Steam \
            starts FM through FM Starship's launcher, which stays in place so that FM still starts.

            A game that's open now keeps FM Starship until you quit it.
            """
        let removeButton = alert.addButton(withTitle: "Remove")
        removeButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            defer { self.look() }
            do {
                try self.folder.remove()
                AppLog.write("Plugin: removed the plugin from \(self.folder.url.path), and left the launcher")
            } catch {
                AppLog.write("Plugin: couldn't remove \(self.folder.url.path): \(error)")
                self.inform("FM Starship couldn't be removed from FM", Self.say(error))
            }
        }
    }

    private static func say(_ error: Error) -> String {
        (error as? PluginInstallError)?.description ?? error.localizedDescription
    }

    private func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        present(alert) { _ in }
    }

    /// As a sheet on whichever window is in front, as the app's other alerts are.
    private func present(_ alert: NSAlert, then: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = appWindow {
            alert.beginSheetModal(for: window, completionHandler: then)
        } else {
            then(alert.runModal())
        }
    }
}

/// Adds the app's copies off the main thread and one at a time, so the refresh at start and the menu's Add are never
/// in the folder at once.
private actor PluginCopier {
    func add(to folder: PluginFolder, from bundled: BundledPlugin, marker: PluginMarker) throws {
        try folder.add(from: bundled, marker: marker, check: PluginFolder.signedLike(app: Bundle.main.bundleURL))
    }
}

/// In the app menu, after Check for Updates, where a Mac app keeps what it installs for other apps.
struct PluginCommands: Commands {
    @ObservedObject var installer: PluginInstaller

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Divider()
            Button("Add FM Starship to FM...") { installer.add() }
            Button("Remove FM Starship from FM...") { installer.remove() }
                .disabled(installer.installed == .nothing)
        }
    }
}

/// The launch option and where it goes in Steam, after the plugin and launcher are in place.
struct LaunchOptionSheet: View {
    let option: String
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste this into FM's launch options in Steam")
                .font(.headline)
            Text("FM Starship is ready to go into FM. Steam starts FM with it once this is in FM's launch options, and Steam doesn't let other apps set those, so you paste it in yourself, once.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 12) {
                GroupBox {
                    Text(option)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(option, forType: .string)
                    copied = true
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Click Copy.")
                Text("2. In Steam, open Football Manager 27 > Properties > General > Launch Options, and paste it in.")
                Text("3. Start FM from Steam and load your career. The FM STARSHIP tab appears after FM's own tabs.")
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("It takes effect the next time FM starts from Steam, so a game that's open now carries on as it is. If the launch option is there already, it hasn't changed. Starting FM with the app's Start Football Manager button doesn't load it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
    }
}
