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

    /// A model with a save read on `readOn`, as Load Save leaves it. Settings aren't loaded in tests, so nothing is written.
    private func model(readOn: Date?) -> AppModel {
        let model = AppModel()
        let database = Database()
        database.gameDate = readOn
        model.database = database
        return model
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
        XCTAssertEqual(progress?.notice, "Your save is on 22 Sep 2029; this was read on 12 Sep. Load Save to read it again.")
        let newYear = SaveProgress(readOn: day(2028, 12, 28), now: day(2029, 1, 3))
        XCTAssertEqual(newYear?.notice, "Your save is on 3 Jan 2029; this was read on 28 Dec 2028. Load Save to read it again.")
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
        model.saveDateSeen(day(2029, 9, 22))
        XCTAssertTrue(model.takeReadOnShow())
        XCTAssertFalse(model.takeReadOnShow(), "Not again for the same day, so a read that fails isn't started over and over")
        model.saveDateSeen(day(2029, 9, 23))
        model.loading = true
        XCTAssertFalse(model.takeReadOnShow(), "Not while a read is going on")
        model.loading = false
        XCTAssertTrue(model.takeReadOnShow(), "Once more for the next day")
    }

    func testTheWarningSaysNobodyIsKnownToWantToCome() {
        XCTAssertEqual(SaveProgress.joinWarning(nil),
                       "FM couldn't be asked who would join, so nobody in this list is known to want to come. Load Save to try again.")
        XCTAssertEqual(SaveProgress.joinWarning(SaveProgress(readOn: day(2029, 9, 12), now: day(2029, 9, 22))),
                       "FM couldn't be asked who would join, so nobody in this list is known to want to come. Your save has moved on to 22 Sep 2029 since it was read: Load Save to read it again.")
    }
}
