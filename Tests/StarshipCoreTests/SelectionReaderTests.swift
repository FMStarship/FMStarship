@testable import StarshipCore
import XCTest

/// A tactic's eleven and bench as FM's PREPARED_TACTICS_CREATOR_ARRAY lists them, and FM's opposition reports, in made-up
/// memory laid out as `MacLayout` says.
final class SelectionReaderTests: XCTestCase {
    typealias T = MacLayout.Tactic
    typealias S = MacLayout.ScoutReport

    /// A 4-4-2's places, as FM's TACTICS_CREATOR keeps them with and without the ball: a position bit with its side, and a role bit.
    private static let places: [(String, UInt64)] = [("GK", 0), ("DR", 0), ("DC", T.right), ("DC", T.left), ("DL", 0), ("MR", 0),
                                                     ("MC", T.right), ("MC", T.left), ("ML", 0), ("ST", T.right), ("ST", T.left)]

    private static func creator(_ game: FakeGame) -> Int64 {
        let creator = game.record("TACTICS_CREATOR", size: Int(T.withoutBall) + T.slots * Int(T.slotSize))
        for (phase, base) in [("with", T.withBall), ("without", T.withoutBall)] {
            for (slot, place) in places.enumerated() {
                let position = Names.positions.firstIndex(of: place.0)!
                let at = Int(base) + slot * Int(T.slotSize)
                creator.set("\(phase) \(slot) position", at, (UInt64(1) << UInt64(Names.posToGame[position])) | place.1)
                creator.set("\(phase) \(slot) role", at + T.slotRole, UInt64(1) << UInt64(slot % 8))
            }
        }
        return creator.address
    }

    /// The array at `address`, already allocated, naming these players: 26 places, `nil` for an empty one.
    private static func fill(_ game: FakeGame, array: FakeRecord, at offset: Int = 0, ids: [UInt32?], creator: Int64) {
        let holder = game.record("creator holder", size: 8)
        holder.set("creator", 0, creator)
        array.set("creators", offset + Int(T.arrayCreators), holder.address)
        let padded = ids + Array(repeating: nil, count: T.places - ids.count)
        array.set("players", offset + Int(T.arrayPlayers), bytes: padded.flatMap { id in
            withUnsafeBytes(of: id ?? T.empty) { Array($0) }
        })
    }

    private static func players(_ indexes: ClosedRange<UInt32>) -> [UInt32: Player] {
        Dictionary(uniqueKeysWithValues: indexes.map { index in
            let player = Player()
            player.index = index
            player.commonName = "Player \(index)"
            return (index, player)
        })
    }

    func testTheBenchFollowsTheElevenWithItsGapsKept() throws {
        let game = FakeGame()
        let array = game.record("PREPARED_TACTICS_CREATOR_ARRAY", size: 0x90)
        let ids: [UInt32?] = Array(1...11) + [12, nil, nil, 13, 14, 999]
        Self.fill(game, array: array, ids: ids, creator: Self.creator(game))
        let tactic = try XCTUnwrap(GameReader.tactic(at: array.address, in: game.process(), players: Self.players(1...14)))
        XCTAssertEqual(tactic.array, array.address)
        XCTAssertEqual(tactic.slots.map(\.index), Array(1...11))
        XCTAssertEqual(tactic.slots.map(\.label), ["GK", "DR", "DC (R)", "DC (L)", "DL", "MR", "MC (R)", "MC (L)", "ML", "ST (R)", "ST (L)"])
        XCTAssertEqual(tactic.bench.count, T.places - T.slots)
        XCTAssertEqual(tactic.bench.prefix(6).map { $0?.index }, [12, nil, nil, 13, 14, 999])
        XCTAssertEqual(tactic.substitutes.map(\.place), [1, 4, 5, 6])
        XCTAssertEqual(tactic.substitutes.map { $0.sub.player?.name }, ["Player 12", "Player 13", "Player 14", nil], "999 isn't read")
    }

    /// The array is read again where it was found, so a change made in FM's tactics since the read shows.
    func testTheLineUpIsReadAgainWhereItWasFound() throws {
        let game = FakeGame()
        let array = game.record("PREPARED_TACTICS_CREATOR_ARRAY", size: 0x90)
        Self.fill(game, array: array, ids: Array(1...12), creator: Self.creator(game))
        let players = Self.players(1...14)
        var found = try XCTUnwrap(GameReader.tactic(at: array.address, in: game.process(), players: players))
        found.fmShape = "4-4-2"
        game.poke(UInt32(14), at: array.address + T.arrayPlayers + 4 * Int64(T.slots))
        let reader = SelectionReader(game: game.process(), rtti: Rtti(game.process()))
        let again = try XCTUnwrap(reader.tactic(again: found, players: players))
        XCTAssertEqual(again.substitutes.first?.sub.index, 14)
        XCTAssertEqual(again.fmShape, "4-4-2", "FM's name for the shape is kept")
        XCTAssertNil(reader.tactic(again: Tactic(slots: found.slots), players: players), "one made by hand has no array")
    }

    /// Pointers from memory that lead nowhere read as no tactic, without trapping.
    func testAGarbageArrayReadsAsNoTactic() {
        let game = FakeGame()
        let array = game.record("PREPARED_TACTICS_CREATOR_ARRAY", size: 0x90)
        Self.fill(game, array: array, ids: Array(1...11), creator: Int64.max - 3)
        XCTAssertNil(GameReader.tactic(at: array.address, in: game.process(), players: [:]))
        XCTAssertNil(GameReader.tactic(at: Int64.max - 3, in: game.process(), players: [:]))
    }

    /// FM keeps two copies of each report: one comes out, newest first, with its date.
    func testScoutReportsComeOutOncePerDateNewestFirst() throws {
        let game = FakeGame()
        let creator = Self.creator(game)
        let size = Int(S.tactics[1] + S.tacticArray) + 0x90
        func report(day: UInt16, ids: [UInt32?]) -> FakeRecord {
            let report = game.record("SCOUT_TEAM_REPORT_NEWS", size: size, vtable: "SCOUT_TEAM_REPORT_NEWS")
            report.set("day", Int(S.day), day)
            report.set("year", Int(S.year), UInt16(2029))
            Self.fill(game, array: report, at: Int(S.tactics[0] + S.tacticArray), ids: ids, creator: creator)
            return report
        }
        let older = report(day: 279, ids: Array(21...31) + [32])
        _ = report(day: 287, ids: Array(1...11) + [12, nil, 13])
        _ = game.copy(older)
        let reader = SelectionReader(game: game.process(), rtti: Rtti(game.process()))
        XCTAssertTrue(reader.findsReports)
        let reports = reader.scoutReports(players: Self.players(1...32))
        XCTAssertEqual(reports.map { Output.day($0.date) }, [287, 279])
        XCTAssertEqual(reports.first?.tactic.substitutes.map(\.place), [1, 3])
        XCTAssertEqual(reports.last?.tactic.slots.first?.player?.name, "Player 21")
    }
}

private enum Output {
    static func day(_ date: Date) -> Int { GameDate.calendar.ordinality(of: .day, in: .year, for: date) ?? 0 }
}
