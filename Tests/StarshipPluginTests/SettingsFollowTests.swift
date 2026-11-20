@testable import FMStarshipUI
import StarshipAnalysis
@testable import StarshipSearch
import XCTest

/// Hidden attributes and Ability set in the other window, the app's or FM Starship's tab inside FM, reach this window's
/// model through the settings file, so Off means gone in both. What's taken from the file isn't written back when this
/// window saves. A temporary folder stands in for the real settings file.
@MainActor
final class SettingsFollowTests: XCTestCase {
    private var folder: URL!
    private var saved = Settings()
    private var savedBaseline: Settings?
    private var savedLoaded = false
    private var savedSeen: Date?

    private var file: URL { folder.appendingPathComponent("settings.json") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsFollowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        saved = Settings.current
        savedBaseline = Settings.baseline
        savedLoaded = Settings.loaded
        savedSeen = Settings.seenModified
        Settings.pathOverride = file
    }

    override func tearDownWithError() throws {
        Settings.pathOverride = nil
        Settings.current = saved
        Settings.baseline = savedBaseline
        Settings.loaded = savedLoaded
        Settings.seenModified = savedSeen
        try? FileManager.default.removeItem(at: folder)
    }

    private func onDisk() throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
    }

    /// As the other window's save would write it, with a modification date that's moved on.
    private func writeAsOther(_ settings: Settings) throws {
        let before = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        try JSONEncoder().encode(settings).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: (before ?? Date()).addingTimeInterval(1)], ofItemAtPath: file.path)
    }

    func testTheModelFollowsTheOtherWindowAndDoesntWriteItBack() throws {
        var start = Settings()
        start.showHidden = true
        start.reveal = Reveal.exact.rawValue
        try JSONEncoder().encode(start).write(to: file)
        Settings.load()
        let model = AppModel()
        // As inside FM, where the theme sets the appearance of FM Starship's own windows. Tests have no NSApp.
        model.applyAppearanceInsideGame = { _ in }
        XCTAssertTrue(model.showHidden)
        model.followSettingsFile()
        XCTAssertTrue(model.showHidden, "Nothing changed")

        // The other window switches Hidden attributes off.
        var other = start
        other.showHidden = false
        try writeAsOther(other)
        model.followSettingsFile()
        XCTAssertFalse(model.showHidden)
        XCTAssertFalse(model.hiddenAttributes, "FM Starship's tab shows it off")
        XCTAssertEqual(model.displayOptions.reveal, .hidden, "CA and PA go with it")
        XCTAssertFalse(model.displayOptions.showHidden)
        XCTAssertFalse(model.playerFilter.showHidden)
        XCTAssertFalse(try onDisk().showHidden)

        // Then on again with Ability at Stars, and this window saves something of its own before following.
        other.showHidden = true
        other.reveal = Reveal.stars.rawValue
        try writeAsOther(other)
        model.setTheme("Night")
        var result = try onDisk()
        XCTAssertEqual(result.theme, "Night")
        XCTAssertTrue(result.showHidden, "Not written back as off")
        XCTAssertEqual(result.reveal, Reveal.stars.rawValue)

        model.followSettingsFile()
        XCTAssertTrue(model.showHidden)
        XCTAssertEqual(model.reveal, .stars)
        XCTAssertEqual(model.ability, .stars, "FM Starship's tab shows Stars")
        XCTAssertEqual(model.displayOptions.reveal, .stars)
        result = try onDisk()
        XCTAssertTrue(result.showHidden)
        XCTAssertEqual(result.reveal, Reveal.stars.rawValue)
        XCTAssertEqual(result.theme, "Night")
    }
}
