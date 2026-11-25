@testable import StarshipCore
import XCTest

/// FM's game date read again where the read found it, as the app's poll does to notice the save moving on. Made-up
/// TRANSFER_MANAGER records in test memory stand in for FM's.
final class GameDateFollowTests: XCTestCase {
    private func transferManager(_ game: FakeGame, year: Int, dayOfYear: Int) -> Int64 {
        let record = game.record("TransferManager", size: MacLayout.gameDate + 8)
        record.set("dayOfYear", MacLayout.gameDate, UInt16(dayOfYear))
        record.set("year", MacLayout.gameDate + 2, UInt16(year))
        return record.address
    }

    func testReadsTheLatestDateWhereTheReadFoundIt() {
        let game = FakeGame()
        let database = Database()
        let earlier = transferManager(game, year: 2029, dayOfYear: 255)
        let today = transferManager(game, year: 2029, dayOfYear: 265)
        // Zeroed, as memory FM has let go of: no date in it.
        let gone = game.record("TransferManager", size: MacLayout.gameDate + 8).address
        database.dateRecords = [earlier, today, gone]
        XCTAssertEqual(GameReader.gameDate(of: database, in: game.process()), GameDate.checked(year: 2029, dayOfYear: 265))
    }

    func testNoDateWhenNothingHoldsOne() {
        let game = FakeGame()
        let database = Database()
        XCTAssertNil(GameReader.gameDate(of: database, in: game.process()), "The read found no records")
        database.dateRecords = [0, game.record("TransferManager", size: MacLayout.gameDate + 8).address]
        XCTAssertNil(GameReader.gameDate(of: database, in: game.process()), "Nothing there holds a date now")
    }
}
