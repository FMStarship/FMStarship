@testable import FMStarshipUI
import StarshipCore
import StarshipSearch
import XCTest

/// FM's save moving on to a later day than the one FM Starship read, as when the player presses Continue with FM
/// Starship's window open: the notice over the screens, the read started once the window is shown again, and the
/// warning over a list nobody could be asked about. None of it needs FM.
@MainActor
final class SaveProgressTests: XCTestCase {
    private var saved = Settings()

    override func setUp() {
        super.setUp()
        saved = Settings.current
        Settings.current = Settings()
    }

    override func tearDown() {
        Settings.current = saved
        super.tearDown()
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        GameDate.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// A model with a save read on `readOn`, as Load Save leaves it. Settings aren't loaded in tests, so nothing is written,
    /// and a read it starts on its own is only counted, so nothing reaches for FM.
    private func model(readOn: Date?) -> AppModel {
        let model = AppModel()
        model.sheetShown = { false }
        model.readOnItsOwn = { [weak self] _ in self?.readsStarted += 1 }
        model.database = database(readOn: readOn)
        return model
    }

    private var readsStarted = 0

    private func database(readOn: Date?) -> Database {
        let database = Database()
        database.gameDate = readOn
        return database
    }

    /// The poll seeing FM on `date` for long enough that it isn't pressing on through days.
    private func settle(_ model: AppModel, on date: Date, from time: TimeInterval = 0) {
        for time in stride(from: time, through: time + AppModel.settleTime, by: 2) { model.saveDateSeen(date, at: time) }
    }

    /// The poll's looks every 2 s from `start` through `end`, seeing FM on `date`.
    private func pollLooks(_ model: AppModel, on date: Date, from start: TimeInterval, through end: TimeInterval) {
        for time in stride(from: start, through: end, by: 2) { model.dateLooked(date, at: time, byPoll: true) }
    }

    func testOnlyALaterDayIsMovingOn() {
        XCTAssertNotNil(SaveProgress(readOn: day(2029, 9, 12), now: day(2029, 9, 13)))
        XCTAssertNil(SaveProgress(readOn: day(2029, 9, 12), now: day(2029, 9, 12)), "The same day")
        XCTAssertNil(SaveProgress(readOn: day(2029, 9, 12), now: day(2029, 9, 11)), "An earlier day isn't this save moving on")
        XCTAssertNil(SaveProgress(readOn: day(2029, 9, 12), now: nil), "FM has let go of the save, or the date can't be read")
        XCTAssertNil(SaveProgress(readOn: nil, now: day(2029, 9, 22)), "The read found no date")
    }

    func testTheNoticeSaysBothDaysAndWhatToDo() {
        let progress = SaveProgress(readOn: day(2029, 9, 12), now: day(2029, 9, 22))
        XCTAssertEqual(progress?.notice, "FM is on 22 Sep 2029, but what FM Starship shows was read on 12 Sep. Press Load Save to read it again.")
        let newYear = SaveProgress(readOn: day(2028, 12, 28), now: day(2029, 1, 3))
        XCTAssertEqual(newYear?.notice, "FM is on 3 Jan 2029, but what FM Starship shows was read on 28 Dec 2028. Press Load Save to read it again.")
    }

    func testTheModelFollowsTheDateFMHoldsNow() {
        let model = model(readOn: day(2029, 9, 12))
        XCTAssertNil(model.saveMovedOn)
        model.saveDateSeen(day(2029, 9, 12))
        XCTAssertNil(model.saveMovedOn, "Still the day it was read")
        model.saveDateSeen(day(2029, 9, 22))
        XCTAssertEqual(model.saveMovedOn, SaveProgress(readOn: day(2029, 9, 12), now: day(2029, 9, 22)))
        model.saveDateSeen(nil)
        XCTAssertNil(model.saveMovedOn, "Nothing is said when the date can't be told")
    }

    func testNoNoticeWithoutASaveOrADate() {
        let model = AppModel()
        model.saveDateSeen(day(2029, 9, 22))
        XCTAssertNil(model.saveMovedOn, "No save loaded")
        let undated = self.model(readOn: nil)
        undated.saveDateSeen(day(2029, 9, 22))
        XCTAssertNil(undated.saveMovedOn, "The read found no date")
    }

    func testShowingTheWindowReadsAgainOnceForEachDay() {
        let model = model(readOn: day(2029, 9, 12))
        XCTAssertFalse(model.takeReadOnShow(), "The save hasn't moved on")
        settle(model, on: day(2029, 9, 22))
        XCTAssertTrue(model.takeReadOnShow())
        XCTAssertFalse(model.takeReadOnShow(), "Not again for the same day, so a read that fails isn't started over and over")
        settle(model, on: day(2029, 9, 23), from: 20)
        model.loading = true
        XCTAssertFalse(model.takeReadOnShow(), "Not while a read is going on")
        model.loading = false
        XCTAssertTrue(model.takeReadOnShow(), "Once more for the next day")
    }

    func testNoReadWhileFMIsStillPressingOnThroughDays() {
        let model = model(readOn: day(2029, 9, 12))
        model.saveDateSeen(day(2029, 9, 20), at: 0)
        XCTAssertNotNil(model.saveMovedOn, "The notice is up")
        XCTAssertFalse(model.takeReadOnShow(), "Seen once: FM may still be on its way")
        model.saveDateSeen(day(2029, 9, 21), at: 2)
        XCTAssertFalse(model.takeReadOnShow(), "Another day since the last look")
        XCTAssertNotNil(model.saveMovedOn, "The notice stays up")
        model.saveDateSeen(day(2029, 9, 21), at: 4)
        model.saveDateSeen(day(2029, 9, 21), at: 8)
        XCTAssertFalse(model.takeReadOnShow(), "The same day for 6 s: FM can take longer than that over a day")
        model.saveDateSeen(day(2029, 9, 21), at: 12)
        XCTAssertTrue(model.takeReadOnShow(), "The same day for 10 s")
    }

    func testTheWindowsOwnLookDoesntSettleTheDay() {
        let model = model(readOn: day(2029, 9, 12))
        for time in stride(from: 0.0, through: 8, by: 2) { model.saveDateSeen(day(2029, 9, 20), at: time) }
        model.saveDateSeen(day(2029, 9, 20), at: 11, byPoll: false)
        XCTAssertFalse(model.takeReadOnShow(), "Only the poll's looks tell how long FM has stayed on a day")
        model.saveDateSeen(day(2029, 9, 20), at: 12)
        XCTAssertTrue(model.takeReadOnShow())

        let moved = self.model(readOn: day(2029, 9, 12))
        settle(moved, on: day(2029, 9, 20))
        moved.saveDateSeen(day(2029, 9, 21), at: 12, byPoll: false)
        XCTAssertEqual(moved.saveMovedOn?.now, day(2029, 9, 21))
        XCTAssertFalse(moved.takeReadOnShow(), "The window's look saw FM go on to another day")
    }

    func testNoReadWhileASheetIsOpen() {
        for sheet in [\AppModel.editingFilter, \.editingColumns] {
            let model = model(readOn: day(2029, 9, 12))
            settle(model, on: day(2029, 9, 22))
            model[keyPath: sheet] = true
            XCTAssertFalse(model.takeReadOnShow(), "A read would search with a half-edited filter, or columns")
            model.windowShown()
            XCTAssertFalse(model.loading, "Showing the window starts no read either")
            model[keyPath: sheet] = false
            XCTAssertTrue(model.takeReadOnShow(), "Once it's closed")
        }
    }

    func testNoReadWhileAShortlistIsOpen() {
        let model = model(readOn: day(2029, 9, 12))
        model.go(to: .shortlists)
        model.showShortlist(OpenShortlist(url: URL(fileURLWithPath: "/nowhere/Targets.fmf"), name: "Targets", isStaff: false, uids: [1]))
        settle(model, on: day(2029, 9, 22))
        XCTAssertFalse(model.takeReadOnShow(), "A read closes the shortlist")
        model.go(to: .players)
        XCTAssertTrue(model.takeReadOnShow(), "Not on the Shortlists screen, nothing open is lost")
    }

    func testAnotherSaveOnTheSameDayReadsAgain() {
        // Read on the 12th, moved on to the 22nd, read on showing. Then an earlier save, moved on to the 22nd as well.
        let model = model(readOn: day(2029, 9, 12))
        settle(model, on: day(2029, 9, 22))
        XCTAssertTrue(model.takeReadOnShow())
        model.database = database(readOn: day(2029, 9, 15))
        settle(model, on: day(2029, 9, 22), from: 20)
        XCTAssertTrue(model.takeReadOnShow(), "Another save, though FM is on the same day")
    }

    func testTheSameSaveReadAgainAndPlayedToTheSameDayReadsAgain() {
        // Read on the 12th, moved on to the 22nd, read on showing. Then the 12th's save loaded and read again, and
        // played to the 22nd once more.
        let model = model(readOn: day(2029, 9, 12))
        settle(model, on: day(2029, 9, 22))
        XCTAssertTrue(model.takeReadOnShow())
        model.install(NewData(database(readOn: day(2029, 9, 12))))
        settle(model, on: day(2029, 9, 22), from: 20)
        XCTAssertTrue(model.takeReadOnShow(), "A read installed since: the 22nd is new again")
    }

    func testNoReadWhileAnotherSheetIsUp() {
        let model = model(readOn: day(2029, 9, 12))
        settle(model, on: day(2029, 9, 22))
        model.sheetShown = { true }
        XCTAssertFalse(model.takeReadOnShow(), "An export or shortlist panel, or a question, is up")
        model.sheetShown = { false }
        XCTAssertTrue(model.takeReadOnShow())
    }

    func testAReadFinishingWhileThePlayerIsBusyWaitsForThem() {
        let model = model(readOn: day(2029, 9, 12))
        let old = model.database
        model.go(to: .shortlists)
        let targets = OpenShortlist(url: URL(fileURLWithPath: "/nowhere/Targets.fmf"), name: "Targets", isStaff: false, uids: [1])
        model.showShortlist(targets)
        let fresh = database(readOn: day(2029, 9, 22))
        model.finished(NewData(fresh), nil, automatic: true)
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.database === old, "Held while the shortlist is open")
        XCTAssertEqual(model.openShortlist, targets, "The shortlist stays open")
        XCTAssertFalse(model.useHeldRead(), "Still open")
        model.go(to: .players)
        XCTAssertTrue(model.useHeldRead())
        XCTAssertTrue(model.database === fresh, "Installed once the player is done")
        XCTAssertFalse(model.useHeldRead(), "Only once")

        for busy in [\AppModel.editingFilter, \.editingColumns] {
            let model = self.model(readOn: day(2029, 9, 12))
            model[keyPath: busy] = true
            let fresh = database(readOn: day(2029, 9, 22))
            model.finished(NewData(fresh), nil, automatic: true)
            XCTAssertFalse(model.database === fresh, "Held while a sheet is open, so it doesn't search with a half-edited filter")
            model[keyPath: busy] = false
            XCTAssertTrue(model.useHeldRead())
            XCTAssertTrue(model.database === fresh)
        }

        let asked = self.model(readOn: day(2029, 9, 12))
        asked.sheetShown = { true }
        let pressed = database(readOn: day(2029, 9, 22))
        asked.finished(NewData(pressed), nil)
        XCTAssertTrue(asked.database === pressed, "Load Save pressed: shown at once, as before")
    }

