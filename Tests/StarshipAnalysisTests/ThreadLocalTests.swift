import CA64
@testable import StarshipCore
import XCTest

/// FM builds a stand-in manager in thread-local memory for a club without one, which the loan rule needs.
final class ThreadLocalTests: XCTestCase {
    func testRegisteringAThreadLocalDestructorDoesNothing() {
        XCTAssertEqual(GameImports.stubs["__tlv_atexit"], A64_STUB_RET0)
    }

    func testARandomSeedNeedsNoSystemCall() {
        XCTAssertEqual(GameImports.stubs["__ZNSt3__113random_deviceclEv"], A64_STUB_RET0)
    }

    func testOlderDyldKeepsTheOffsetWhereTheLinkerPutIt() {
        let live: [(key: UInt64, offset: UInt64)] = [(0x155, 0), (0x155, 0xc920), (0x155, 0xc4f8)]
        XCTAssertEqual(GameImports.threadLocalStub(file: [0, 0xc920, 0xc4f8], live: live), A64_STUB_TLV)
    }

    /// FM 27.0.0.2493426 on macOS 27: key and offset as dyld left them.
    func testNewerDyldPacksTheOffsetIntoTheKey() {
        let live: [(key: UInt64, offset: UInt64)] = [(0x0000_0155, 0xcb48_0000_0290), (0xc920_0000_0155, 0xcb48_0000_01b8),
                                                     (0xc4f8_0000_0155, 0xcb48_0000_01a0)]
        XCTAssertEqual(GameImports.threadLocalStub(file: [0, 0xc920, 0xc4f8], live: live), A64_STUB_TLV_PACKED)
    }

    /// Guessing would put thread-locals on top of each other, so an unknown layout leaves them unsupported.
    func testAnUnknownLayoutIsNotGuessed() {
        let live: [(key: UInt64, offset: UInt64)] = [(0x155, 0x40), (0x155, 0x58)]
        XCTAssertNil(GameImports.threadLocalStub(file: [0xc920, 0xc4f8], live: live))
    }
}
