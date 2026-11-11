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
        for text in ["153", "", "-0.5★", "5.5★", "3,5★", "3.5", "nan★", "inf★", "1e1★", "3.5★ "] {
            XCTAssertNil(FMElements.halfStars(text), "\(text) isn't a number of stars")
        }
        // An average, such as the tactics' role stars, is between FM's half stars, so it stays text.
        XCTAssertNil(FMElements.halfStars("3.45★"))
    }

    func testHalfStarsAreReadFromARolesStars() {
        XCTAssertEqual(FMElements.halfStars("★★★½"), 7)
        XCTAssertEqual(FMElements.halfStars("★"), 2)
        XCTAssertEqual(FMElements.halfStars("½"), 1)
        XCTAssertEqual(FMElements.halfStars("★★★★★"), 10)
        // Every role's stars as the engine writes them, half a star to five.
        for halves in 1...10 {
            XCTAssertEqual(FMElements.halfStars(RoleBook.stars(halves)), halves, RoleBook.stars(halves))
        }
        // A role FM gives no stars is a dash, which stays a dash.
        XCTAssertNil(FMElements.halfStars(RoleBook.stars(0)))
        for text in ["★★★★★½", "★★★★★★", "½★", "★½★", "½½", "★★★ ", "Here: Inside Full-Back ★★★½", "Berg ★★★", "+0.5★", "-1★"] {
            XCTAssertNil(FMElements.halfStars(text), "\(text) isn't a role's stars")
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
        let ownColumn = FMTable.Extra(host: FMTable.ownID("Value"), title: "Value", values: [1: "4.0★", 2: "£4.5M"])
        XCTAssertFalse(FMTable.showsStars(ownColumn), "One of our columns only with nothing but stars in it")
        FMTable.starsFailed = true
        XCTAssertFalse(stars.contains(where: FMTable.showsStars), "Text again once FM's stars have failed")
    }

    /// The Squad planner's first team inside FM, as the engine makes it, in Stars mode.
    private func firstTeam(_ people: [Person]) -> [FMTable.Extra] {
        let cells = [["GK", "Goalkeeper", "Goalkeeper", "Abel", "★★★½", "3.5★", "Here: Goalkeeper ★★★½", "Berg ★★", "1 / 2", "Fine", ""],
                     ["DR", "Inside Full-Back", "Full-Back", "Berg", "★★★★", "3.0★", "Here: Inside Full-Back ★★★★", "Nobody", "1 / 2", "Watch", "Thin"],
                     ["DC", "Centre-Back", "Centre-Back", "Carr", "-", "2.5★", "", "", "2 / 4", "Fine", ""],
                     ["ST", "Poacher", "Poacher", "nobody picked", "", "", "", "", "0 / 2", "Gap", "Nobody"]]
        let table = AnalysisTable(columns: SquadPlanner.slotColumns, rows: zip(cells, people).map { TableRow(cells: $0, person: $1) })
        let layout = FMTable.layout(of: table, fm: ["Player": "name", "Best": "name"])
        return FMTable.extras(from: table, titles: layout.extras)
    }

    func testTheRoleColumnGetsFMsStarsAndBestFitStaysText() {
        let extras = firstTeam(players())
        let role = extras.first { $0.title == "Role" }
        XCTAssertEqual(role?.host, "fmstarship-role")
        XCTAssertEqual(role?.values[1], "★★★½")
        XCTAssertFalse(extras.contains(where: FMTable.showsStars), "Text until the developer command turns them on")
        FMTable.nativeStars = true
        XCTAssertEqual(extras.filter(FMTable.showsStars).map(\.host), ["fmstarship-role", "hidden-current-ability"],
                       "The role's stars and CA; a dash and no player stay text in their cells")
        XCTAssertEqual(extras.filter(FMTable.holdsStars).map(\.host), ["fmstarship-role", "hidden-current-ability"])
        for title in ["Best fit", "Cover", "Have / want", "Status", "What's missing", "With the ball"] {
            let extra = extras.first { $0.title == title }
            XCTAssertNotNil(extra, title)
            XCTAssertFalse(extra.map(FMTable.showsStars) ?? true, "\(title) stays text")
        }
        FMTable.starsFailed = true
        XCTAssertFalse(extras.contains(where: FMTable.showsStars), "Text again once FM's stars have failed")
    }

    func testTheRoleColumnSortsByStarsWithNoneBelowHalfAStar() {
        let people = (1...6).map { index -> Person in
            let person = Person()
            person.index = UInt32(index)
            return person
        }
        let role = FMTable.Extra(host: FMTable.ownID("Role"), title: "Role",
                                 values: [1: "★★★½", 2: "★★★★", 3: "-", 4: "", 5: "½", 6: "★★★★★"])
        XCTAssertEqual(FMTable.sorted(people, by: role, descending: true).map(\.index), [6, 2, 1, 5, 3, 4])
        XCTAssertEqual(FMTable.sorted(people, by: role, descending: false).map(\.index), [3, 5, 1, 2, 6, 4])
    }

    func testCAAndPAAreCalledAbilityAndPotentialInStarsModeAsFMsStarColumnsAre() {
        XCTAssertEqual(extras(.stars).map(\.heading), ["Ability", "Potential"])
        XCTAssertEqual(extras(.stars).map(\.title), [nil, nil], "Still FM's own columns for them")
        XCTAssertEqual(extras(.numbers).map(\.heading), [nil, nil], "FM's CA and PA in Exact")
        XCTAssertTrue(extras(.hidden).isEmpty)
        // Without the developer command too: the heading goes with Stars mode, not with FM's star graphic.
        XCTAssertFalse(FMTable.nativeStars)
        // Our own columns keep their own titles, and get no heading of FM's.
        XCTAssertTrue(firstTeam(players()).filter { $0.title != nil }.allSatisfy { $0.heading == nil })
        // Wide enough for "Potential".
        XCTAssertGreaterThanOrEqual(extras(.stars)[1].width, Float("Potential".count) * 7 + 24)
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

    func testStarsTooNarrowAskForMoreRoomOnceAndNoMoreThanTwoAndAHalfTimes() {
        // 81 needed in a 68 cell: about 1.21 times as wide.
        let wider = FMTable.widen(by: 1, need: 81, got: 68)
        XCTAssertNotNil(wider)
        XCTAssertGreaterThan(wider ?? 0, 1.19)
        XCTAssertLessThan(wider ?? 9, 1.25)
        XCTAssertNil(FMTable.widen(by: 1, need: 81, got: 90), "They fit")
        XCTAssertEqual(FMTable.widen(by: 2.4, need: 81, got: 20), 2.5)
        XCTAssertNil(FMTable.widen(by: 2.5, need: 81, got: 20), "As far as it goes")
        XCTAssertNil(FMTable.widen(by: 1, need: 81, got: 0))
        XCTAssertNil(FMTable.widen(by: 1, need: .nan, got: 68))
    }
}
