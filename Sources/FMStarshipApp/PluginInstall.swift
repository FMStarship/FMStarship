import Darwin
import Foundation
import Security

/// The plugin and its launcher as the app carries them, where Apple wants a dylib and a helper app, so that the app's
/// signature and notarization cover them. A build without them, such as `swift run`, has nothing to add.
struct BundledPlugin: Sendable {
    let plugin: URL
    let launcher: URL

    init(app: URL) {
        plugin = app.appendingPathComponent("Contents/Frameworks/\(PluginFolder.pluginName)")
        launcher = app.appendingPathComponent("Contents/Helpers/\(PluginFolder.launcherName)", isDirectory: true)
    }

    var isThere: Bool {
        FileManager.default.fileExists(atPath: plugin.path) && FileManager.default.fileExists(atPath: launcher.path)
    }
}

/// Which app put the copies there, written beside them. Scripts/install-plugin.sh leaves none.
struct PluginMarker: Codable, Equatable, Sendable {
    var version: String
    var build: String
}

/// What's in the plugin's folder.
enum InstalledPlugin: Equatable, Sendable {
    /// No plugin. A launcher on its own, as Remove leaves it, only starts FM without FM Starship.
    case nothing
    /// Copies the app put there, from this build. Nil if the marker can't be read.
    case fromApp(build: String?)
    /// Copies with no marker: a developer's own build, from Scripts/install-plugin.sh.
    case fromScript
}

/// What the app does about the plugin's folder.
enum PluginStep: Equatable, Sendable {
    case copy, ask, leave
}

enum PluginInstallError: Error, CustomStringConvertible {
    case notInApp
    case notSigned(String, OSStatus)
    case otherSigner(String)
    case quarantineStays(String, Int32)

    var description: String {
        switch self {
        case .notInApp:
            return "This copy of FM Starship doesn't carry the plugin. Download FM Starship again. A build of your own only has it when it's made with Scripts/build-app.sh."
        case .notSigned(let name, let status):
            return "The app's copy of \(name) failed its signature check (\(status)). Download FM Starship again."
        case .otherSigner(let name):
            return "The app's copy of \(name) isn't signed by whoever signed the app. Download FM Starship again."
        case .quarantineStays(let path, let error):
            return "macOS's download flag couldn't be taken off \(path): \(String(cString: strerror(error)))."
        }
    }
}

/// `~/Library/Application Support/FMStarship/Plugin`, where Steam's launch option finds the launcher and the launcher
/// finds the plugin. The app copies both in from itself, so a player adds FM Starship to FM without Xcode.
struct PluginFolder: Sendable {
    static let pluginName = "libStarshipPlugin.dylib"
    static let launcherName = "FM Starship Launcher.app"
    static let markerName = "installed-by-app.json"
    /// FM's table asset files, which the plugin keeps between starts, as `FMTable.Kind.assetFile` names them.
    static let tableFileNames = ["fm-table-assets.json", "fm-staff-table-assets.json"]
    /// How each add's own staging folder is named. Scripts/install-plugin.sh names its staging otherwise, so the sweep
    /// leaves that alone.
    static let stagingPrefix = ".adding."

