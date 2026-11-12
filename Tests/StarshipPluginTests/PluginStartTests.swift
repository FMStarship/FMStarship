@testable import StarshipCore
import XCTest

/// The plugin's start, `Sources/StarshipPluginStart/start.c`, may only start FM Starship inside FM itself, whatever a patch calls
/// fm.app or its executable. These build it with clang, with a stand-in for the Swift side, and insert it into a harmless program
/// copied into stand-in bundles, as the launcher inserts the plugin into FM.
final class PluginStartTests: XCTestCase {
    private var folder: URL!

    /// Says whether the start ran and left DYLD_INSERT_LIBRARIES set, then asks start.c about each path it's given.
    private static let host = """
        #include <dlfcn.h>
        #include <stdbool.h>
        #include <stdio.h>
        #include <stdlib.h>
        int main(int argc, char **argv) {
            const char *app = getenv("STARSHIP_STARTED");
            printf("started=%s\\n", app ? "yes" : "no");
            if (app) printf("app=%s\\n", app);
            printf("inserted=%s\\n", getenv("DYLD_INSERT_LIBRARIES") ? "yes" : "no");
            bool (*is_game)(const char *) = (bool (*)(const char *))dlsym(RTLD_DEFAULT, "starship_plugin_is_game");
            for (int i = 1; i < argc; i++) printf("game=%d\\n", is_game ? is_game(argv[i]) : -1);
            return 0;
        }
        """
    /// Stands in for the Swift side, which start.c calls only inside FM, and says which bundle it was given.
    private static let swiftSide = """
        #include <stdlib.h>
        void starship_plugin_start(const char *game_app) { setenv("STARSHIP_STARTED", game_app ? game_app : "NULL", 1); }
        """

    private static let built = Result { try build() }
    private var tools: URL { get throws { try Self.built.get() } }

    private static func build() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("PluginStartTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try host.write(to: out.appendingPathComponent("host.c"), atomically: true, encoding: .utf8)
        try swiftSide.write(to: out.appendingPathComponent("swift.c"), atomically: true, encoding: .utf8)
        let start = root.appendingPathComponent("Sources/StarshipPluginStart")
        try clang(["-O2", "-Wall", "-arch", "arm64", "-mmacosx-version-min=14.0", "-dynamiclib", "-I", start.appendingPathComponent("include").path,
                   "-o", out.appendingPathComponent("start.dylib").path, start.appendingPathComponent("start.c").path,
                   out.appendingPathComponent("swift.c").path, "-framework", "CoreFoundation"])
        try clang(["-o", out.appendingPathComponent("host").path, out.appendingPathComponent("host.c").path])
        return out
    }

