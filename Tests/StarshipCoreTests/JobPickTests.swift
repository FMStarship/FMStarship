import CA64
@testable import StarshipCore
import XCTest

/// The routine `RulesEngine.staffJobInterest` puts in place of `GAME_PERSON`'s job pick, run in the interpreter with no game.
final class JobPickTests: XCTestCase {
    func testTheJobPickAnswersTheJobAndTeamAskedAbout() throws {
        let image = try XCTUnwrap(a64_image_new({ _, _, out in
            memset(out, 0, Int(A64_PAGE))
            return 1
        }, nil))
        defer { a64_image_free(image) }
        let cpu = try XCTUnwrap(a64_new(image))
        defer { a64_free(cpu) }
        let pick = UInt64(A64_SCRATCH) + 0x300, out = UInt64(A64_SCRATCH) + 0x400
        let team: Int64 = 0x7cca_3d49_08
        RulesEngine.writeJobPick(cpu, at: pick, job: 58, team: team)
        // As the staff rule leaves its answer before the call: zeroed, here with a marker after it.
        for offset in stride(from: UInt64(0), to: 24, by: 8) { a64_write(cpu, out + offset, 0, 8) }
        a64_write(cpu, out + 24, 0xabcd, 8)
        a64_set_x(cpu, 3, out)
        a64_set_x(cpu, 31, UInt64(A64_STACK_TOP) - 0x1000)
        a64_set_x(cpu, 30, UInt64(A64_RETURN_SENTINEL))

        XCTAssertEqual(a64_run(cpu, pick, 100), A64_OK)
        XCTAssertEqual(a64_get_x(cpu, 0), 1, "FM's pick returns 1 when it found a job")
        XCTAssertEqual(a64_read(cpu, out, 1), 58, "the job asked about")
        XCTAssertEqual(a64_read(cpu, out + 1, 1), 0, "no second job")
        XCTAssertEqual(a64_read(cpu, out + 8, 8), UInt64(bitPattern: team))
        XCTAssertEqual(a64_read(cpu, out + 16, 8), 0, "no second team")
        XCTAssertEqual(a64_read(cpu, out + 24, 8), 0xabcd, "nothing past the answer")
        XCTAssertEqual(a64_read(cpu, pick + RulesEngine.jobPickAsked, 4), 1, "it says it was asked")
        XCTAssertEqual(a64_steps(cpu), UInt64(RulesEngine.jobPickCode.count))
    }
}
