import StarshipCore
@testable import StarshipSearch
import XCTest

/// The Attributes tab's rules: eight rows to start with, "Add a rule" up to twenty, and back to eight on a reset.
final class AttributeRulesTests: XCTestCase {
    /// A player whose hidden attributes and personality numbers are all 4, and whose others are all 18.
    private func player() -> Player {
        let player = Player()
        player.block = 1
        player.raw = [UInt8](repeating: 90, count: player.raw.count)
        for name in Names.hidden { player.raw[Names.playerIndex[name]!] = 20 }
        for name in Names.personality { player.pers[Names.personalityIndex[name]!] = 4 }
        return player
    }

    private func playerFilter(hidden: Bool) -> PlayerFilter {
        var filter = PlayerFilter(showHidden: hidden, showAbility: hidden)
        filter.ratingAtLeast = ""
        filter.markDefaults()
        return filter
    }

    private func rule(_ attribute: String, atLeast: Bool = true, _ value: String) -> AttrRule {
        var rule = AttrRule()
        rule.attribute = attribute
        rule.atLeast = atLeast
        rule.value = value
        return rule
    }

    func testAFilterStartsWithEightRulesAndAddsUpToTwenty() {
        var filter = playerFilter(hidden: false)
        XCTAssertEqual(filter.rules.count, 8)
        XCTAssertEqual(StaffFilter(showHidden: false, showAbility: false).rules.count, 8)

        for _ in 0..<30 { filter.addRule() }
        XCTAssertEqual(filter.rules.count, 20)
        XCTAssertFalse(filter.canAddRule)
        XCTAssertFalse(filter.isActive(tab: "Attributes"), "Blank rows filter nothing")

        // Every row has a field in the section, so the window can draw it and the tab's "●" can see it.
        XCTAssertEqual(PlayerFilter.sections.first { $0.title == "Attributes" }?.fields.count, 20)
        XCTAssertEqual(StaffFilter.sections.first { $0.title == "Attributes" }?.fields.count, 20)
    }

    func testAnAddedRuleFiltersAndMarksTheTab() {
        var filter = playerFilter(hidden: false)
        while filter.rules.count < 16 { filter.addRule() }
        XCTAssertTrue(filter.matches(player()))

        filter.rules[15] = rule("Finishing", "19")
        XCTAssertFalse(filter.matches(player()))
        XCTAssertTrue(filter.describe().contains("Finishing 19+"))
        XCTAssertTrue(filter.isActive(tab: "Attributes"))

        filter.rules[15].value = "18"
        XCTAssertTrue(filter.matches(player()))
    }

    func testResetGoesBackToEightRows() {
        var filter = playerFilter(hidden: false)
        while filter.rules.count < 12 { filter.addRule() }
        filter.rules[2] = rule("Finishing", "19")
        filter.rules[11] = rule("Pace", "19")

        filter.reset(tab: "Attributes")
        XCTAssertEqual(filter.rules.count, 8)
        XCTAssertTrue(filter.rules.allSatisfy { $0.attribute == AttrRule.noAttribute })
        XCTAssertFalse(filter.isActive(tab: "Attributes"))

        while filter.rules.count < 12 { filter.addRule() }
        filter.rules[11] = rule("Pace", "19")
        filter.reset()
        XCTAssertEqual(filter.rules.count, 8)
        XCTAssertTrue(filter.matches(player()))

        var staff = StaffFilter(showHidden: false, showAbility: false)
        while staff.rules.count < 12 { staff.addRule() }
        staff.reset()
        XCTAssertEqual(staff.rules.count, 8)
    }

