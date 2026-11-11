@testable import FMStarship
import Darwin
import XCTest

/// The app adds the plugin and its launcher to FM's plugin folder from its own bundle. These run on a stand-in app and a
/// temporary home, never the real Application Support.
final class PluginInstallTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home") }
    private var app: URL { root.appendingPathComponent("FM Starship.app") }
    private var folder: PluginFolder { PluginFolder(home: home) }
    private var bundled: BundledPlugin { BundledPlugin(app: app) }
    private let marker = PluginMarker(version: "27.0.7", build: "8")
    private let flag = "0083;00000000;Safari;"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginInstallTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    /// The app's plugin and launcher, flagged as downloaded, as they are in an app dragged out of the disk image.
    private func makeApp(plugin: String = "new plugin", launcher: String = "new launcher") throws {
        try write(plugin, to: bundled.plugin)
        try write(launcher, to: bundled.launcher.appendingPathComponent("Contents/MacOS/FM Starship Launcher"))
        try write("<plist/>", to: bundled.launcher.appendingPathComponent("Contents/Info.plist"))
        for item in try everything(in: app) { try quarantine(item) }
    }

    /// What install-plugin.sh leaves, or an older app: a plugin, a launcher and FM's table files.
    private func makeOldInstall(marker: PluginMarker? = nil) throws {
        try write("old plugin", to: folder.plugin)
        try write("old launcher", to: folder.launcher.appendingPathComponent("Contents/MacOS/FM Starship Launcher"))
        try write("{\"players\":1}", to: folder.url.appendingPathComponent("fm-table-assets.json"))
        try write("{\"staff\":2}", to: folder.url.appendingPathComponent("fm-staff-table-assets.json"))
        if let marker { try JSONEncoder().encode(marker).write(to: folder.marker) }
        for item in try everything(in: folder.url) { try quarantine(item) }
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

    private func quarantine(_ url: URL) throws {
        XCTAssertEqual(setxattr(url.path, "com.apple.quarantine", flag, flag.utf8.count, 0, XATTR_NOFOLLOW), 0)
    }

    private func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// The item and everything inside it.
    private func everything(in url: URL) throws -> [URL] {
        let inside = try FileManager.default.subpathsOfDirectory(atPath: url.path).map { url.appendingPathComponent($0) }
        return [url] + inside
    }

    // MARK: The launch option

    func testTheLaunchOptionQuotesTheLauncherBeforeFMsCommand() {
        XCTAssertEqual(PluginFolder(home: URL(fileURLWithPath: "/Users/you")).launchOption,
                       "\"/Users/you/Library/Application Support/FMStarship/Plugin/FM Starship Launcher.app\" %command%")
    }

    func testTheLaunchOptionEscapesWhatAShellReadsInsideDoubleQuotes() {
        XCTAssertEqual(PluginFolder.launchOption(launcher: #"/Volumes/A "B"/$HOME/`x`/back\slash/Launcher.app"#),
                       #""/Volumes/A \"B\"/\$HOME/\`x\`/back\\slash/Launcher.app" %command%"#)
    }

    func testAShellReadsTheQuotedPathBackAsItWas() throws {
        for path in ["/Users/you/Library/Application Support/FMStarship/Plugin/FM Starship Launcher.app",
                     #"/Volumes/My "Games" $5 `odd` back\slash's/FM Starship Launcher.app"#] {
            let option = PluginFolder.launchOption(launcher: path)
            XCTAssertTrue(option.hasSuffix(" %command%"))
            let quoted = String(option.dropLast(" %command%".count))
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", "printf '%s' \(quoted)"]
            let out = Pipe()
            shell.standardOutput = out
            try shell.run()
            shell.waitUntilExit()
            XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), path)
        }
    }

    // MARK: What the app decides

    func testAtStartOnlyTheAppsOwnOlderCopiesAreRefreshed() {
        func step(_ installed: InstalledPlugin, _ build: String? = "8", carried: Bool = true) -> PluginStep {
            PluginFolder.stepAtStart(installed, appBuild: build, carried: carried)
        }
        XCTAssertEqual(step(.fromApp(build: "7")), .copy)
        XCTAssertEqual(step(.fromApp(build: "9"), "10"), .copy, "builds compare as numbers")
        XCTAssertEqual(step(.fromApp(build: nil)), .copy, "an unreadable marker is still the app's")
        XCTAssertEqual(step(.fromApp(build: "8")), .leave)
        XCTAssertEqual(step(.fromApp(build: "9")), .leave, "an older app leaves a newer one's copies")
        XCTAssertEqual(step(.fromScript), .leave, "a developer's own build is never replaced by itself")
        XCTAssertEqual(step(.nothing), .leave, "nothing is added without being asked")
        XCTAssertEqual(step(.fromApp(build: "7"), carried: false), .leave, "a build without the plugin has nothing to copy")
        XCTAssertEqual(step(.fromApp(build: "7"), nil), .leave)
    }

    func testAddingAsksBeforeReplacingADevelopersBuild() {
        XCTAssertEqual(PluginFolder.stepToAdd(.nothing), .copy)
        XCTAssertEqual(PluginFolder.stepToAdd(.fromApp(build: "8")), .copy)
        XCTAssertEqual(PluginFolder.stepToAdd(.fromScript), .ask)
    }

    func testWhatsInstalledComesFromTheFilesAndTheMarker() throws {
        XCTAssertEqual(folder.installed(), .nothing)
        try write("{}", to: folder.marker)
        XCTAssertEqual(folder.installed(), .nothing, "a marker on its own isn't an install")
        try FileManager.default.removeItem(at: folder.marker)
        try makeOldInstall()
        XCTAssertEqual(folder.installed(), .fromScript)
        try JSONEncoder().encode(PluginMarker(version: "27.0.6", build: "7")).write(to: folder.marker)
        XCTAssertEqual(folder.installed(), .fromApp(build: "7"))
        try write("not json", to: folder.marker)
        XCTAssertEqual(folder.installed(), .fromApp(build: nil))
    }

    // MARK: The copy

    func testAddingCopiesBothWithoutTheQuarantineAndWritesTheMarker() throws {
        try makeApp()
        try folder.add(from: bundled, marker: marker)
        XCTAssertEqual(try read(folder.plugin), "new plugin")
        XCTAssertEqual(try read(folder.launcher.appendingPathComponent("Contents/MacOS/FM Starship Launcher")), "new launcher")
        XCTAssertEqual(try read(folder.launcher.appendingPathComponent("Contents/Info.plist")), "<plist/>")
        for item in try everything(in: folder.url) { XCTAssertFalse(isQuarantined(item), item.path) }
        for item in try everything(in: app) { XCTAssertTrue(isQuarantined(item), "the app's own stay as they are: \(item.path)") }
        XCTAssertEqual(try JSONDecoder().decode(PluginMarker.self, from: Data(contentsOf: folder.marker)), marker)
        XCTAssertEqual(folder.installed(), .fromApp(build: "8"))
        XCTAssertEqual(PluginFolder.stepAtStart(folder.installed(), appBuild: "8", carried: true), .leave)
    }

    func testAddingReplacesTheOldCopiesAndKeepsFMsTableFiles() throws {
        try makeApp()
        try makeOldInstall(marker: PluginMarker(version: "27.0.6", build: "7"))
        try folder.add(from: bundled, marker: marker)
        XCTAssertEqual(try read(folder.plugin), "new plugin")
        XCTAssertEqual(try read(folder.launcher.appendingPathComponent("Contents/MacOS/FM Starship Launcher")), "new launcher")
        XCTAssertEqual(try read(folder.url.appendingPathComponent("fm-table-assets.json")), "{\"players\":1}")
        XCTAssertEqual(try read(folder.url.appendingPathComponent("fm-staff-table-assets.json")), "{\"staff\":2}")
        XCTAssertTrue(isQuarantined(folder.url.appendingPathComponent("fm-table-assets.json")), "only the copies are touched")
        XCTAssertFalse(isQuarantined(folder.plugin), "the old copy's flag doesn't come back with the new one")
        XCTAssertFalse(isQuarantined(folder.launcher))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).filter { $0.hasPrefix(".") }, [], "no staging left")
        XCTAssertEqual(folder.installed(), .fromApp(build: "8"))
    }

    func testAGameRunningWithTheOldPluginKeepsIt() throws {
        try makeApp()
        try makeOldInstall()
        let loaded = try FileHandle(forReadingFrom: folder.plugin)
        defer { try? loaded.close() }
        try folder.add(from: bundled, marker: marker)
        XCTAssertEqual(String(decoding: try loaded.readToEnd() ?? Data(), as: UTF8.self), "old plugin",
                       "replaced beside it, never written over in place")
        XCTAssertEqual(try read(folder.plugin), "new plugin")
    }

    func testAnAppWithoutThePluginAddsNothing() throws {
        try write("new plugin", to: bundled.plugin)
        XCTAssertThrowsError(try folder.add(from: bundled, marker: marker)) { error in
            guard case PluginInstallError.notInApp = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.url.path))
    }

    func testACopyThatFailsItsCheckLeavesTheOldOnesInPlace() throws {
        try makeApp()
        try makeOldInstall()
        var seen: [String] = []
        XCTAssertThrowsError(try folder.add(from: bundled, marker: marker) { _, name in
            seen.append(name)
            throw PluginInstallError.otherSigner(name)
        })
        XCTAssertEqual(seen, ["libStarshipPlugin.dylib"])
        XCTAssertEqual(try read(folder.plugin), "old plugin")
        XCTAssertEqual(folder.installed(), .fromScript, "no marker without the copies")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).filter { $0.hasPrefix(".") }, [], "no staging left")
    }

    func testAFirstAddThatStopsHalfwayIsTheAppsToFinish() throws {
        try makeApp()
        XCTAssertThrowsError(try folder.add(from: bundled, marker: marker) { _, name in
            if name == PluginFolder.launcherName { throw PluginInstallError.otherSigner(name) }
        })
        XCTAssertEqual(try read(folder.plugin), "new plugin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.launcher.path))
        XCTAssertEqual(folder.installed(), .fromApp(build: "0"), "not a developer's own build")
        XCTAssertEqual(PluginFolder.stepAtStart(folder.installed(), appBuild: "8", carried: true), .copy, "the next start finishes it")
        XCTAssertEqual(PluginFolder.stepToAdd(folder.installed()), .copy, "the next Add doesn't ask")
        try folder.add(from: bundled, marker: marker)
        XCTAssertEqual(try read(folder.launcher.appendingPathComponent("Contents/MacOS/FM Starship Launcher")), "new launcher")
        XCTAssertEqual(folder.installed(), .fromApp(build: "8"))
    }

    /// Two copies of the app refreshing at the same start, each with a check slow enough for the other to get in.
    func testAddsAtTheSameTimeDontShareTheirCopies() throws {
        try makeApp()
        try makeOldInstall(marker: PluginMarker(version: "27.0.6", build: "7"))
        let (folder, bundled, marker) = (folder, bundled, marker)
        let lock = NSLock()
        var failures: [String] = []
        for _ in 0..<20 {
            DispatchQueue.concurrentPerform(iterations: 2) { _ in
                do {
                    try folder.add(from: bundled, marker: marker) { _, _ in usleep(2_000) }
                } catch {
                    lock.withLock { failures.append("\(error)") }
                }
            }
        }
        XCTAssertEqual(failures, [])
        XCTAssertEqual(try read(folder.plugin), "new plugin")
        XCTAssertEqual(try read(folder.launcher.appendingPathComponent("Contents/MacOS/FM Starship Launcher")), "new launcher")
        XCTAssertEqual(folder.installed(), .fromApp(build: "8"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).filter { $0.hasPrefix(".") }, [], "no staging left")
    }

    func testAnAddSweepsUpOldStagingButNotAnotherAddsInProgress() throws {
        try makeApp()
        let left = folder.url.appendingPathComponent(PluginFolder.stagingPrefix + "left")
        let going = folder.url.appendingPathComponent(PluginFolder.stagingPrefix + "going")
        for staging in [left, going] { try write("half a copy", to: staging.appendingPathComponent(PluginFolder.pluginName)) }
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: left.path)
        try folder.add(from: bundled, marker: marker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.path), "left by an add that stopped partway")
        XCTAssertTrue(FileManager.default.fileExists(atPath: going.path), "another copy of the app may still be adding from it")
        XCTAssertEqual(try read(folder.plugin), "new plugin")
    }

    func testTheCheckRefusesWhatIsntSigned() throws {
        try write("not code", to: root.appendingPathComponent("unsigned"))
        let check = PluginFolder.signedLike(app: URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertThrowsError(try check(root.appendingPathComponent("unsigned"), "unsigned")) { error in
            guard case PluginInstallError.notSigned = error else { return XCTFail("\(error)") }
        }
        let copy = root.appendingPathComponent("true")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: copy)
        XCTAssertNoThrow(try check(copy, "true"), "a copy signed as the app is passes")
    }

    func testRemovingTakesTheWholeFolder() throws {
        try makeApp()
        try makeOldInstall()
        try folder.add(from: bundled, marker: marker)
        try folder.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.url.path))
        XCTAssertEqual(folder.installed(), .nothing)
        XCTAssertNoThrow(try folder.remove(), "nothing there is fine")
    }
}
