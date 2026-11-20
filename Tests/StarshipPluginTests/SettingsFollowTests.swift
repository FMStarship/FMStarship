@testable import FMStarshipUI
import StarshipAnalysis
@testable import StarshipSearch
import XCTest

/// Hidden attributes and Ability set in the other window, the app's or FM Starship's tab inside FM, reach this window's
/// model through the settings file, so Off means gone in both. A follow writes nothing, so neither what's taken from the
/// file nor this window's column layout goes back over the other's. A temporary folder stands in for the real file.
@MainActor
final class SettingsFollowTests: XCTestCase {
    private var folder: URL!
    private var saved = Settings()
    private var savedBaseline: Settings?
    private var savedLoaded = false
    private var savedSeen: Date?
    private var savedWait: TimeInterval = 0

    private var file: URL { folder.appendingPathComponent("settings.json") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsFollowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        saved = Settings.current
        savedBaseline = Settings.baseline
        savedLoaded = Settings.loaded
        savedSeen = Settings.seenModified
        savedWait = Settings.lockWait
        Settings.pending = [:]
        Settings.saveFailures = .init()
        Settings.followFailures = .init()
        Settings.retryAfter = 30
        Settings.pathOverride = file
    }

    override func tearDownWithError() throws {
        Settings.pathOverride = nil
        Settings.current = saved
        Settings.baseline = savedBaseline
        Settings.loaded = savedLoaded
        Settings.seenModified = savedSeen
        Settings.lockWait = savedWait
        Settings.pending = [:]
        Settings.saveFailures = .init()
        Settings.followFailures = .init()
        Settings.retryAfter = 30
        try? FileManager.default.removeItem(at: folder)
    }

