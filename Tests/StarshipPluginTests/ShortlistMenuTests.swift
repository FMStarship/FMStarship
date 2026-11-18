@testable import FMStarshipUI
import StarshipCore
import StarshipFiles
import StarshipSearch
import XCTest

/// Right-clicking people in an open shortlist offers to take them off it, and only there. The shortlist is a file in a
/// temporary folder, never FM's own.
@MainActor
final class ShortlistMenuTests: XCTestCase {
    private var saved = Settings()
    private var folder: URL!

    override func setUpWithError() throws {
        saved = Settings.current
        Settings.current = Settings()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShortlistMenuTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Settings.current = saved
        try FileManager.default.removeItem(at: folder)
    }

    private func player(_ uid: UInt32, _ name: String) -> Player {
        let player = Player()
        player.uid = uid
        player.commonName = name
        player.prepare()
        return player
    }

    private func titles(_ entries: [MenuEntry]) -> [String] { entries.map(\.title) }

    func testTheOpenShortlistOffersToTakePeopleOffIt() throws {
        let url = try ShortlistFile.create(name: "Targets", isStaff: false, uids: [1, 2, 3], in: folder)
        let model = AppModel()
        model.go(to: .shortlists)
        model.showShortlist(OpenShortlist(url: url, name: "Targets", isStaff: false, uids: [1, 2, 3]))

        let on = player(2, "Kari Nordmann")
        let off = player(9, "Ola Nordmann")
        let entry = try XCTUnwrap(model.menuItems(for: [on]).first { $0.title == "Remove Kari Nordmann from \"Targets\"" })
        XCTAssertTrue(entry.enabled)
        XCTAssertEqual(model.menuItems(for: [off]).first { $0.title.hasPrefix("Remove") }?.enabled, false, "Not on it")

        guard case .action(let remove) = entry.kind else { return XCTFail("Not an action") }
        remove()
        XCTAssertEqual(try ShortlistFile.read(url).uids, [1, 3])
        XCTAssertEqual(model.openShortlist?.uids, [1, 3], "The open shortlist shows the change")
        XCTAssertEqual(try ShortlistFile.read(ShortlistFile.backupURL(for: url)).uids, [1, 2, 3])
    }

    func testOnlyTheShortlistsScreenOffersIt() throws {
        let url = try ShortlistFile.create(name: "Targets", isStaff: false, uids: [2], in: folder)
        let model = AppModel()
        model.go(to: .shortlists)
        model.showShortlist(OpenShortlist(url: url, name: "Targets", isStaff: false, uids: [2]))
        model.go(to: .dashboard)
        XCTAssertFalse(titles(model.menuItems(for: [player(2, "Kari Nordmann")])).contains { $0.hasPrefix("Remove") })
    }

    func testAStaffShortlistDoesntOfferToTakePlayersOff() throws {
        let url = try ShortlistFile.create(name: "Coaches", isStaff: true, uids: [2], in: folder)
        let model = AppModel()
        model.go(to: .shortlists)
        model.showShortlist(OpenShortlist(url: url, name: "Coaches", isStaff: true, uids: [2]))
        XCTAssertFalse(titles(model.menuItems(for: [player(2, "Kari Nordmann")])).contains { $0.hasPrefix("Remove") })
    }
}
