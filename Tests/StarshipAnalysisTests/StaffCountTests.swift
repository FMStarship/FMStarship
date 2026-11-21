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
    private func head(level: Int, squads: (first: String, second: String, youth: String) = ("First team", "Reserves", "U19"))
        throws -> String? {
        let db = Database()
        db.staff = [staff(1, "First Assistant", job: "Assistant Manager", squad: squads.first, attributes: 12),
                    staff(2, "Reserve Assistant", job: "Assistant Manager", squad: squads.second, attributes: 16),
                    staff(5, "Youth Assistant", job: "Assistant Manager", squad: squads.youth, attributes: 10),
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
        XCTAssertTrue(reserves.hasPrefix("You have 1 assistant manager"), reserves)
        XCTAssertTrue(reserves.contains("your best: Reserve Assistant"), reserves)
        let youth = try XCTUnwrap(try head(level: 2))
        XCTAssertTrue(youth.hasPrefix("You have 1 assistant manager"), youth)
        XCTAssertTrue(youth.contains("your best: Youth Assistant"), youth)
    }

    /// With no board limits, as here, the levels are called Reserves and Youth team, but a club's teams can be a B team and
    /// an U19, which count by level all the same.
    func testWithoutTheBoardsLimitsTeamsCountByLevel() throws {
        let squads = (first: "First team", second: "B team", youth: "U19")
        let reserves = try XCTUnwrap(try head(level: 1, squads: squads))
        XCTAssertTrue(reserves.hasPrefix("You have 1 assistant manager"), reserves)
        XCTAssertTrue(reserves.contains("your best: Reserve Assistant"), reserves)
        let youth = try XCTUnwrap(try head(level: 2, squads: squads))
        XCTAssertTrue(youth.hasPrefix("You have 1 assistant manager"), youth)
        XCTAssertTrue(youth.contains("your best: Youth Assistant"), youth)
    }

    /// A member of staff whose team FM Starship couldn't read counts for the first team, as in Staff review.
    func testAnUnknownSquadCountsAsTheFirstTeam() throws {
        let first = try XCTUnwrap(try head(level: 0, squads: (first: "", second: "U23", youth: "Youths")))
        XCTAssertTrue(first.hasPrefix("You have 1 assistant manager"), first)
        XCTAssertTrue(first.contains("your best: First Assistant"), first)
    }

    /// A level the club can't have counts everyone, rather than trapping.
    func testALevelOutOfRangeCountsEveryone() throws {
        for level in [-1, 3] {
            let head = try XCTUnwrap(try head(level: level))
            XCTAssertTrue(head.hasPrefix("You have 3 assistant managers"), head)
        }
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
