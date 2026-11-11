@testable import StarshipAnalysis
import StarshipCore
import XCTest

/// CA and PA are hidden in FM, so while they're off nothing on any screen may say or imply them.
final class AbilityOffTests: XCTestCase {
    private static let club = "Testing FC"

    private func player(_ uid: UInt32, age: Int, ca: Int, pa: Int, at club: String = AbilityOffTests.club) -> Player {
        let player = Player()
        player.uid = uid
        player.block = 1
        player.club = club
        player.clubFull = club
        player.squad = "First team"
        player.age = age
        player.ca = ca
        player.pa = pa
        player.value = Int64(uid) * 100_000
        player.wage = 1000
        player.endYear = 2027
        player.endDay = 100
        for position in player.pos.indices { player.pos[position] = 20 }
        return player
    }

    /// CAs and PAs that can't be mistaken for anything else in a cell, and a youngster and a rival club to bring out every report.
    private func session(_ reveal: AbilityReveal, showHidden: Bool) -> AnalysisSession {
        var squad = (1...12).map { player(UInt32($0), age: 26, ca: 171, pa: 183) }
        squad.append(player(13, age: 18, ca: 137, pa: 197))
        let rivals = (21...32).map { player(UInt32($0), age: 24, ca: 139, pa: 177, at: "Rivals FC") }
        let db = Database()
        db.players = squad + rivals
        db.gameDate = GameDate.checked(year: 2026, dayOfYear: 270)
        return AnalysisSession(db: db, club: ChosenClub(team: 1, name: Self.club), display: DisplayOptions(reveal: reveal, showHidden: showHidden))
    }

