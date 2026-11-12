@testable import StarshipAnalysis
import StarshipCore
import XCTest

final class TacticTests: XCTestCase {
    private func slot(_ name: String, _ side: TacticSlot.Side = .centre) -> TacticSlot {
        let position = Names.positions.firstIndex(of: name)!
        return TacticSlot(player: nil, position: position, positionWithoutBall: position, side: side, sideWithoutBall: side, role: 0, roleWithoutBall: 0)
    }

    func testStarsMatchFMsTacticsScreen() {
        XCTAssertEqual(RoleBook.stars(8), "★★★★")
        XCTAssertEqual(RoleBook.stars(7), "★★★½")
        XCTAssertEqual(RoleBook.stars(0), "-")
        // Measured on FM's screen: 5 and 6 show as three stars, 5 and 4 as two and a half.
        XCTAssertEqual(RoleBook.combined(5, 6), 6)
        XCTAssertEqual(RoleBook.combined(5, 4), 5)
        XCTAssertEqual(RoleBook.combined(8, 8), 8)
    }

    func testTheRolesStarsAreCalledRoleBesideCA() {
        // Not Stars, which beside CA in Stars mode reads as the same column twice.
        for columns in [SquadPlanner.slotColumns, BestEleven.columns, TacticOptimizer.detailColumns] {
            XCTAssertTrue(columns.contains { $0.title == "Role" })
            XCTAssertFalse(columns.contains { $0.title == "Stars" })
        }
    }

    func testAShapeNoPresetUsesIsCountedLineByLine() {
        let back = [slot("GK"), slot("DR"), slot("DC", .right), slot("DC", .left), slot("DL")]
        XCTAssertEqual(Tactic(slots: back + [slot("DM"), slot("MC", .right), slot("MC", .left), slot("AMR"), slot("AML"), slot("ST")]).shape(in: nil), "4-1-2-2-1")
        XCTAssertEqual(Tactic(slots: back + [slot("MR"), slot("MC", .right), slot("MC", .left), slot("ML"), slot("ST", .right), slot("ST", .left)]).shape(in: nil), "4-4-2")
    }

    func testAShapeWithNoForwardsStillWritesThatLine() {
        let back = [slot("GK"), slot("DR"), slot("DC", .right), slot("DC", .left), slot("DL")]
        XCTAssertEqual(Tactic(slots: back + [slot("DM", .right), slot("DM", .left), slot("AMR"), slot("AMC", .right), slot("AMC", .left), slot("AML")]).shape(in: nil), "4-2-4-0")
    }

    func testAShapeAPresetUsesGetsThatPresetsName() {
        let places = [slot("ST", .left), slot("ST", .right), slot("DM")]
        let presetPlaces = places.reversed().map {
            PresetSlot(position: $0.position, positionWithoutBall: $0.position, side: $0.side, sideWithoutBall: $0.side, role: 0, roleWithoutBall: 0,
                       allowedRoles: [], allowedRolesWithoutBall: [])
        }
        let library = TacticLibrary(styles: [], presets: [TacticPreset(name: "Test", style: "test", shape: "FM's name", shapeWithoutBall: "FM's name", slots: presetPlaces)],
                                    complexity: [:], complexityWithoutBall: [:])
        XCTAssertEqual(Tactic(slots: places).shape(in: library), "FM's name")
        XCTAssertEqual(Tactic(slots: places).shapeWithoutBall(in: library), "FM's name")
        XCTAssertEqual(Tactic(slots: [slot("DM")]).shape(in: library), "1-0")
    }

    func testTheGamesOwnNameComesFirst() {
        let back = [slot("GK"), slot("DR"), slot("DC", .right), slot("DC", .left), slot("DL")]
        var tactic = Tactic(slots: back + [slot("DM"), slot("MC", .right), slot("MC", .left), slot("AMR"), slot("AML"), slot("ST")])
        tactic.fmShape = "4-3-3 DM Bredt"
        tactic.fmShapeWithoutBall = "4-1-4-1 DM"
        XCTAssertEqual(tactic.shape(in: nil), "4-3-3 DM Bredt")
        XCTAssertEqual(tactic.shapeWithoutBall(in: nil), "4-1-4-1 DM")
    }

