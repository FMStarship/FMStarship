@testable import FMStarshipUI
import XCTest

final class SeasonScopeTests: XCTestCase {
    /// Checked in FM 27.1.0 on 20 Nov 2026: a player FM shows with six Champions League matches and no cup matches has six
    /// in scope 3 and none in scope 2.
    func testTheCupAndContinentalTabsReadFMsOwnScopes() {
        let scopes = Dictionary(uniqueKeysWithValues: ProfileFacts.scopes.map { ($0.1, $0.0) })
        XCTAssertEqual(scopes["Cup"], 2)
        XCTAssertEqual(scopes["Continental"], 3)
        XCTAssertEqual(scopes["League"], 1)
    }

    /// Checked the same day: FM showed 6 internationals this season for a player whose scope 4 gave 8 and scope 7 gave 4.
    func testInternationalsAreLeftOutSinceNeitherScopeMatchesFM() {
        XCTAssertFalse(ProfileFacts.scopes.contains { $0.0 == 4 || $0.0 == 7 || $0.1 == "International" })
    }
}
