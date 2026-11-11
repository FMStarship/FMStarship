import XCTest

/// Steam starts `plugin/launcher.c` in FM's place, so FM has to start whatever state the plugin is in. These build the launcher with
/// clang and run it on a stand-in for FM, with a temporary HOME.
final class LauncherTests: XCTestCase {
    private var folder: URL!
    private var home: URL { folder.appendingPathComponent("home") }
    private var bundle: URL { folder.appendingPathComponent("fm.app") }
    private var plugin: URL { home.appendingPathComponent("Library/Application Support/FMStarship/Plugin/libStarshipPlugin.dylib") }
    private var log: URL { home.appendingPathComponent("Library/Logs/FM Starship/plugin.log") }
    private var seen: URL { folder.appendingPathComponent("seen.txt") }
    private var count: URL { plugin.deletingLastPathComponent().appendingPathComponent("launcher-starts") }
    private var status: URL { plugin.deletingLastPathComponent().appendingPathComponent("status.json") }

    /// The stand-in writes down its arguments and the environment that matters, waits FAKE_SLEEP seconds, and exits with
    /// FAKE_EXIT, or ends on the signal FAKE_SIGNAL.
    private static let fakeFM = """
        #include <signal.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
            FILE *out = fopen(getenv("FAKE_OUT"), "w");
            if (!out) return 99;
            for (int i = 0; i < argc; i++) fprintf(out, "arg=%s\\n", argv[i]);
            const char *names[] = {"DYLD_INSERT_LIBRARIES", "SteamAppId", "SteamGameId", "FAKE_PLUGIN", "FAKE_OVERLAY"};
            for (int i = 0; i < 5; i++) if (getenv(names[i])) fprintf(out, "%s=%s\\n", names[i], getenv(names[i]));
            fclose(out);
            if (getenv("FAKE_SLEEP")) sleep((unsigned)atoi(getenv("FAKE_SLEEP")));
            if (getenv("FAKE_SIGNAL")) kill(getpid(), atoi(getenv("FAKE_SIGNAL")));
            return getenv("FAKE_EXIT") ? atoi(getenv("FAKE_EXIT")) : 0;
        }
        """
    /// A library that sets MARKER when dyld loads it, standing in for the plugin and for Steam's overlay.
    private static let fakeLibrary = """
        #include <stdlib.h>
        __attribute__((constructor)) static void load(void) { setenv(MARKER, "1", 1); }
        """

    private static let built = Result { try build() }
    private var tools: URL { get throws { try Self.built.get() } }
    private var overlay: URL { get throws { try tools.appendingPathComponent("overlay.dylib") } }

    private static func build() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("LauncherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try fakeFM.write(to: out.appendingPathComponent("fakefm.c"), atomically: true, encoding: .utf8)
        try fakeLibrary.write(to: out.appendingPathComponent("library.c"), atomically: true, encoding: .utf8)
        // The same flags as Scripts/install-plugin.sh.
        try clang(["-O2", "-Wall", "-arch", "arm64", "-mmacosx-version-min=14.0", "-o", out.appendingPathComponent("launcher").path,
                   root.appendingPathComponent("plugin/launcher.c").path, "-framework", "CoreFoundation"])
        // The crash-loop breaker's tests can't wait three minutes, so they get a launcher whose window is two seconds.
        try clang(["-O2", "-Wall", "-arch", "arm64", "-mmacosx-version-min=14.0", "-DCRASH_WINDOW_SECONDS=2",
                   "-o", out.appendingPathComponent("launcher-2s").path,
                   root.appendingPathComponent("plugin/launcher.c").path, "-framework", "CoreFoundation"])
        try clang(["-o", out.appendingPathComponent("fakefm").path, out.appendingPathComponent("fakefm.c").path])
        try clang(["-dynamiclib", "-DMARKER=\"FAKE_PLUGIN\"", "-o", out.appendingPathComponent("plugin.dylib").path,
                   out.appendingPathComponent("library.c").path])
        try clang(["-dynamiclib", "-DMARKER=\"FAKE_OVERLAY\"", "-o", out.appendingPathComponent("overlay.dylib").path,
                   out.appendingPathComponent("library.c").path])
        return out
    }

