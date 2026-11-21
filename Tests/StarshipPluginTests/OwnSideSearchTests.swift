@testable import FMStarshipUI
import StarshipCore
import StarshipSearch
import XCTest

/// The Players search starts on the side of men's and women's football the chosen club can sign from, the one FM
/// Starship's tab inside FM shows too. A squad or a shortlist shows everyone in it. None of it needs FM.
@MainActor
final class OwnSideSearchTests: XCTestCase {
    private var saved = Settings()

    override func setUp() {
        super.setUp()
        saved = Settings.current
        Settings.current = Settings()
    }

    override func tearDown() {
        // `install` fills the shared club list; leave it empty for the next test.
        RulesState.shared.fill(Database())
        Settings.current = saved
        super.tearDown()
    }

    private func player(_ uid: UInt32, woman: Bool) -> Player {
        let player = Player()
        player.uid = uid
        player.index = uid
        player.block = 1
        player.commonName = woman ? "Kari Nordmann" : "Ola Nordmann"
        player.isWoman = woman
        for position in player.pos.indices { player.pos[position] = 20 }
        player.prepare()
        return player
    }

    private func database(womensClub: Bool, knowsSides: Bool = true, clubs: Bool = true) -> Database {
        let db = Database()
        db.players = [player(1, woman: false), player(2, woman: true)]
        if clubs { db.humanClubs = [(team: 7, name: "Molde", manager: 0)] }
        db.knowsSides = knowsSides
        if womensClub { db.womensTeams = [7] }
        return db
    }

    /// The Players screen's rows once its search has finished.
    private func searched(_ model: AppModel) async throws -> Set<UInt32> {
        model.go(to: .players)
        model.search()
        for _ in 0..<500 where model.searching { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.searching, "The search finished")
        return Set(model.players.map(\.uid))
    }

    private func model(hidden: Bool, _ db: Database) -> AppModel {
        Settings.current.showHidden = hidden
        let model = AppModel()
        model.install(NewData(db))
        return model
    }

    func testOnlyThePlayersSearchStartsOnTheClubsSide() {
        for hidden in [false, true] {
            Settings.current.showHidden = hidden
            let model = AppModel()
            XCTAssertEqual(model.playerFilter.gender, PlayerFilter.ownSide)
            XCTAssertEqual(model.squadPlayerFilter.gender, "Any")
            XCTAssertEqual(model.listPlayerFilter.gender, "Any")
            model.showShortlist(nil)
            XCTAssertEqual(model.listPlayerFilter.gender, "Any", "A shortlist's fresh filter shows everyone on it")
        }
    }

    func testAMensClubsSearchLeavesOutWomen() async throws {
        for hidden in [false, true] {
            let model = model(hidden: hidden, database(womensClub: false))
            let found = try await searched(model)
            XCTAssertEqual(found, [1])
            XCTAssertEqual(model.filterSummary, "", "The default doesn't read as a filter")
        }
    }

    func testAWomensClubsSearchLeavesOutMen() async throws {
        let found = try await searched(model(hidden: false, database(womensClub: true)))
        XCTAssertEqual(found, [2])
    }

    func testUnknownSidesFilterNothing() async throws {
        let found = try await searched(model(hidden: true, database(womensClub: true, knowsSides: false)))
        XCTAssertEqual(found, [1, 2])
    }

    func testAnyShowsBothAndResetGoesBack() async throws {
        let model = model(hidden: false, database(womensClub: false))
        model.go(to: .players)
        model.playerFilter.gender = "Any"
        var found = try await searched(model)
        XCTAssertEqual(found, [1, 2])
        XCTAssertEqual(model.filterSummary, "men and women")
        model.resetFilters()
        XCTAssertEqual(model.playerFilter.gender, PlayerFilter.ownSide)
        found = try await searched(model)
        XCTAssertEqual(found, [1])
    }

    /// A choice the player made stays when another save is read, and when Hidden attributes changes.
    func testAChosenSideStays() {
        let model = model(hidden: false, database(womensClub: false))
        model.playerFilter.gender = "Women"
        model.install(NewData(database(womensClub: true)))
        XCTAssertEqual(model.playerFilter.gender, "Women")
        model.showHidden = true
        XCTAssertTrue(model.playerFilter.showHidden)
        XCTAssertEqual(model.playerFilter.gender, "Women")
    }

    /// FM Starship's tab says "No filters." for an empty line, so it names the side the default keeps, while the app's
    /// strip leaves the default out.
    func testTheTabSaysWhichSideTheDefaultKeeps() async throws {
        for hidden in [false, true] {
            let men = model(hidden: hidden, database(womensClub: false))
            _ = try await searched(men)
            XCTAssertEqual(men.listInsideGame(staff: false)?.filter, "men's players")
            XCTAssertEqual(men.filterSummary, "")
            men.playerFilter.ageMax = "21"
            XCTAssertEqual(men.listInsideGame(staff: false)?.filter, "men's players, age up to 21")
            XCTAssertEqual(men.filterSummary, "age up to 21")
            men.playerFilter.gender = "Any"
            XCTAssertEqual(men.listInsideGame(staff: false)?.filter, "men and women, age up to 21")

            let women = model(hidden: hidden, database(womensClub: true))
            _ = try await searched(women)
            XCTAssertEqual(women.listInsideGame(staff: false)?.filter, "women's players")
        }
        // When the side isn't known it keeps both, so there's nothing to say.
        let unknown = model(hidden: false, database(womensClub: true, knowsSides: false))
        _ = try await searched(unknown)
        XCTAssertEqual(unknown.listInsideGame(staff: false)?.filter, "")
    }

    /// Choosing another club in the sidebar runs the search again, so the rows follow that club's side.
    func testChangingClubSearchesAgain() async throws {
        let db = database(womensClub: false)
        db.humanClubs = [(team: 7, name: "Molde", manager: 0), (team: 8, name: "Rosenborg", manager: 0)]
        db.womensTeams = [8]
        let model = model(hidden: false, db)
        model.pickClub("Molde")
        var found = try await searched(model)
        XCTAssertEqual(found, [1])
        model.pickClub("Rosenborg")
        XCTAssertTrue(model.searching, "Picking the club started a search")
        for _ in 0..<500 where model.searching { try await Task.sleep(for: .milliseconds(10)) }
        found = Set(model.players.map(\.uid))
        XCTAssertEqual(found, [2])
        XCTAssertEqual(model.listInsideGame(staff: false)?.filter, "women's players")
    }

    /// With no club, there's no side to keep, so the search shows both.
    func testNoClubFiltersNothing() async throws {
        for hidden in [false, true] {
            let model = model(hidden: hidden, database(womensClub: false, clubs: false))
            let found = try await searched(model)
            XCTAssertEqual(found, [1, 2])
            XCTAssertNil(model.session?.clubSignsWomen)
            XCTAssertEqual(model.listInsideGame(staff: false)?.filter, "")
        }
    }
}
