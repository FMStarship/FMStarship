@testable import StarshipCore
import XCTest

/// The order positions sort in, as FM sorts its own Position column.
final class PositionOrderTests: XCTestCase {
    private func player(_ ratings: [String: UInt8]) -> Player {
        let player = Player()
        for (name, rating) in ratings { player.pos[Names.positions.firstIndex(of: name)!] = rating }
        return player
    }

    private func rank(_ name: String) -> Int { PositionOrder.rank(name, across: nil)! }

    func testEveryOneOfFMsPositionsHasAPlace() {
        for name in Names.positions { XCTAssertNotNil(PositionOrder.rank(name), name) }
        XCTAssertEqual(Set(PositionOrder.order.joined()), Set(Names.positions))
    }

    func testTheOrderGoesUpThePitchFromTheRightToTheLeft() {
        let order = ["GK", "DR", "WBR", "DC", "DL", "WBL", "DM", "MR", "MC", "ML", "AMR", "AMC", "AML", "ST"].map(rank)
        XCTAssertEqual(order, order.sorted())
        XCTAssertEqual(Set(order).count, order.count)
        XCTAssertEqual(rank("SW"), rank("DC"), "The sweeper goes with the centre-backs")
    }

    func testAPlayerGoesByThePositionTheyreRatedBestAt() {
        XCTAssertEqual(PositionOrder.rank(of: player(["MC": 18, "AMC": 15, "ST": 20])), rank("ST"))
        XCTAssertEqual(PositionOrder.rank(of: player(["DC": 20, "DM": 16])), rank("DC"))
    }

    func testATieOnTheBestRatingGoesToTheEarliestInTheOrder() {
        XCTAssertEqual(PositionOrder.rank(of: player(["DL": 20, "DR": 20, "DC": 19])), rank("DR"))
        XCTAssertEqual(PositionOrder.rank(of: player(["ST": 20, "AML": 20])), rank("AML"))
    }

    func testAPlayerRatedNowhereHasNoPlace() {
        XCTAssertNil(PositionOrder.rank(of: Player()))
    }

    func testFMsShortFormsGoByTheirFirstAndEarliestPosition() {
        XCTAssertEqual(PositionOrder.rank("GK"), rank("GK"))
        XCTAssertEqual(PositionOrder.rank("D (C)"), rank("DC"))
        XCTAssertEqual(PositionOrder.rank("D (RLC)"), rank("DR"))
        XCTAssertEqual(PositionOrder.rank("D (LC)"), rank("DC"))
        XCTAssertEqual(PositionOrder.rank("D/WB (L)"), rank("DL"))
        XCTAssertEqual(PositionOrder.rank("WB (L)"), rank("WBL"))
        XCTAssertEqual(PositionOrder.rank("AM (RL)"), rank("AMR"))
        XCTAssertEqual(PositionOrder.rank("M/AM (RC)"), rank("MR"))
        XCTAssertEqual(PositionOrder.rank("M/AM (C)"), rank("MC"))
        XCTAssertEqual(PositionOrder.rank("ST (C)"), rank("ST"))
        // Only the first of several: the rest are where else they can play.
        XCTAssertEqual(PositionOrder.rank("M (C), AM (LC), ST (C)"), rank("MC"))
        XCTAssertEqual(PositionOrder.rank("DM M (C)"), rank("DM"))
    }

    func testTheEnginesListsOfBestPositionsGoByTheirFirst() {
        XCTAssertEqual(PositionOrder.rank("AMR"), rank("AMR"))
        XCTAssertEqual(PositionOrder.rank("DC, DR"), rank("DC"))
        XCTAssertEqual(PositionOrder.rank("ST, AMC, MC"), rank("ST"))
    }

