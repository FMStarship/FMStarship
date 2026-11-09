@testable import StarshipPlugin
import StarshipAnalysis
import StarshipCore
import XCTest

/// The Edit Search pages for Recommended signings and Bargains: what they offer, what they set, and FM's count of
/// what's changed, which need no game.
final class EditSearchTests: XCTestCase {
    private let pounds = MoneyUnits(symbol: "£", perPound: 1)

    private func bargains(fee: String = "9", showsAbility: Bool = true, canCheckInterest: Bool = true) -> BargainSearch {
        BargainSearch(startingMaxFee: fee, units: pounds, showsAbility: showsAbility, canCheckInterest: canCheckInterest)
    }

    private func choices(_ search: any ScreenSearch, _ id: String) -> (labels: [String], selected: Int)? {
        guard case .choice(let labels, let selected) = search.criteria.first(where: { $0.id == id })?.control else { return nil }
        return (labels, selected)
    }

    func testSigningsStartAsTheAppsDoWithNothingToCount() {
        let search = SigningSearch(units: pounds)
        XCTAssertEqual(search.changes, 0)
        XCTAssertEqual(search.buttonTitle, "Edit Search")
        XCTAssertEqual(search.criteria.map(\.id), ["mode", "show", "fee", "loans", "upgrades"])
        XCTAssertEqual(choices(search, "fee")?.selected, 0)
        XCTAssertEqual(choices(search, "fee")?.labels.first, "Any")
    }

    func testEachChangeIsCountedAndClearGoesBack() {
        var search = SigningSearch(units: pounds)
        search.position = Names.positions.firstIndex(of: "ST")!
        search.choose("show", 1)
        search.toggle("loans")
        let fees = choices(search, "fee")!.labels
        search.choose("fee", fees.firstIndex(of: "£5M")!)
        XCTAssertEqual(search.options.show, .freeAgentsOnly)
        XCTAssertTrue(search.options.includeLoans)
        XCTAssertEqual(search.options.maxFee, "5")
        XCTAssertEqual(search.changes, 4)
        XCTAssertEqual(search.buttonTitle, "Edit Search (4)")
        search.clear()
        XCTAssertEqual(search.changes, 0)
        XCTAssertEqual(search.options.position, -1)
    }

    func testSigningsOfferTheBudgetAmongTheFeesButStartWithAny() {
        let search = SigningSearch(units: pounds, budget: "9")
        let fee = choices(search, "fee")!
        XCTAssertEqual(fee.labels[fee.selected], "Any")
        XCTAssertTrue(fee.labels.contains("£9M (budget)"))
    }

    func testBudgetSigningsSayWhatTheyCostWithoutAFee() {
        var search = SigningSearch(units: pounds)
        search.choose("mode", RecommendOptions.Mode.allCases.firstIndex(of: .budget)!)
        let fee = search.criteria.first { $0.id == "fee" }
        XCTAssertEqual(fee?.note, "Budget signings cost up to £1M.")
    }

    func testBargainsStartWithTheFeeAtTheBudget() {
        let search = bargains()
        XCTAssertEqual(search.options.maxFee, "9")
        XCTAssertEqual(search.changes, 0)
        let fee = choices(search, "fee")!
        XCTAssertEqual(fee.labels[fee.selected], "£9M (budget)")
    }

    func testANewReadOfTheSavePutsTheFeeBackButKeepsTheRest() {
        var search = bargains()
        search.choose("fee", 1)
        search.choose("age", BargainSearch.ages.firstIndex(of: 23)! + 1)
        let kept = BargainSearch(keeping: search.options, newSave: false, startingMaxFee: "9", units: pounds, showsAbility: true,
                                 canCheckInterest: true)
        XCTAssertEqual(kept.options.maxFee, search.options.maxFee)
        let again = BargainSearch(keeping: search.options, newSave: true, startingMaxFee: "12", units: pounds, showsAbility: true,
                                  canCheckInterest: true)
        XCTAssertEqual(again.options.maxFee, "12")
        XCTAssertEqual(again.options.maxAge, "23")
        XCTAssertEqual(again.changes, 1)
    }

    func testWithAbilityOffThereIsNoCAToChooseOrCount() {
        var search = bargains()
        search.choose("ca", BargainSearch.abilities.firstIndex(of: 120)! + 1)
        XCTAssertEqual(search.options.minCA, "120")
        XCTAssertEqual(search.changes, 1)
        let off = BargainSearch(keeping: search.options, newSave: false, startingMaxFee: "9", units: pounds, showsAbility: false,
                                canCheckInterest: true)
        XCTAssertFalse(off.criteria.contains { $0.id == "ca" })
        XCTAssertEqual(off.changes, 0)
        XCTAssertFalse(off.key.contains("120"))
    }

    func testWhoWouldJoinCantBeChangedWithoutTheGame() {
        var search = bargains(canCheckInterest: false)
        let join = search.criteria.first { $0.id == "join" }
        XCTAssertEqual(join?.control, .toggle(on: true, enabled: false))
        XCTAssertEqual(join?.note, "Needs the live game and your club.")
        search.toggle("join")
        XCTAssertTrue(search.options.onlyJoin)
    }

    func testTheFeeIsntUsedForContractsEnding() {
        var search = bargains()
        XCTAssertEqual(search.criteria.first { $0.id == "fee" }?.note, "Not used for contracts ending.")
        search.choose("kind", BargainOptions.Kind.allCases.firstIndex(of: .free)!)
        XCTAssertEqual(search.criteria.first { $0.id == "fee" }?.note, "")
    }

    func testFeesAreRoundSumsInTheCurrencyShown() {
        let fees = FeeChoices(units: pounds)
        XCTAssertEqual(fees.values, ["", "0.1", "0.2", "0.5", "1", "2", "5", "10", "20", "50", "100", "200"])
        XCTAssertEqual(fees.labels[1], "£100K")
        XCTAssertEqual(fees.index(of: "20"), 8)
        XCTAssertEqual(fees.index(of: ""), 0)

        // A currency worth less per unit starts higher, so the steps are still round sums there.
        let kroner = FeeChoices(units: MoneyUnits(symbol: "Kr", perPound: 13), budget: "9.1")
        XCTAssertEqual(kroner.values.prefix(4), ["", "2", "5", "9.1"])
        XCTAssertEqual(kroner.labels[3], "Kr9.1M (budget)")
        XCTAssertEqual(kroner.values.last, "2000")
    }

    func testThePitchHasFMsPositionsAndNoSweeper() {
        let spots = PitchSpot.spots
        XCTAssertEqual(spots.count, 14)
        XCTAssertFalse(spots.contains { Names.positions[$0.position] == "SW" })
        let striker = spots.first { Names.positions[$0.position] == "ST" }
        XCTAssertEqual(striker?.name, "ST (C)")
        XCTAssertEqual(striker?.row, 0)
        XCTAssertEqual(PitchSpot.name(of: striker!.position), "Striker (Centre)")
        XCTAssertEqual(PitchSpot.name(of: -1), "Any")
    }
}
