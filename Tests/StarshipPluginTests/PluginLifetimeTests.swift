import AppKit
import os
import StarshipAnalysis
@testable import StarshipPlugin
import XCTest

/// What the plugin keeps of FM's interface, and for how long: rows it remembers by address, its clicks, the work it
/// starts again, and FM quitting. The parts that need FM's runtime are checked inside FM.
@MainActor
final class PluginLifetimeTests: XCTestCase {
    private func address(_ value: UInt) -> IL2CPP.Pointer { IL2CPP.Pointer(bitPattern: value)! }

    func testATablesRowsAndHeadingsAreForgottenWithIt() {
        let shown = FMTable.Shown()
        let row = address(0x1000), cell = address(0x2000), heading = address(0x3000), button = address(0x4000)
        shown.person[row] = 7
        shown.cells[row] = [cell]
        shown.fitted = [row]
        shown.hooked = [heading]
        shown.buttons = [button]
        shown.columns = ["name", "hidden-current-ability"]
        ClickActions.actions[button] = {}
        let other = address(0x5000)
        ClickActions.actions[other] = {}
        defer { ClickActions.actions[other] = nil }

        shown.forget(nil)
        XCTAssertTrue(shown.person.isEmpty && shown.cells.isEmpty && shown.fitted.isEmpty && shown.pinned.isEmpty)
        XCTAssertTrue(shown.hooked.isEmpty, "A heading FM makes again at the same address gets our click again")
        XCTAssertTrue(shown.buttons.isEmpty)
        XCTAssertNil(ClickActions.actions[button], "The headings' clicks go with the table")
        XCTAssertNotNil(ClickActions.actions[other], "Nothing else's")
        XCTAssertEqual(shown.columns, ["name", "hidden-current-ability"], "Set again by whoever saw the columns change")
    }

    func testAScreensWorkStartsOncePerAnalysisAndSearch() {
        let now = FMInterface.WorkFor(revision: 4, version: 1)
        XCTAssertTrue(FMInterface.needsWork(made: nil, empty: nil, running: false, now: now))
        XCTAssertTrue(FMInterface.needsWork(made: 3, empty: nil, running: false, now: now), "Made from an older analysis")
        XCTAssertFalse(FMInterface.needsWork(made: 4, empty: nil, running: false, now: now))
        XCTAssertFalse(FMInterface.needsWork(made: nil, empty: nil, running: true, now: now))
    }

    func testWorkThatCameBackEmptyIsntStartedAgainForTheSame() {
        let now = FMInterface.WorkFor(revision: 4, version: 1)
        XCTAssertFalse(FMInterface.needsWork(made: nil, empty: now, running: false, now: now), "It would come back empty again, forever")
        XCTAssertTrue(FMInterface.needsWork(made: nil, empty: FMInterface.WorkFor(revision: 4, version: 0), running: false, now: now),
                      "The search has changed since")
        XCTAssertTrue(FMInterface.needsWork(made: nil, empty: FMInterface.WorkFor(revision: 3, version: 1), running: false, now: now),
                      "The save was read again, or a setting changed")
    }

    func testFeeChoicesWithNoRateToGoByOfferOnlyAny() {
        for rate in [0, -1, Double.nan, .infinity, 1e308] {
            let fees = FeeChoices(units: MoneyUnits(symbol: "Kr", perPound: rate), budget: "9.1", current: "2")
            XCTAssertEqual(fees.values, [""], "\(rate)")
            XCTAssertEqual(fees.labels, ["Any"], "\(rate)")
        }
        XCTAssertGreaterThan(FeeChoices(units: MoneyUnits(symbol: "Kr", perPound: 1e-6)).values.count, 1, "A tiny rate still has sums")
    }

    func testClicksInFMStarshipsOwnWindowsArentFMs() {
        func window() -> NSWindow {
            let made = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
            made.isReleasedWhenClosed = false
            return made
        }
        let ours = window(), popover = window(), fm = window()
        ours.addChildWindow(popover, ordered: .above)
        defer { ours.removeChildWindow(popover) }
        XCTAssertTrue(Plugin.owns(ours, ours: [ours]))
        XCTAssertTrue(Plugin.owns(popover, ours: [ours]), "A popover or sheet of ours")
        XCTAssertFalse(Plugin.owns(fm, ours: [ours]))
        XCTAssertFalse(Plugin.owns(fm, ours: []))
    }

    func testOnlyTheFirstOfFMsQuitHooksStopsAnything() {
        // Unity's quit on the main thread and FM's exit on another may come at once.
        let latch = Latch()
        let firsts = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if latch.set() { firsts.withLock { $0 += 1 } }
        }
        XCTAssertEqual(firsts.withLock { $0 }, 1)
        XCTAssertTrue(latch.isSet)
        XCTAssertFalse(latch.set())
    }

    func testNothingCallsIntoFMOnceItsQuitting() {
        // FM's exit may come on a thread of its own.
        DispatchQueue.global().sync { _ = IL2CPP.stop() }
        XCTAssertTrue(IL2CPP.stopped)
        XCTAssertFalse(IL2CPP.stop(), "The hook that comes second does nothing")
        XCTAssertNil(IL2CPP.shared)
        XCTAssertNil(FMElements(IL2CPP.shared))
        // Already stopped, so this does nothing, off the main thread too: no timers, no log.
        DispatchQueue.global().sync { FMInterface.quitting("a test") }
    }
}
