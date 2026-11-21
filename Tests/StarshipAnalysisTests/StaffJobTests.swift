import StarshipAnalysis
import StarshipCore
import XCTest

/// What FM is asked about the job itself in Recommended staff, and whose preference Wants job reads.
final class StaffJobTests: XCTestCase {
    func testEveryJobHasFMsNumber() {
        for role in StaffRoles.all {
            XCTAssertNotNil(StaffRoles.jobCode(role.name), role.name)
        }
        XCTAssertEqual(StaffRoles.jobCode("Recruitment Analyst"), 58)
        XCTAssertEqual(StaffRoles.jobCode("Head Physio"), 50)
    }

    func testATeamsJobIsAskedAtItsTeamAndAClubsJobWithTheFirstTeam() throws {
        let assistant = try XCTUnwrap(StaffRoles.base.first { $0.name == "Assistant Manager" })
        XCTAssertEqual(StaffRecommender.jobQuestion(role: assistant, level: 2)?.level, 2)
        let coach = try XCTUnwrap(StaffRoles.all.first { $0.name == "Coach" && $0.level == 1 })
        XCTAssertEqual(StaffRecommender.jobQuestion(role: coach, level: 1)?.job, 2)
        XCTAssertEqual(StaffRecommender.jobQuestion(role: coach, level: 1)?.level, 1)
        let analyst = try XCTUnwrap(StaffRoles.base.first { $0.name == "Recruitment Analyst" })
        XCTAssertEqual(StaffRecommender.jobQuestion(role: analyst, level: 1)?.level, 0)
    }

    /// FM keeps 15 job preferences. Five jobs here have none of their own.
    func testWantsJobSaysWhenItIsAnotherJobsPreference() {
        let noted = StaffRoles.base.filter { StaffRoles.preferenceNote($0.name) != nil }.map(\.name)
        XCTAssertEqual(Set(noted), ["Recruitment Analyst", "Head Performance Analyst", "Head of Sports Science", "Head Physio", "Chief Scout"])
        XCTAssertEqual(StaffRoles.preferenceNote("Head of Sports Science"),
                       "Wants job is how keen they are to be a sports scientist: FM keeps no preference for head of sports science.")
        XCTAssertEqual(StaffRoles.preferenceNote("Chief Scout"),
                       "Wants job is how keen they are to be a scout: FM keeps one preference for scout and chief scout.")
    }
}
