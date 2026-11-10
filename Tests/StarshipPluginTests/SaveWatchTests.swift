@testable import StarshipPlugin
import StarshipAnalysis
import XCTest

/// FM Starship's screens inside FM never show a save other than the one FM has loaded, nor anything hidden once Hidden
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

    /// The settings as the model gives them: with Hidden attributes off, Ability is off too.
    private func shown(_ reveal: AbilityReveal = .numbers, hidden: Bool = true, units: MoneyUnits = MoneyUnits()) -> ShownAs {
        ShownAs(DisplayOptions(reveal: hidden ? reveal : .hidden, showHidden: hidden, units: units, insideGame: true))
    }

    func testAScreenMadeWithHiddenAttributesOnIsntShownOnceItsOff() {
        let withAbility = MadeScreen(revision: 3, shownAs: shown(), content: "CA 153, PA 160")
        XCTAssertTrue(withAbility.fits(shown()))
        XCTAssertFalse(withAbility.fits(shown(hidden: false)), "Not even until it's made again")
        XCTAssertFalse(withAbility.fits(nil), "No read to show it with")
    }

    func testAScreenMadeWithHiddenAttributesOffIsMadeAgainOnceItsOn() {
        let without = MadeScreen(revision: 3, shownAs: shown(hidden: false), content: "Would join on: Transfer")
        XCTAssertTrue(without.fits(shown(hidden: false)))
        XCTAssertFalse(without.fits(shown()))
    }

    /// With Ability off, CA and PA were never shown, but Bargains' Drive, the Dashboard's injury proneness and the
    /// planner's notes are hidden attributes all the same.
    func testWithAbilityOffAScreenStillGoesWhenHiddenAttributesGoesOff() {
        let on = DisplayOptions(reveal: .hidden, showHidden: true, insideGame: true)
        let off = DisplayOptions(reveal: .hidden, showHidden: false, insideGame: true)
        XCTAssertEqual(on.showsAbility, off.showsAbility, "CA and PA are off both ways")
        let made = MadeScreen(revision: 3, shownAs: ShownAs(on), content: "Drive (hidden): 17")
        XCTAssertTrue(made.fits(ShownAs(on)))
        XCTAssertFalse(made.fits(ShownAs(off)), "Not even until it's made again")

        let madeOff = MadeScreen(revision: 3, shownAs: ShownAs(off), content: "No Drive column")
        XCTAssertFalse(madeOff.fits(ShownAs(on)), "Made again with the hidden attributes")
    }

    func testAnotherAbilityOrOtherUnitsMakeTheScreenAgain() {
        let made = MadeScreen(revision: 3, shownAs: shown(), content: "CA 153, £2.5M, £20K p/w, 183 cm")
        XCTAssertFalse(made.fits(shown(.stars)), "Stars mustn't give away the exact CA")
        XCTAssertFalse(made.fits(shown(.hidden)), "Ability off")
        XCTAssertFalse(made.fits(shown(units: MoneyUnits(symbol: "€", perPound: 1.17))))
        XCTAssertFalse(made.fits(shown(units: MoneyUnits(symbol: "£", perPound: 1, wagePeriod: .month))))
        XCTAssertFalse(made.fits(shown(units: MoneyUnits(feetAndInches: true))))
        XCTAssertTrue(made.fits(shown(units: MoneyUnits(symbol: "£", perPound: 1))), "The same settings made again")
    }

    /// A display setting added later has to decide what's shown too, or be said here not to.
    func testTheKeyHoldsEveryDisplaySetting() {
        let settings = Set(Mirror(reflecting: DisplayOptions()).children.compactMap(\.label))
        let key = Set(Mirror(reflecting: shown()).children.compactMap(\.label))
        XCTAssertEqual(settings.subtracting(key), ["insideGame"], "Always true inside FM")
    }

    func testTablesFollowTheSameRule() {
        XCTAssertTrue(MadeScreen<Void>.fits(madeWith: shown(), now: shown()))
        XCTAssertFalse(MadeScreen<Void>.fits(madeWith: shown(), now: shown(hidden: false)), "Its old CA and PA aren't written again")
        XCTAssertFalse(MadeScreen<Void>.fits(madeWith: shown(.hidden), now: shown(.hidden, hidden: false)), "Nor its hidden attributes")
        XCTAssertFalse(MadeScreen<Void>.fits(madeWith: shown(hidden: false), now: nil))
        XCTAssertFalse(MadeScreen<Void>.fits(madeWith: nil, now: nil), "One made with no read is made again")
    }
}
