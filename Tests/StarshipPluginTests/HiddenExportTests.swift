@testable import FMStarshipUI
import StarshipCore
import StarshipFiles
import StarshipSearch
import XCTest

/// With Hidden attributes off, an export has no hidden column, CA or PA, whatever columns it was asked for, and the
/// model's filters start from the setting rather than showing hidden values. None of it needs FM.
@MainActor
final class HiddenExportTests: XCTestCase {
    private var saved = Settings()

    override func setUp() {
        super.setUp()
        saved = Settings.current
        Settings.current = Settings()
    }

    override func tearDown() {
        Settings.current = saved
        super.tearDown()
    }

    private func model(hidden: Bool, reveal: Reveal = .exact) -> AppModel {
        Settings.current.showHidden = hidden
        Settings.current.reveal = reveal.rawValue
        return AppModel()
    }

    /// Hidden values no other column has: CA 187, PA 193, and 3 in every hidden attribute and personality number.
    private func player() -> Player {
        let player = Player()
        player.block = 1
        player.commonName = "Kari Nordmann"
        player.ca = 187
        player.pa = 193
        player.raw = [UInt8](repeating: 90, count: player.raw.count)
        for name in Names.hidden { player.raw[Names.playerIndex[name]!] = 15 }
        player.pers = [UInt8](repeating: 3, count: player.pers.count)
        player.prepare()
        return player
    }

    private func staff() -> Staff {
        let staff = Staff()
        staff.block = 1
        staff.commonName = "Ola Nordmann"
        staff.ca = 187
        staff.pa = 193
        staff.attr = [UInt8](repeating: 3, count: staff.attr.count)
        for name in Names.staffShown { staff.attr[Names.staffIndex[name]!] = 17 }
        staff.pers = [UInt8](repeating: 3, count: staff.pers.count)
        staff.prepare()
        return staff
    }

    /// Every column, as "every column" in the save panel asks for, all of them visible.
    private func everyColumn(_ columns: [Col]) -> [Col] {
        columns.map { col in
            var col = col
            col.visible = true
            return col
        }
    }

    private func csv(_ columns: [Col], _ person: Person, hidden: Bool, reveal: Reveal) -> [[String]] {
        let data = AppModel.exportFile(.csv, columns: everyColumn(columns), rows: [person], showHidden: hidden,
                                       showAbility: hidden && reveal != .hidden, reveal: reveal, title: "Test")
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { line in line.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: ["\u{FEFF}"]) } }
    }

    func testAPlayerExportHasNoHiddenColumnWhileHiddenAttributesIsOff() throws {
        let lines = csv(Columns.forPlayers(), player(), hidden: false, reveal: .exact)
        let header = try XCTUnwrap(lines.first)
        let row = try XCTUnwrap(lines.last)
        XCTAssertEqual(header.count, row.count)
        for name in ["CA", "PA", "Growth room"] + Names.hidden + Names.personality {
            XCTAssertFalse(header.contains(name), "\(name) isn't exported")
        }
        XCTAssertTrue(header.contains("Name"))
        XCTAssertTrue(row.contains("Kari Nordmann"))
        XCTAssertFalse(row.contains("187"), "No CA")
        XCTAssertFalse(row.contains("193"), "No PA")
        XCTAssertFalse(row.contains("3"), "No hidden attribute or personality number")

        let expected = Columns.forPlayers().filter { !$0.hidden && !$0.ability }.map(\.name)
        XCTAssertEqual(header, expected, "Everything else is still exported")
    }

    func testAStaffExportHasNoHiddenColumnWhileHiddenAttributesIsOff() throws {
        let lines = csv(Columns.forStaff(), staff(), hidden: false, reveal: .exact)
        let header = try XCTUnwrap(lines.first)
        let row = try XCTUnwrap(lines.last)
        XCTAssertFalse(header.contains("CA"))
        XCTAssertFalse(header.contains("PA"))
        for name in Columns.forStaff().filter(\.hidden).map(\.name) + Names.personality { XCTAssertFalse(header.contains(name), name) }
        XCTAssertTrue(row.contains("Ola Nordmann"))
        XCTAssertFalse(row.contains("187"))
        XCTAssertFalse(row.contains("193"))
        XCTAssertFalse(row.contains("3"), "No hidden attribute or personality number")
        XCTAssertEqual(header, Columns.forStaff().filter { !$0.hidden && !$0.ability }.map(\.name))
    }

    func testAnExportHasThemWhileHiddenAttributesIsOn() throws {
        let lines = csv(Columns.forPlayers(), player(), hidden: true, reveal: .exact)
        let header = try XCTUnwrap(lines.first)
        let row = try XCTUnwrap(lines.last)
        for name in ["CA", "PA"] + Names.hidden + Names.personality { XCTAssertTrue(header.contains(name), name) }
        XCTAssertEqual(row[try XCTUnwrap(header.firstIndex(of: "CA"))], "187")
        XCTAssertEqual(row[try XCTUnwrap(header.firstIndex(of: "Consistency"))], "3")
    }

    func testHiddenAttributesOnWithAbilityOffExportsNoCAOrPA() throws {
        let header = try XCTUnwrap(csv(Columns.forPlayers(), player(), hidden: true, reveal: .hidden).first)
        XCTAssertFalse(header.contains("CA"))
        XCTAssertFalse(header.contains("PA"))
        XCTAssertTrue(header.contains("Consistency"))
    }

    // MARK: The model

    func testTheModelsFiltersFollowTheSettingFromTheStart() {
        let off = model(hidden: false)
        for filter in [off.playerFilter, off.squadPlayerFilter, off.listPlayerFilter] {
            XCTAssertFalse(filter.showHidden)
            XCTAssertFalse(filter.showAbility)
        }
        for filter in [off.staffFilter, off.squadStaffFilter, off.listStaffFilter] { XCTAssertFalse(filter.showHidden) }

        let on = model(hidden: true)
        XCTAssertTrue(on.playerFilter.showHidden)
        XCTAssertTrue(on.playerFilter.showAbility)
        XCTAssertTrue(on.staffFilter.showHidden)

        let abilityOff = model(hidden: true, reveal: .hidden)
        XCTAssertTrue(abilityOff.playerFilter.showHidden)
        XCTAssertFalse(abilityOff.playerFilter.showAbility)
    }

    func testAShortlistsFreshFiltersFollowTheSetting() {
        let model = model(hidden: false)
        model.showShortlist(nil)
        XCTAssertFalse(model.listPlayerFilter.showHidden)
        XCTAssertFalse(model.listPlayerFilter.showAbility)
        model.showShortlist(OpenShortlist(url: URL(fileURLWithPath: "/nonexistent/Test.fmsl"), name: "Test", isStaff: true, uids: []))
        XCTAssertFalse(model.listStaffFilter.showHidden)
    }

    func testAColumnFilterOnAHiddenColumnDoesNothingWhileHiddenAttributesIsOff() {
        let columns = everyColumn(Columns.forPlayers())
        let texts = ["Consistency": ">10", "CA": ">100", "Loyalty": ">10", "Age": ">20"]
        XCTAssertEqual(Set(model(hidden: true).parsedFilters(columns, texts).map(\.col.name)), Set(texts.keys))
        XCTAssertEqual(model(hidden: false).parsedFilters(columns, texts).map(\.col.name), ["Age"])
    }
}
