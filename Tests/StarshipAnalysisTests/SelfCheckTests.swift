@testable import StarshipCore
import XCTest

/// A failed self-check has to reach the screen, so what it found has to come back out of `checks`.
final class SelfCheckTests: XCTestCase {
    private func healthyRead() -> Database {
        let db = Database()
        db.players = (1...1000).map { uid in
            let player = Player()
            player.uid = UInt32(uid)
            player.commonName = "Player \(uid)"
            player.club = "Testing FC"
            player.ca = 100
            player.pa = 120
            return player
        }
        return db
    }

    func testAReadThatPassesHasNothingToSay() {
        let db = healthyRead()
        db.checks = GameReader.selfCheck(db)
        XCTAssertEqual(db.checks, "PASS")
        XCTAssertNil(db.checkProblems)
    }

    func testAFailedCheckSaysWhatItFound() {
        let db = healthyRead()
        db.players[0].pa = 50
        db.checks = GameReader.selfCheck(db)
        XCTAssertEqual(db.checkProblems, "PA below CA")
    }

    func testAnUncheckedDatabaseHasNothingToSay() {
        XCTAssertNil(Database().checkProblems)
    }
}
