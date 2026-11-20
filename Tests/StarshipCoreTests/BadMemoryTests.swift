@testable import StarshipCore
import XCTest

/// The reader against records holding pointers no live record would: the leftover copies FM keeps, or the memory of a
/// save FM has let go. Inside FM a trap closes the game, so these must come back as nothing, not stop the process.
/// Every name and number is made up.
final class BadMemoryTests: XCTestCase {
    /// Just short of the top of the address space, where adding a field's offset overflows.
    private static let nearTop = Int64.max - 3

    func testPointersNearTheTopOfMemoryReadAsNothing() throws {
        let game = FakeGame()
        let club = game.club(full: "Mockport Rovers FC", short: "Mockport", nation: Self.nearTop)
        let team = game.team(club: club, index: 0x1267, type: 0, competition: Self.nearTop)
        var player = FakeGame.PlayerValues()
        player.person.nation = Self.nearTop
        player.person.contract?.team = Self.nearTop
        player.person.contract?.fallbackTeam = Self.nearTop
        game.player(player)
        // A member of staff at a real club, whose other team is garbage: that's where their squad is read.
        var staff = FakeGame.StaffValues()
        staff.person.uid = 2
        staff.person.contract?.team = team
        staff.person.contract?.fallbackTeam = Self.nearTop
        game.staff(staff)

        let database = try game.read()
        let read = try XCTUnwrap(database.players.first)
        XCTAssertEqual(read.nation, "")
        XCTAssertEqual(read.club, "")
        let member = try XCTUnwrap(database.staff.first)
        XCTAssertEqual(member.clubFull, "Mockport Rovers FC")
        XCTAssertEqual(member.clubNation, "")
        XCTAssertEqual(member.league, "")
        XCTAssertEqual(member.squad, "")
    }

    func testFarApartBoundsReadAsNoClausesAndNoInjuries() throws {
        let game = FakeGame()
        // Far enough apart that `end - begin` overflows.
        let list = game.record("Injury list", size: 16)
        list.set("begin", 0, Int64.min + 8)
        list.set("end", 8, Int64.max - 8)
        var player = FakeGame.PlayerValues()
        player.history = list.address
        player.person.contract?.clausesAt = (Int64.min + 8, Int64.max - 8)
        game.player(player)

        let read = try XCTUnwrap(try game.read().players.first)
        XCTAssertNil(read.injuries)
        XCTAssertEqual(read.releaseClause, 0)
    }

    /// FM Starship inside FM asks this every few seconds to notice another save, by when the team it read is gone.
    func testClubNameOfAGoneTeamIsEmpty() {
        let game = FakeGame()
        let team = game.team(club: Self.nearTop, index: 1, type: 0, competition: 0)
        let process = game.process()
        XCTAssertEqual(GameReader.clubName(team: team, in: process), "")
        XCTAssertEqual(GameReader.clubName(team: Self.nearTop, in: process), "")
    }

    func testANegativeCountReadsNothing() {
        let game = FakeGame()
        let at = game.allocate(16)
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertFalse(buffer.withUnsafeMutableBytes { game.process().read(at, into: $0.baseAddress!, count: -1) })
    }
}
