@testable import StarshipCore
import XCTest

/// The transfer budget is what FM shows as Available, not the budget the board last set.
final class BudgetTests: XCTestCase {
    /// Molde's CLUB_FINANCE words on a real save, 23/7/2028. FM showed Available Kr 9.01M, which is £716,735.
    /// The next word, £2,393,703 (Kr 30.12M), is what the app used to show.
    private func molde() -> [UInt8] {
        var record = [UInt8](repeating: 0, count: 0x818)
        func put(_ value: Int32, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { record.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        put(716_735, at: 0x7c4)
        put(2_393_703, at: 0x7c8)
        put(4_246_837, at: 0x7cc)
        put(196_429, at: 0x808)
        put(145_108, at: 0x814)
        return record
    }

    func testTheTransferBudgetIsWhatIsLeftToSpend() {
        XCTAssertEqual(GameReader.budget(molde()).transfer, 716_735)
    }

    func testWageRoomIsTheWageBudgetLessTheWagesPaid() {
        XCTAssertEqual(GameReader.budget(molde()).wageRoom, 51_321)
    }
}
