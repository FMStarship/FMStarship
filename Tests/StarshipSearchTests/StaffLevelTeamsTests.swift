@testable import StarshipCore
import StarshipSearch
import XCTest

/// The Staff search's Interest column and its "Interested in joining you" toggles name the teams FM's staff rule asks about:
/// for Molde, FM's reserves and youth levels are both its U19, and Molde 2 isn't asked about at all.
final class StaffLevelTeamsTests: XCTestCase {
    private final class Engine: GameRulesEngine {
        private let lock = NSLock()
        var levelTeams: [Int: TeamAtLevel] = [1: TeamAtLevel(object: 1, type: 0), 3: TeamAtLevel(object: 21, type: 11),
                                              4: TeamAtLevel(object: 21, type: 11)]
        /// FM's levels whose team can't be told, as when the call fails.
        var failing: Set<Int> = []
        private var calls = 0
        var levelTeamCalls: Int { lock.withLock { calls } }

        var supportsInjuryDays: Bool { false }
        func interest(player: Player, team: Int64) -> (transfer: JoinInterest, loan: JoinInterest)? { nil }
        /// Yes at FM's first-team and reserves levels, no at its youth level.
        func staffInterest(staff: Staff, team: Int64, level: Int) -> Bool? { level != 4 }
        func staffLevelTeam(team: Int64, level: Int) -> TeamAtLevel? {
            lock.withLock { calls += 1 }
            return failing.contains(level) ? nil : levelTeams[level]
        }
        func preferredJob(staff: Staff) -> Int? { nil }
        func jobPreferences(staff: Staff) -> [UInt8]? { nil }
        func roleRows(player: Player, team: Int64) -> [RoleRow]? { nil }
        func seasonStats(player: Player, season: Int) -> SeasonStats? { nil }
        func form(player: Player) -> String? { nil }
        func injuryReturnDays(player: Player) -> Int? { nil }
    }

    private var savedClub = ""

    override func setUp() {
        super.setUp()
        savedClub = Settings.current.interestClub
    }

    override func tearDown() {
        GameRules.engine = nil
        RulesState.shared.reset()
        RulesState.shared.fill(Database())
        Settings.current.interestClub = savedClub
        super.tearDown()
    }

    private func start(_ engine: Engine) -> RulesState {
        GameRules.engine = engine
        let db = Database()
        db.humanClubs = [(team: 1, name: "Molde", manager: 9)]
        let rules = RulesState.shared
        rules.reset()
        rules.fill(db)
        XCTAssertEqual(rules.team, 1)
        return rules
    }

    private func coach(_ index: UInt32) -> Staff {
        let staff = Staff()
        staff.index = index
        staff.block = 0x1000 + Int64(index) * 0x400
        staff.job = "Coach"
        return staff
    }

    private func label(_ id: String) throws -> String? {
        let field = try XCTUnwrap(StaffFilter.sections.flatMap(\.fields).first { $0.id == id })
        return StaffFilter.label(for: field)
    }

    func testInterestNamesTheTeamsFMAskedAbout() {
        let engine = Engine()
        engine.failing = [3]
        let rules = start(engine)
        let person = coach(7)
        XCTAssertNotNil(rules.staffCheck(person))
        XCTAssertEqual(rules.staffText(person), "First team, Reserves", "FM's own level names while it can't tell which team")
        XCTAssertNil(rules.knownStaffLevelTeams, "not kept while a level is missing")

        engine.failing = []
        XCTAssertEqual(rules.staffText(person), "First team, U19", "asked again, and the U19 named once")
        let calls = engine.levelTeamCalls
        XCTAssertEqual(rules.staffText(person), "First team, U19")
        XCTAssertEqual(engine.levelTeamCalls, calls, "kept once FM answered for every level")

        rules.reset()
        XCTAssertNil(rules.knownStaffLevelTeams, "forgotten with the answers")
        XCTAssertEqual(rules.staffText(person), "")
        XCTAssertNotNil(rules.staffCheck(person))
        XCTAssertEqual(rules.staffText(person), "First team, U19")
        XCTAssertEqual(engine.levelTeamCalls, calls + 3, "asked again after a reset")
    }

    /// The background pass asks for the teams, so the list's text doesn't have to run FM's code.
    func testCheckingAllStaffAsksForTheTeams() {
        let rules = start(Engine())
        XCTAssertNil(rules.knownStaffLevelTeams)
        rules.checkAllStaff([coach(8)], workers: 1)
        XCTAssertEqual(rules.knownStaffLevelTeams?.map(\.object), [1, 21, 21])
    }

    func testTheTogglesAreNamedAfterTheTeams() throws {
        let rules = start(Engine())
        XCTAssertEqual(try label("firstTeam"), "First Team", "FM's own level names until the teams are known")
        XCTAssertEqual(try label("reserves"), "Reserves")
        XCTAssertEqual(try label("youthTeam"), "Youth Team")
        XCTAssertNil(try label("reservesOrYouth"))

        rules.checkAllStaff([coach(9)], workers: 1)
        XCTAssertEqual(try label("firstTeam"), "First team")
        XCTAssertNil(try label("reserves"), "FM's reserves and youth levels are the same team: one toggle")
        XCTAssertNil(try label("youthTeam"))
        XCTAssertEqual(try label("reservesOrYouth"), "U19")

        // A filter set before, with Reserves ticked, still filters, and the one toggle shows it and clears it.
        var filter = StaffFilter(showHidden: false, showAbility: false)
        filter.reserves = true
        XCTAssertTrue(filter.reservesOrYouth)
        XCTAssertTrue(filter.matchesInterest(coach(9)))
        XCTAssertTrue(filter.describe().contains("would join your U19"), filter.describe())
        filter.firstTeam = true
        filter.youthTeam = true
        XCTAssertTrue(filter.describe().contains("would join your first team / U19"), filter.describe())
        filter.reservesOrYouth = false
        XCTAssertFalse(filter.reserves || filter.youthTeam)
        filter.reservesOrYouth = true
        XCTAssertTrue(filter.reserves && filter.youthTeam)
    }

    func testTwoTeamsKeepTwoToggles() throws {
        let engine = Engine()
        engine.levelTeams[3] = TeamAtLevel(object: 22, type: 10)
        let rules = start(engine)
        rules.checkAllStaff([coach(10)], workers: 1)
        XCTAssertEqual(try label("reserves"), "U21")
        XCTAssertEqual(try label("youthTeam"), "U19")
        XCTAssertNil(try label("reservesOrYouth"))
        XCTAssertEqual(rules.staffText(coach(10)), "First team, U21")
    }
}
