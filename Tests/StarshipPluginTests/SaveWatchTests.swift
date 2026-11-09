@testable import StarshipPlugin
import XCTest

/// FM Starship's screens inside FM never show a save other than the one FM has loaded, nor CA and PA once Hidden
/// attributes is off. Which reads and screens may be shown doesn't need FM.
final class SaveWatchTests: XCTestCase {
    /// Stands in for one of the model's reads of the save.
    private final class Read {}

    private let molde = SaveIdentity(date: "23/7/2028", clubs: "Molde FK")

    func testAReadIsUsedUntilFMsSaveChanges() {
        var watch = SaveWatch()
        let read = Read()
        XCTAssertTrue(watch.needsReading(nil, loading: false), "Nothing read yet")
        XCTAssertFalse(watch.needsReading(nil, loading: true), "A read going on is waited for")
        XCTAssertEqual(watch.follow(read: read, loading: false, now: { self.molde }), .none)
        XCTAssertTrue(watch.usable(read))
        XCTAssertFalse(watch.needsReading(read, loading: false))

        watch.saveChanged(read: read, loading: false)
        XCTAssertFalse(watch.usable(read))
        XCTAssertTrue(watch.needsReading(read, loading: false))
        XCTAssertTrue(watch.needsReading(read, loading: false), "A read that failed leaves the old one, still stale")

        let again = Read()
        XCTAssertTrue(watch.usable(again))
        XCTAssertFalse(watch.needsReading(again, loading: false))
    }

    func testAnotherDateOrClubsGoneMeansAnotherSave() {
        var watch = SaveWatch()
        let read = Read()
        XCTAssertEqual(watch.follow(read: read, loading: false, now: { self.molde }), .none, "The first look is how FM showed it then")
        XCTAssertEqual(watch.readAs, molde)
        XCTAssertEqual(watch.follow(read: read, loading: false, now: { self.molde }), .none)
        XCTAssertEqual(watch.follow(read: read, loading: false, now: { SaveIdentity(date: "24/7/2028", clubs: "Molde FK") }), .saveChanged)
        XCTAssertEqual(watch.follow(read: read, loading: false, now: { SaveIdentity(date: "23/7/2028", clubs: "") }), .saveChanged,
                       "FM has let go of the club the read found")
        XCTAssertEqual(watch.follow(read: read, loading: false, now: { SaveIdentity(date: "23/7/2028", clubs: "Brann") }), .saveChanged)
    }

    func testWhatCantBeToldChangesNothing() {
        var watch = SaveWatch()
        let read = Read()
        _ = watch.follow(read: read, loading: false, now: { self.molde })
        XCTAssertEqual(watch.follow(read: read, loading: false, now: { SaveIdentity(date: nil, clubs: "Molde FK") }), .none,
                       "No date in FM's bar, as during a match")
        XCTAssertEqual(watch.follow(read: read, loading: false, now: { SaveIdentity() }), .none)

        var snapshot = SaveWatch()
        _ = snapshot.follow(read: read, loading: false, now: { SaveIdentity() })
        XCTAssertEqual(snapshot.follow(read: read, loading: false, now: { self.molde }), .none, "Nothing was known when it was read")
    }

    func testANewReadIsComparedWithHowFMShowedTheSaveWhenItWasMade() {
        var watch = SaveWatch()
        let read = Read()
        _ = watch.follow(read: read, loading: false, now: { self.molde })
        XCTAssertEqual(watch.follow(read: read, loading: false, now: { SaveIdentity(date: "1/8/2028", clubs: "Molde FK") }), .saveChanged)
        watch.saveChanged(read: read, loading: false)
        XCTAssertNil(watch.readAs)

        let again = Read()
        let later = SaveIdentity(date: "1/8/2028", clubs: "Molde FK")
        XCTAssertEqual(watch.follow(read: again, loading: false, now: { later }), .none)
        XCTAssertEqual(watch.readAs, later)
        XCTAssertEqual(watch.follow(read: again, loading: false, now: { later }), .none)
    }

    func testFMsSaveIsOnlyLookedAtWhenThereIsAReadToCompare() {
        var watch = SaveWatch()
        var looks = 0
        let look = { () -> SaveIdentity in
            looks += 1
            return self.molde
        }
        XCTAssertEqual(watch.follow(read: nil, loading: false, now: look), .none)
        let read = Read()
        watch.saveChanged(read: read, loading: false)
        XCTAssertEqual(watch.follow(read: read, loading: false, now: look), .none)
        XCTAssertEqual(looks, 0)
    }

    func testAReadGoingOnWhenTheSaveChangedIsStaleToo() {
        var watch = SaveWatch()
        let read = Read()
        _ = watch.follow(read: read, loading: false, now: { self.molde })
        // The save is being read again when FM loads another.
        watch.saveChanged(read: read, loading: true)
        XCTAssertFalse(watch.usable(read))
        XCTAssertFalse(watch.needsReading(read, loading: true), "Waited for")
        XCTAssertEqual(watch.follow(read: read, loading: true, now: { self.molde }), .none)

        let during = Read()
        XCTAssertFalse(watch.usable(during), "Done, but not yet followed")
        XCTAssertEqual(watch.follow(read: during, loading: false, now: { self.molde }), .readWasStale)
        XCTAssertFalse(watch.usable(during))
        XCTAssertTrue(watch.needsReading(during, loading: false))
        XCTAssertEqual(watch.follow(read: during, loading: false, now: { self.molde }), .none, "Said once")

        let after = Read()
        XCTAssertTrue(watch.usable(after))
    }

    func testAReadGoingOnThatFailsLeavesTheOldOneStale() {
        var watch = SaveWatch()
        let read = Read()
        watch.saveChanged(read: read, loading: true)
        XCTAssertEqual(watch.follow(read: read, loading: false, now: { self.molde }), .readWasStale)
        XCTAssertFalse(watch.usable(read))
        XCTAssertTrue(watch.needsReading(read, loading: false))
    }

    func testAStaleReadTheModelHasLetGoOfDoesntMakeTheNextStale() {
        var watch = SaveWatch()
        var read: Read? = Read()
        watch.saveChanged(read: read, loading: false)
        read = nil
        let next = Read()
        XCTAssertTrue(watch.usable(next))
        XCTAssertEqual(watch.follow(read: next, loading: false, now: { self.molde }), .none)
        XCTAssertEqual(watch.readAs, molde)
    }

    // MARK: Hidden attributes

    func testAScreenMadeWithHiddenAttributesOnIsntShownOnceItsOff() {
        let withAbility = MadeScreen(revision: 3, showsAbility: true, content: "CA 153, PA 160")
        XCTAssertTrue(withAbility.fits(showsAbility: true))
        XCTAssertFalse(withAbility.fits(showsAbility: false), "Not even until it's made again")
        XCTAssertFalse(withAbility.fits(showsAbility: nil), "No read to show it with")
    }

    func testAScreenMadeWithHiddenAttributesOffIsMadeAgainOnceItsOn() {
        let without = MadeScreen(revision: 3, showsAbility: false, content: "Would join on: Transfer")
        XCTAssertTrue(without.fits(showsAbility: false))
        XCTAssertFalse(without.fits(showsAbility: true))
    }

    func testTablesFollowTheSameRule() {
        XCTAssertTrue(MadeScreen<Void>.fits(madeWith: true, now: true))
        XCTAssertFalse(MadeScreen<Void>.fits(madeWith: true, now: false), "Its old CA and PA aren't written again")
        XCTAssertFalse(MadeScreen<Void>.fits(madeWith: false, now: nil))
    }
}