    private func assertGivesNothingAway(_ table: AnalysisTable?, file: StaticString = #filePath, line: UInt = #line) {
        guard let table else { return XCTFail("no table", file: file, line: line) }
        for title in table.columns.map(\.title) {
            XCTAssertFalse(AnalysisTable.abilityColumns.contains(title), title, file: file, line: line)
        }
        for text in table.rows.flatMap(\.cells) + [table.status] {
            XCTAssertNil(text.range(of: #"\b(CA|PA)\b"#, options: .regularExpression), text, file: file, line: line)
        }
        // The values themselves, and the 60 between the youngster's CA and PA.
        for text in table.rows.flatMap(\.cells) + [table.head, table.status] {
            XCTAssertNil(text.range(of: #"\b(171|183|137|197|139|177|60|\+?34)\b"#, options: .regularExpression), text, file: file, line: line)
        }
    }

    private var bothWaysOff: [AnalysisSession] { [session(.hidden, showHidden: false), session(.hidden, showHidden: true)] }

    func testNoClubReportGivesAbilityAway() {
        for session in bothWaysOff {
            let report = ClubReport(session: session)
            assertGivesNothingAway(report.health())
            assertGivesNothingAway(report.loans())
            assertGivesNothingAway(report.development())
            assertGivesNothingAway(report.talent())
        }
    }

    func testAProspectIsNotPickedOutOnPA() {
        for session in bothWaysOff {
            let health = ClubReport(session: session).health()
            XCTAssertFalse(health.rows.contains { $0.cells.contains("Renew: a prospect") })
        }
        let shown = ClubReport(session: session(.numbers, showHidden: true)).health()
        XCTAssertTrue(shown.rows.contains { $0.cells.contains("Renew: a prospect") })
    }

    func testNoSigningListGivesAbilityAway() {
        for session in bothWaysOff {
            let recommender = SigningRecommender(session: session)
            let best = recommender.find(RecommendOptions(mode: .best, upgradesOnly: false))
            assertGivesNothingAway(best)
            XCTAssertFalse(best?.rows.isEmpty ?? true)
            let young = recommender.find(RecommendOptions(mode: .young))
            assertGivesNothingAway(young)
            XCTAssertEqual(young?.rows.count, 0)
            XCTAssertTrue(young?.head.contains(session.display.abilityHint) ?? false)
        }
    }

    func testNoSquadPlanGivesAbilityAway() {
        for session in bothWaysOff {
            let lines = SquadPlanner.analyse(session)
            assertGivesNothingAway(SquadPlanner.squadTable(lines, session: session))
            assertGivesNothingAway(SquadPlanner.squadView(lines, session: session).table)
            assertGivesNothingAway(SquadPlanner.plan(session, lines: lines, budget: "500M", wageRoom: "500K", includeLoans: false)?.table)
            assertGivesNothingAway(SquadPlanner.plan(session, lines: lines, budget: "", wageRoom: "", includeLoans: false)?.table)
        }
        let shown = session(.numbers, showHidden: true)
        let plan = SquadPlanner.plan(shown, lines: SquadPlanner.analyse(shown), budget: "500M", wageRoom: "500K", includeLoans: false)
        XCTAssertTrue(plan?.table.columns.contains { $0.title == "vs best" } ?? false)
    }

    func testRecommendedStaffOnlyShowFMStarsWhileCAIsOn() throws {
        let role = try XCTUnwrap(StaffRoles.all.first { $0.name == "Physio" })
        func table(_ session: AnalysisSession) -> AnalysisTable? {
            let physio = Staff()
            physio.uid = 1
            physio.block = 1
            physio.club = "Rivals FC"
            physio.clubFull = "Rivals FC"
            physio.job = "Physio"
            physio.ca = 171
            physio.attr = [UInt8](repeating: 15, count: physio.attr.count)
            session.db.staff = [physio]
            return StaffRecommender(session: session).find(StaffSearchOptions(role: role, onlyJoin: false))
        }
        for session in bothWaysOff {
            let found = table(session)
            XCTAssertFalse(found?.rows.isEmpty ?? true)
            XCTAssertFalse(found?.columns.contains { $0.title == "FM stars" } ?? true)
            XCTAssertTrue(found?.columns.contains { $0.title == "vs your best" } ?? false)
        }
        XCTAssertTrue(table(session(.stars, showHidden: true))?.columns.contains { $0.title == "FM stars" } ?? false)
    }

    func testNoBargainListGivesAbilityAway() {
        for session in bothWaysOff {
            for kind in BargainOptions.Kind.allCases {
                assertGivesNothingAway(BargainFinder(session: session).find(BargainOptions(kind: kind)))
            }
            XCTAssertEqual(BargainFinder(session: session).find(BargainOptions(kind: .wonderkid))?.rows.count, 0)
        }
    }

    func testTheCABoxOnlyAppliesWhileCAIsOn() {
        let session = session(.hidden, showHidden: false)
        session.db.players.forEach { $0.endYear = 2026 }
        let options = BargainOptions(kind: .ending, minCA: "199")
        XCTAssertFalse(BargainFinder(session: session).find(options)?.rows.isEmpty ?? true)
        session.display.reveal = .numbers
        XCTAssertEqual(BargainFinder(session: session).find(options)?.rows.count, 0)
    }

    func testComparingPeopleLeavesAbilityOut() {
        for session in bothWaysOff {
            let rows = CompareReport(people: Array(session.db.players.prefix(2)), session: session).rows()
            XCTAssertFalse(rows.contains { ["Current ability", "Potential ability"].contains($0.label) })
        }
        let shown = session(.stars, showHidden: true)
        XCTAssertTrue(CompareReport(people: Array(shown.db.players.prefix(2)), session: shown).rows().contains { $0.label == "Current ability" })
    }

    func testTheDashboardListsNoProspectsWhileAbilityIsOff() {
        for session in bothWaysOff {
            let dashboard = ClubDashboard(session: session)
            XCTAssertFalse(dashboard.showsAbility)
            XCTAssertTrue(dashboard.prospects.isEmpty)
            XCTAssertFalse(dashboard.facts.contains { $0.label == "Best eleven" })
        }
        XCTAssertFalse(ClubDashboard(session: session(.numbers, showHidden: true)).prospects.isEmpty)
    }

    func testEveryTableWithAnAbilityColumnLosesIt() {
        let off = DisplayOptions(reveal: .hidden)
        for columns in [BestEleven.columns, SquadPlanner.slotColumns, SquadPlanner.squadColumns, SquadPlanner.pickColumns,
                        SigningRecommender.columns, SigningRecommender.youngColumns] {
            assertGivesNothingAway(off.fit(AnalysisTable(columns: columns)))
        }
    }

    func testRemovingAColumnKeepsTheRestOfTheRowInStep() {
        let table = AnalysisTable(columns: [TableColumn("Name", 1), TableColumn("CA", 1), TableColumn("Status", 1), TableColumn("Note", 1)], rows: [
            TableRow(cells: ["A", "137", "Fine", "Small print"], sortKeys: [.text("A"), .number(137), .text("Fine"), .text("Small print")],
                     tone: .good, toneColumn: 2, quietColumn: 3),
        ])
        let row = try? XCTUnwrap(DisplayOptions(reveal: .hidden).fit(table).rows.first)
        XCTAssertEqual(row?.cells, ["A", "Fine", "Small print"])
        XCTAssertEqual(row?.sortKeys, [.text("A"), .text("Fine"), .text("Small print")])
        XCTAssertEqual(row?.toneColumn, 1)
        XCTAssertEqual(row?.quietColumn, 2)
        XCTAssertEqual(DisplayOptions(reveal: .stars).fit(table).columns.count, 4)
    }

    func testARowColouredByAColumnThatGoesLosesTheColour() {
        let table = AnalysisTable(columns: [TableColumn("Name", 1), TableColumn("Verdict", 1)],
                                  rows: [TableRow(cells: ["A", "improving fast"], tone: .good, toneColumn: 1)])
        let row = DisplayOptions(reveal: .hidden).fit(table, also: ["Verdict"]).rows.first
        XCTAssertNil(row?.tone)
        XCTAssertNil(row?.toneColumn)
    }

    func testTheHintSaysWhichSwitchIsOff() {
        XCTAssertTrue(DisplayOptions(reveal: .hidden, showHidden: false).abilityHint.contains("Hidden attributes"))
        XCTAssertTrue(DisplayOptions(reveal: .hidden, showHidden: true).abilityHint.contains("Set Ability"))
    }

    func testInsideFMTheHintPointsAtFMStarshipsTabNotTheToolbar() {
        let hiddenOff = DisplayOptions(reveal: .hidden, showHidden: false, insideGame: true).abilityHint
        XCTAssertEqual(hiddenOff, "Switch on Hidden attributes at the top right of FM Starship's tab")
        XCTAssertFalse(hiddenOff.contains("eye"), "FM's tab has no toolbar and no eye")
        // Ability is beside the switch in FM's tab.
        let abilityOff = DisplayOptions(reveal: .hidden, showHidden: true, insideGame: true).abilityHint
        XCTAssertEqual(abilityOff, "Set Ability to Exact or Stars at the top right of FM Starship's tab")
        XCTAssertFalse(abilityOff.contains("window"), "No need to open FM Starship's window for it")
    }

    func testTheAppsOwnHintIsAsItWas() {
        XCTAssertEqual(DisplayOptions(reveal: .hidden, showHidden: false).abilityHint, "Switch on Hidden attributes (the eye in the toolbar)")
        XCTAssertEqual(DisplayOptions(reveal: .hidden, showHidden: true).abilityHint, "Set Ability in the toolbar to Exact or Stars")
    }
}
