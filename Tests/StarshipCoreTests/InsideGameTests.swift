@testable import StarshipCore
import XCTest

/// Inside FM the plugin reads memory directly. The test process stands in for FM, with libSystem as its game image.
final class InsideGameTests: XCTestCase {
    private func game() throws -> GameProcess {
        try XCTUnwrap(GameProcess.inside(imageEndingWith: "/libSystem.B.dylib"))
    }

    func testFindsTheImageAndReadsDirectly() throws {
        let game = try game()
        XCTAssertTrue(game.inside)
        XCTAssertEqual(game.pid, getpid())
        XCTAssertGreaterThan(game.pluginSize, 0)

        var value: UInt64 = 0x1122_3344_5566_7788
        let address = withUnsafePointer(to: &value) { Int64(Int(bitPattern: $0)) }
        XCTAssertEqual(game.read(address, count: 8), withUnsafeBytes(of: value) { Array($0) })
    }

    func testSweepSeesTheSameBytesAwayFromPageEdges() throws {
        let game = try game()
        let bytes = (0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        try bytes.withUnsafeBytes { raw in
            let start = Int64(Int(bitPattern: raw.baseAddress!)) + 3
            let seen = try XCTUnwrap(game.withBytes(start, count: 50_000) { Array($0) })
            XCTAssertEqual(seen, Array(bytes[3..<50_003]))
        }
    }

    func testUnmappedMemoryIsAnErrorNotACrash() throws {
        let game = try game()
        XCTAssertNil(game.read(0x20000, count: 8))
        XCTAssertNil(game.withBytes(0x20000, count: 8) { _ in true })
    }

    /// Inside FM, the plugin notices FM loading another save by the club's name no longer being where the read found it.
    func testClubNameIsReadWhereTheReadFoundTheTeam() throws {
        let game = try game()
        let name = Array("Molde FK".utf8)
        let text = UnsafeMutableRawPointer.allocate(byteCount: 4 + name.count, alignment: 8)
        let club = UnsafeMutableRawPointer.allocate(byteCount: 256, alignment: 8)
        let team = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { [text, club, team].forEach { $0.deallocate() } }
        text.storeBytes(of: Int32(name.count), as: Int32.self)
        name.withUnsafeBytes { (text + 4).copyMemory(from: $0.baseAddress!, byteCount: name.count) }
        club.initializeMemory(as: UInt8.self, repeating: 0, count: 256)
        team.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        club.storeBytes(of: Int64(Int(bitPattern: text)), toByteOffset: MacLayout.Club.fullName, as: Int64.self)
        team.storeBytes(of: Int64(Int(bitPattern: club)), toByteOffset: MacLayout.Team.club, as: Int64.self)
        let address = Int64(Int(bitPattern: team))

        XCTAssertEqual(GameReader.clubName(team: address, in: game), "Molde FK")
        // FM has let go of the team, and something else is there now.
        team.storeBytes(of: Int64(0), toByteOffset: MacLayout.Team.club, as: Int64.self)
        XCTAssertEqual(GameReader.clubName(team: address, in: game), "")
        XCTAssertEqual(GameReader.clubName(team: 0, in: game), "")
        XCTAssertEqual(GameReader.clubName(team: 0x20000, in: game), "", "Unmapped")
    }

    /// The reader's own locals would otherwise be found there as records.
    func testLeavesOutThreadStacks() throws {
        let game = try game()
        var local: Int64 = 0x5EED
        let address = withUnsafeMutablePointer(to: &local) { Int64(Int(bitPattern: $0)) }
        XCTAssertFalse(game.regions.contains { $0.base <= address && address < $0.base + $0.size })
    }

    /// The sweep still covers malloc's small zones, where FM keeps records such as human managers, but knows them.
    func testKnowsMallocsSmallZones() throws {
        let small = try XCTUnwrap(malloc(64)), large = try XCTUnwrap(malloc(8 << 20))
        defer { free(small); free(large) }
        memset(small, 1, 64)
        memset(large, 1, 8 << 20)
        let smallAddress = Int64(Int(bitPattern: small)), largeAddress = Int64(Int(bitPattern: large))
        let game = try game()
        XCTAssertTrue(game.regions.contains { $0.base <= smallAddress && smallAddress < $0.base + $0.size })
        XCTAssertTrue(game.inSmallHeap(smallAddress))
        XCTAssertFalse(game.inSmallHeap(largeAddress))
    }
}
