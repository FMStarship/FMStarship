@testable import StarshipPlugin
import XCTest

/// The Hidden attributes switch in FM Starship's tab and the eye in its window set the same setting, and each shows
/// what the other did. Which of them moved is told from what the switch was last set to, which doesn't need FM.
final class HiddenSwitchTests: XCTestCase {
    private func agreed(switch value: Bool?, setting: Bool, shown: Bool) -> Bool {
        FMInterface.hiddenAttributes(switch: value, setting: setting, shown: shown)
    }

    func testNothingMovedChangesNothing() {
        for on in [false, true] { XCTAssertEqual(agreed(switch: on, setting: on, shown: on), on) }
    }

    func testFMsSwitchClickedSoTheSettingFollowsIt() {
        XCTAssertTrue(agreed(switch: true, setting: false, shown: false), "Switched on in FM's tab")
        XCTAssertFalse(agreed(switch: false, setting: true, shown: true), "Switched off in FM's tab: off means gone")
    }

    func testTheEyeChangedTheSettingSoTheSwitchFollowsIt() {
        XCTAssertTrue(agreed(switch: false, setting: true, shown: false))
        XCTAssertFalse(agreed(switch: true, setting: false, shown: true))
    }

    func testBothMovedTheSameWay() {
        XCTAssertTrue(agreed(switch: true, setting: true, shown: false))
        XCTAssertFalse(agreed(switch: false, setting: false, shown: true))
    }

    func testASwitchThatCantBeReadChangesNothing() {
        XCTAssertFalse(agreed(switch: nil, setting: false, shown: false))
        XCTAssertTrue(agreed(switch: nil, setting: true, shown: true))
        XCTAssertTrue(agreed(switch: nil, setting: true, shown: false), "The eye's change still shows")
    }
}