    func testStandingComparesWithTheQuartilesOfTheLeague() {
        let league = [4.0, 6, 8, 10, 12, 14, 16, 18]
        XCTAssertEqual(Standing.of(18, against: league), .strong)
        XCTAssertEqual(Standing.of(12, against: league), .good)
        XCTAssertEqual(Standing.of(9, against: league), .below)
        XCTAssertEqual(Standing.of(3, against: league), .poor)
    }

    /// "2nd of 2" says nothing about a league, however it reads.
    func testStandingNeedsEnoughPeopleToCompare() {
        XCTAssertEqual(Standing.of(3, against: [10]), .unknown)
        XCTAssertEqual(Standing.of(3, against: [10, 12]), .unknown)
        XCTAssertEqual(Standing.of(3, against: []), .unknown)
    }

    func testEveryClubWideJobHasItsOwnPlaceInTheBoardsTable() {
        let jobs = StaffRoles.base.filter { $0.limitIndex >= 0 }
        XCTAssertEqual(jobs.count, 11)
        XCTAssertEqual(Set(jobs.map(\.limitIndex)).count, 11)
        XCTAssertEqual(jobs.first { $0.name == "Head Physio" }?.limitIndex, StaffLimits.Club.headPhysio)
    }

    func testSlotsListFromGoalkeeperForwardsAndRightToLeft() {
        let slots = [slot("ST"), slot("AML"), slot("AMC"), slot("DC", .left), slot("DL"), slot("DC", .right), slot("DR"), slot("GK")]
        XCTAssertEqual(slots.stableSorted { $0.pitchOrder < $1.pitchOrder }.map(\.label),
                       ["GK", "DR", "DC (R)", "DC (L)", "DL", "AMC", "AML", "ST"])
    }

    func testEveryPositionGetsARowInThePlanner() {
        for (position, name) in Names.positions.enumerated() {
            XCTAssertNotNil(SquadPlanner.group(of: position), name)
        }
        XCTAssertEqual(SquadPlanner.group(of: 1)?.name, "Centre-back")
    }

    func testAssignFindsTheBestSplitNotTheGreedyOne() {
        // Greedy gives player 0 their best place and scores 10; the other way round scores 13.
        let scores = [[9, 8], [5, 1]]
        XCTAssertEqual(TacticOptimizer.assign(scores, places: 2), [1, 0])
    }

    func testAssignNeedsEnoughPlayers() {
        XCTAssertNil(TacticOptimizer.assign([[1, 2]], places: 2))
    }

    private func rated(_ stars: Int, finer: Int = 100) -> RoleBook.Rating {
        RoleBook.Rating(withBall: stars, withoutBall: stars, score: finer)
    }

    func testBestElevenPutsEveryoneWhereTheTeamGainsMost() {
        // Player 0 is best in place 0, but the team gets more with them in place 1 and player 1 in place 0.
        let ratings = [[rated(9), rated(8)], [rated(7), rated(2)]]
        XCTAssertEqual(BestEleven.choose(ratings, current: [0, 1], places: 2), [1, 0])
    }

    func testBestElevenKeepsYourPickWhenTheStarsTie() {
        // FM's finer rating prefers player 1, but you couldn't see the difference.
        let ratings = [[rated(6, finer: 100)], [rated(6, finer: 900)]]
        XCTAssertEqual(BestEleven.choose(ratings, current: [0], places: 1), [0])
    }

    func testBestElevenGoesByFinerRatingWhenNobodyIsPicked() {
        let ratings = [[rated(6, finer: 100)], [rated(6, finer: 900)]]
        XCTAssertEqual(BestEleven.choose(ratings, current: [nil], places: 1), [1])
    }

    func testBestElevenTakesHalfAStarOverYourPick() {
        // Half a star is worth more than any finer rating FM can give.
        let ratings = [[rated(6, finer: Int(Int32.max) * 2)], [rated(7, finer: 0)]]
        XCTAssertEqual(BestEleven.choose(ratings, current: [0], places: 1), [1])
    }

    func testBestElevenCountsAPlayerFMHasNoRatingFor() {
        let ratings: [[RoleBook.Rating?]] = [[nil, rated(4)], [rated(4), nil]]
        XCTAssertEqual(BestEleven.choose(ratings, current: [nil, nil], places: 2), [1, 0])
    }

