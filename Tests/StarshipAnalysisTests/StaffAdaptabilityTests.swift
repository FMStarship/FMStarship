@testable import StarshipAnalysis
import StarshipCore
import XCTest

/// FM shows a member of staff's Adaptability with Determination and Level of Discipline, so comparing staff shows it with
/// Hidden attributes off. A player's Adaptability, and the rest of staff personality, stay hidden.
final class StaffAdaptabilityTests: XCTestCase {
    private func session(showHidden: Bool) -> AnalysisSession {
        AnalysisSession(db: Database(), club: ChosenClub(team: 1, name: "Testing FC"),
                        display: DisplayOptions(reveal: .hidden, showHidden: showHidden))
    }

    private func staff(_ uid: UInt32, adaptability: UInt8) -> Staff {
        let staff = Staff()
        staff.uid = uid
        staff.block = 1
        staff.attr = [UInt8](repeating: 10, count: staff.attr.count)
        staff.pers = [UInt8](repeating: 4, count: staff.pers.count)
        staff.pers[Names.personalityIndex["Adaptability"]!] = adaptability
        return staff
    }

    private func player(_ uid: UInt32) -> Player {
        let player = Player()
        player.uid = uid
        player.block = 1
        player.pers = [UInt8](repeating: 4, count: player.pers.count)
        return player
    }

    func testComparingStaffShowsAdaptabilityWhileHiddenAttributesIsOff() throws {
        let rows = CompareReport(people: [staff(1, adaptability: 16), staff(2, adaptability: 7)], session: session(showHidden: false)).rows()
        let adaptability = try XCTUnwrap(rows.first { $0.label == "Adaptability" })
        XCTAssertFalse(adaptability.hidden)
        XCTAssertEqual(adaptability.cells, ["16", "7"])
        XCTAssertEqual(adaptability.best, [true, false])
        for name in Names.staffHiddenPersonality { XCTAssertFalse(rows.contains { $0.label == name }, name) }

        let shown = CompareReport(people: [staff(1, adaptability: 16), staff(2, adaptability: 7)], session: session(showHidden: true)).rows()
        XCTAssertEqual(shown.filter { $0.label == "Adaptability" }.count, 1, "Not again under Hidden")
        for name in Names.staffHiddenPersonality { XCTAssertTrue(shown.contains { $0.label == name }, name) }
    }

    func testComparingPlayersStillHidesAdaptability() {
        let rows = CompareReport(people: [player(1), player(2)], session: session(showHidden: false)).rows()
        XCTAssertFalse(rows.contains { $0.label == "Adaptability" })
        let shown = CompareReport(people: [player(1), player(2)], session: session(showHidden: true)).rows()
        XCTAssertEqual(shown.first { $0.label == "Adaptability" }?.hidden, true)
    }
}
