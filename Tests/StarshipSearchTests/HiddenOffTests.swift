import StarshipCore
@testable import StarshipSearch
import XCTest

/// The lists' side of Hidden attributes being off, beyond CA and PA: consistency, important matches, injury proneness,
/// the other hidden attributes and the personality numbers are gone from columns and filters. Off means gone. A member of
/// staff's Adaptability is the exception: FM shows it with their other attributes.
final class HiddenOffTests: XCTestCase {
    /// Every hidden attribute a rule can pick for players: the hidden ones and the personality numbers.
    private let hiddenPlayerAttributes = Names.hidden + Names.personality

    /// A player whose hidden attributes and personality numbers are all 4, and whose others are all 18.
    private func player() -> Player {
        let player = Player()
        player.block = 1
        player.raw = [UInt8](repeating: 90, count: player.raw.count)
        for name in Names.hidden { player.raw[Names.playerIndex[name]!] = 20 }
        for name in Names.personality { player.pers[Names.personalityIndex[name]!] = 4 }
        return player
    }

    private func staff() -> Staff {
        let staff = Staff()
        staff.block = 1
        staff.attr = [UInt8](repeating: 4, count: staff.attr.count)
        for name in Names.personality { staff.pers[Names.personalityIndex[name]!] = 4 }
        return staff
    }

    private func playerFilter(hidden: Bool) -> PlayerFilter {
        var filter = PlayerFilter(showHidden: hidden, showAbility: hidden)
        filter.ratingAtLeast = ""
        filter.markDefaults()
        return filter
    }

    private func staffFilter(hidden: Bool) -> StaffFilter {
        var filter = StaffFilter(showHidden: hidden, showAbility: hidden)
        filter.job = "Any job"
        filter.rank = StaffFilter.noRanking
        filter.markDefaults()
        return filter
    }

    // MARK: Columns

    func testEveryHiddenAttributeIsAHiddenColumn() {
        let players = Dictionary(uniqueKeysWithValues: Columns.forPlayers().map { ($0.name, $0) })
        for name in hiddenPlayerAttributes {
            XCTAssertEqual(players[name]?.hidden, true, "\(name) is a hidden player column")
        }
        let staff = Dictionary(uniqueKeysWithValues: Columns.forStaff().map { ($0.name, $0) })
        for name in Columns.hiddenStaffAttributes.filter({ !$0.hasPrefix("Unnamed") }) + Names.staffHiddenPersonality {
            XCTAssertEqual(staff[name]?.hidden, true, "\(name) is a hidden staff column")
        }
    }

    func testNoHiddenColumnCanBeShownWhileHiddenAttributesIsOff() {
        for (all, hiddenNames) in [(Columns.forPlayers(), hiddenPlayerAttributes), (Columns.forStaff(), Columns.hiddenStaffAttributes + Names.staffHiddenPersonality)] {
            var everyColumn = all
            for index in everyColumn.indices { everyColumn[index].visible = true }
            let shown = Columns.shown(everyColumn, showHidden: false, showAbility: false)
            XCTAssertFalse(shown.contains { $0.hidden || $0.ability }, shown.filter { $0.hidden || $0.ability }.map(\.name).joined(separator: ", "))
            XCTAssertFalse(all.contains { ($0.hidden || $0.ability) && Columns.allowed($0, showHidden: false, showAbility: false) })
            for name in hiddenNames { XCTAssertFalse(shown.contains { $0.name == name }, name) }
        }
    }

    // MARK: Player filters

    func testTheHiddenBoxesDoNothingWhileHiddenAttributesIsOff() {
        let weak = player()
        for (keyPath, typed, words) in [(\PlayerFilter.consistency, "15", "consistency"),
                                        (\PlayerFilter.importantMatches, "15", "imp. matches"),
                                        (\PlayerFilter.injuryProneness, "2", "inj. proneness")] {
            var on = playerFilter(hidden: true)
            on[keyPath: keyPath] = typed
            XCTAssertFalse(on.matches(weak), "\(words) filters while on")
            XCTAssertTrue(on.describe().contains(words))

            var off = playerFilter(hidden: false)
            off[keyPath: keyPath] = typed
            XCTAssertTrue(off.matches(weak), "\(words) does nothing while off")
            XCTAssertFalse(off.describe().contains(words))
            XCTAssertFalse(off.isActive(tab: "Attributes"), "No mark on the tab for a box that isn't there")

            // Switched off after typing, as the eye does.
            on.showHidden = false
            XCTAssertTrue(on.matches(weak), "\(words) does nothing once switched off")
        }
    }

    func testTheHiddenSectionGoesFromTheFilterWindow() {
        XCTAssertTrue(playerFilter(hidden: true).visibleSections(inTab: "Attributes").contains { $0.title == "Hidden" })
        XCTAssertFalse(playerFilter(hidden: false).visibleSections(inTab: "Attributes").contains { $0.title == "Hidden" })
    }

    func testARuleCantPickAHiddenAttributeWhileHiddenAttributesIsOff() {
        let choices = playerFilter(hidden: false).ruleChoices
        for name in hiddenPlayerAttributes { XCTAssertFalse(choices.contains(name), name) }
        let staffChoices = staffFilter(hidden: false).ruleChoices
        for name in Columns.hiddenStaffAttributes + Names.staffHiddenPersonality { XCTAssertFalse(staffChoices.contains(name), name) }
    }