    private func onDisk() throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
    }

    private func modified() throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    }

    /// As the other window's save would write it, with a modification date that's moved on.
    private func writeAsOther(_ settings: Settings) throws {
        let before = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        try JSONEncoder().encode(settings).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: (before ?? Date()).addingTimeInterval(1)], ofItemAtPath: file.path)
    }

    /// The model, as the app or the plugin starts it, from the file.
    private func startModel(_ start: Settings) throws -> AppModel {
        try JSONEncoder().encode(start).write(to: file)
        Settings.load()
        let model = AppModel()
        // As inside FM, where the theme sets the appearance of FM Starship's own windows. Tests have no NSApp.
        model.applyAppearanceInsideGame = { _ in }
        return model
    }

    /// Follows as the poll does, twice, and checks that neither the follow nor the next poll wrote the file.
    private func follow(_ model: AppModel, file line: UInt = #line) throws {
        let bytes = try Data(contentsOf: file)
        let date = try modified()
        model.followSettingsFile()
        XCTAssertEqual(try Data(contentsOf: file), bytes, "The follow wrote the file", line: line)
        XCTAssertEqual(try modified(), date, "The follow wrote the file", line: line)
        model.followSettingsFile()
        XCTAssertEqual(try Data(contentsOf: file), bytes, "The next poll wrote the file", line: line)
        XCTAssertEqual(try modified(), date, "The next poll wrote the file", line: line)
    }

    /// A player column layout other than the one the model would capture: the first column wider, and the first two
    /// swapped.
    private func otherLayout(from start: [ColState]?) -> [ColState] {
        let all = Columns.forPlayers()
        var layout = start ?? Columns.capture(all: all, shown: Columns.shown(all, showHidden: false, showAbility: false), saved: nil)
        layout[0].width = 333
        if layout.count > 1 { (layout[0].order, layout[1].order) = (layout[1].order, layout[0].order) }
        return layout
    }

    func testTheModelFollowsTheOtherWindowAndWritesNothing() throws {
        var start = Settings()
        start.showHidden = true
        start.reveal = Reveal.exact.rawValue
        let model = try startModel(start)
        XCTAssertTrue(model.showHidden)
        try follow(model)
        XCTAssertTrue(model.showHidden, "Nothing changed")

        // The other window switches Hidden attributes off, with a column layout of its own.
        var other = start
        other.showHidden = false
        other.playerColumns = otherLayout(from: nil)
        try writeAsOther(other)
        try follow(model)
        XCTAssertFalse(model.showHidden)
        XCTAssertFalse(model.hiddenAttributes, "FM Starship's tab shows it off")
        XCTAssertEqual(model.displayOptions.reveal, .hidden, "CA and PA go with it")
        XCTAssertFalse(model.displayOptions.showHidden)
        XCTAssertFalse(model.playerFilter.showHidden)

        // Then on again with Ability at Stars, and this window saves something of its own before following.
        other.showHidden = true
        other.reveal = Reveal.stars.rawValue
        try writeAsOther(other)
        model.setTheme("Night")
        var result = try onDisk()
        XCTAssertEqual(result.theme, "Night")
        XCTAssertTrue(result.showHidden, "Not written back as off")
        XCTAssertEqual(result.reveal, Reveal.stars.rawValue)
        XCTAssertEqual(result.playerColumns, other.playerColumns, "The other window's layout survives")

        try follow(model)
        XCTAssertTrue(model.showHidden)
        XCTAssertEqual(model.reveal, .stars)
        XCTAssertEqual(model.ability, .stars, "FM Starship's tab shows Stars")
        XCTAssertEqual(model.displayOptions.reveal, .stars)
        result = try onDisk()
        XCTAssertTrue(result.showHidden)
        XCTAssertEqual(result.reveal, Reveal.stars.rawValue)
        XCTAssertEqual(result.theme, "Night")
        XCTAssertEqual(result.playerColumns, other.playerColumns)
    }

    /// The review's experiment: both windows started from the same saved layout, and the other window widens a column and
    /// switches Hidden attributes on. This window's capture would record hidden columns at another width.
    func testAFollowKeepsTheOtherWindowsLayoutWhenBothHadOne() throws {
        var start = Settings()
        let all = Columns.forPlayers()
        start.playerColumns = Columns.capture(all: all, shown: Columns.shown(all, showHidden: false, showAbility: false), saved: nil)
        let model = try startModel(start)
        var other = start
        other.showHidden = true
        other.playerColumns = otherLayout(from: start.playerColumns)
        try writeAsOther(other)
        try follow(model)
        XCTAssertTrue(model.showHidden)
        XCTAssertEqual(try onDisk().playerColumns, other.playerColumns)
    }

    /// The same, with no layout saved when this window started, which its capture would turn into a whole one.
    func testAFollowKeepsTheOtherWindowsLayoutWhenThisOneHadNone() throws {
        let model = try startModel(Settings())
        var other = Settings()
        other.showHidden = true
        other.playerColumns = otherLayout(from: nil)
        try writeAsOther(other)
        try follow(model)
        XCTAssertTrue(model.showHidden)
        XCTAssertEqual(try onDisk().playerColumns, other.playerColumns)
    }

    /// The review's experiment: switching Hidden attributes off while the other process holds the lock fails to save,
    /// and the poll saves it, so the file and the other window don't keep it on.
    func testThePollSavesOffAfterAFailedSave() throws {
        var start = Settings()
        start.showHidden = true
        let model = try startModel(start)
        Settings.lockWait = 0.05
        let other = open(folder.appendingPathComponent("settings.lock").path, O_RDWR | O_CREAT, 0o644)
        XCTAssertGreaterThanOrEqual(other, 0)
        XCTAssertEqual(flock(other, LOCK_EX | LOCK_NB), 0)
        model.showHidden = false
        XCTAssertTrue(try onDisk().showHidden, "Not saved while the lock is held")
        model.followSettingsFile()
        XCTAssertTrue(try onDisk().showHidden, "Still held: the poll doesn't wait for it")
        flock(other, LOCK_UN)
        close(other)
        model.followSettingsFile()
        XCTAssertFalse(try onDisk().showHidden, "Saved by the poll once the lock is free")
        XCTAssertFalse(model.showHidden, "And not followed back on")
        let log = try String(contentsOf: folder.appendingPathComponent("errors.log"), encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "settings not saved").count - 1, 1, "Logged once, not on every poll")
    }

    func testInsideFMASaveNeverWaitsForTheLock() throws {
        let edition = AppModel.editionInsideGame
        defer { AppModel.editionInsideGame = edition }
        AppModel.editionInsideGame = "test, inside Football Manager"
        try JSONEncoder().encode(Settings()).write(to: file)
        let model = AppModel.startUp()
        model.applyAppearanceInsideGame = { _ in }
        XCTAssertEqual(Settings.lockWait, 0)
        let other = open(folder.appendingPathComponent("settings.lock").path, O_RDWR | O_CREAT, 0o644)
        XCTAssertEqual(flock(other, LOCK_EX | LOCK_NB), 0)
        let started = Date()
        model.showHidden = true
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "The switch inside FM doesn't wait for the app")
        XCTAssertFalse(try onDisk().showHidden)
        flock(other, LOCK_UN)
        close(other)
        model.followSettingsFile()
        XCTAssertTrue(try onDisk().showHidden, "The poll saves it")
    }
}
