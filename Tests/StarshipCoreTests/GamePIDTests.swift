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
}
