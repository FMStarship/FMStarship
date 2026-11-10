@testable import StarshipPlugin
import StarshipAnalysis
import XCTest

/// Until FM's own tables are known, a list that goes in one is in plain rows, and says what to open in FM to get them.
final class TableHintTests: XCTestCase {
    private func section(fmColumns: [String]?, kind: FMTable.Kind = .players) -> TableSection {
        TableSection(title: "Recommended signings", table: AnalysisTable(columns: [TableColumn("Name", 5)], rows: []),
                     fmColumns: fmColumns, kind: kind)
    }

    func testAListMeantForFMsTableFallsBackUntilItsKindIsKnown() {
        let signings = section(fmColumns: ["name", "age"])
        XCTAssertTrue(FMInterface.fallsBack(signings, ready: { _ in false }))
        XCTAssertFalse(FMInterface.fallsBack(signings, ready: { _ in true }))
        let staff = section(fmColumns: ["portrait-name"], kind: .staff)
        XCTAssertTrue(FMInterface.fallsBack(staff, ready: { $0 == .players }), "FM's player table is no use for staff")
    }

    func testTheEnginesOwnTablesNeverSayIt() {
        // Such as the squad planner's places, which are never in FM's tables.
        XCTAssertFalse(FMInterface.fallsBack(section(fmColumns: nil), ready: { _ in false }))
    }

    func testTheLineSaysWhichOfFMsListsToOpen() {
        let players = NativePage.tableHint(.players), staff = NativePage.tableHint(.staff)
        XCTAssertTrue(players.hasPrefix("Open one of FM's own player lists, such as your Squad"))
        XCTAssertTrue(staff.hasPrefix("Open one of FM's own staff lists, such as Club > Staff"))
        for line in [players, staff] {
            XCTAssertTrue(line.contains("come back here to get FM's tables, with sorting and right-click"))
            XCTAssertFalse(line.contains("\n"), "One line")
        }
    }
}
