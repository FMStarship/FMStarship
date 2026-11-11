@testable import StarshipPlugin
import StarshipAnalysis
import StarshipCore
import XCTest

/// CA and PA in Stars mode as FM's own star graphic: which stars it shows for our values, on our scale where CA 200 is
/// five stars, and which of our columns get it. Drawing it needs FM; none of this does.
@MainActor
final class NativeStarsTests: XCTestCase {
    override func tearDown() {
        FMTable.nativeStars = false
        FMTable.starsFailed = false
        super.tearDown()
    }

    private func players() -> [Person] {
        [(200, 200), (153, 171), (117, 140), (0, 45)].enumerated().map { index, ability in
            let player = Player()
            player.uid = UInt32(index + 1)
            player.index = UInt32(index + 1)
            player.commonName = "Player \(index + 1)"
            player.ca = ability.0
            player.pa = ability.1
            return player
        }
    }

    /// CA and PA as FM's table gets them from the Players screen, with Ability set to `reveal`.
    private func extras(_ reveal: AbilityReveal) -> [FMTable.Extra] {
        let list = PeopleListView(people: players(), staff: false, filter: "", display: DisplayOptions(reveal: reveal, showHidden: reveal != .hidden))
        return FMTable.extras(from: list.table, titles: ["CA", "PA"])
    }

    func testHalfStarsAreReadFromWhatStarsModeShows() {
        XCTAssertEqual(FMElements.halfStars("3.5★"), 7)
        XCTAssertEqual(FMElements.halfStars("0.0★"), 0)
        XCTAssertEqual(FMElements.halfStars("5.0★"), 10)
        for text in ["153", "", "★", "-0.5★", "5.5★", "3,5★", "3.5", "nan★", "inf★", "1e1★", "3.5★ "] {
            XCTAssertNil(FMElements.halfStars(text), "\(text) isn't a number of stars")
        }
    }

    func testOurScaleHasCA200AsFiveStars() {
        let display = DisplayOptions(reveal: .stars, showHidden: true)
        XCTAssertEqual(FMElements.halfStars(display.ability(200)), 10)
        XCTAssertEqual(FMElements.halfStars(display.ability(117)), 6, "3.0★, as the app shows CA 117")
        XCTAssertEqual(FMElements.halfStars(display.ability(0)), 0)
        var last = 0
        for ability in 0...200 {
            let text = display.ability(ability)
            guard let halves = FMElements.halfStars(text) else { return XCTFail("\(ability) shows as \(text)") }
            // The same number of stars the text says, never more.
            XCTAssertEqual(Double(halves) / 2, Double(text.dropLast()), "\(ability)")
            XCTAssertTrue((last...last + 1).contains(halves), "\(ability): stars only go up, half a star at a time")
            last = halves
        }
    }

    func testEachStarIsGoldHalfOrEmptyAsFMsOwnCellsDrawThem() {
        // FM's own Ability column with 3.5 stars, as the plugin's table dump wrote it out from FM.
        XCTAssertEqual(FMElements.starClasses(7), [
            ["ability-max-potential-level-fullfilled-youth-false", "fm-star-rating-star"],
            ["ability-max-potential-level-fullfilled-youth-false", "fm-star-rating-star"],
            ["ability-max-potential-level-fullfilled-youth-false", "fm-star-rating-star"],
            ["ability-half-potential-level-none-youth-false", "fm-star-rating-star"],
            ["ability-minimum-potential-level-none-youth-false", "fm-star-rating-star-no-margin"],
        ])
        XCTAssertEqual(FMElements.starRating, "fm-star-rating-container")
        XCTAssertEqual(FMElements.starClasses(1)[0], [FMElements.halfStar, FMElements.starGap])
        XCTAssertTrue(FMElements.starClasses(0).allSatisfy { $0.contains(FMElements.emptyStar) })
        XCTAssertTrue(FMElements.starClasses(10).allSatisfy { $0.contains(FMElements.goldStar) })
        for halves in 0...10 {
            let stars = FMElements.starClasses(halves)
            XCTAssertEqual(stars.map(\.count), [2, 2, 2, 2, 2], "A fill and a gap for each of five")
            let gold = stars.filter { $0.contains(FMElements.goldStar) }.count * 2 + stars.filter { $0.contains(FMElements.halfStar) }.count
            XCTAssertEqual(gold, halves)
        }
    }

    func testOnlyCAAndPAInStarsModeGetFMsStarsOnceSwitchedOn() {
        let stars = extras(.stars)
        XCTAssertEqual(stars.map(\.host), ["hidden-current-ability", "hidden-potential-ability"])
        XCTAssertEqual(stars[0].values[2], "4.0★")
        XCTAssertFalse(stars.contains(where: FMTable.showsStars), "Text until the developer command turns them on")
        FMTable.nativeStars = true
        XCTAssertTrue(stars.allSatisfy(FMTable.showsStars))
        XCTAssertFalse(extras(.numbers).contains(where: FMTable.showsStars), "Exact numbers stay numbers")
        let ownColumn = FMTable.Extra(host: FMTable.ownID("Value"), title: "Value", values: [1: "4.0★"])
        XCTAssertFalse(FMTable.showsStars(ownColumn), "Only FM's CA and PA columns")
        FMTable.starsFailed = true
        XCTAssertFalse(stars.contains(where: FMTable.showsStars), "Text again once FM's stars have failed")
    }

    func testWithHiddenAttributesOffThereAreNoStars() {
        FMTable.nativeStars = true
        XCTAssertTrue(extras(.hidden).isEmpty, "CA and PA are gone, not shown as empty stars")
    }

    func testStarsSortByStarsWithTiesInTheEnginesOrder() {
        let people = players()
        let ca = extras(.stars)[0]
        XCTAssertEqual(FMTable.sorted(people, by: ca, descending: true).map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(FMTable.sorted(people, by: ca, descending: false).map(\.index), [4, 3, 2, 1])
        // Two at 4.0★ keep the engine's order either way, rather than give away which has the higher CA.
        let tied = FMTable.Extra(host: "hidden-current-ability", title: nil, values: [1: "4.0★", 2: "4.0★", 3: "3.5★"])
        XCTAssertEqual(FMTable.sorted(Array(people.prefix(3)), by: tied, descending: true).map(\.index), [1, 2, 3])
        XCTAssertEqual(FMTable.sorted(Array(people.prefix(3)), by: tied, descending: false).map(\.index), [3, 1, 2])
    }

    func testStarColumnsAreAsWideAsFMsOwn() {
        // FM lays five of its stars out 73 wide, and its cells keep 4 to the left of them.
        XCTAssertGreaterThanOrEqual(FMTable.starsWidth, 77)
    }
}
