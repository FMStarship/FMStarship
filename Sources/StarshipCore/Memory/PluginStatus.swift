import Foundation

/// Why the plugin was kept out of FM, for the app to tell the player. Whatever kept it out writes it, the plugin on a build
/// nobody has checked and the launcher after a crash loop, as `status.json` in the plugin's folder. The plugin removes it
/// once it runs again.
public struct PluginStatus: Codable, Equatable, Sendable {
    public static let uncheckedBuild = "unchecked-build"
    public static let crashLoop = "crash-loop"

    /// "off", the only state written.
    public var plugin: String
    /// `uncheckedBuild` or `crashLoop`.
    public var reason: String
    /// One sentence for the player.
    public var detail: String
    /// When, in ISO 8601.
    public var at: String
    /// FM's version.
    public var fm: String

    public init(plugin: String = "off", reason: String, detail: String, at: String, fm: String) {
        self.plugin = plugin
        self.reason = reason
        self.detail = detail
        self.at = at
        self.fm = fm
    }

    /// `~/Library/Application Support/FMStarship/Plugin/status.json`, under the home folder given.
    public static func file(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/FMStarship/Plugin/status.json")
    }

    /// What the plugin writes when it stays out of a build nobody has checked.
    public static func unchecked(fm version: String?, at date: Date = Date()) -> PluginStatus {
        PluginStatus(reason: uncheckedBuild,
                     detail: "FM has updated\(version.map { " to \($0)" } ?? ""), and FM Starship's tab inside FM comes back with the next FM Starship update.",
                     at: ISO8601DateFormatter().string(from: date), fm: version ?? "")
    }

    /// Nil if there's no file, or it can't be read.
    public static func read(from file: URL) -> PluginStatus? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(PluginStatus.self, from: $0) }
    }

    /// Written to a copy that then replaces the file, so a reader never sees half of it.
    public func write(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    /// Gone once the plugin runs again. Nothing there is fine.
    public static func remove(at file: URL) {
        try? FileManager.default.removeItem(at: file)
    }
}
