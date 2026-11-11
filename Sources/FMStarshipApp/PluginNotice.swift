import Foundation
import StarshipCore

/// What the app tells the player when FM Starship is kept out of FM, so a missing tab doesn't look like a fault. Said once
/// for each build of FM, or each crash loop.
struct PluginNotice: Equatable {
    /// What it was said about, remembered so it isn't said again.
    let key: String
    let title: String
    let message: String

    static let shownKey = "PluginNoticeShown"

    /// From the status file the plugin or its launcher left, or else from the installed FM itself, so the player hears
    /// before FM is even started. `appBuild` is this app's CFBundleVersion. Nil when there's nothing to say, or no plugin
    /// to say it about.
    static func notice(installed: InstalledPlugin, status: PluginStatus?, installedFM: FMBuild?, appBuild: String?,
                       checked: [FMBuild] = CheckedBuilds.list) -> PluginNotice? {
        guard installed != .nothing else { return nil }
        if let status, status.plugin == "off" {
            switch status.reason {
            case PluginStatus.uncheckedBuild:
                // Left from before this app listed that build, or before FM changed again to one it lists. The plugin
                // removes it at its next start.
                if let written = status.build {
                    if CheckedBuilds.contains(written, in: checked) { return nil }
                    if let installedFM, installedFM != written, CheckedBuilds.contains(installedFM, in: checked) { return nil }
                }
                return updated(fm: installedFM?.version ?? (status.fm.isEmpty ? nil : status.fm))
            case PluginStatus.unreadableBuild:
                // Said whatever the app reads of FM, since the plugin couldn't. Once per FM build, not per start: the gate
                // writes the file again at every start it stays out of, which the launcher's crash-loop breaker relies on.
                let fm = installedFM.map { "\($0.version) \($0.gameAssembly)" } ?? "unknown"
                return PluginNotice(key: "\(status.reason) \(fm)", title: "FM Starship stayed out of FM",
                                    message: PluginStatus.unreadableDetail)
            default:
                return PluginNotice(key: "\(status.reason) \(status.at)", title: "FM Starship stayed out of FM", message: status.detail)
            }
        }
        // The app's own copy goes by the same list as the app, but only this app's: a newer app's copy, which an older app
        // leaves in place, may know builds this one doesn't. A developer's own build may run anyway, so it's only told by
        // what that build writes.
        guard let appBuild, !appBuild.isEmpty, installed == .fromApp(build: appBuild), let installedFM,
              !CheckedBuilds.contains(installedFM, in: checked) else { return nil }
        return updated(fm: installedFM.version)
    }

    private static func updated(fm version: String?) -> PluginNotice {
        PluginNotice(key: "\(PluginStatus.uncheckedBuild) \(version ?? "")", title: "FM has updated",
                     message: """
                        Football Manager has updated\(version.map { " to \($0)" } ?? ""), and FM Starship hasn't been checked \
                        on it yet. Its tab inside FM comes back with the next FM Starship update. Until then FM starts as \
                        usual, without it.
                        """)
    }

    /// Whether it's new, by what was shown last.
    static func shouldShow(_ notice: PluginNotice, defaults: UserDefaults) -> Bool {
        defaults.string(forKey: shownKey) != notice.key
    }

    static func markShown(_ notice: PluginNotice, defaults: UserDefaults) {
        defaults.set(notice.key, forKey: shownKey)
    }
}