    func testBestElevenLeavesAPlaceEmptyOnlyWhenPlayersRunOut() {
        let ratings = [[rated(4), rated(8)]]
        XCTAssertEqual(BestEleven.choose(ratings, current: [nil, 0], places: 2), [nil, 0])
    }

    func testBestElevenWritesGainsTheWayFMWritesStars() {
        XCTAssertEqual(BestEleven.gain(1), "+0.5★")
        XCTAssertEqual(BestEleven.gain(2), "+1★")
        XCTAssertEqual(BestEleven.gain(3), "+1.5★")
        XCTAssertEqual(BestEleven.gain(-1), "-0.5★")
    }

    private func player(_ uid: UInt32, at club: String, squad: String = "First team", loanedTo loan: String = "") -> Player {
        let player = Player()
        player.uid = uid
        player.block = 1
        player.clubFull = club
        player.club = club
        player.squad = loan.isEmpty ? squad : ""
        player.loanClub = loan
        player.loanClubFull = loan
        return player
    }

    private func molde(_ players: [Player]) -> AnalysisSession {
        let db = Database()
        db.players = players
        db.gameDate = GameDate.checked(year: 2026, dayOfYear: 270)
        return AnalysisSession(db: db, club: ChosenClub(team: 1, name: "Molde FK"), display: DisplayOptions(reveal: .numbers, showHidden: true))
    }

    /// Rivals and the league are read off the first player, and a loan in carries the parent club's.
    func testThePlannersSquadListsLoansInAfterTheClubsOwnPlayers() {
        let session = molde([
            player(1, at: "Rosenborg BK", loanedTo: "Molde FK"),
            player(2, at: "Molde FK", loanedTo: "Lillestrøm SK"),
            player(3, at: "Molde FK", squad: "U19"),
            player(4, at: "Molde FK"),
        ])
        XCTAssertEqual(SquadPlanner.analysedSquad(session).map(\.uid), [4, 1])
    }

    func testALoanInCountsAtTheirPositionAndSaysTheyAreOnLoan() throws {
        let midfield = Names.positions.firstIndex(of: "MC")!
        let loaned = player(1, at: "Rosenborg BK", loanedTo: "Molde FK")
        loaned.pos[midfield] = 20
        loaned.ca = 130
        // The parent club's contract: it says nothing about how long they're here.
        loaned.endYear = 2026
        loaned.endDay = 300
        let lines = SquadPlanner.analyse(molde([loaned]))
        let line = try XCTUnwrap(lines.first { $0.group.name == "Central midfield" })
        XCTAssertEqual(line.players.map(\.uid), [1])
        XCTAssertTrue(line.issues.contains("\(loaned.name) is on loan from Rosenborg BK"))
        XCTAssertFalse(line.issues.contains { $0.contains("contract") })
    }

    func testALoanInSaysWhenItEnds() throws {
        let midfield = Names.positions.firstIndex(of: "MC")!
        let loaned = player(1, at: "Rosenborg BK", loanedTo: "Molde FK")
        loaned.pos[midfield] = 20
        loaned.ca = 130
        loaned.loanEndYear = 2027
        loaned.loanEndDay = 151
        let line = try XCTUnwrap(SquadPlanner.analyse(molde([loaned])).first { $0.group.name == "Central midfield" })
        XCTAssertTrue(line.issues.contains("\(loaned.name) is on loan from Rosenborg BK until May 2027"))
    }

    func testRecommendedSigningsMeasureAgainstLoansIn() {
        let midfield = Names.positions.firstIndex(of: "MC")!
        let own = player(1, at: "Molde FK")
        own.pos[midfield] = 20
        own.ca = 120
        let loaned = player(2, at: "Rosenborg BK", loanedTo: "Molde FK")
        loaned.pos[midfield] = 20
        loaned.ca = 140
        let elsewhere = player(3, at: "Rosenborg BK")
        elsewhere.pos[midfield] = 20
        elsewhere.ca = 170
        XCTAssertEqual(SigningRecommender(session: molde([own, loaned, elsewhere])).bestAt[midfield], 140)
    }

