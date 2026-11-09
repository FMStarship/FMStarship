@testable import StarshipAnalysis
import StarshipCore
import XCTest

/// The app finds Open Squad's clubs and squads off the main thread, before the session exists.
final class OpenSquadTests: XCTestCase {
    private func database() -> Database {
        func player(_ club: String, _ squad: String, loanedTo loan: String = "") -> Player {
            let player = Player()
            player.clubFull = club
            player.squad = squad
            player.loanClub = loan
            return player
        }
        let coach = Staff()
        coach.clubFull = "Aalesund"
        let db = Database()
        db.players = [player("Molde", "First team"), player("Molde", "U19"), player("brann", "First team", loanedTo: "Molde"),
                      player("Bodø/Glimt", "First team")]
        db.staff = [coach]
        db.humanClubs = [(team: 1, name: "Molde", manager: 0)]
        return db
    }

    private func session(_ db: Database) -> AnalysisSession {
        AnalysisSession(db: db, club: ChosenClub(team: 1, name: "Molde"))
    }

    func testChoicesFoundAheadAreTheSame() {
        let db = database()
        let found = OpenSquad(session: session(db))
        let ahead = OpenSquad(session: session(db), choices: OpenSquad.Choices(db: db))
        XCTAssertEqual(ahead.clubs, ["Aalesund", "Bodø/Glimt", "brann", "Molde"])
        XCTAssertEqual(ahead.clubs, found.clubs)
        for club in found.clubs { XCTAssertEqual(ahead.squads(for: club), found.squads(for: club)) }
        XCTAssertEqual(ahead.squads(for: "brann"), [OpenSquad.allSquads, "First team", "On loan"])
        XCTAssertEqual(ahead.startingClub(), "Molde")
    }

    /// Choices from another read would list clubs that aren't in this one.
    func testChoicesFromAnotherDatabaseAreFoundAgain() {
        let old = database()
        let new = database()
        new.players.removeAll { $0.clubFull == "Bodø/Glimt" }
        let squads = OpenSquad(session: session(new), choices: OpenSquad.Choices(db: old))
        XCTAssertEqual(squads.clubs, ["Aalesund", "brann", "Molde"])
    }
}