    /// The launcher looks for the plugin under HOME, and Scripts/install-plugin.sh puts it there, so the app goes by
    /// HOME too. Foundation's home folder ignores it.
    static var home: URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty { return URL(fileURLWithPath: home, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    let url: URL

    init(home: URL) {
        url = home.appendingPathComponent("Library/Application Support/FMStarship/Plugin", isDirectory: true)
    }

    var plugin: URL { url.appendingPathComponent(Self.pluginName) }
    var launcher: URL { url.appendingPathComponent(Self.launcherName, isDirectory: true) }
    var marker: URL { url.appendingPathComponent(Self.markerName) }

    /// What goes in FM's launch options in Steam, which starts the launcher in FM's place with FM's own command after it.
    var launchOption: String { Self.launchOption(launcher: launcher.path) }

    /// The path in double quotes, because of its spaces, with what's special inside them escaped as a shell does, in
    /// case the home folder's path has a quote, a dollar, a backquote or a backslash in it.
    static func launchOption(launcher path: String) -> String {
        var quoted = ""
        for character in path {
            if "\"\\$`".contains(character) { quoted.append("\\") }
            quoted.append(character)
        }
        return "\"\(quoted)\" %command%"
    }

    func installed() -> InstalledPlugin {
        let files = FileManager.default
        guard files.fileExists(atPath: plugin.path) else { return .nothing }
        guard files.fileExists(atPath: marker.path) else { return .fromScript }
        let read = (try? Data(contentsOf: marker)).flatMap { try? JSONDecoder().decode(PluginMarker.self, from: $0) }
        return .fromApp(build: read?.build)
    }

    /// When the app starts, and so after an update: it keeps its own copies as new as itself, and leaves a developer's
    /// own build alone. Builds only go up, so an older app leaves a newer one's copies too.
    static func stepAtStart(_ installed: InstalledPlugin, appBuild: String?, carried: Bool) -> PluginStep {
        guard carried, let appBuild, case .fromApp(let build) = installed else { return .leave }
        guard let build else { return .copy }
        return build.compare(appBuild, options: .numeric) == .orderedAscending ? .copy : .leave
    }

    /// From the menu, which the player chose: replacing a developer's own build needs a yes first.
    static func stepToAdd(_ installed: InstalledPlugin) -> PluginStep {
        installed == .fromScript ? .ask : .copy
    }

    /// Copies the app's plugin and launcher in, each beside its old copy and then put in its place, so FM, if it's
    /// running, keeps the copy it has loaded and gets the new one at its next start. Everything else in the folder stays,
    /// such as FM's table asset files the plugin keeps between starts. `check` sees each copy before it goes in.
    func add(from bundled: BundledPlugin, marker: PluginMarker, check: (_ copy: URL, _ name: String) throws -> Void = { _, _ in }) throws {
        guard bundled.isThere else { throw PluginInstallError.notInApp }
        let files = FileManager.default
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        sweep()
        // A folder of its own for each add, so two at once, from two copies of the app, never share a copy.
        let staging = url.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        for (source, target) in [(bundled.plugin, plugin), (bundled.launcher, launcher)] {
            let staged = staging.appendingPathComponent(target.lastPathComponent, isDirectory: target.hasDirectoryPath)
            try files.copyItem(at: source, to: staged)
            try check(staged, target.lastPathComponent)
            // Every way of copying keeps the download's quarantine flag, and with it Gatekeeper could stop Steam
            // starting the launcher. A copy has no notarization ticket stapled to it to show instead.
            try Self.removeQuarantine(staged)
            // Marked as the app's, at a build below any real one, before anything of the app's goes in. A copy that
            // stops halfway is then the app's to finish at its next start, not a developer's own build to leave alone.
            try mark(PluginMarker(version: marker.version, build: "0"))
            if files.fileExists(atPath: target.path) {
                // The new copy as the app has it, with none of the old copy's metadata carried over.
                _ = try files.replaceItemAt(target, withItemAt: staged, options: .usingNewMetadataOnly)
            } else {
                try files.moveItem(at: staged, to: target)
            }
        }
        try mark(marker)
    }

    /// Takes away the staging folders of adds that stopped partway, such as when the app was quit. A new one may be
    /// another copy of the app's add that's still going, and an add takes well under a second, so only those an hour
    /// old go.
    private func sweep() {
        let files = FileManager.default
        let stale = Date(timeIntervalSinceNow: -3600)
        for name in (try? files.contentsOfDirectory(atPath: url.path)) ?? [] where name.hasPrefix(Self.stagingPrefix) {
            let item = url.appendingPathComponent(name, isDirectory: true)
            guard let made = try? item.resourceValues(forKeys: [.creationDateKey]).creationDate, made < stale else { continue }
            try? files.removeItem(at: item)
        }
    }

    private func mark(_ marker: PluginMarker) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: self.marker, options: .atomic)
    }

    /// Takes the plugin, the marker and FM's table files away, and leaves the launcher, so Steam still starts FM, without
    /// the plugin, while its launch option names it. `Scripts/install-plugin.sh --uninstall` does the same, and
    /// `--uninstall-all` takes the whole folder. The plugin goes first, so a removal that stops partway never leaves the
    /// app's plugin without its marker, which would read as a developer's own build. The logs stay.
    func remove() throws {
        let files = FileManager.default
        for item in [plugin, marker] + Self.tableFileNames.map({ url.appendingPathComponent($0) }) where files.fileExists(atPath: item.path) {
            try files.removeItem(at: item)
        }
    }

    static func removeQuarantine(_ item: URL) throws {
        var paths = [item.path]
        if let walk = FileManager.default.enumerator(atPath: item.path) {
            while let path = walk.nextObject() as? String { paths.append(item.appendingPathComponent(path).path) }
        }
        for path in paths where removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0 {
            let error = errno
            if error != ENOATTR { throw PluginInstallError.quarantineStays(path, error) }
        }
    }

    /// The check the app gives `add`: the copy is intact and signed by whoever signed the app, the Developer ID in a
    /// release or nobody's ad hoc signature in a build of your own, so the quarantine only comes off code that's ours.
    static func signedLike(app: URL) -> (_ copy: URL, _ name: String) throws -> Void {
        let appTeam = team(of: app)
        return { copy, name in
            var code: SecStaticCode?
            var status = SecStaticCodeCreateWithPath(copy as CFURL, [], &code)
            if status == errSecSuccess, let code {
                // Offline: updates are all the app goes online for, and Gatekeeper makes its own online checks when
                // Steam opens the launcher.
                let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode).union(.noNetworkAccess)
                status = SecStaticCodeCheckValidity(code, flags, nil)
            }
            guard status == errSecSuccess else { throw PluginInstallError.notSigned(name, status) }
            guard team(of: copy) == appTeam else { throw PluginInstallError.otherSigner(name) }
        }
    }

    private static func team(of url: URL) -> String? {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
        else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