    func testBestElevenCanPickAnyoneTheManagerCouldName() {
        let youth = Player()
        youth.clubFull = "Molde FK"
        youth.squad = "U19"
        XCTAssertTrue(BestEleven.canPlay(youth, for: "Molde FK"))

        let loanedOut = Player()
        loanedOut.clubFull = "Molde FK"
        loanedOut.loanClub = "Lillestrøm"
        loanedOut.loanClubFull = "Lillestrøm SK"
        XCTAssertFalse(BestEleven.canPlay(loanedOut, for: "Molde FK"))

        // A loan in still belongs to the parent club.
        let loanedIn = Player()
        loanedIn.clubFull = "Rosenborg BK"
        loanedIn.loanClub = "Molde"
        loanedIn.loanClubFull = "Molde FK"
        XCTAssertTrue(BestEleven.canPlay(loanedIn, for: "Molde FK"))
    }

    func testBestElevenCountsAClubsOwnBTeamButNotARealLoan() {
        let sent = Player()
        sent.clubFull = "Espanyol"
        sent.loanClub = "U.E. Vilassar"
        sent.loanClubFull = "U.E. Vilassar"
        XCTAssertFalse(BestEleven.canPlay(sent, for: "Espanyol"))
        sent.isAtOwnBTeam = true
        XCTAssertTrue(BestEleven.canPlay(sent, for: "Espanyol"))
    }

    func testBestElevenSaysWhenThereIsNothingToChange() {
        let player = Player()
        var picked = slot("DC")
        picked.player = player
        let same = BestEleven.Place(slot: picked, stars: 6, current: player, currentStars: 6)
        XCTAssertEqual(BestEleven.headline([same]), "Your eleven is already the best the club has for this tactic.")
    }

    func testBestElevenCountsTheChanges() {
        let mine = Player(), other = Player()
        mine.uid = 1
        other.uid = 2
        var picked = slot("DC")
        picked.player = other
        let change = BestEleven.Place(slot: picked, stars: 7, current: mine, currentStars: 6)
        XCTAssertEqual(BestEleven.headline([change]), "1 change takes your eleven's average from 3.00★ to 3.50★.")
        XCTAssertEqual(BestEleven.headline([change, change]), "2 changes take your eleven's average from 3.00★ to 3.50★.")
    }

    func testFlanksAndCentreAreNeighboursButOppositeFlanksAreNot() {
        let index = { (name: String) in Names.positions.firstIndex(of: name)! }
        XCTAssertTrue(TacticOptimizer.Combinations.neighbours(index("DL"), .centre, index("AML"), .centre))
        XCTAssertTrue(TacticOptimizer.Combinations.neighbours(index("DC"), .left, index("DC"), .right))
        XCTAssertTrue(TacticOptimizer.Combinations.neighbours(index("DM"), .left, index("MC"), .centre))
        XCTAssertFalse(TacticOptimizer.Combinations.neighbours(index("DL"), .centre, index("DR"), .centre))
        XCTAssertFalse(TacticOptimizer.Combinations.neighbours(index("DC"), .left, index("ST"), .centre))
    }

    func testRolesOnlyFitNeighboursFMPutsThemWith() {
        let dc = Names.positions.firstIndex(of: "DC")!
        let slots = { (side: TacticSlot.Side, role: Int) in
            PresetSlot(position: dc, positionWithoutBall: dc, side: side, sideWithoutBall: side, role: role, roleWithoutBall: 3, allowedRoles: [role], allowedRolesWithoutBall: [3])
        }
        let combinations = TacticOptimizer.Combinations([
            TacticPreset(name: "Test", style: "test", shape: "", shapeWithoutBall: "", slots: [slots(.left, 1), slots(.right, 24)]),
        ])
        let make = { (side: TacticSlot.Side, role: Int) in
            TacticSlot(player: nil, position: dc, positionWithoutBall: dc, side: side, sideWithoutBall: side, role: role, roleWithoutBall: 3)
        }
        XCTAssertTrue(combinations.fits(make(.left, 1), with: [make(.right, 24)]))
        XCTAssertFalse(combinations.fits(make(.left, 24), with: [make(.right, 24)]))
    }
}
