import AppKit
@testable import StarshipPlugin
import XCTest

/// The arrow beside FM STARSHIP in FM's top bar opens a menu of FM Starship's screens, as FM's own tabs' arrows do.
/// What opens and closes it, where it goes and what it marks don't need FM.
final class TabMenuTests: XCTestCase {
    func testItListsTheScreensInTheOrderOfTheirSubtabs() {
        XCTAssertEqual(StarshipScreen.allCases.map(\.title),
                       ["Dashboard", "Recommended signings", "Squad planner", "Bargains", "Shortlists", "Players", "Staff"])
    }

    // MARK: Clicks

    private func click(open: Bool, onArrow: Bool = false, onMenu: Bool = false) -> FMInterface.TabMenuClick {
        FMInterface.tabMenuClick(open: open, onArrow: onArrow, onMenu: onMenu)
    }

    func testAClickOnTheArrowOpensItButNeverPinsOrClosesIt() {
        XCTAssertEqual(click(open: false, onArrow: true), .open)
        XCTAssertEqual(click(open: true, onArrow: true), .nothing, "The pointer is on the arrow, so the menu stays while it does")
    }

    func testAClickOutsideItClosesIt() {
        XCTAssertEqual(click(open: true), .close, "Anywhere else in FM, such as FM's Back, its tabs or its screen")
        XCTAssertEqual(click(open: false), .nothing, "With the menu closed, FM's clicks are FM's")
    }

    func testAClickOnItIsItsOwn() {
        XCTAssertEqual(click(open: true, onMenu: true), .nothing, "The row clicked chooses its screen")
    }

    func testEscapeClosesIt() {
        XCTAssertTrue(FMInterface.closesTabMenu(keyCode: 53, modifiers: []))
        XCTAssertTrue(FMInterface.closesTabMenu(keyCode: 53, modifiers: [.capsLock]), "Caps Lock isn't a modifier here")
        XCTAssertFalse(FMInterface.closesTabMenu(keyCode: 53, modifiers: [.command]), "Command-Escape stays FM's")
        XCTAssertFalse(FMInterface.closesTabMenu(keyCode: 36, modifiers: []), "Return stays FM's")
    }

    // MARK: Staying open

    func testFMMovingOnClosesIt() {
        let over = ["0x1 portal"]
        XCTAssertTrue(FMInterface.tabMenuStaysOpen(menuUp: true, tabUp: true, openedOver: over, now: over))
        XCTAssertFalse(FMInterface.tabMenuStaysOpen(menuUp: true, tabUp: true, openedOver: over, now: ["0x2 squad"]),
                       "FM went to another screen, such as with a key")
        XCTAssertFalse(FMInterface.tabMenuStaysOpen(menuUp: true, tabUp: true, openedOver: over, now: over + ["0x3 report"]),
                       "FM opened a report card over its screen")
    }

    func testLosingTheTabOrTheMenuClosesIt() {
        XCTAssertFalse(FMInterface.tabMenuStaysOpen(menuUp: true, tabUp: false, openedOver: [], now: []), "FM built its bar again")
        XCTAssertFalse(FMInterface.tabMenuStaysOpen(menuUp: false, tabUp: true, openedOver: [], now: []), "FM took the menu out")
    }

    // MARK: What it marks

    func testItMarksTheScreenThatsUp() {
        XCTAssertEqual(FMInterface.tabMenuCurrent(screenUp: true, current: .dashboard), 0)
        XCTAssertEqual(FMInterface.tabMenuCurrent(screenUp: true, current: .bargains), 3)
        XCTAssertEqual(FMInterface.tabMenuCurrent(screenUp: true, current: .staff), 6)
    }

    func testWithFMsOwnScreenUpItMarksNone() {
        for screen in StarshipScreen.allCases { XCTAssertNil(FMInterface.tabMenuCurrent(screenUp: false, current: screen)) }
    }

    // MARK: Where it goes

