import StarshipCore
@testable import StarshipSearch
import XCTest

/// Cancel in the filter window puts back the filter as it was when the window opened. Inside FM, FM Starship's tab can switch
/// Hidden attributes or Ability off while the window is open, and Cancel mustn't bring back what that switched off.
final class FilterCancelTests: XCTestCase {
    private func player(ca: Int, consistency: Int) -> Player {
        let player = Player()
        player.block = 1
        player.ca = ca
        player.raw = [UInt8](repeating: 90, count: player.raw.count)
        player.raw[Names.playerIndex["Consistency"]!] = UInt8(consistency)
        player.prepare()
        return player
    }

    private func rule(_ attribute: String, _ value: String) -> AttrRule {
        var rule = AttrRule()
        rule.attribute = attribute
        rule.value = value
        return rule
    }

    func testCancelKeepsHiddenAttributesAndAbilityAsTheyAreNow() {
        var original = PlayerFilter(showHidden: true, showAbility: true)
        original.rules[0] = rule("Consistency", "15")
        original.caMin = "150"
        let weak = player(ca: 100, consistency: 2)
        XCTAssertFalse(original.matches(weak), "Both rules filter while they're on")

        var now = original
        now.rules[1] = rule("Finishing", "19")
        now.showHidden = false
        now.showAbility = false

        let restored = now.restoring(original)
        XCTAssertFalse(restored.showHidden)
        XCTAssertFalse(restored.showAbility)
        XCTAssertEqual(restored.rules[0].attribute, AttrRule.noAttribute, "The hidden rule stays dropped")
        XCTAssertEqual(restored.rules[1].attribute, AttrRule.noAttribute, "The change made in the window is undone")
        XCTAssertEqual(restored.caMin, "150", "Kept as typed, but it filters nothing while Ability is off")
        XCTAssertTrue(restored.matches(weak))
        XCTAssertFalse(restored.describe().contains("Consistency"))
    }

    func testCancelWithNothingSwitchedIsTheOriginal() {
        var original = StaffFilter(showHidden: true, showAbility: true)
        original.rules[0] = rule(Names.personality[1], "15")
        var now = original
        now.rules[0] = AttrRule()
        XCTAssertEqual(now.restoring(original), original)
    }
}
