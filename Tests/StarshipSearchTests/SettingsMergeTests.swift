@testable import StarshipSearch
import XCTest

/// The app and the plugin inside FM each load settings.json once. A save keeps the file's value for every key this process
/// hasn't changed, so neither writes back the other's older values.
final class SettingsMergeTests: XCTestCase {
    /// One process's view of the settings, swapped in and out of `Settings`' statics.
    private struct Process {
        var current = Settings()
        var baseline: Settings?
        var seenModified: Date?
        var pending: [String: Settings.Pending] = [:]
        var saveFailures = Settings.Failures()
        var followFailures = Settings.Failures()

        mutating func run(_ body: () -> Void) {
            Settings.current = current
            Settings.baseline = baseline
            Settings.seenModified = seenModified
            Settings.pending = pending
            Settings.saveFailures = saveFailures
            Settings.followFailures = followFailures
            body()
            current = Settings.current
            baseline = Settings.baseline
            seenModified = Settings.seenModified
            pending = Settings.pending
            saveFailures = Settings.saveFailures
            followFailures = Settings.followFailures
        }
    }

    private var folder: URL!
    private var saved = Settings()
    private var savedBaseline: Settings?
    private var savedLoaded = false
    private var savedSeen: Date?
    private var savedWait: TimeInterval = 0

    private var file: URL { folder.appendingPathComponent("settings.json") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsMergeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        saved = Settings.current
        savedBaseline = Settings.baseline
        savedLoaded = Settings.loaded
        savedSeen = Settings.seenModified
        savedWait = Settings.lockWait
        // Tests that hold the lock needn't wait the half second.
        Settings.lockWait = 0.05
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

    private func write(_ settings: Settings) throws {
        try JSONEncoder().encode(settings).write(to: file)
    }

    private var log: URL { folder.appendingPathComponent("errors.log") }

    /// What the file says, key by key, without decoding it as `Settings`.
    private func keys() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    /// Writes the file as the other process's save would, and makes sure its modification date moves on.
    private func writeAsOther(_ settings: Settings) throws {
        let before = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        try write(settings)
        let later = (before ?? Date()).addingTimeInterval(1)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: file.path)
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

    func testAFileThatIsntJSONIsWrittenOverAndLogged() throws {
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
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("isn't JSON"))
    }