    func testAReadNobodyAskedForPutsFailedSelfChecksOnTheStatusLine() {
        let model = model(readOn: day(2029, 9, 12))
        let failing = database(readOn: day(2029, 9, 22))
        failing.checks = "FAIL: ages"
        model.finished(NewData(failing), nil, automatic: true)
        XCTAssertNil(model.alert, "Nobody asked for it, so no alert")
        XCTAssertTrue(model.status.hasPrefix("FM Starship's self-checks failed on this save (ages)"), model.status)
        model.finished(NewData(failing), nil)
        XCTAssertNotNil(model.alert, "Load Save pressed: the alert as before")
    }

    func testAReadThatFailsOnItsOwnSaysSoOnTheStatusLine() {
        let model = AppModel()
        model.loading = true
        model.failed("Football Manager isn't running.", automatic: true)
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.status, "Football Manager isn't running.")
        XCTAssertNil(model.alert, "Nobody asked for it, so no alert")
        model.loading = true
        model.failed("Football Manager isn't running.")
        XCTAssertEqual(model.alert, "Football Manager isn't running.", "Load Save pressed: the alert as before")
    }

    func testAWindowShownBeforeTheDayHasHeldReadsOnceItHas() {
        let model = model(readOn: day(2029, 9, 12))
        model.dateLooked(day(2029, 9, 22), at: 0, byPoll: true)
        model.windowShown()
        XCTAssertEqual(readsStarted, 0, "FM has only just stopped on the 22nd")
        model.dateLooked(day(2029, 9, 22), at: 2, byPoll: true)
        XCTAssertEqual(readsStarted, 0, "2 s on the same day")
        pollLooks(model, on: day(2029, 9, 22), from: 4, through: 8)
        XCTAssertEqual(readsStarted, 0, "8 s on the same day")
        model.dateLooked(day(2029, 9, 22), at: 10, byPoll: true)
        XCTAssertEqual(readsStarted, 1, "The window's showing still asks: FM has held the day for 10 s")
        model.dateLooked(day(2029, 9, 22), at: 12, byPoll: true)
        XCTAssertEqual(readsStarted, 1, "One read, not one on every look")

        // FM pressing on again while the window waits: the wait starts over on the new day.
        let pressing = self.model(readOn: day(2029, 9, 12))
        readsStarted = 0
        pressing.dateLooked(day(2029, 9, 22), at: 0, byPoll: true)
        pressing.windowShown()
        pollLooks(pressing, on: day(2029, 9, 23), from: 4, through: 12)
        XCTAssertEqual(readsStarted, 0, "8 s on the 23rd")
        pressing.dateLooked(day(2029, 9, 23), at: 14, byPoll: true)
        XCTAssertEqual(readsStarted, 1)
    }

    func testAWindowWaitingForTheDayStopsWaitingWhenItsNotWanted() {
        // Hidden, or the app gone to the back.
        let hidden = model(readOn: day(2029, 9, 12))
        hidden.dateLooked(day(2029, 9, 22), at: 0, byPoll: true)
        hidden.windowShown()
        hidden.windowHidden()
        pollLooks(hidden, on: day(2029, 9, 22), from: 2, through: 10)
        XCTAssertEqual(readsStarted, 0, "The window was hidden before the day had held")
        hidden.windowShown()
        XCTAssertEqual(readsStarted, 1, "Shown again once it has")

        // A read installed meanwhile: Load Save, or a snapshot opened.
        let installed = model(readOn: day(2029, 9, 12))
        readsStarted = 0
        installed.dateLooked(day(2029, 9, 22), at: 0, byPoll: true)
        installed.windowShown()
        installed.install(NewData(database(readOn: day(2029, 9, 15))))
        pollLooks(installed, on: day(2029, 9, 22), from: 2, through: 12)
        XCTAssertEqual(readsStarted, 0, "What the window was shown for has been answered")

        // A read going on when the day has held, or the player busy then.
        for busy in [\AppModel.loading, \.editingFilter] {
            let model = model(readOn: day(2029, 9, 12))
            readsStarted = 0
            model.dateLooked(day(2029, 9, 22), at: 0, byPoll: true)
            model.windowShown()
            pollLooks(model, on: day(2029, 9, 22), from: 2, through: 8)
            model[keyPath: busy] = true
            model.dateLooked(day(2029, 9, 22), at: 10, byPoll: true)
            model[keyPath: busy] = false
            model.dateLooked(day(2029, 9, 22), at: 12, byPoll: true)
            XCTAssertEqual(readsStarted, 0, "As before: only waiting for the day keeps it waiting")
        }
    }

    func testAWindowShownStopsWaitingAfterAMinute() {
        // FM pressing on through days after the window is shown, as inside FM, where the window stays up while the
        // player clicks back into FM and presses Continue.
        func pressedOnUntil(_ held: TimeInterval) -> AppModel {
            let model = model(readOn: day(2029, 9, 12))
            model.dateLooked(day(2029, 9, 20), at: 0, byPoll: true)
            model.windowShown(at: 0)
            for (days, time) in stride(from: 2.0, to: held, by: 2).enumerated() {
                model.dateLooked(day(2029, 9, 21 + days), at: time, byPoll: true)
            }
            return model
        }
        readsStarted = 0
        let inTime = pressedOnUntil(50)
        pollLooks(inTime, on: day(2029, 10, 30), from: 50, through: 58)
        XCTAssertEqual(readsStarted, 0)
        inTime.dateLooked(day(2029, 10, 30), at: 60, byPoll: true)
        XCTAssertEqual(readsStarted, 1, "FM held a day 10 s within a minute of the window being shown")

        readsStarted = 0
        let late = pressedOnUntil(52)
        pollLooks(late, on: day(2029, 10, 31), from: 52, through: 64)
        XCTAssertTrue(late.daySettled)
        XCTAssertEqual(readsStarted, 0, "Held from 52 s: that's more than a minute after the window was shown")
        late.windowShown(at: 66)
        XCTAssertEqual(readsStarted, 1, "Shown again, it reads at once")
    }

    func testAGapBetweenThePollsLooksStartsTheDayOver() {
        let model = model(readOn: day(2029, 9, 12))
        model.dateLooked(day(2029, 9, 22), at: 0, byPoll: true)
        model.windowShown(at: 0)
        model.dateLooked(day(2029, 9, 22), at: 12, byPoll: true)
        XCTAssertFalse(model.daySettled, "FM's main thread held up for 12 s, as over a day: it wasn't seen staying")
        XCTAssertEqual(readsStarted, 0)
        pollLooks(model, on: day(2029, 9, 22), from: 14, through: 20)
        XCTAssertEqual(readsStarted, 0, "8 s since the gap")
        model.dateLooked(day(2029, 9, 22), at: 22, byPoll: true)
        XCTAssertEqual(readsStarted, 1, "10 s since the gap")

        let steady = self.model(readOn: day(2029, 9, 12))
        for time in stride(from: 0.0, through: 12, by: 4) { steady.saveDateSeen(day(2029, 9, 22), at: time) }
        XCTAssertTrue(steady.daySettled, "Looks 4 s apart, as when one waits on a slow one before it, still count")
    }

    func testALookIsTimedWhenItsMade() {
        let before = ProcessInfo.processInfo.systemUptime
        let (date, time) = AppModel.look {
            Thread.sleep(forTimeInterval: 0.2)
            return self.day(2029, 9, 22)
        }
        XCTAssertEqual(date, day(2029, 9, 22))
        XCTAssertLessThan(time - before, 0.1, "Not when a slow answer arrives, which would stretch how long the day held")
    }

    func testAHeldReadWaitsForAnotherReadToFinish() {
        let model = model(readOn: day(2029, 9, 12))
        let old = model.database
        model.editingFilter = true
        let held = database(readOn: day(2029, 9, 22))
        model.finished(NewData(held), nil, automatic: true)
        model.editingFilter = false
        model.loading = true  // Load Save pressed meanwhile
        XCTAssertFalse(model.useHeldRead())
        model.pollGame()
        XCTAssertTrue(model.loading, "The other read's progress stays up")
        XCTAssertTrue(model.database === old, "And the older read isn't put in under it")
        model.loading = false
        model.pollGame()
        XCTAssertTrue(model.database === held)
    }

    func testTheHeldReadAndQuietSelfChecksStayOnTheStatusLine() {
        let model = model(readOn: day(2029, 9, 12))
        model.go(to: .shortlists)
        let targets = OpenShortlist(url: URL(fileURLWithPath: "/nowhere/Targets.fmf"), name: "Targets", isStaff: false, uids: [1])
        model.showShortlist(targets)
        model.finished(NewData(database(readOn: day(2029, 9, 22))), nil, automatic: true)
        XCTAssertEqual(model.status, AppModel.heldReadNote)
        XCTAssertTrue(model.idleStatus().hasPrefix(AppModel.heldReadNote), "Not overwritten by the shortlist's line")
        model.go(to: .players)
        XCTAssertTrue(model.idleStatus().hasPrefix(AppModel.heldReadNote), "Nor by the list's")
        model.useHeldRead()
        XCTAssertFalse(model.idleStatus().contains(AppModel.heldReadNote), "Gone once it's shown")

        let failing = database(readOn: day(2029, 9, 23))
        failing.checks = "FAIL: ages"
        model.finished(NewData(failing), nil, automatic: true)
        model.go(to: .shortlists)
        model.showShortlist(targets)
        XCTAssertTrue(model.idleStatus().hasPrefix("FM Starship's self-checks failed on this save (ages)"), model.idleStatus())
        XCTAssertTrue(model.idleStatus().contains("Shortlist \"Targets\""))
    }

    func testThePollsCostLeavesOutInstallingAHeldRead() {
        let model = model(readOn: day(2029, 9, 12))
        model.editingFilter = true
        let held = database(readOn: day(2029, 9, 22))
        model.finished(NewData(held), nil, automatic: true)
        model.editingFilter = false
        // Installing it is slow here, as a search on a full save is.
        model.sheetShown = { Thread.sleep(forTimeInterval: 0.05); return false }
        model.pollGame()
        XCTAssertTrue(model.database === held)
        XCTAssertLessThan(model.checkGameCost.worst, 0.05, "The plugin logs the poll's cost, not the install's")
        XCTAssertGreaterThanOrEqual(model.heldReadCost.worst, 0.05, "The install's goes in its own line")
        model.pollGame()
        XCTAssertNotNil(model.heldReadCost.take())
        XCTAssertNil(model.heldReadCost.take(), "Only polls that installed one count")
    }

    func testOnlyTheAppAndThePluginKeepDevelopmentSnapshots() {
        XCTAssertNil(AppModel().developmentStore, "A model a test makes never writes to the player's Application Support")
    }

    func testTheWarningSaysNobodyIsKnownToWantToCome() {
        let base = "FM couldn't be asked who would join, so nobody in this list is known to want to come."
        let progress = SaveProgress(readOn: day(2029, 9, 12), now: day(2029, 9, 22))
        XCTAssertEqual(SaveProgress.joinWarning(nil, canReload: true), base + " Press Load Save to try again.")
        XCTAssertEqual(SaveProgress.joinWarning(progress, canReload: true),
                       base + " FM has moved on to 22 Sep 2029 since your save was read. Press Load Save to read it again.")
        // A snapshot, or a build with FM's rules off: Load Save can't help.
        XCTAssertEqual(SaveProgress.joinWarning(nil, canReload: false), base)
        XCTAssertEqual(SaveProgress.joinWarning(progress, canReload: false), base)
    }

    func testWithoutTheLiveGameTheWarningDoesntSendYouToLoadSave() {
        XCTAssertNil(GameRules.engine)
        let model = model(readOn: day(2029, 9, 12))
        XCTAssertEqual(model.joinWarning, "FM couldn't be asked who would join, so nobody in this list is known to want to come.")
    }
}
