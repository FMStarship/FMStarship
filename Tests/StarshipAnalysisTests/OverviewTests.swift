@testable import StarshipAnalysis
import StarshipCore
import XCTest

final class OverviewTests: XCTestCase {
    private final class Report: OverviewReport {
        let rows: [OverviewRow]
        let headline = "Two places need work."
        let groups = ["Defence", "Attack"]
        let placeTitle = "Position"
        let nowTitle = "Playing now"
        let footnote = ""
        let exportTitle = "Test"

        init(rows: [OverviewRow]) { self.rows = rows }

        func search(_ row: OverviewRow, taken: inout Set<UInt32>, isCancelled: () -> Bool) -> OverviewResult? { nil }
    }

    private func row(_ id: String, group: String, standing: Standing, warning: String? = nil) -> OverviewRow {
        OverviewRow(id: id, group: group, place: id, person: nil, name: "Nobody picked", score: "", detail: "Age 30", warning: warning,
                    standing: standing, lookup: .signing(position: 0), searches: true)
    }

    func testTheDashboardSaysWhatNeedsYouInOneSentence() {
        let team = [row("a", group: "Defence", standing: .poor), row("b", group: "Defence", standing: .below), row("c", group: "Attack", standing: .strong)]
        XCTAssertEqual(ClubDashboard.headline(team: team, emptyPlaces: 1, actions: 3),
                       "2 places in your team need work, 1 backroom place is empty and 3 players need action now.")
        XCTAssertEqual(ClubDashboard.headline(team: team, emptyPlaces: 0, actions: 0), "2 places in your team need work.")
        XCTAssertEqual(ClubDashboard.headline(team: nil, emptyPlaces: 14, actions: 1), "14 backroom places are empty and 1 player needs action now.")
        XCTAssertEqual(ClubDashboard.headline(team: [row("c", group: "Attack", standing: .good)], emptyPlaces: 0, actions: 0), "Nothing needs you right now.")
    }

    func testAbilityInSentencesFollowsTheSetting() {
        XCTAssertEqual(DisplayOptions(reveal: .numbers, showHidden: true).labelled("CA", 117), "CA 117")
        XCTAssertEqual(DisplayOptions(reveal: .stars, showHidden: true).labelled("CA", 117), "CA 3.0★")
        XCTAssertNil(DisplayOptions(reveal: .hidden, showHidden: false).labelled("CA", 117))
    }

    func testAWageShownInAnotherCurrencyComesBackToTheSamePounds() {
        let kroner = MoneyUnits(symbol: "Kr ", perPound: 13.01)
        for pounds in [4234, 38, 1, 123_456] {
            let shown = Int64((Double(pounds) * 13.01).rounded())
            XCTAssertEqual(SquadPlanner.poundsFor(budget: 0, wages: shown, units: kroner).wages, pounds)
        }
    }

    func testABarGivesAwayNoMoreThanTheNumbersBesideIt() {
        XCTAssertEqual(DisplayOptions(reveal: .numbers, showHidden: true).shown(117), 117)
        XCTAssertEqual(DisplayOptions(reveal: .stars, showHidden: true).shown(117), 120)
        XCTAssertEqual(DisplayOptions(reveal: .stars, showHidden: true).shown(113), 120)
    }

    func testARowNeedsWorkWhenItIsWeakOrSomethingIsAboutToGoWrong() {
        XCTAssertTrue(row("a", group: "Defence", standing: .missing).needsWork)
        XCTAssertTrue(row("b", group: "Defence", standing: .below).needsWork)
        XCTAssertFalse(row("c", group: "Defence", standing: .good).needsWork)
        XCTAssertFalse(row("d", group: "Defence", standing: .unknown).needsWork)
        XCTAssertTrue(row("e", group: "Defence", standing: .strong, warning: "No real cover").needsWork)
    }

    func testSomeoneDevelopingIsNoProblemToFix() {
        XCTAssertFalse(row("a", group: "Attack", standing: .developing).needsWork)
        XCTAssertTrue(row("b", group: "Attack", standing: .developing, warning: "No real cover").needsWork)
        XCTAssertTrue(Standing.developing > .unknown && Standing.developing < .good)
    }

    func testExportKeepsTheGroupsInOrderAndSaysWhoWouldJoin() {
        let report = Report(rows: [row("ST", group: "Attack", standing: .below), row("DC", group: "Defence", standing: .missing, warning: "No real cover")])
        let hire = OverviewHire(person: Player(), name: "Song Bum-Keun", score: "★★★", gain: "+1★", detail: "Jeonbuk")
        let table = report.table(hires: ["DC": .hire(hire), "ST": .nobody("Nobody better would join")])
        XCTAssertEqual(table.head, "Two places need work.")
        XCTAssertEqual(table.rows.map { $0.cells[0] }, ["DC", "ST"])
        XCTAssertEqual(table.rows[0].cells[4], "Age 30; No real cover")
        XCTAssertEqual(Array(table.rows[0].cells[5...]), ["Song Bum-Keun", "★★★", "+1★", "Jeonbuk"])
        XCTAssertEqual(table.rows[1].cells[5], "Nobody better would join")
    }
}
