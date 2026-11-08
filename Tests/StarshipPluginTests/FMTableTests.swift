@testable import StarshipPlugin
import StarshipAnalysis
import StarshipCore
import XCTest

/// FM's own tables need the game, but which of FM Starship's columns go into them, under which headings, and how a
/// click on their headings sorts the list, don't.
@MainActor
final class FMTableTests: XCTestCase {
    private func person(_ index: UInt32) -> Person {
        let person = Person()
        person.index = index
        return person
    }

    /// Four signings as the engine shows them with Hidden attributes on: two share a CA, one has no PA.
    private func signings() -> (table: AnalysisTable, people: [Person]) {
        let people = (1...4).map { person(UInt32($0)) }
        let columns = ["Name", "CA", "PA", "Would join on", "vs your best"].map { TableColumn($0, 5) }
        let cells = [["Abel", "140", "150", "Transfer", "+4 (GK)"],
                     ["Berg", "153", "160", "Transfer or loan", "+15 (GK)"],
                     ["Carr", "141", "", "Loan", "-2 (ST)"],
                     ["Dahl", "153", "155", "Transfer", "+15 (DC)"]]
        return (AnalysisTable(columns: columns, rows: zip(cells, people).map { TableRow(cells: $0, person: $1) }), people)
    }

    private func names(_ people: [Person]) -> [UInt32] { people.map(\.index) }

    private func extra(_ title: String) -> FMTable.Extra {
        let extras = FMTable.extras(from: signings().table, titles: ["CA", "PA", "Would join on", "vs your best"])
        return extras.first { ($0.title ?? $0.host) == title }!
    }

    func testCAAndPAGoInFMsOwnColumnsForThemAndTheRestUnderTheEnginesHeadings() {
        let extras = FMTable.extras(from: signings().table, titles: ["CA", "PA", "Would join on", "vs your best"])
        XCTAssertEqual(extras.map(\.host).prefix(2), ["hidden-current-ability", "hidden-potential-ability"])
        // FM's own headings stay on CA and PA; the rest are the engine's, with FM's word for whether a player would join.
        XCTAssertEqual(extras.map(\.title), [nil, nil, "Interest", "vs your best"])
        XCTAssertEqual(Set(extras.map(\.host)).count, 4, "Each in a column of its own")
        XCTAssertEqual(extras[0].values[2], "153")
        XCTAssertEqual(extras[2].values[2], "Transfer or loan")
    }

    func testWithHiddenAttributesOffTheEngineHasNoCAAndFMsScoutsKeepTheirColumns() {
        // The engine leaves out CA, PA and what's worked out from them while Hidden attributes is off.
        var table = signings().table
        table.columns = [TableColumn("Name", 5), TableColumn("Would join on", 5)]
        table.rows = table.rows.map { TableRow(cells: [$0.cells[0], $0.cells[3]], person: $0.person) }
        let extras = FMTable.extras(from: table, titles: ["CA", "PA", "Would join on", "vs your best"])
        XCTAssertEqual(extras.map(\.title), ["Interest"])
        let columns = FMTable.columns(["name", "scout-opinion-current-ability", "scout-opinion-potential-ability"], with: extras)
        XCTAssertEqual(columns.prefix(3), ["name", "scout-opinion-current-ability", "scout-opinion-potential-ability"])
        XCTAssertFalse(columns.contains("hidden-current-ability"))
    }

    func testOurCAAndPATakeTheScoutsPlacesAndTheRestGoAtTheEnd() {
        let extras = FMTable.extras(from: signings().table, titles: ["CA", "PA", "Would join on", "vs your best"])
        let columns = FMTable.columns(["name", "scout-opinion-current-ability", "scout-opinion-potential-ability", "wage"], with: extras)
        XCTAssertEqual(columns.prefix(4), ["name", "hidden-current-ability", "hidden-potential-ability", "wage"])
        XCTAssertEqual(columns.count, 6)
        XCTAssertEqual(Array(columns.suffix(2)), extras.suffix(2).map(\.host))
    }

    func testSortingByANumberPutsTheHighestFirstAndKeepsTiesInTheEnginesOrder() {
        let people = signings().people
        XCTAssertEqual(names(FMTable.sorted(people, by: extra("hidden-current-ability"), descending: true)), [2, 4, 3, 1])
        XCTAssertEqual(names(FMTable.sorted(people, by: extra("hidden-current-ability"), descending: false)), [1, 3, 2, 4])
    }

    func testSortingBySignedNumbersReadsTheSign() {
        XCTAssertEqual(names(FMTable.sorted(signings().people, by: extra("vs your best"), descending: true)), [2, 4, 1, 3])
    }

    func testPlayersWithoutAValueGoLastEitherWay() {
        let people = signings().people
        XCTAssertEqual(names(FMTable.sorted(people, by: extra("hidden-potential-ability"), descending: true)), [2, 4, 1, 3])
        XCTAssertEqual(names(FMTable.sorted(people, by: extra("hidden-potential-ability"), descending: false)), [1, 4, 2, 3])
    }

    func testTextSortsAlphabetically() {
        XCTAssertEqual(names(FMTable.sorted(signings().people, by: extra("Interest"), descending: false)), [3, 1, 4, 2])
    }

    func testOurColumnsAreWideEnoughForTheirLongestValue() {
        XCTAssertGreaterThan(extra("Interest").width, extra("vs your best").width)
        XCTAssertLessThanOrEqual(extra("Interest").width, 220)
    }

    func testTheAppsHintsAboutDoubleClickingAreLeftOut() {
        XCTAssertEqual(NativePage.withoutAppHints("Top 10 who would join Molde FK. Double-click a player for the full profile."),
                       "Top 10 who would join Molde FK.")
        XCTAssertEqual(NativePage.withoutAppHints("Double-click for the full profile; right-click to compare or add to a shortlist."), "")
        XCTAssertEqual(NativePage.withoutAppHints("Nothing found"), "Nothing found")
    }
}
