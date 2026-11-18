@testable import FMStarshipUI
import StarshipSearch
import XCTest

/// The app looks for shortlists everywhere FM keeps them; only inside FM is it held to ~/Library.
@MainActor
final class ShortlistRootsTests: XCTestCase {
    func testTheAppLooksEverywhere() {
        let saved = Settings.current
        defer { Settings.current = saved }
        Settings.current = Settings()
        XCTAssertFalse(AppModel.isInsideGame)
        XCTAssertNil(AppModel().shortlistRoots)
    }
}
