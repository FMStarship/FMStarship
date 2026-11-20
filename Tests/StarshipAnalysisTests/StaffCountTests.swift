import StarshipAnalysis
import StarshipCore
import StarshipSearch
import XCTest

/// Recommended staff's line about the club's own people for a job: a job that belongs to one team counts only that team's.
final class StaffCountTests: XCTestCase {
    private static let club = "Testing FC"

    private func staff(_ uid: UInt32, _ name: String, job: String, squad: String, attributes: UInt8) -> Staff {
        let person = Staff()
        person.uid = uid
        person.index = uid
        person.block = Int64(uid)
        person.commonName = name
        person.club = Self.club
        person.clubFull = Self.club
        person.job = job
        person.squad = squad
        person.attr = [UInt8](repeating: attributes, count: person.attr.count)
        return person
    }

    /// The reserves' assistant is the better one, so counting him for the first team would also make him "your best".
    private func head(level: Int) throws -> String? {
        let db = Database()
        db.staff = [staff(1, "First Assistant", job: "Assistant Manager", squad: "First team", attributes: 12),
                    staff(2, "Reserve Assistant", job: "Assistant Manager", squad: "Reserves", attributes: 16),
                    staff(3, "Scout One", job: "Scout", squad: "First team", attributes: 14),
                    staff(4, "Scout Two", job: "Scout", squad: "Reserves", attributes: 14)]
        let session = AnalysisSession(db: db, club: ChosenClub(team: 1, name: Self.club), display: DisplayOptions(reveal: .numbers, showHidden: true))
        let role = try XCTUnwrap(StaffRoles.all.first { $0.name == "Assistant Manager" && $0.level < 0 })
        return StaffRecommender(session: session).find(StaffSearchOptions(role: role, level: level, onlyJoin: false))?.head
    }

    func testATeamJobCountsOnlyTheChosenTeamsStaff() throws {
        let first = try XCTUnwrap(try head(level: 0))
        XCTAssertTrue(first.hasPrefix("You have 1 assistant manager"), first)
        XCTAssertTrue(first.contains("your best: First Assistant"), first)
        let reserves = try XCTUnwrap(try head(level: 1))
        XCTAssertTrue(reserves.contains("your best: Reserve Assistant"), reserves)
    }

    func testAClubWideJobCountsEveryone() throws {
        let db = Database()
        db.staff = [staff(3, "Scout One", job: "Scout", squad: "First team", attributes: 14),
                    staff(4, "Scout Two", job: "Scout", squad: "Reserves", attributes: 14)]
        let session = AnalysisSession(db: db, club: ChosenClub(team: 1, name: Self.club), display: DisplayOptions(reveal: .numbers, showHidden: true))
        let role = try XCTUnwrap(StaffRoles.all.first { $0.jobs.contains("Scout") && $0.teamJob < 0 })
        let head = try XCTUnwrap(StaffRecommender(session: session).find(StaffSearchOptions(role: role, onlyJoin: false))?.head)
        XCTAssertTrue(head.hasPrefix("You have 2 "), head)
    }
}
