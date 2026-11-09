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

    /// The stand-in writes down its arguments and the environment that matters, and exits with FAKE_EXIT.
    private static let fakeFM = """
        #include <stdio.h>
        #include <stdlib.h>
        int main(int argc, char **argv) {
            FILE *out = fopen(getenv("FAKE_OUT"), "w");
            if (!out) return 99;
            for (int i = 0; i < argc; i++) fprintf(out, "arg=%s\\n", argv[i]);
            const char *names[] = {"DYLD_INSERT_LIBRARIES", "SteamAppId", "SteamGameId", "FAKE_PLUGIN", "FAKE_OVERLAY"};
            for (int i = 0; i < 5; i++) if (getenv(names[i])) fprintf(out, "%s=%s\\n", names[i], getenv(names[i]));
            fclose(out);
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
        var info: [String: Any] = ["CFBundleIdentifier": "test.fm"]
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
    private func launch(_ arguments: [String], _ environment: [String: String]) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = try tools.appendingPathComponent("launcher")
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
        XCTAssertEqual(run.stderr, "")
        let fm = try XCTUnwrap(seenByFM())
        XCTAssertEqual(fm.arguments, [bundle.path + "/Contents/MacOS/Football Manager 27", "-windowed", "two words"])
        XCTAssertEqual(fm.environment["DYLD_INSERT_LIBRARIES"], "\(plugin.path):\(try overlay.path)")
        XCTAssertEqual(fm.environment["FAKE_PLUGIN"], "1")
        XCTAssertEqual(fm.environment["FAKE_OVERLAY"], "1")
        XCTAssertEqual(fm.environment["SteamAppId"], "4530370")
        XCTAssertEqual(fm.environment["SteamGameId"], "4530370")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
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
        XCTAssertEqual(try launch([bundle.path + "/"], ["HOME": home.path]).status, 0)
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
}
