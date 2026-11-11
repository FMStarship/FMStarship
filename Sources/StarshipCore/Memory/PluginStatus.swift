import Foundation

/// Why the plugin was kept out of FM, for the app to tell the player. Whatever kept it out writes it, the plugin on a build
/// nobody has checked and the launcher after a crash loop, as `status.json` in the plugin's folder. The plugin removes it
/// once it runs again.
public struct PluginStatus: Codable, Equatable, Sendable {
    public static let uncheckedBuild = "unchecked-build"
    public static let unreadableBuild = "unreadable-build"
    public static let crashLoop = "crash-loop"

    /// "off", the only state written.
    public var plugin: String
    /// `uncheckedBuild`, `unreadableBuild` or `crashLoop`.
    public var reason: String
    /// One sentence for the player.
    public var detail: String
    /// When, in ISO 8601.
    public var at: String
    /// FM's version.
    public var fm: String
    /// GameAssembly's UUID, which with `fm` is the build the plugin went by. The launcher's C may leave it out or empty.
    public var gameAssembly: String

    public init(plugin: String = "off", reason: String, detail: String, at: String, fm: String, gameAssembly: String = "") {
        self.plugin = plugin
        self.reason = reason
        self.detail = detail
        self.at = at
        self.fm = fm
        self.gameAssembly = gameAssembly
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        plugin = try values.decode(String.self, forKey: .plugin)
        reason = try values.decode(String.self, forKey: .reason)
        detail = try values.decode(String.self, forKey: .detail)
        at = try values.decode(String.self, forKey: .at)
        fm = try values.decode(String.self, forKey: .fm)
        gameAssembly = try values.decodeIfPresent(String.self, forKey: .gameAssembly) ?? ""
    }

    /// The build the file names, if it names a whole one.
    public var build: FMBuild? {
        fm.isEmpty || gameAssembly.isEmpty ? nil : FMBuild(version: fm, gameAssembly: gameAssembly)
    }

    /// The home folder the plugin's folder is under. The launcher looks for the plugin under HOME, and
    /// Scripts/install-plugin.sh puts it there, so the plugin and the app go by HOME too. Foundation's home folder ignores it.
    public static var home: URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty { return URL(fileURLWithPath: home, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/Library/Application Support/FMStarship/Plugin/status.json`, under the home folder given.
    public static func file(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/FMStarship/Plugin/status.json")
    }

    /// What the plugin writes when it stays out of a build nobody has checked, or one it couldn't read.
    public static func keptOut(_ build: FMBuild?, at date: Date = Date()) -> PluginStatus {
        let at = ISO8601DateFormatter().string(from: date)
        guard let build else {
            return PluginStatus(reason: unreadableBuild, detail: unreadableDetail, at: at, fm: "")
        }
        return PluginStatus(reason: uncheckedBuild,
                            detail: "FM has updated to \(build.version), and FM Starship's tab inside FM comes back with the next FM Starship update.",
                            at: at, fm: build.version, gameAssembly: build.gameAssembly)
    }

    /// What the player is told when the plugin couldn't read FM's build.
    public static let unreadableDetail = "FM Starship couldn't tell which version of FM this is, so it stayed out of FM, which started as usual without it."

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
