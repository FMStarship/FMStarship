@testable import StarshipSearch
import XCTest

/// The app and the plugin inside FM each load settings.json once. A save keeps the file's value for every key this process
/// hasn't changed, so neither writes back the other's older values.
final class SettingsMergeTests: XCTestCase {
    /// One process's view of the settings, swapped in and out of `Settings`' statics.
    private struct Process {
        var current = Settings()
        var baseline: Settings?

        mutating func run(_ body: () -> Void) {
            Settings.current = current
            Settings.baseline = baseline
            body()
            current = Settings.current
            baseline = Settings.baseline
        }
    }

    private var folder: URL!
    private var saved = Settings()
    private var savedBaseline: Settings?

    private var file: URL { folder.appendingPathComponent("settings.json") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsMergeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        saved = Settings.current
        savedBaseline = Settings.baseline
        Settings.pathOverride = file
    }

    override func tearDownWithError() throws {
        Settings.pathOverride = nil
        Settings.current = saved
        Settings.baseline = savedBaseline
        try? FileManager.default.removeItem(at: folder)
    }

    private func onDisk() throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
    }

    private func write(_ settings: Settings) throws {
        try JSONEncoder().encode(settings).write(to: file)
    }

    func testTwoWritersKeepEachOthersKeys() throws {
        var start = Settings()
        start.showHidden = true
        start.heightUnit = "cm"
        try write(start)

        var app = Process(), plugin = Process()
        app.run { Settings.load() }
        plugin.run { Settings.load() }

        app.run {
            Settings.current.showHidden = false
            Settings.save()
        }
        plugin.run {
            Settings.current.heightUnit = "in"
            Settings.current.playerColumns = [ColState()]
            Settings.save()
        }

        var result = try onDisk()
        XCTAssertFalse(result.showHidden, "The plugin mustn't write back the ShowHidden it loaded")
        XCTAssertEqual(result.heightUnit, "in")
        XCTAssertEqual(result.playerColumns, [ColState()])

        // And the other way round: the app's next save keeps the plugin's keys.
        app.run {
            Settings.current.theme = "Night"
            Settings.save()
        }
        result = try onDisk()
        XCTAssertEqual(result.theme, "Night")
        XCTAssertEqual(result.heightUnit, "in", "The app mustn't write back the unit it loaded")
        XCTAssertEqual(result.playerColumns, [ColState()])
        XCTAssertFalse(result.showHidden)
    }

    func testBothChangingTheSameKeyLaterWins() throws {
        try write(Settings())
        var app = Process(), plugin = Process()
        app.run { Settings.load() }
        plugin.run { Settings.load() }

        app.run {
            Settings.current.theme = "Night"
            Settings.save()
        }
        plugin.run {
            Settings.current.theme = "Day"
            Settings.save()
        }
        XCTAssertEqual(try onDisk().theme, "Day")

        app.run {
            Settings.current.theme = "Dusk"
            Settings.save()
        }
        XCTAssertEqual(try onDisk().theme, "Dusk")
    }

    func testSettingTheLoadedValueAgainIsNoChange() throws {
        var start = Settings()
        start.showHidden = true
        try write(start)
        var app = Process(), plugin = Process()
        app.run { Settings.load() }
        plugin.run { Settings.load() }
        app.run {
            Settings.current.showHidden = false
            Settings.save()
        }
        plugin.run {
            Settings.current.showHidden = true
            Settings.current.theme = "Night"
            Settings.save()
        }
        XCTAssertFalse(try onDisk().showHidden, "The plugin still has the value it loaded, so the app's later choice stays")
    }

    func testAKeySetBackToNilIsRemoved() throws {
        var start = Settings()
        start.playerColumns = [ColState()]
        try write(start)
        var app = Process()
        app.run {
            Settings.load()
            Settings.current.playerColumns = nil
            Settings.save()
        }
        XCTAssertNil(try onDisk().playerColumns)
    }

    func testAMissingFileGetsEverything() throws {
        var app = Process()
        app.run {
            Settings.load()
            Settings.current.showHidden = true
            Settings.save()
        }
        var expected = Settings()
        expected.showHidden = true
        XCTAssertEqual(try onDisk(), expected)
    }

    func testAFileRemovedSinceLoadingGetsEverything() throws {
        var start = Settings()
        start.theme = "Night"
        try write(start)
        var app = Process()
        app.run { Settings.load() }
        try FileManager.default.removeItem(at: file)
        app.run {
            Settings.current.showHidden = true
            Settings.save()
        }
        let result = try onDisk()
        XCTAssertTrue(result.showHidden)
        XCTAssertEqual(result.theme, "Night", "With nothing to merge into, all of this process's settings are written")
    }

    func testADamagedFileIsWrittenOverAndLogged() throws {
        var start = Settings()
        start.theme = "Night"
        try write(start)
        var app = Process()
        app.run { Settings.load() }
        try Data("{ not json".utf8).write(to: file)
        app.run {
            Settings.current.showHidden = true
            Settings.save()
        }
        let result = try onDisk()
        XCTAssertTrue(result.showHidden)
        XCTAssertEqual(result.theme, "Night")
        let log = try String(contentsOf: folder.appendingPathComponent("errors.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("settings file damaged"))
    }

    func testAFileOfTheWrongShapeIsWrittenOver() throws {
        try Data(#"{"ShowHidden": "yes"}"#.utf8).write(to: file)
        var app = Process()
        app.run {
            Settings.load()
            Settings.current.theme = "Night"
            Settings.save()
        }
        let result = try onDisk()
        XCTAssertEqual(result.theme, "Night")
        XCTAssertFalse(result.showHidden)
    }

    func testNothingChangedWritesNothing() throws {
        var start = Settings()
        start.theme = "Night"
        try write(start)
        var app = Process(), plugin = Process()
        app.run { Settings.load() }
        plugin.run { Settings.load() }
        app.run {
            Settings.current.theme = "Day"
            Settings.save()
        }
        plugin.run { Settings.save() }
        XCTAssertEqual(try onDisk().theme, "Day")
    }

    func testAFailedSaveIsTriedAgainNextTime() throws {
        try write(Settings())
        var plugin = Process()
        plugin.run { Settings.load() }
        // A folder where the file should be makes the write fail.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        plugin.run {
            Settings.current.showHidden = true
            Settings.save()
        }
        try FileManager.default.removeItem(at: file)
        try write(Settings())
        plugin.run { Settings.save() }
        XCTAssertTrue(try onDisk().showHidden, "The change that failed to save is still this process's to write")
    }
}
