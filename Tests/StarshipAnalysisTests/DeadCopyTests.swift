@testable import StarshipCore
import XCTest

/// FM can keep a dead copy of the world, and a free agent there has no contract to give it away.
final class DeadCopyTests: XCTestCase {
    func testARegionWhoseContractsNameSomeoneElseIsDead() {
        // The counts from a real save: in the dead copy, 11,795 people's contracts named the live person and one named its own.
        let dead = GameReader.deadRegions(confirmed: [0x70: 1, 0x72: 39_848, 0x78: 5_091], stale: [0x70: 11_795])
        XCTAssertEqual(dead, [0x70])
    }

    func testARegionWithNoContractsIsKept() {
        XCTAssertEqual(GameReader.deadRegions(confirmed: [0x72: 100], stale: [:]), [])
    }

    func testAFewStaleContractsDoNotCondemnALiveRegion() {
        XCTAssertEqual(GameReader.deadRegions(confirmed: [0x72: 100], stale: [0x72: 3]), [])
    }
}
