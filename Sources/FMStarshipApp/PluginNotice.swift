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
    /// before FM is even started. Nil when there's nothing to say, or no plugin to say it about.
    static func notice(installed: InstalledPlugin, status: PluginStatus?, installedFM: FMBuild?,
                       checked: [FMBuild] = CheckedBuilds.list) -> PluginNotice? {
        guard installed != .nothing else { return nil }
        if let status, status.plugin == "off" {
            guard status.reason == PluginStatus.uncheckedBuild else {
                return PluginNotice(key: "\(status.reason) \(status.at)", title: "FM Starship stayed out of FM", message: status.detail)
            }
            // Left from before FM updated again, to a build this app knows.
            if let installedFM, CheckedBuilds.contains(installedFM, in: checked) { return nil }
            return updated(fm: status.fm.isEmpty ? installedFM?.version : status.fm)
        }
        // The app's own copy goes by the same list as the app. A developer's own build may run anyway, so it's only told
        // by what that build writes.
        guard case .fromApp = installed, let installedFM, !CheckedBuilds.contains(installedFM, in: checked) else { return nil }
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