    private static func clang(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["clang"] + arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw XCTSkip("clang couldn't build the launcher's test: \(arguments.joined(separator: " "))") }
    }

    override class func tearDown() {
        if case .success(let tools) = built { try? FileManager.default.removeItem(at: tools) }
        super.tearDown()
    }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    /// A stand-in fm.app whose Info.plist names `name` as its executable, or names none, and whose executable is `executable`.
    private func makeFM(name: String?, executable: String? = nil) throws {
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "test.fm", "CFBundleShortVersionString": "27.2.1"]
        info["CFBundleExecutable"] = name
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        if let executable = executable ?? name {
            try FileManager.default.copyItem(at: tools.appendingPathComponent("fakefm"), to: macOS.appendingPathComponent(executable))
        }
    }

    private func installPlugin() throws {
        try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: tools.appendingPathComponent("plugin.dylib"), to: plugin)
    }

    /// Runs the launcher with `environment` and nothing else, as `steam %command% arguments` would.
    private func launch(_ arguments: [String], _ environment: [String: String], launcher: String = "launcher") throws
        -> (status: Int32, stderr: String) {
        try? FileManager.default.removeItem(at: seen)
        let process = Process()
        process.executableURL = try tools.appendingPathComponent(launcher)
        process.arguments = arguments
        process.environment = environment.merging(["PATH": "/usr/bin:/bin", "FAKE_OUT": seen.path]) { $1 }
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        let text = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }

    /// What the stand-in for FM was started with, or nil if it never ran.
    private func seenByFM() -> (arguments: [String], environment: [String: String])? {
        guard let text = try? String(contentsOf: seen, encoding: .utf8) else { return nil }
        var arguments: [String] = [], environment: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "arg" { arguments.append(parts[1]) } else { environment[parts[0]] = parts[1] }
        }
        return (arguments, environment)
    }

    func testThePluginGoesInFrontOfSteamsOwnLibrary() throws {
        try makeFM(name: "Football Manager 27")
        try installPlugin()
        let run = try launch([bundle.path, "-windowed", "two words"],
                             ["HOME": home.path, "DYLD_INSERT_LIBRARIES": try overlay.path, "FAKE_EXIT": "7"])
        XCTAssertEqual(run.status, 7)
        // An error so soon after the start counts against the plugin, which the crash-loop breaker's tests cover.
        XCTAssertTrue(run.stderr.contains("FM closed with status 7"), run.stderr)
        let fm = try XCTUnwrap(seenByFM())
        XCTAssertEqual(fm.arguments, [bundle.path + "/Contents/MacOS/Football Manager 27", "-windowed", "two words"])
        XCTAssertEqual(fm.environment["DYLD_INSERT_LIBRARIES"], "\(plugin.path):\(try overlay.path)")
        XCTAssertEqual(fm.environment["FAKE_PLUGIN"], "1")
        XCTAssertEqual(fm.environment["FAKE_OVERLAY"], "1")
        XCTAssertEqual(fm.environment["SteamAppId"], "4530370")
        XCTAssertEqual(fm.environment["SteamGameId"], "4530370")
    }

    func testFMStartsWithoutAMissingPluginAndSaysWhy() throws {
        try makeFM(name: "Football Manager 27")
        let run = try launch([bundle.path], ["HOME": home.path, "DYLD_INSERT_LIBRARIES": try overlay.path])
        XCTAssertEqual(run.status, 0)
        let fm = try XCTUnwrap(seenByFM(), "dyld ends FM if an inserted library is missing")
        XCTAssertEqual(fm.environment["DYLD_INSERT_LIBRARIES"], try overlay.path)
        XCTAssertNil(fm.environment["FAKE_PLUGIN"])
        XCTAssertEqual(fm.environment["FAKE_OVERLAY"], "1")
        XCTAssertTrue(run.stderr.contains("Starting FM without FM Starship, because \(plugin.path) can't be read"), run.stderr)
        XCTAssertTrue(run.stderr.contains("Open the FM Starship app and choose FM Starship > Add FM Starship to FM, or clear FM's "
                                          + "launch option in Steam."), run.stderr)
        XCTAssertFalse(run.stderr.contains("install-plugin.sh"), "players add it from the app, not from the source")
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("Launcher: Starting FM without FM Starship"))
    }

    func testFMStartsWithoutThePluginWhenHOMEIsUnset() throws {
        try makeFM(name: "Football Manager 27")
        let run = try launch([bundle.path], [:])
        XCTAssertEqual(run.status, 0)
        let fm = try XCTUnwrap(seenByFM())
        XCTAssertNil(fm.environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertTrue(run.stderr.contains("HOME isn't set"), run.stderr)
    }

    func testTheExecutableIsTheOneFMsInfoPlistNames() throws {
        try makeFM(name: "Football Manager 28")
        try installPlugin()
        let run = try launch([bundle.path + "/"], ["HOME": home.path])
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stderr, "", "a start that goes well says nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        let fm = try XCTUnwrap(seenByFM())
        XCTAssertEqual(fm.arguments, [bundle.path + "/Contents/MacOS/Football Manager 28"])
        XCTAssertEqual(fm.environment["FAKE_PLUGIN"], "1")
    }

    func testWithoutANameInInfoPlistItTriesTodaysName() throws {
        try makeFM(name: nil, executable: "Football Manager 27")
        try installPlugin()
        let run = try launch([bundle.path], ["HOME": home.path])
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(seenByFM()?.arguments, [bundle.path + "/Contents/MacOS/Football Manager 27"])
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("No CFBundleExecutable"))
    }

    func testAFailedStartIsSaidAndAddedToTheLog() throws {
        try makeFM(name: "Football Manager 27", executable: "Something else")
        try installPlugin()
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("An earlier line\n".utf8).write(to: log)
        let run = try launch([bundle.path], ["HOME": home.path])
        XCTAssertEqual(run.status, 1)
        XCTAssertNil(seenByFM())
        XCTAssertTrue(run.stderr.contains("Couldn't start FM at \(bundle.path)/Contents/MacOS/Football Manager 27"), run.stderr)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.first, "An earlier line")
        XCTAssertTrue(lines.last?.contains("Launcher: Couldn't start FM") == true)
    }

    func testWithNoGameItSaysTheLaunchOptionNeedsCommand() throws {
        let run = try launch([], ["HOME": home.path])
        XCTAssertEqual(run.status, 1)
        XCTAssertTrue(run.stderr.contains("needs %command%"), run.stderr)
    }

    // The crash-loop breaker, through the launcher whose window is two seconds.

    /// Starts the stand-in through the breaker's launcher, ending as `ending` says, and says whether the plugin went in.
    @discardableResult
    private func start(_ ending: [String: String] = [:]) throws -> (plugin: Bool, stderr: String) {
        let run = try launch([bundle.path], ending.merging(["HOME": home.path, "DYLD_INSERT_LIBRARIES": try overlay.path]) { $1 },
                             launcher: "launcher-2s")
        let fm = try XCTUnwrap(seenByFM(), "FM always starts")
        XCTAssertEqual(fm.environment["FAKE_OVERLAY"], "1", "Steam's overlay stays in")
        return (fm.environment["FAKE_PLUGIN"] == "1", run.stderr)
    }

    private let crash = ["FAKE_SIGNAL": "15"]
    private let failure = ["FAKE_EXIT": "3"]
    private let pastTheWindow = ["FAKE_SLEEP": "3"]

    private func statusFile() throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: status)) as? [String: String])
    }

    func testTwoQuickCrashesInARowStartFMWithoutThePluginAndSayWhy() throws {
        try makeFM(name: "Football Manager 27")
        try installPlugin()
        XCTAssertTrue(try start(crash).plugin)
        XCTAssertTrue(try start(failure).plugin, "one quick crash isn't enough")
        let third = try start()
        XCTAssertFalse(third.plugin)
        XCTAssertTrue(third.stderr.contains("Starting FM without FM Starship, because FM closed within"), third.stderr)
        XCTAssertTrue(third.stderr.contains("2 times in a row"), third.stderr)
        let log = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(log.contains("FM closed on signal 15"), log)
        XCTAssertTrue(log.contains("FM closed with status 3"), log)

        let written = try statusFile()
        XCTAssertEqual(written["plugin"], "off")
        XCTAssertEqual(written["reason"], "crash-loop")
        XCTAssertEqual(written["fm"], "27.2.1")
        XCTAssertFalse(written["detail", default: ""].isEmpty)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: written["at", default: ""]))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: status.deletingLastPathComponent().path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".") }, "written atomically, with nothing left over: \(leftovers)")

        // A start without the plugin says nothing about it, so it stays out, however that start ends.
        XCTAssertFalse(try start(pastTheWindow).plugin)
        XCTAssertFalse(try start().plugin)
    }

    func testARunPastTheWindowResetsTheCount() throws {
        try makeFM(name: "Football Manager 27")
        try installPlugin()
        try start(crash)
        XCTAssertTrue(try start(pastTheWindow.merging(crash) { $1 }).plugin, "a crash past the window isn't the plugin's start")
        try start(crash)
        XCTAssertTrue(try start().plugin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: status.path))
    }

    func testAQuickQuitOfThePlayersOwnChangesNothing() throws {
        try makeFM(name: "Football Manager 27")
        try installPlugin()
        try start(crash)
        XCTAssertEqual(try String(contentsOf: count, encoding: .utf8).split(separator: " ").last, "1\n")
        try start()
        XCTAssertEqual(try String(contentsOf: count, encoding: .utf8).split(separator: " ").last, "1\n")
        try start(crash)
        XCTAssertFalse(try start().plugin)
    }

    func testANewBuildOfThePluginGoesBackInAndClearsTheStatus() throws {
        try makeFM(name: "Football Manager 27")
        try installPlugin()
        try start(crash)
        try start(crash)
        XCTAssertFalse(try start().plugin)
        XCTAssertTrue(FileManager.default.fileExists(atPath: status.path))
        // As the app's update and Add FM Starship to FM do: a new copy in the plugin's place.
        let copy = folder.appendingPathComponent("new.dylib")
        try FileManager.default.copyItem(at: tools.appendingPathComponent("plugin.dylib"), to: copy)
        _ = try FileManager.default.replaceItemAt(plugin, withItemAt: copy, options: .usingNewMetadataOnly)
        XCTAssertTrue(try start().plugin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: status.path), "the plugin runs again, so the status goes")
        try start(crash)
        XCTAssertTrue(try start().plugin, "the new build's count starts again")
    }

    func testAStatusForAnotherReasonStays() throws {
        try makeFM(name: "Football Manager 27")
        try installPlugin()
        let other = Data(#"{"plugin": "off", "reason": "unchecked-build", "detail": "", "at": "", "fm": ""}"#.utf8)
        try other.write(to: status)
        XCTAssertTrue(try start().plugin)
        XCTAssertEqual(try Data(contentsOf: status), other)
    }

    func testAMissingOrDamagedCountStartsFMWithThePlugin() throws {
        try makeFM(name: "Football Manager 27")
        try installPlugin()
        for damaged in ["", "nonsense", "\(String(repeating: "x", count: 600)) 9", "x 99999999999999999999", "a b c",
                        "\u{0}\u{1}\u{2} 5\n"] {
            try Data(damaged.utf8).write(to: count)
            XCTAssertTrue(try start().plugin, "count: \(damaged)")
        }
        try FileManager.default.removeItem(at: count)
        XCTAssertEqual(mkfifo(count.path, 0o644), 0)
        XCTAssertTrue(try start().plugin, "a count that isn't a plain file doesn't hold FM up")
        try FileManager.default.removeItem(at: count)
        XCTAssertEqual(mkfifo(status.path, 0o644), 0)
        XCTAssertTrue(try start().plugin)
        try FileManager.default.removeItem(at: status)
        // Someone else's count, at its limit, for a build that isn't this one.
        try Data("1:2:3:4.5 2\n".utf8).write(to: count)
        XCTAssertTrue(try start().plugin)
        try FileManager.default.removeItem(at: count)
        XCTAssertTrue(try start(crash).plugin)
        XCTAssertTrue(try String(contentsOf: count, encoding: .utf8).hasSuffix(" 1\n"), "a crash makes a new count")
    }

    func testACountThatCantBeWrittenStillStartsFM() throws {
        try makeFM(name: "Football Manager 27")
        try installPlugin()
        try FileManager.default.createDirectory(at: count, withIntermediateDirectories: false)
        for _ in 0..<3 {
            let run = try start(crash)
            XCTAssertTrue(run.plugin)
            XCTAssertTrue(run.stderr.contains("Couldn't note how FM's start went"), run.stderr)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: count.deletingLastPathComponent().path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".") }, "\(leftovers)")
    }

    func testAPluginFolderThatCantBeWrittenStillKeepsAPluginThatCrashesOut() throws {
        try makeFM(name: "Football Manager 27")
        try installPlugin()
        try start(crash)
        try start(crash)
        let pluginFolder = plugin.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: pluginFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pluginFolder.path) }
        let run = try start()
        XCTAssertFalse(run.plugin)
        XCTAssertTrue(run.stderr.contains("Couldn't write \(pluginFolder.path)/status.json"), run.stderr)
    }
}
