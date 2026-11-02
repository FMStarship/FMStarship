import StarshipCore
@testable import StarshipFiles
import XCTest

final class SnapshotSidesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testASnapshotKeepsWhoIsOnWhichSide() throws {
        let database = Database()
        let woman = Player(), man = Player()
        woman.uid = 1
        woman.isWoman = true
        man.uid = 2
        database.players = [woman, man]
        database.knowsSides = true
        database.womensTeams = [7]
        let file = folder.appendingPathComponent("sides.fmasnap")
        try Storage.saveSnapshot(database, to: file)

        let loaded = try Storage.loadSnapshot(from: file)
        XCTAssertEqual(loaded.players.map(\.isWoman), [true, false])
        XCTAssertTrue(loaded.knowsSides)
        XCTAssertEqual(loaded.womensTeams, [7])
    }

    /// The smallest version 1 file: one empty string, then every field and count of an empty database.
    func testAnOlderSnapshotStillOpensAndDoesntKnowTheSides() throws {
        var body: [UInt8] = [1, 0]
        body += [0, 0] + [UInt8](repeating: 0, count: 8) + [0, 0, 0, 0]
        body += [0, 0, 0, 0, 0]
        var file = Array("FMSTRSNP".utf8) + [1, 0, 0, 0]
        file += try Zstd.compress(body)
        let url = folder.appendingPathComponent("old.fmasnap")
        try Data(file).write(to: url)

        let loaded = try Storage.loadSnapshot(from: url)
        XCTAssertFalse(loaded.knowsSides)
        XCTAssertTrue(loaded.womensTeams.isEmpty)
    }
}