    func testARuleOnAHiddenAttributeDoesNothingWhileHiddenAttributesIsOff() {
        let weak = player()
        for name in hiddenPlayerAttributes {
            let lowerIsBetter = name == "Injury Proneness" || name == "Dirtiness" || name == "Controversy"
            var rule = AttrRule()
            rule.attribute = name
            rule.atLeast = !lowerIsBetter
            rule.value = lowerIsBetter ? "2" : "15"

            var on = playerFilter(hidden: true)
            on.rules[0] = rule
            XCTAssertFalse(on.matches(weak), "A rule on \(name) filters while on")
            XCTAssertTrue(on.describe().contains(name))

            // Set while off, as a saved or restored filter could be.
            var off = playerFilter(hidden: false)
            off.rules[0] = rule
            XCTAssertTrue(off.matches(weak), "A rule on \(name) does nothing while off")
            XCTAssertFalse(off.describe().contains(name))

            // Switched off: the rule is dropped, not just ignored.
            on.showHidden = false
            XCTAssertEqual(on.rules[0].attribute, AttrRule.noAttribute, name)
            XCTAssertTrue(on.matches(weak))
        }
    }

    // MARK: Staff filters

    func testAStaffRuleOnAHiddenAttributeDoesNothingWhileHiddenAttributesIsOff() {
        let weak = staff()
        for name in Columns.hiddenStaffAttributes.filter({ !$0.hasPrefix("Unnamed") }) + Names.staffHiddenPersonality {
            var rule = AttrRule()
            rule.attribute = name
            rule.value = "15"

            var on = staffFilter(hidden: true)
            on.rules[0] = rule
            XCTAssertFalse(on.matches(weak), "A rule on \(name) filters while on")

            var off = staffFilter(hidden: false)
            off.rules[0] = rule
            XCTAssertTrue(off.matches(weak), "A rule on \(name) does nothing while off")
            XCTAssertFalse(off.describe().contains(name))

            on.showHidden = false
            XCTAssertEqual(on.rules[0].attribute, AttrRule.noAttribute, name)
        }
    }

    // MARK: Staff Adaptability

    /// FM shows a member of staff's Adaptability with Determination and the other staff attributes, so it's no hidden value
    /// for staff. A player's stays hidden.
    func testStaffAdaptabilityIsAShownStaffAttribute() throws {
        XCTAssertEqual(Names.staffHiddenPersonality, Names.personality.filter { $0 != "Adaptability" })

        let adaptability = try XCTUnwrap(Columns.forStaff().first { $0.name == "Adaptability" })
        XCTAssertFalse(adaptability.hidden)
        XCTAssertEqual(adaptability.group, "Attributes")
        XCTAssertEqual(Columns.forStaff().filter { $0.name == "Adaptability" }.count, 1, "One Adaptability column for staff")
        XCTAssertEqual(try XCTUnwrap(Columns.forPlayers().first { $0.name == "Adaptability" }).hidden, true)

        var everyColumn = Columns.forStaff()
        for index in everyColumn.indices { everyColumn[index].visible = true }
        XCTAssertTrue(Columns.shown(everyColumn, showHidden: false, showAbility: false).contains { $0.name == "Adaptability" })

        let someone = staff()
        someone.pers[Names.personalityIndex["Adaptability"]!] = 16
        XCTAssertEqual(someone.a("Adaptability"), 16, "Read from the personality bytes")
        XCTAssertEqual(adaptability.cell(someone, reveal: .hidden).text, "16")
    }

    func testAStaffRuleOnAdaptabilityWorksWhileHiddenAttributesIsOff() {
        XCTAssertTrue(staffFilter(hidden: false).ruleChoices.contains("Adaptability"))
        XCTAssertFalse(playerFilter(hidden: false).ruleChoices.contains("Adaptability"))

        let adaptable = staff()
        adaptable.pers[Names.personalityIndex["Adaptability"]!] = 16
        var rule = AttrRule()
        rule.attribute = "Adaptability"
        rule.value = "15"

        var off = staffFilter(hidden: false)
        off.rules[0] = rule
        XCTAssertFalse(off.matches(staff()), "A rule on staff Adaptability filters while off")
        XCTAssertTrue(off.matches(adaptable))
        XCTAssertTrue(off.describe().contains("Adaptability"))

        // Switching Hidden attributes off keeps it, as it does Determination.
        var on = staffFilter(hidden: true)
        on.rules[0] = rule
        on.showHidden = false
        XCTAssertEqual(on.rules[0].attribute, "Adaptability")
    }

    // MARK: Cells

    func testAnAbilityCellShowsNoNumberWhenRevealIsOff() throws {
        let ca = try XCTUnwrap(Columns.forPlayers().first { $0.name == "CA" })
        let someone = player()
        someone.ca = 151
        XCTAssertEqual(ca.cell(someone, reveal: .exact).text, "151")
        XCTAssertFalse(ca.cell(someone, reveal: .hidden).text.contains("151"))
    }
}