    func testAFileThatDoesntDecodeKeepsItsGoodAndUnknownKeys() throws {
        try Data(#"{"ShowHidden": "yes", "Theme": "Night", "SomethingNewer": [1, 2]}"#.utf8).write(to: file)
        var app = Process()
        app.run {
            Settings.load()
            Settings.current.heightUnit = "in"
            Settings.save()
        }
        let result = try keys()
        XCTAssertEqual(result["HeightUnit"] as? String, "in")
        XCTAssertEqual(result["Theme"] as? String, "Night", "A good key the save didn't change survives")
        XCTAssertEqual(result["SomethingNewer"] as? [Int], [1, 2], "So does one this build doesn't know")
        XCTAssertEqual(result["ShowHidden"] as? String, "yes", "A bad key this process didn't change is left as it is")
    }

    func testAFileThatCantBeReadIsntWrittenOver() throws {
        var start = Settings()
        start.theme = "Night"
        try write(start)
        var app = Process()
        app.run { Settings.load() }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        app.run {
            Settings.current.showHidden = true
            Settings.save()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(try onDisk(), start, "Not written over with this process's settings")
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("settings not saved"))
        app.run { Settings.save() }
        XCTAssertTrue(try onDisk().showHidden, "Saved next time")
        XCTAssertEqual(try onDisk().theme, "Night")
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

    func testAMissingFileIsntLogged() throws {
        var app = Process()
        app.run {
            Settings.load()
            XCTAssertFalse(Settings.followFile())
            Settings.current.showHidden = true
            Settings.save()
        }
        XCTAssertTrue(try onDisk().showHidden)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    func testASaveWaitsForTheLockThenGivesUpAndTriesAgainLater() throws {
        try write(Settings())
        var app = Process()
        app.run { Settings.load() }
        Settings.lockWait = 0.05
        let other = open(folder.appendingPathComponent("settings.lock").path, O_RDWR | O_CREAT, 0o644)
        XCTAssertGreaterThanOrEqual(other, 0)
        XCTAssertEqual(flock(other, LOCK_EX | LOCK_NB), 0)
        let started = Date()
        app.run {
            Settings.current.showHidden = true
            Settings.save()
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "It doesn't wait for long")
        XCTAssertFalse(try onDisk().showHidden, "Not saved while the other process holds the lock")
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("settings not saved"))
        flock(other, LOCK_UN)
        close(other)
        app.run { Settings.save() }
        XCTAssertTrue(try onDisk().showHidden, "Saved once the lock is free")
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(left, [], "No temporary file is left behind")
    }

    func testFollowingTakesHiddenAttributesAndAbilityWithoutSavingThemBack() throws {
        var start = Settings()
        start.showHidden = true
        start.reveal = 0
        try write(start)
        var app = Process()
        app.run { Settings.load() }
        app.run { XCTAssertFalse(Settings.followFile(), "Nothing has changed since loading") }

        // The plugin switches Hidden attributes off and Ability to Stars.
        var plugin = start
        plugin.showHidden = false
        plugin.reveal = 1
        try writeAsOther(plugin)
        app.run {
            XCTAssertTrue(Settings.followFile())
            XCTAssertFalse(Settings.current.showHidden)
            XCTAssertEqual(Settings.current.reveal, 1)
            XCTAssertFalse(Settings.followFile(), "Read once per change")
        }

        // The plugin switches them back, then the app saves a change of its own without having followed.
        plugin.showHidden = true
        plugin.reveal = 0
        try writeAsOther(plugin)
        app.run {
            Settings.current.theme = "Night"
            Settings.save()
        }
        let result = try onDisk()
        XCTAssertEqual(result.theme, "Night")
        XCTAssertTrue(result.showHidden, "What the app took from the file isn't its change to write back")
        XCTAssertEqual(result.reveal, 0)
    }

    /// The other process holds the lock, as when it's in the middle of a save of its own.
    private func holdLock() throws -> Int32 {
        let other = open(folder.appendingPathComponent("settings.lock").path, O_RDWR | O_CREAT, 0o644)
        XCTAssertGreaterThanOrEqual(other, 0)
        XCTAssertEqual(flock(other, LOCK_EX | LOCK_NB), 0)
        return other
    }

    private func release(_ lock: Int32) {
        flock(lock, LOCK_UN)
        close(lock)
    }

    private func setModified(_ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    /// The app switches Hidden attributes on and the save fails. The plugin's write came clearly before, so the app's
    /// choice is the later one and stays.
    func testAPendingChangeLaterThanTheOtherWindowsStays() throws {
        try write(Settings())
        var app = Process()
        app.run { Settings.load() }
        var plugin = Settings()
        plugin.reveal = 2
        try write(plugin)
        try setModified(Date().addingTimeInterval(-10))
        let lock = try holdLock()
        app.run {
            Settings.current.showHidden = true
            Settings.save()
        }
        release(lock)
        app.run {
            XCTAssertTrue(Settings.followFile(), "Reveal is taken")
            XCTAssertTrue(Settings.current.showHidden, "This process's later change stays")
            XCTAssertEqual(Settings.current.reveal, 2)
            Settings.saveIfPending()
        }
        let result = try onDisk()
        XCTAssertTrue(result.showHidden)
        XCTAssertEqual(result.reveal, 2)
    }

    /// The app sets Ability to Stars and the save fails. The plugin then sets it to Off, clearly later: the plugin's
    /// choice wins and the app's isn't written.
    func testAPendingChangeGivesWayToALaterOneFromTheOtherWindow() throws {
        var start = Settings()
        start.showHidden = true
        start.reveal = 0
        try write(start)
        var app = Process()
        app.run { Settings.load() }
        let lock = try holdLock()
        app.run {
            Settings.current.reveal = 1
            Settings.save()
        }
        release(lock)
        var plugin = start
        plugin.reveal = 2
        try write(plugin)
        try setModified(Date().addingTimeInterval(10))
        app.run {
            XCTAssertTrue(Settings.followFile())
            XCTAssertEqual(Settings.current.reveal, 2, "The other window's later choice")
            Settings.saveIfPending()
        }
        XCTAssertEqual(try onDisk().reveal, 2)
    }

    /// The review's repro: the app's switch to on fails to save, then inside FM the player switches it on and off again,
    /// so the file reads as the app loaded it. Which came later can't be told, so it's settled off, and both windows and
    /// the file agree on off.
    func testARetryDoesntWriteOverALaterChoiceInTheOtherWindow() throws {
        try write(Settings())
        var app = Process(), plugin = Process()
        app.run { Settings.load() }
        plugin.run { Settings.load() }
        let lock = try holdLock()
        app.run {
            Settings.current.showHidden = true
            Settings.save()
        }
        release(lock)
        plugin.run {
            Settings.current.showHidden = true
            Settings.save()
            Settings.current.showHidden = false
            Settings.save()
        }
        XCTAssertFalse(try onDisk().showHidden)
        // The app's poll: follow first, then save what's pending.
        app.run {
            XCTAssertTrue(Settings.followFile())
            XCTAssertFalse(Settings.current.showHidden, "Settled off")
            Settings.saveIfPending()
        }
        XCTAssertFalse(try onDisk().showHidden, "The retry didn't write on over the later off")
        plugin.run {
            _ = Settings.followFile()
            XCTAssertFalse(Settings.current.showHidden, "And the plugin doesn't switch back on")
        }
    }

    /// The same, with Ability: a change that can't be placed before or after the other window's settles to Off.
    func testAnUnclearOrderSettlesAbilityToOff() throws {
        var start = Settings()
        start.showHidden = true
        try write(start)
        var app = Process()
        app.run { Settings.load() }
        let lock = try holdLock()
        app.run {
            Settings.current.reveal = 1
            Settings.save()
        }
        release(lock)
        var plugin = start
        plugin.theme = "Night"
        try writeAsOther(plugin)
        try setModified(Date())
        app.run {
            XCTAssertTrue(Settings.followFile())
            XCTAssertEqual(Settings.current.reveal, Reveal.hidden.rawValue)
            Settings.saveIfPending()
        }
        let result = try onDisk()
        XCTAssertEqual(result.reveal, Reveal.hidden.rawValue)
        XCTAssertEqual(result.theme, "Night")
    }

    func testLoadingAFileThatDoesntDecodeStillTakesHiddenAttributesAndAbility() throws {
        try Data(#"{"ShowHidden": true, "Reveal": 1, "Theme": 5}"#.utf8).write(to: file)
        var app = Process()
        app.run {
            Settings.load()
            XCTAssertTrue(Settings.current.showHidden, "As followFile and the file read it")
            XCTAssertEqual(Settings.current.reveal, 1)
            XCTAssertEqual(Settings.current.theme, Settings().theme)
        }
        for odd in [#"{"ShowHidden": 1, "Theme": 5}"#, #"{"ShowHidden": "true"}"#, #"{"ShowHidden": null}"#] {
            try Data(odd.utf8).write(to: file)
            app.run {
                Settings.load()
                XCTAssertFalse(Settings.current.showHidden, "Only a JSON true is on: \(odd)")
            }
        }
    }

    func testFollowingTakesTheDefaultForAMissingOrBadKey() throws {
        var start = Settings()
        start.showHidden = true
        try write(start)
        var app = Process()
        app.run { Settings.load() }
        try Data(#"{"ShowHidden": "yes", "Reveal": 7}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        app.run {
            XCTAssertTrue(Settings.followFile())
            XCTAssertFalse(Settings.current.showHidden, "Off. Loading such a file gives all the defaults, which has it off too")
            XCTAssertEqual(Settings.current.reveal, Reveal.hidden.rawValue, "Clamped, as the model's Reveal(setting:) does")
        }
    }

    func testALockFileThisUserCantWriteStillLocks() throws {
        try write(Settings())
        let lock = folder.appendingPathComponent("settings.lock")
        FileManager.default.createFile(atPath: lock.path, contents: nil, attributes: [.posixPermissions: 0o444])
        var app = Process()
        app.run {
            Settings.load()
            Settings.current.showHidden = true
            Settings.save()
        }
        XCTAssertTrue(try onDisk().showHidden)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    func testAFollowThatCantReadTheFileTriesAgainThenBacksOffAndLogsOnce() throws {
        try write(Settings())
        var app = Process()
        app.run { Settings.load() }
        var plugin = Settings()
        plugin.showHidden = true
        try writeAsOther(plugin)
        Settings.retryAfter = 0.2
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        app.run {
            XCTAssertFalse(Settings.followFile())
            XCTAssertFalse(Settings.followFile())
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let logged = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(logged.components(separatedBy: "settings not followed").count - 1, 1, "Logged once")
        app.run { XCTAssertFalse(Settings.followFile(), "Backing off after failing twice the same way") }
        Thread.sleep(forTimeInterval: 0.25)
        app.run {
            XCTAssertTrue(Settings.followFile(), "Read again, though its modification date hasn't changed since")
            XCTAssertTrue(Settings.current.showHidden)
        }
    }

    func testANewerFileIsFollowedAtOnceWhileBackingOff() throws {
        try write(Settings())
        var app = Process()
        app.run { Settings.load() }
        try writeAsOther(Settings())
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        app.run {
            XCTAssertFalse(Settings.followFile())
            XCTAssertFalse(Settings.followFile())
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        var plugin = Settings()
        plugin.showHidden = true
        try writeAsOther(plugin)
        app.run { XCTAssertTrue(Settings.followFile(), "A newer file isn't held back") }
    }

    func testSaveIfPendingSavesOnlyAChangeLeftBehindAndBacksOff() throws {
        try write(Settings())
        var app = Process(), plugin = Process()
        app.run { Settings.load() }
        plugin.run { Settings.load() }
        let date = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        app.run { Settings.saveIfPending() }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, date,
                       "Nothing pending, nothing written")

        Settings.lockWait = 0.05
        Settings.retryAfter = 0.2
        var lock = try holdLock()
        app.run {
            Settings.current.theme = "Night"
            Settings.save()
            Settings.save()
            let started = Date()
            Settings.saveIfPending()
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.04, "The poll's try doesn't wait for the lock")
        }
        // The other process writes once in between, and the app follows it: that doesn't log the save's failure again.
        release(lock)
        plugin.run {
            Settings.current.heightUnit = "in"
            Settings.save()
        }
        lock = try holdLock()
        app.run {
            XCTAssertFalse(Settings.followFile(), "Nothing it follows changed")
            for _ in 0..<4 { Settings.saveIfPending() }
        }
        release(lock)
        app.run { Settings.saveIfPending() }
        XCTAssertNotEqual(try onDisk().theme, "Night", "Backing off after the poll's tries failed twice the same way")
        Thread.sleep(forTimeInterval: 0.25)
        app.run { Settings.saveIfPending() }
        let result = try onDisk()
        XCTAssertEqual(result.theme, "Night")
        XCTAssertEqual(result.heightUnit, "in")
        let logged = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(logged.components(separatedBy: "settings not saved").count - 1, 1, "The same failure is logged once")
    }
}
