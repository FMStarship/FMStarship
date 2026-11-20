@testable import FMStarshipUI
import StarshipFiles
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

    func testInsideFMOnlyFMsOwnFolderIsLookedIn() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let roots = AppModel.shortlistRoots(insideGame: true, home: home)
        XCTAssertEqual(roots, ShortlistFile.fmFolderRoots(home: home))
        XCTAssertFalse(roots?.contains { $0.path.contains("/Documents/") } ?? true)
        XCTAssertNil(AppModel.shortlistRoots(insideGame: false, home: home))
    }
}
