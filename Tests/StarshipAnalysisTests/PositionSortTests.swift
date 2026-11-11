@testable import StarshipAnalysis
import StarshipCore
import XCTest

/// A click on a Position column's heading sorts in FM's order for its own Position column, not from A to Z.
final class PositionSortTests: XCTestCase {
    private func player(_ ratings: [String: UInt8]) -> Player {
        let player = Player()
        for (name, rating) in ratings { player.pos[Names.positions.firstIndex(of: name)!] = rating }
        return player
    }

    private func table(_ order: TableColumn.Order, _ rows: [(String, Person?)]) -> AnalysisTable {
        AnalysisTable(columns: [TableColumn("Position", 5, order: order)],
                      rows: rows.map { TableRow(cells: [$0.0], person: $0.1) })
    }

    private func sorted(_ table: AnalysisTable, descending: Bool = false) -> [String] {
        table.sortedIndices(byColumn: 0, descending: descending).map { table.rows[$0].cells[0] }
    }

    func testPlayersSortByTheirBestPositionAsFMsSquadScreenDoes() {
        let list = table(.playerPosition, [
            ("ST, MC, AMC", player(["ST": 20, "MC": 18, "AMC": 18])),
            // Rated the same at left and right back: FM puts them with the right-backs, ahead of the centre-backs.
            ("DL, DR", player(["DL": 20, "DR": 20])),
            ("DC", player(["DC": 20])),
            ("DM", nil),
            ("AMR", player(["AMR": 19])),
            ("GK", player(["GK": 20])),
        ])
        XCTAssertEqual(sorted(list), ["GK", "DL, DR", "DC", "DM", "AMR", "ST, MC, AMC"])
        XCTAssertEqual(sorted(list, descending: true), ["ST, MC, AMC", "AMR", "DM", "DC", "DL, DR", "GK"])
    }

    func testATacticsPlacesSortByThePlaceNotWhoIsInIt() {
        // A natural centre-back picked in midfield stays with the midfield.
        let list = table(.place, [
            ("ST (L)", nil), ("DC (L)", nil), ("AMR", nil), ("GK", nil), ("DM", player(["DC": 20, "DM": 12])),
            ("DC (R)", nil), ("WBR", nil), ("ST (R)", nil),
        ])
        XCTAssertEqual(sorted(list), ["GK", "WBR", "DC (R)", "DC (L)", "DM", "AMR", "ST (R)", "ST (L)"])
    }

    func testThePlannersLinesSortUpThePitch() {
        let lines = SquadPlanner.groups.map(\.name)
        let list = table(.place, lines.reversed().map { ($0, nil) })
        XCTAssertEqual(sorted(list), ["Goalkeeper", "Right-back", "Centre-back", "Left-back", "Defensive midfield", "Right wing",
                                      "Central midfield", "Left wing", "Attacking midfield", "Striker"])
    }

    func testThePlannersLinesGoByTheFirstOfTheirPositions() {
        for group in SquadPlanner.groups {
            XCTAssertEqual(PositionOrder.rank(group.name), group.positions.compactMap { PositionOrder.rank(Names.positions[$0]) }.min(),
                           group.name)
        }
    }

    func testWhatTheOrderCantPlaceGoesAfterThePositionsEitherWay() {
        let list = table(.place, [("ST", nil), ("nobody", nil), ("GK", nil), ("", nil)])
        XCTAssertEqual(sorted(list), ["GK", "ST", "", "nobody"])
        XCTAssertEqual(sorted(list, descending: true), ["ST", "GK", "nobody", ""])
    }

    func testOtherColumnsSortAsBefore() {
        let list = table(.text, [("ST", nil), ("GK", nil), ("DC", nil)])
        XCTAssertEqual(sorted(list), ["DC", "GK", "ST"])
        let numbers = AnalysisTable(columns: [TableColumn("Age", 5)],
                                    rows: [TableRow(cells: ["9"], sortKeys: [.number(9)]), TableRow(cells: ["10"], sortKeys: [.number(10)])])
        XCTAssertEqual(numbers.sortedIndices(byColumn: 0, descending: true), [1, 0])
    }

    func testEveryPositionColumnSortsInFMsOrder() {
        let tables = [SigningRecommender.columns, SigningRecommender.youngColumns, SquadPlanner.squadColumns, SquadPlanner.slotColumns,
                      BestEleven.columns, TacticOptimizer.detailColumns]
        for columns in tables {
            XCTAssertNotEqual(columns.first { $0.title == "Position" }?.order ?? .text, .text)
        }
    }
}