    func testATacticsPlacesGoFromTheRightToTheLeftAcrossAPlace() {
        let places = ["GK", "DR", "DC (R)", "DC", "DC (L)", "DL", "DM (R)", "DM (L)", "MC (R)", "MC (L)", "AMR", "ST (R)", "ST", "ST (L)"]
        let ranks = places.map { PositionOrder.rank($0)! }
        XCTAssertEqual(ranks, ranks.sorted())
        XCTAssertEqual(Set(ranks).count, ranks.count)
        XCTAssertEqual(PositionOrder.rank("ST (C)"), PositionOrder.rank("ST"))
        XCTAssertEqual(PositionOrder.rank("WBR"), rank("WBR"))
    }

    func testARoleAfterThePositionIsLeftOut() {
        XCTAssertEqual(PositionOrder.rank("DM: Anchor"), rank("DM"))
        XCTAssertEqual(PositionOrder.rank("D (C) - Ball-Playing Defender"), rank("DC"))
        XCTAssertEqual(PositionOrder.rank("AMR Inside Forward"), rank("AMR"))
    }

    func testThePlannersLinesGoByTheirPositions() {
        let lines = ["Goalkeeper", "Right-back", "Centre-back", "Left-back", "Defensive midfield", "Right wing", "Central midfield",
                     "Left wing", "Attacking midfield", "Striker"]
        let ranks = lines.map { PositionOrder.rank($0)! }
        XCTAssertEqual(ranks, ranks.sorted())
        XCTAssertEqual(PositionOrder.rank("Right-back"), rank("DR"))
        XCTAssertEqual(PositionOrder.rank("Right wing"), rank("MR"))
    }

    func testTextThatNamesNoPositionHasNoPlace() {
        for text in ["", "nobody picked", "  or", "Goalkeeping coach", "Free agent", "TBC", "D/", "X (C)", "153"] {
            XCTAssertNil(PositionOrder.rank(text), text)
        }
    }

    /// FM's own Squad screen, sorted by Position: the user's squad as FM listed it, each player's positions in
    /// FM's words. FM goes by each player's best position, which it doesn't show, so this checks that a best position
    /// can be picked from each player's own that keeps FM's list in our order, and that none can with the left first.
    private static let fmSquadByPosition: [[String]] = [
        ["GK"], ["GK"], ["D/WB (R)"], ["D (RC)"], ["D (RC)"], ["D (C)"], ["D/WB (RL)"], ["D (LC)"], ["D (LC)", "WB (L)"],
        ["D/WB (RL)"], ["DM", "M (C)"], ["DM", "M (C)"], ["DM", "M/AM (C)", "ST (C)"], ["M/AM (C)"], ["M (C)", "AM (LC)"],
        ["AM (RL)", "ST (C)"], ["AM (RL)", "ST (C)"], ["AM (RLC)", "ST (C)"], ["AM (RLC)", "ST (C)"], ["AM (RL)", "ST (C)"],
        ["M (C)", "AM (LC)", "ST (C)"], ["ST (C)"],
    ]

    private func fitsFMsList(_ rank: (String) -> Int?) -> Bool {
        var last = Int.min
        for positions in Self.fmSquadByPosition {
            let theirs = positions.flatMap { PositionOrder.places($0) }.compactMap { rank($0.name) }
            XCTAssertFalse(theirs.isEmpty, "\(positions)")
            guard let best = theirs.filter({ $0 >= last }).min() else { return false }
            last = best
        }
        return true
    }

    func testFMsOwnSquadScreenSortsInThisOrder() {
        XCTAssertTrue(fitsFMsList { PositionOrder.rank($0, across: nil) })
        // The same order the other way round across each line: D (RC), D (C), D (LC) wouldn't fit.
        func mirrored(_ name: String) -> String {
            name.hasSuffix("R") ? String(name.dropLast()) + "L" : name.hasSuffix("L") ? String(name.dropLast()) + "R" : name
        }
        XCTAssertFalse(fitsFMsList { PositionOrder.rank(mirrored($0), across: nil) })
    }
}
