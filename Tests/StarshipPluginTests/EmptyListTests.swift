@testable import StarshipPlugin
import StarshipAnalysis
import StarshipCore
import XCTest

/// FM's table with nobody in it stands empty with no word of why, so a list with nobody in it says why in its place.
final class EmptyListTests: XCTestCase {
    private static let club = "Testing FC"

    private func player(_ uid: UInt32, age: Int, at club: String) -> Player {
        let player = Player()
        player.uid = uid
        player.block = 1
        player.club = club
        player.clubFull = club
        player.age = age
        player.ca = 140
        player.pa = 180
        player.value = Int64(uid) * 100_000
        for position in player.pos.indices { player.pos[position] = 20 }
        return player
    }

    /// With Hidden attributes off, and youngsters at another club who'd be picked with it on.
    private var hiddenOff: AnalysisSession { hiddenOff(insideGame: false) }

    private func hiddenOff(insideGame: Bool) -> AnalysisSession {
        let db = Database()
        db.players = (1...12).map { player(UInt32($0), age: 26, at: Self.club) } + (21...26).map { player(UInt32($0), age: 18, at: "Rivals FC") }
        db.gameDate = GameDate.checked(year: 2026, dayOfYear: 270)
        return AnalysisSession(db: db, club: ChosenClub(team: 1, name: Self.club), display: DisplayOptions(reveal: .hidden, showHidden: false, insideGame: insideGame))
    }

    private func section(_ table: AnalysisTable, notes: [String] = []) -> TableSection {
        TableSection(title: "Recommended signings", table: table, notes: notes, fmColumns: ["name", "age"])
    }

    func testYoungstersWithHiddenAttributesOffSayWhyWhereTheTableWouldBe() throws {
        let session = hiddenOff
        let young = try XCTUnwrap(SigningRecommender(session: session).find(RecommendOptions(mode: .young)))
        let wonderkids = try XCTUnwrap(BargainFinder(session: session).find(BargainOptions(kind: .wonderkid)))
        for table in [young, wonderkids] {
            let list = section(table)
            XCTAssertFalse(list.hasPeople, "No table goes in")
            XCTAssertTrue(table.head.contains("is off. \(session.display.abilityHint) to see them."), table.head)
            XCTAssertEqual(list.inPlaceOfTable, table.head)
            XCTAssertEqual(list.headingNote, "", "Said once, where the table would be")
        }
    }

    func testInsideFMTheyPointAtTheSwitchInFMStarshipsTab() throws {
        let session = hiddenOff(insideGame: true)
        let young = try XCTUnwrap(SigningRecommender(session: session).find(RecommendOptions(mode: .young)))
        let wonderkids = try XCTUnwrap(BargainFinder(session: session).find(BargainOptions(kind: .wonderkid)))
        for table in [young, wonderkids] {
            let line = try XCTUnwrap(section(table).inPlaceOfTable)
            XCTAssertTrue(line.hasSuffix("is off. Switch on Hidden attributes at the top right of FM Starship's tab to see them."), line)
            XCTAssertFalse(line.contains("toolbar"), line)
        }
    }

    func testAListWithPeopleKeepsItsTableAndItsLineOverIt() {
        let table = AnalysisTable(columns: [TableColumn("Name", 5)],
                                  rows: [TableRow(cells: ["Abel"], person: player(1, age: 20, at: "Brann"))],
                                  head: "4-2-3-1. Stars are FM's own, for the role in each place.")
        XCTAssertTrue(section(table).hasPeople)
        XCTAssertEqual(section(table).headingNote, table.head)
        XCTAssertNil(section(table).inPlaceOfTable)
    }

    func testTheLinesUnderAListWithNobodySayWhyThemselves() {
        // Shown under it already: its status line, its rows about nobody, and its notes.
        let nobodyFound = AnalysisTable(columns: [TableColumn("Name", 5)],
                                        status: "Nobody found who would join you with these settings - try a higher max fee.")
        let gap = AnalysisTable(columns: [TableColumn("Name", 5)], rows: [TableRow(cells: ["Left back", " ", "Nobody fits the budget"])])
        for list in [section(nobodyFound), section(gap), section(AnalysisTable(), notes: ["Loans are left out."])] {
            XCTAssertFalse(list.hasPeople)
            XCTAssertNil(list.inPlaceOfTable)
        }
    }

    func testAListWithNoWordsAtAllSaysThereIsNobody() {
        // The app's hints are left out of the status line, so they don't count; nor do blank rows and notes.
        let table = AnalysisTable(columns: [TableColumn("Name", 5)], rows: [TableRow(cells: ["", " "])],
                                  status: "Double-click a player for the full profile.")
        XCTAssertEqual(section(table, notes: [""]).inPlaceOfTable, "Nobody to show.")
        XCTAssertEqual(section(AnalysisTable()).inPlaceOfTable, "Nobody to show.")
    }
}
