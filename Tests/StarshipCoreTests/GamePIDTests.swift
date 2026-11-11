@testable import StarshipCore
import XCTest

/// Finding FM's pid, which the app and the plugin ask for every two seconds. Fake processes stand in for the Mac's.
final class GamePIDTests: XCTestCase {
    func testChecksOnlyTheRememberedPidWhileItIsStillTheGame() {
        var walked = false
        let pid = GameProcess.gamePID(remembered: 42, isGame: { $0 == 42 }, all: { walked = true; return [7, 42] })
        XCTAssertEqual(pid, 42)
        XCTAssertFalse(walked)
    }

    func testWalksAgainOnceTheGameHasGone() {
        let pid = GameProcess.gamePID(remembered: 42, isGame: { $0 == 99 }, all: { [7, 42, 99] })
        XCTAssertEqual(pid, 99)
    }

    func testWalksTheFirstTime() {
        XCTAssertEqual(GameProcess.gamePID(remembered: nil, isGame: { $0 == 42 }, all: { [7, 42] }), 42)
    }

    func testNothingWhenTheGameIsntRunning() {
        XCTAssertNil(GameProcess.gamePID(remembered: 42, isGame: { _ in false }, all: { [7, 42] }))
        XCTAssertNil(GameProcess.gamePID(remembered: nil, isGame: { _ in false }, all: { [] }))
    }

    /// FM is known by its bundle identifier and the executable its Info.plist names, so a patch can rename both fm.app and
    /// the executable. Stand-in bundles, with empty files for executables.
    func testFMIsKnownByItsBundleNotItsPath() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        func app(_ bundle: String, _ identifier: String, names name: String?, has files: [String]) throws -> URL {
            let macOS = folder.appendingPathComponent("\(bundle)/Contents/MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            var info = ["CFBundleIdentifier": identifier]
            info["CFBundleExecutable"] = name
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: macOS.deletingLastPathComponent().appendingPathComponent("Info.plist"))
            for file in files { try Data().write(to: macOS.appendingPathComponent(file)) }
            return macOS
        }
        let fm = try app("fm.app", GameProcess.gameIdentifier, names: "Football Manager 27", has: ["Football Manager 27", "Helper"])
        let renamed = try app("Football Manager 28.app", GameProcess.gameIdentifier, names: "FM", has: ["FM"])
        let steam = try app("Steam.app", "com.valvesoftware.steam", names: "steam_osx", has: ["steam_osx"])
        let fm26 = try app("fm26.app", "com.SportsInteractive.FootballManager26", names: "Football Manager 26", has: ["Football Manager 26"])
        let unnamed = try app("unnamed.app", GameProcess.gameIdentifier, names: nil, has: ["Football Manager 27"])

        XCTAssertTrue(GameProcess.isGameExecutable(fm.appendingPathComponent("Football Manager 27").path))
        XCTAssertTrue(GameProcess.isGameExecutable(renamed.appendingPathComponent("FM").path))
        XCTAssertFalse(GameProcess.isGameExecutable(fm.appendingPathComponent("Helper").path), "a helper in FM's bundle")
        XCTAssertFalse(GameProcess.isGameExecutable(steam.appendingPathComponent("steam_osx").path))
        XCTAssertFalse(GameProcess.isGameExecutable(fm26.appendingPathComponent("Football Manager 26").path))
        XCTAssertFalse(GameProcess.isGameExecutable(unnamed.appendingPathComponent("Football Manager 27").path))
        XCTAssertFalse(GameProcess.isGameExecutable(fm.appendingPathComponent("Missing").path))
        XCTAssertFalse(GameProcess.isGameExecutable(""))
        XCTAssertFalse(GameProcess.runsInsideGame, "the tests' own process isn't FM")
    }
}