    private static func clang(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["clang"] + arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw XCTSkip("clang couldn't build the plugin start's test: \(arguments.joined(separator: " "))") }
    }

    override class func tearDown() {
        if case .success(let tools) = built { try? FileManager.default.removeItem(at: tools) }
        super.tearDown()
    }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    /// A stand-in bundle whose Info.plist has `identifier` and names `name`, or no executable, with the host copied in as each of
    /// `executables`. Returns its Contents/MacOS folder.
    private func app(_ bundle: String, _ identifier: String, names name: String?, executables: [String]) throws -> URL {
        let macOS = folder.appendingPathComponent("\(bundle)/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        var info = ["CFBundleIdentifier": identifier]
        info["CFBundleExecutable"] = name
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: macOS.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        for executable in executables {
            try FileManager.default.copyItem(at: tools.appendingPathComponent("host"), to: macOS.appendingPathComponent(executable))
        }
        return macOS
    }

    /// Runs `executable` with the start inserted, and what it said.
    private func launch(_ executable: URL, asking paths: [String] = []) throws -> (started: Bool, inserted: Bool, games: [Bool], app: String?) {
        let process = Process()
        process.executableURL = executable
        process.arguments = paths
        process.environment = ["DYLD_INSERT_LIBRARIES": try tools.appendingPathComponent("start.dylib").path]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, text)
        let lines = text.split(separator: "\n").map(String.init)
        return (lines.contains("started=yes"), lines.contains("inserted=yes"),
                lines.filter { $0.hasPrefix("game=") }.map { $0 == "game=1" },
                lines.first { $0.hasPrefix("app=") }.map { String($0.dropFirst(4)) })
    }

    func testItStartsInFMWhateverAPatchCallsItsBundleOrExecutable() throws {
        let today = try app("fm.app", GameProcess.gameIdentifier, names: "Football Manager 27", executables: ["Football Manager 27"])
        let renamed = try app("Football Manager 28.app", GameProcess.gameIdentifier, names: "FM", executables: ["FM"])
        for fm in [today.appendingPathComponent("Football Manager 27"), renamed.appendingPathComponent("FM")] {
            let run = try launch(fm)
            XCTAssertTrue(run.started, fm.path)
            XCTAssertFalse(run.inserted, "anything FM starts mustn't get the plugin")
            // The bundle the Swift side reads FM's build from, worked out here so it never asks CFBundle before FM's main().
            let bundle = try XCTUnwrap(realpath(fm.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path, nil))
            defer { free(bundle) }
            XCTAssertEqual(run.app, String(cString: bundle))
        }
    }

    func testItStaysOutOfEveryOtherProcess() throws {
        let fm = try app("fm.app", GameProcess.gameIdentifier, names: "Football Manager 27", executables: ["Helper"])
        let steam = try app("Steam.app", "com.valvesoftware.steam", names: "steam_osx", executables: ["steam_osx"])
        let launcher = try app("FM Starship Launcher.app", "com.fmstarship.launcher", names: "FM Starship Launcher",
                               executables: ["FM Starship Launcher"])
        let fm26 = try app("fm26.app", "com.SportsInteractive.FootballManager26", names: "Football Manager 26",
                           executables: ["Football Manager 26"])
        let unnamed = try app("unnamed.app", GameProcess.gameIdentifier, names: nil, executables: ["Football Manager 27"])
        let others = [fm.appendingPathComponent("Helper"), steam.appendingPathComponent("steam_osx"),
                      launcher.appendingPathComponent("FM Starship Launcher"), fm26.appendingPathComponent("Football Manager 26"),
                      unnamed.appendingPathComponent("Football Manager 27"), try tools.appendingPathComponent("host")]
        for other in others {
            let run = try launch(other)
            XCTAssertFalse(run.started, other.path)
            XCTAssertFalse(run.inserted, other.path)
        }
    }

    /// The plugin decides with start.c, and GameProcess with its own copy of the rule, so the two must agree.
    func testTheStartAndGameProcessAgree() throws {
        let fm = try app("fm.app", GameProcess.gameIdentifier, names: "Football Manager 27", executables: ["Football Manager 27", "Helper"])
        let renamed = try app("Football Manager 28.app", GameProcess.gameIdentifier, names: "FM", executables: ["FM"])
        let steam = try app("Steam.app", "com.valvesoftware.steam", names: "steam_osx", executables: ["steam_osx"])
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fm.appendingPathComponent("Football Manager 27"))
        let cases: [(path: String, game: Bool)] = [
            (fm.appendingPathComponent("Football Manager 27").path, true),
            (renamed.appendingPathComponent("FM").path, true),
            (link.path, true),
            (fm.appendingPathComponent("Helper").path, false),
            (fm.appendingPathComponent("Missing").path, false),
            (steam.appendingPathComponent("steam_osx").path, false),
            (fm.deletingLastPathComponent().path, false),
            ("", false),
        ]
        let run = try launch(try tools.appendingPathComponent("host"), asking: cases.map(\.path))
        XCTAssertEqual(run.games, cases.map(\.game))
        XCTAssertEqual(cases.map { GameProcess.isGameExecutable($0.path) }, cases.map(\.game))
    }
}