    func testItOpensJustUnderTheTabFromItsLeftEdge() {
        // FM STARSHIP in FM's bar at 1680 points wide, as FM's interface has it.
        let origin = NativeTabMenu.origin(under: (x: 643, y: 3, width: 109, height: 48), in: (x: 0, y: 0, width: 1680, height: 1054))
        XCTAssertEqual(origin.left, 643)
        XCTAssertEqual(origin.top, 53)
    }

    func testItsPlaceIsInFMsDocumentNotOnTheScreen() {
        let origin = NativeTabMenu.origin(under: (x: 643, y: 3, width: 109, height: 48), in: (x: 10, y: 20, width: 1680, height: 1054))
        XCTAssertEqual(origin.left, 633)
        XCTAssertEqual(origin.top, 33)
    }

    func testItNeverOpensOffTheTopOrLeft() {
        let origin = NativeTabMenu.origin(under: (x: -30, y: -60, width: 109, height: 48), in: (x: 0, y: 0, width: 1680, height: 1054))
        XCTAssertEqual(origin.left, 0)
        XCTAssertEqual(origin.top, 0)
    }

    func testOnlyTheArrowTheWayDownAndTheMenuKeepIt() {
        var places = FMInterface.HoverPlaces()
        places.tab = (x: 644, y: 2, width: 109, height: 48)
        places.arrow = (x: 728, y: 13, width: 24, height: 25)
        // Before the menu is laid out, the space under the tab where it opens counts.
        XCTAssertTrue(FMInterface.pointerKeepsMenu(places, x: 740, y: 25), "on the arrow")
        XCTAssertTrue(FMInterface.pointerKeepsMenu(places, x: 700, y: 150), "where the menu opens")
        XCTAssertFalse(FMInterface.pointerKeepsMenu(places, x: 680, y: 25), "on the tab's name, as FM's menus close there")
        places.menu = (x: 644, y: 53, width: 205, height: 212)
        XCTAssertTrue(FMInterface.pointerKeepsMenu(places, x: 740, y: 46), "on the way down from the arrow")
        XCTAssertTrue(FMInterface.pointerKeepsMenu(places, x: 840, y: 200), "on the menu")
        XCTAssertFalse(FMInterface.pointerKeepsMenu(places, x: 680, y: 25), "on the tab's name")
        XCTAssertFalse(FMInterface.pointerKeepsMenu(places, x: 700, y: 300), "below the menu")
        XCTAssertFalse(FMInterface.pointerKeepsMenu(places, x: 900, y: 100), "right of the menu")
        XCTAssertFalse(FMInterface.pointerKeepsMenu(FMInterface.HoverPlaces(), x: 700, y: 20), "no tab, nothing keeps it")
    }

    func testInsideHasAMargin() {
        let arrow = (x: Float(729), y: Float(12), width: Float(20), height: Float(25))
        XCTAssertTrue(FMInterface.inside(arrow, x: 730, y: 20))
        XCTAssertTrue(FMInterface.inside(arrow, x: 727.5, y: 20, margin: 2))
        XCTAssertFalse(FMInterface.inside(arrow, x: 727.5, y: 20))
        XCTAssertFalse(FMInterface.inside(nil, x: 730, y: 20))
    }

    func testAPointerJustPastTheArrowKeepsItButNotOneOnFMsTabToTheLeft() {
        var places = FMInterface.HoverPlaces()
        places.tab = (x: 644, y: 2, width: 109, height: 48)
        places.arrow = (x: 728, y: 13, width: 24, height: 25)
        places.menu = (x: 644, y: 53, width: 205, height: 212)
        XCTAssertTrue(FMInterface.pointerKeepsMenu(places, x: 757, y: 16), "Seen in FM: just past the arrow")
        XCTAssertFalse(FMInterface.pointerKeepsMenu(places, x: 778, y: 18), "Well past it")
        XCTAssertFalse(FMInterface.pointerKeepsMenu(places, x: 639, y: 18), "On CLUB, to the left: FM's menu opens there")
    }
}
