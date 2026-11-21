import StarshipCore
import StarshipSearch
import XCTest

final class GenderFilterTests: XCTestCase {
    private func player(woman: Bool) -> Player {
        let player = Player()
        player.block = 1
        player.isWoman = woman
        return player
    }

    func testTheFilterKeepsOneSideOrBoth() {
        var filter = PlayerFilter(showHidden: true, showAbility: true)
        filter.ratingAtLeast = ""
        XCTAssertTrue(filter.matches(player(woman: false)))
        XCTAssertTrue(filter.matches(player(woman: true)))
        filter.gender = "Men"
        XCTAssertTrue(filter.matches(player(woman: false)))
        XCTAssertFalse(filter.matches(player(woman: true)))
        XCTAssertTrue(filter.describe().contains("Men"))
        filter.gender = "Women"
        XCTAssertFalse(filter.matches(player(woman: false)))
        XCTAssertTrue(filter.matches(player(woman: true)))
        filter.reset()
        XCTAssertEqual(filter.gender, "Any")
    }

    // MARK: Your club's side

    /// The Players search's filter, with Hidden attributes on or off, which "Men or women" doesn't care about.
    private func ownSide(hidden: Bool) -> PlayerFilter {
        var filter = PlayerFilter(showHidden: hidden, showAbility: hidden, gender: PlayerFilter.ownSide)
        filter.ratingAtLeast = ""
        filter.markDefaults()
        return filter
    }

    func testYourClubsSideKeepsTheSideTheClubSignsFrom() {
        for hidden in [false, true] {
            let filter = ownSide(hidden: hidden)
            XCTAssertEqual(filter.gender, PlayerFilter.ownSide)
            // A men's club.
            XCTAssertTrue(filter.matches(player(woman: false), clubSignsWomen: false))
            XCTAssertFalse(filter.matches(player(woman: true), clubSignsWomen: false), "A men's club leaves out women")
            // A women's club.
            XCTAssertFalse(filter.matches(player(woman: false), clubSignsWomen: true), "A women's club leaves out men")
            XCTAssertTrue(filter.matches(player(woman: true), clubSignsWomen: true))
            // No club, or a save that doesn't say.
            XCTAssertTrue(filter.matches(player(woman: false)))
            XCTAssertTrue(filter.matches(player(woman: true)), "Unknown sides filter nothing")
        }
    }

    func testTheOtherChoicesIgnoreTheClub() {
        var filter = ownSide(hidden: true)
        filter.gender = "Any"
        for side in [false, true] {
            XCTAssertTrue(filter.matches(player(woman: false), clubSignsWomen: side))
            XCTAssertTrue(filter.matches(player(woman: true), clubSignsWomen: side), "Any shows both")
        }
        filter.gender = "Women"
        XCTAssertFalse(filter.matches(player(woman: false), clubSignsWomen: false))
        XCTAssertTrue(filter.matches(player(woman: true), clubSignsWomen: false), "Women is women, whatever the club")
        filter.gender = "Men"
        XCTAssertTrue(filter.matches(player(woman: false), clubSignsWomen: true))
        XCTAssertFalse(filter.matches(player(woman: true), clubSignsWomen: true))
    }

    func testResetGoesBackToWhereTheFilterStarted() throws {
        var filter = ownSide(hidden: false)
        filter.gender = "Any"
        filter.reset()
        XCTAssertEqual(filter.gender, PlayerFilter.ownSide)
        filter.gender = "Women"
        filter.reset(tab: "General")
        XCTAssertEqual(filter.gender, PlayerFilter.ownSide, "Reset this tab too")
        filter.gender = "Men"
        filter.reset(section: try XCTUnwrap(PlayerFilter.sections.first { $0.title == "Basics" }))
        XCTAssertEqual(filter.gender, PlayerFilter.ownSide)

        var plain = PlayerFilter(showHidden: false, showAbility: false)
        plain.gender = PlayerFilter.ownSide
        plain.reset()
        XCTAssertEqual(plain.gender, "Any", "A filter that starts on Any goes back to Any")
    }

    /// As the default it isn't a filter anyone set, so the summary and the "●" leave it out; chosen, it's said plainly.
    func testTheSummaryOnlyMentionsItWhenItIsntTheDefault() throws {
        let basics = try XCTUnwrap(PlayerFilter.sections.first { $0.title == "Basics" })
        for hidden in [false, true] {
            var filter = ownSide(hidden: hidden)
            XCTAssertEqual(filter.describe(), "")
            XCTAssertFalse(filter.isActive(basics))
            XCTAssertFalse(filter.isActive(tab: "General"))
            filter.gender = "Any"
            XCTAssertEqual(filter.describe(), "men and women")
            XCTAssertTrue(filter.isActive(basics))
            filter.gender = "Women"
            XCTAssertEqual(filter.describe(), "Women")
            filter.ageMax = "21"
            filter.gender = PlayerFilter.ownSide
            XCTAssertEqual(filter.describe(), "age up to 21")
            XCTAssertEqual(filter.describe(clubSignsWomen: false), "age up to 21")
            XCTAssertEqual(filter.describe(clubSignsWomen: false, sayingSide: true), "men's players, age up to 21")
            XCTAssertEqual(filter.describe(clubSignsWomen: true, sayingSide: true), "women's players, age up to 21")
            XCTAssertEqual(filter.describe(clubSignsWomen: nil, sayingSide: true), "age up to 21",
                           "With the side unknown it keeps both, so there's nothing to say")
        }
        var plain = PlayerFilter(showHidden: true, showAbility: true)
        plain.ratingAtLeast = ""
        plain.markDefaults()
        XCTAssertEqual(plain.describe(), "")
        plain.gender = PlayerFilter.ownSide
        XCTAssertEqual(plain.describe(clubSignsWomen: false), "men's players")
        XCTAssertEqual(plain.describe(clubSignsWomen: true), "women's players")
        XCTAssertEqual(plain.describe(), "", "Chosen with the side unknown, it keeps both")
        XCTAssertTrue(plain.isActive(basics))
    }
}
