import StarshipCore
import StarshipFiles
import XCTest

final class ShortlistFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testRoundTrip() throws {
        for isStaff in [false, true] {
            let file = try ShortlistFile.encode(name: "Mål 2026", isStaff: isStaff, uids: [7, 2_000_000_001, 7, 42])
            XCTAssertEqual(try ShortlistFile.parse(file), Shortlist(name: "Mål 2026", isStaff: isStaff, uids: [7, 2_000_000_001, 42]))
        }
    }

    func testEmptyList() throws {
        let file = try ShortlistFile.encode(name: "Empty", isStaff: false, uids: [])
        XCTAssertEqual(try ShortlistFile.parse(file).uids, [])
    }

    func testCreateRefusesATakenName() throws {
        let url = try ShortlistFile.create(name: "Targets", isStaff: false, uids: [1], in: folder)
        XCTAssertThrowsError(try ShortlistFile.create(name: "Targets", isStaff: false, uids: [2], in: folder)) {
            XCTAssertEqual($0 as? ShortlistError, .alreadyExists(url))
        }
        XCTAssertEqual(try ShortlistFile.read(url).uids, [1])
    }

    func testAddKeepsABackupAndSkipsPeopleAlreadyThere() throws {
        let url = try ShortlistFile.create(name: "Targets", isStaff: false, uids: [1, 2], in: folder)
        let (shortlist, added) = try ShortlistFile.add([2, 3], to: url)
        XCTAssertEqual(added, 1)
        XCTAssertEqual(shortlist.uids, [1, 2, 3])
        XCTAssertEqual(try ShortlistFile.read(url).uids, [1, 2, 3])
        XCTAssertEqual(try ShortlistFile.read(ShortlistFile.backupURL(for: url)).uids, [1, 2])
    }

    func testFileNamesStayLegalOnWindows() {
        XCTAssertEqual(ShortlistFile.sanitizedFileName("a/b:c*d?\"e<f>g|h\\i"), "abcdefghi")
    }

    func testDamagedFilesAreRefused() throws {
        var file = try ShortlistFile.encode(name: "Targets", isStaff: false, uids: [1])
        file[26] ^= 0xff
        XCTAssertThrowsError(try ShortlistFile.parse(file)) { XCTAssertEqual($0 as? ShortlistError, .notFMFile) }
    }

    /// A file FM wrote itself has to be recognised as FM's container, not refused as damaged.
    func testRecognisesAContainerFMWrote() throws {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sports Interactive/Football Manager 26/cloud/tactics")
        let files = (try? FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? []
        guard let real = files.first(where: { $0.pathExtension == ShortlistFile.fileExtension }) else {
            throw XCTSkip("No FM file on this Mac")
        }
        XCTAssertThrowsError(try ShortlistFile.read(real)) { XCTAssertEqual($0 as? ShortlistError, .notShortlist) }
    }
}

/// Reads the real game's files, so it proves the formats against what FM ships.
final class FMDataTests: XCTestCase {
    private func library() throws -> TacticLibrary {
        guard let library = FMData.library else { throw XCTSkip("Football Manager 27 isn't installed here") }
        return library
    }

    func testReadsEveryPresetAndStyle() throws {
        let library = try library()
        XCTAssertEqual(library.presets.count, 90)
        // An eleventh style, Clean Slate, is FM's blank page and has no presets.
        XCTAssertEqual(library.styles.filter { style in library.presets.contains { $0.style == style.id } }.count, 10)
        XCTAssertTrue(library.presets.allSatisfy { $0.slots.count == 11 && $0.slots[0].position == 0 })
        XCTAssertTrue(library.presets.allSatisfy { preset in library.styles.contains { $0.id == preset.style } })
    }

    func testPresetRolesAreOnesTheGameAllowsThere() throws {
        for preset in try library().presets {
            for slot in preset.slots {
                XCTAssertTrue(slot.allowedRoles.contains(slot.role), preset.name)
                XCTAssertTrue(slot.allowedRolesWithoutBall.contains(slot.roleWithoutBall), preset.name)
                XCTAssertNotNil(Names.rolesIp[slot.role], preset.name)
                XCTAssertNotNil(Names.rolesOop[slot.roleWithoutBall], preset.name)
            }
        }
    }

    func testGegenpressMatchesTheScreenInFM() throws {
        let library = try library()
        let preset = try XCTUnwrap(library.presets.first { $0.name == "Gegenpress 4-2-3-1 - 4-4-2" })
        XCTAssertEqual(preset.shape, "4-2-3-1 DM AM Wide")
        XCTAssertEqual(preset.shapeWithoutBall, "4-4-2 2DM")
        let roles = preset.slots.map { Names.rolesIp[$0.role] ?? "" }
        XCTAssertTrue(roles.contains("Second Striker") && roles.contains("Deep-Lying Playmaker"))
        let style = try XCTUnwrap(library.styles.first { $0.id == "gegenpress" })
        XCTAssertEqual(style.favouredAttributes, ["Stamina", "Acceleration", "Dribbling"])
        XCTAssertTrue(style.preferredRoles.contains("Second Striker"))
    }

    private func tacticSlot(_ slot: PresetSlot) -> TacticSlot {
        TacticSlot(player: nil, position: slot.position, positionWithoutBall: slot.positionWithoutBall, side: slot.side, sideWithoutBall: slot.sideWithoutBall,
                   role: slot.role, roleWithoutBall: slot.roleWithoutBall)
    }

    func testEveryRoleHasAComplexity() throws {
        let library = try library()
        for preset in library.presets {
            for slot in preset.slots.map(tacticSlot) {
                XCTAssertNotNil(library.complexity(of: slot), slot.roleName + " / " + slot.roleNameWithoutBall)
            }
        }
    }

    /// FM's file names say what FM calls each of its own shapes, with the ball and without it.
    /// The planner's board, the narrowest there is, with every card as wide as the longest surname seen in a save.
    func testNoShapeFMShipsPutsOneCardOnAnother() throws {
        let board = CGSize(width: 320, height: 410)
        for preset in try library().presets {
            let slots = preset.slots.map(tacticSlot)
            let cards = slots.map { PitchPlan.Card(spot: PitchPlan.spot($0, among: slots), width: 104, height: 41) }
            let centres = PitchPlan.centres(cards, in: board)
            for (index, centre) in centres.enumerated() {
                XCTAssertGreaterThanOrEqual(centre.x - 52, 0, preset.name)
                XCTAssertLessThanOrEqual(centre.x + 52, board.width, preset.name)
                XCTAssertGreaterThanOrEqual(centre.y - 20.5, 0, preset.name)
                XCTAssertLessThanOrEqual(centre.y + 20.5, board.height, preset.name)
                for other in centres[(index + 1)...] {
                    XCTAssertFalse(abs(centre.x - other.x) < 104 && abs(centre.y - other.y) < 41, "\(preset.name) \(preset.shape): \(centre), \(other)")
                }
            }
        }
    }

    func testFormationNamesMatchEveryShapeFMShips() throws {
        let library = try library()
        for preset in library.presets {
            let tactic = Tactic(slots: preset.slots.map(tacticSlot))
            XCTAssertEqual(tactic.shape(in: library), preset.shape, preset.name)
            XCTAssertEqual(tactic.shapeWithoutBall(in: library), preset.shapeWithoutBall, preset.name)
        }
    }
}