    /// Eight rows with defaults for rule0 to rule7 only, built by hand: filters aren't saved anywhere, so this is the
    /// shape the code had before, not one a player can load. It still matches, marks the tab and resets.
    func testAnEightRowFilterBuiltByHandStillWorks() {
        var filter = playerFilter(hidden: false)
        filter.rules = [AttrRule](repeating: AttrRule(), count: 8)
        filter.defaults = filter.defaults.filter { key, _ in
            guard key.hasPrefix("rule"), let number = Int(key.dropFirst(4).prefix { $0.isNumber }) else { return true }
            return number < 8
        }
        filter.rules[7] = rule("Finishing", "19")
        XCTAssertFalse(filter.matches(player()))
        XCTAssertTrue(filter.isActive(tab: "Attributes"))

        // Cancel in the filter window puts back the copy it took, rows and all.
        let original = filter
        while filter.rules.count < 20 { filter.addRule() }
        filter.rules[19] = rule("Pace", "19")
        filter = original
        XCTAssertEqual(filter.rules.count, 8)
        XCTAssertEqual(filter.rules[7].attribute, "Finishing")

        filter.reset(tab: "Attributes")
        XCTAssertEqual(filter.rules.count, 8)
        XCTAssertEqual(filter.rules[7].attribute, AttrRule.noAttribute)
        XCTAssertTrue(filter.matches(player()))
    }

    /// Every row there can be has its defaults marked, so a rule in any of them lights the tab and Reset tab clears it.
    func testDefaultsCoverEveryRowThereCanBe() {
        let filter = playerFilter(hidden: false)
        for index in 0..<AttrRule.maxCount {
            XCTAssertTrue(filter.defaults.keys.contains { $0.hasPrefix("rule\(index).") }, "rule\(index)")
        }
    }

    func testARowPastTheEndIsSafe() {
        var filter = playerFilter(hidden: false)
        for index in [-1, 8, 20, 1000] { XCTAssertEqual(filter.rule(at: index), AttrRule()) }

        filter.setRule(-1, rule("Pace", "19"))
        filter.setRule(20, rule("Pace", "19"))
        filter.setRule(9, AttrRule())
        XCTAssertEqual(filter.rules.count, 8, "Out of range or blank sets add nothing")

        // The review's case: the window's last write to a row Reset tab has just removed, with a value in it.
        filter.updateRule(10, rule("Pace", "19"))
        filter.updateRule(-1, rule("Pace", "19"))
        XCTAssertEqual(filter.rules.count, 8, "The window's writes never add a row")
        XCTAssertFalse(filter.isActive(tab: "Attributes"))
        filter.updateRule(3, rule("Pace", "19"))
        XCTAssertEqual(filter.rules[3].attribute, "Pace", "A row it has is changed as before")

        // Defaults holding a rule the filter no longer has a row for put the row back.
        filter.defaults["rule12.attr"] = "Pace"
        filter.defaults["rule12.value"] = "19"
        filter.reset(tab: "Attributes")
        XCTAssertEqual(filter.rules.count, 13)
        XCTAssertEqual(filter.rules[12].attribute, "Pace")
    }

    func testHiddenOffDropsAHiddenRuleAtAnyRow() {
        let weak = player()
        for index in [0, 7, 8, 13, 19] {
            for name in Names.hidden + Names.personality {
                let lowerIsBetter = name == "Injury Proneness" || name == "Dirtiness" || name == "Controversy"
                let hiddenRule = rule(name, atLeast: !lowerIsBetter, lowerIsBetter ? "2" : "15")

                var on = playerFilter(hidden: true)
                on.setRule(index, hiddenRule)
                XCTAssertEqual(on.rule(at: index).attribute, name)
                XCTAssertFalse(on.matches(weak), "A rule on \(name) in row \(index) filters while on")

                // Set while off, as a restored filter could be.
                var off = playerFilter(hidden: false)
                off.setRule(index, hiddenRule)
                XCTAssertTrue(off.matches(weak), "A rule on \(name) in row \(index) does nothing while off")
                XCTAssertFalse(off.describe().contains(name))

                on.showHidden = false
                XCTAssertEqual(on.rule(at: index).attribute, AttrRule.noAttribute, "\(name) in row \(index)")
                XCTAssertTrue(on.matches(weak))
            }

            var staff = StaffFilter(showHidden: true, showAbility: true)
            staff.setRule(index, rule(Names.personality[1], "15"))
            staff.showHidden = false
            XCTAssertEqual(staff.rule(at: index).attribute, AttrRule.noAttribute, "Staff row \(index)")
        }
    }
}
