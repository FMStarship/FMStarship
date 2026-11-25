import StarshipAnalysis
import StarshipCore
@testable import StarshipMCP
import StarshipSearch
import XCTest

/// Every tool on a save built by hand, with Hidden attributes on and Ability exact unless a test says otherwise.
final class ToolTests: XCTestCase {
    override func tearDown() {
        GameRules.engine = nil
        super.tearDown()
    }

    // MARK: Reading and keeping the save

    func testNothingIsReadUntilAToolNeedsTheSaveAndThenItIsKept() throws {
        let harness = Harness()
        XCTAssertEqual(harness.source.reads, 0)
        _ = harness.toolbox.definitions
        _ = try harness.answer("shortlists")
        XCTAssertEqual(harness.source.reads, 0, "listing tools or shortlists mustn't touch FM")
        _ = try harness.answer("squad")
        _ = try harness.answer("staff")
        _ = try harness.answer("person", ["uid": 1])
        XCTAssertEqual(harness.source.reads, 1)

        harness.source.current = false
        _ = try harness.answer("squad")
        XCTAssertEqual(harness.source.reads, 2, "a save that has moved on is read again")
        harness.source.current = true
        _ = try harness.answer("game_status", ["refresh": true])
        XCTAssertEqual(harness.source.reads, 3, "refresh reads again")
        _ = try harness.answer("game_status")
        XCTAssertEqual(harness.source.reads, 3)
    }

    func testEveryToolSaysWhatToDoWhenFMIsntThere() throws {
        for problem in [GameProblem.notRunning, .withoutStarship, .noSave] {
            let harness = Harness()
            harness.source.problem = problem
            for tool in ["squad", "staff", "search_players", "club_overview"] {
                XCTAssertEqual(try harness.refusal(tool), problem.sentence)
            }
            let status = try harness.answer("game_status")
            XCTAssertEqual(status["what_to_do"]?.string, problem.sentence)
            XCTAssertNil(status["game_date"])
            XCTAssertEqual(status["hidden_attributes"], "on")
        }
        XCTAssertTrue(GameProblem.notRunning.sentence.contains("Start FM"))
    }

    func testAReadWithNoDateStandsForAFewMinutesOnly() {
        let day = GameDate.checked(year: 2026, dayOfYear: 270)
        let next = GameDate.checked(year: 2026, dayOfYear: 271)
        let clubs = [World.club]
        XCTAssertTrue(LiveGame.stillCurrent(dateNow: day, dateAtRead: day, clubsNow: clubs, clubsAtRead: clubs, age: 3600))
        XCTAssertFalse(LiveGame.stillCurrent(dateNow: next, dateAtRead: day, clubsNow: clubs, clubsAtRead: clubs, age: 1))
        XCTAssertFalse(LiveGame.stillCurrent(dateNow: day, dateAtRead: day, clubsNow: [""], clubsAtRead: clubs, age: 1))
        // No date at the read: nothing can say a day went by, so it's read again after a while.
        XCTAssertTrue(LiveGame.stillCurrent(dateNow: nil, dateAtRead: nil, clubsNow: clubs, clubsAtRead: clubs, age: 60))
        XCTAssertFalse(LiveGame.stillCurrent(dateNow: nil, dateAtRead: nil, clubsNow: clubs, clubsAtRead: clubs,
                                             age: LiveGame.undatedLimit + 1))
        XCTAssertFalse(LiveGame.stillCurrent(dateNow: nil, dateAtRead: day, clubsNow: clubs, clubsAtRead: clubs, age: 1))
    }

    // MARK: Game status

    func testGameStatus() throws {
        let harness = Harness()
        let status = try harness.answer("game_status")
        XCTAssertEqual(status["fm"], "running with FM Starship")
        XCTAssertEqual(status["game_date"], "2026-09-27")
        XCTAssertEqual(status["club_used"], .string(World.club))
        let club = try XCTUnwrap(status["clubs"]?.array?.first)
        XCTAssertEqual(club["name"], .string(World.club))
        XCTAssertEqual(club["manager"], "The Manager")
        XCTAssertEqual(club["transfer_budget"], "£5M")
        XCTAssertEqual(club["wage_room"], "£20,000 p/w")
        XCTAssertEqual(status["hidden_attributes"], "on")
        XCTAssertEqual(status["ability"], "exact")
        XCTAssertEqual(status["rules"], "on")
        XCTAssertEqual(status["units"]?["symbol"], "£")

        harness.settings = World.settings(hidden: false, reveal: .exact)
        let off = try harness.answer("game_status")
        XCTAssertEqual(off["hidden_attributes"], "off")
        XCTAssertEqual(off["ability"], "off", "Hidden attributes off takes Ability with it")
    }

    func testAnUncheckedBuildOfFMHasItsRulesOff() throws {
        let harness = Harness(engine: nil)
        let status = try harness.answer("game_status")
        XCTAssertTrue(status["rules"]?.string?.hasPrefix("off:") ?? false)
        let squad = try harness.answer("squad")
        XCTAssertTrue(squad.rowsByName.allSatisfy { $0["Starts"] == .null && $0["Days out"] == .null })
        XCTAssertNil(try harness.answer("person", ["uid": 21])["Would join your club"])
        XCTAssertTrue(try harness.refusal("squad_overview").contains("rules"))
    }

    // MARK: Squads and staff

    func testSquadIsTheFirstTeamInFMsOrderWithTheSquadsTheClubHas() throws {
        let harness = Harness()
        let squad = try harness.answer("squad")
        XCTAssertEqual(squad["squad"], "First team")
        XCTAssertEqual(squad["squads"]?.array, ["First team", "U19"])
        XCTAssertEqual(squad["players"], 12)
        XCTAssertEqual(Array(squad.columnNames.prefix(5)), ["uid", "Name", "Age", "Nation", "Position"])
        for name in ["CA", "PA", "Value", "Wage", "Contract end", "Starts", "Sub appearances", "Yellow cards", "Red cards", "Injury", "Days out"] {
            XCTAssertTrue(squad.columnNames.contains(name), name)
        }
        let hurt = try XCTUnwrap(squad.rowsByName.first { $0["uid"] == 13 })
        XCTAssertEqual(hurt["Name"], "Hurt Player")
        XCTAssertEqual(hurt["Nation"], "Mockovia")
        XCTAssertEqual(hurt["CA"], 171)
        XCTAssertEqual(hurt["Contract end"], "2027-04-10")
        XCTAssertEqual(hurt["Value"], "£1.3M")
        XCTAssertEqual(hurt["Injury"], "Hamstring strain")
        XCTAssertEqual(hurt["Days out"], 14)
        // FM's "9 (1)": nine starts and one as a substitute, never the two added up as if they were starts.
        XCTAssertFalse(squad.columnNames.contains("Appearances"))
        XCTAssertEqual(hurt["Starts"], 9)
        XCTAssertEqual(hurt["Sub appearances"], 1)
        XCTAssertEqual(hurt["Yellow cards"], 2)
        XCTAssertEqual(hurt["Red cards"], 1)
        XCTAssertEqual(hurt["Average rating"], 7.05)

        let youth = try harness.answer("squad", ["squad": "u19"])
        XCTAssertEqual(youth.rowsByName.map { $0["uid"] }, [12])
        let all = try harness.answer("squad", ["squad": "all"])
        XCTAssertEqual(all["players"], 13)
        XCTAssertTrue(all.columnNames.contains("Squad"))
        let rivals = try harness.answer("squad", ["club": "rivals fc"])
        XCTAssertEqual(rivals["club"], .string(World.rivals))
        XCTAssertTrue(try harness.refusal("squad", ["squad": "U23"]).contains("First team, U19"))
        XCTAssertTrue(try harness.refusal("squad", ["club": "Rival"]).contains("Did you mean: \(World.rivals)"))
    }

    func testStarsShowAbilityAsTheAppDoes() throws {
        let harness = Harness(reveal: .stars)
        let row = try XCTUnwrap(try harness.answer("squad").rowsByName.first)
        XCTAssertEqual(row["CA"], "4.5★")
        XCTAssertEqual(row["PA"], "4.5★")
    }

    func testStaffListsJobsAndBestCoaching() throws {
        let harness = Harness()
        let staff = try harness.answer("staff")
        XCTAssertEqual(staff["staff"], 2)
        let coach = try XCTUnwrap(staff.rowsByName.first { $0["uid"] == 501 })
        XCTAssertEqual(coach["Job"], "Coach")
        XCTAssertEqual(coach["Best coaching"], "Att Tac 4.5★, Att Tec 3.5★")
        XCTAssertEqual(coach["CA"], 171)
    }

    // MARK: One person

    func testAPlayerInFull() throws {
        let harness = Harness()
        let person = try harness.answer("person", ["uid": 13])
        XCTAssertEqual(person["kind"], "player")
        XCTAssertEqual(person["name"], "Hurt Player")
        XCTAssertEqual(person["General"]?["Position"], "DC")
        XCTAssertEqual(person["General"]?["Injury"], "Hamstring strain")
        XCTAssertEqual(person["General"]?["Days out"], 14)
        XCTAssertEqual(person["Ability"]?["CA"], 171)
        XCTAssertEqual(person["Contract"]?["Contract end"], "2027-04-10")
        XCTAssertEqual(person["Contract"]?["Release clause"], "£3M")
        XCTAssertEqual(person["Technical"]?["Finishing"], 10)
        XCTAssertEqual(person["Hidden"]?["Consistency"], 19)
        XCTAssertEqual(person["Positions"]?["DC"], 20)
        XCTAssertEqual(person["Personality"]?["Personality"], "Resolute")
        XCTAssertEqual(person["Personality"]?["Ambition"], 17)
        XCTAssertEqual(person["Season stats"]?["Form (last 5 ratings)"], "7.1 6.8 7.4")
        XCTAssertEqual(person["Traits"]?.array?.count, 1)
        XCTAssertNil(person["Would join your club"], "he's already at the club")

        let rival = try harness.answer("person", ["uid": 21])
        XCTAssertEqual(rival["Would join your club"]?["transfer"], "Interested")
        XCTAssertEqual(rival["Would join your club"]?["loan"], "Doubtful")
        XCTAssertTrue(try harness.refusal("person", ["uid": 99]).contains("99"))
        XCTAssertTrue(try harness.refusal("person").contains("uid"))
    }

    func testAMemberOfStaffInFull() throws {
        let harness = Harness()
        let coach = try harness.answer("person", ["uid": 502])
        XCTAssertEqual(coach["kind"], "staff")
        XCTAssertEqual(coach["General"]?["Job"], "Coach")
        XCTAssertEqual(coach["Coaching stars"]?["Att Tac"], 4.5)
        XCTAssertEqual(coach["Attributes"]?["Adaptability"], 12)
        XCTAssertEqual(coach["Would join your club"]?["first_team"], true)
        XCTAssertEqual(coach["Would join your club"]?["reserves"], false)
    }

    func testStartsAndSubAppearancesAreTwoNumbersEverywhere() throws {
        let harness = Harness()
        try harness.saveShortlist("Targets", isStaff: false, uids: [21])
        let lists = [try harness.answer("search_players", ["club": "Rivals", "limit": 1]),
                     try harness.answer("search_players", ["sort": "Appearances", "limit": 1]),
                     try harness.answer("shortlist", ["name": "Targets"])]
        for list in lists {
            XCTAssertFalse(list.columnNames.contains("Appearances"), list.text)
            XCTAssertEqual(list.rowsByName.first?["Starts"], 9, list.text)
            XCTAssertEqual(list.rowsByName.first?["Sub appearances"], 1, list.text)
        }
        let person = try harness.answer("person", ["uid": 21])
        XCTAssertEqual(person["Season stats"]?["Starts"], 9)
        XCTAssertEqual(person["Season stats"]?["Sub appearances"], 1)
        XCTAssertNil(person["Season stats"]?["Appearances"])
        let rows = try harness.answer("compare", ["uids": [1, 21]])["rows"]?.array ?? []
        XCTAssertTrue(rows.contains(["Starts", 9, 9]))
        XCTAssertTrue(rows.contains(["Sub appearances", 1, 1]))
        XCTAssertFalse(rows.contains { $0.array?.first == "Appearances" })
    }

    func testMoneyIsInTheUsersCurrencyFromTheFirstAnswer() throws {
        // A fresh server knows only the pound until a save is read.
        Units.currencies = [Units.pound]
        Units.money = Units.pound
        defer {
            Units.currencies = [Units.pound]
            Units.money = Units.pound
        }
        let harness = Harness()
        harness.source.database.currencies = [Currency(name: "United Kingdom Pound", symbol: "£", rate: 1),
                                              Currency(name: "Norwegian Krone", symbol: "", rate: 13)]
        harness.settings.currencyName = "Norwegian Krone"

        let status = try harness.answer("game_status")
        XCTAssertEqual(status["units"]?["currency"], "Norwegian Krone")
        XCTAssertEqual(status["clubs"]?.array?.first?["transfer_budget"], "Kr 65M")
        XCTAssertEqual(try harness.answer("squad").rowsByName.first?["Value"], "Kr 1.3M")

        // A read that brings other currencies, such as another save or new rates, with a money argument read in that same
        // call. Before the read the server only knows the pound again, so only the read's own currencies can get this right.
        harness.source.database.currencies = [Currency(name: "United Kingdom Pound", symbol: "£", rate: 1),
                                              Currency(name: "Norwegian Krone", symbol: "", rate: 10)]
        Units.currencies = [Units.pound]
        Units.money = Units.pound
        harness.source.current = false
        let cheap = try harness.answer("search_players", ["value_max": 1_000_000])
        XCTAssertEqual(cheap.rowsByName.map { $0["uid"] }, [1], "1M kroner at the new rate is £100K")
        XCTAssertEqual(cheap.rowsByName.first?["Value"], "Kr 1M")
        XCTAssertEqual(harness.source.reads, 2)
    }

    func testSquadOverviewRefusesWhenFMGivesNoRoleRatings() throws {
        let engine = FakeEngine()
        engine.roleRatings = false
        let sentence = try Harness(engine: engine).refusal("squad_overview")
        XCTAssertTrue(sentence.contains("didn't give"), sentence)
        XCTAssertFalse(sentence.contains("cover"), sentence)
    }

    func testSquadOverviewRefusesWhenFMRatesTheStartersButNotTheBench() throws {
        let engine = FakeEngine()
        engine.ratedPlayers = Set(1...11)
        let sentence = try Harness(engine: engine).refusal("squad_overview")
        XCTAssertTrue(sentence.contains("didn't give"), sentence)
        // With every player rated, the same squad has cover.
        XCTAssertFalse(try Harness().answer("squad_overview").text.contains("11 have no real cover"))
    }

    func testSquadOverviewSaysWhenNobodyIsPicked() throws {
        let harness = Harness()
        harness.source.database.tactics = [1: World.tactic([])]
        let sentence = try harness.refusal("squad_overview")
        XCTAssertTrue(sentence.contains("nobody picked"), sentence)
        XCTAssertFalse(sentence.contains("role ratings"), sentence)
    }

    func testSearchesOrderByStartsAndSayWhatAnAppearancesOrderMeans() throws {
        let harness = Harness()
        var many = SeasonStats()
        many.apps = 21
        many.starts = 20
        many.subs = 1
        var few = SeasonStats()
        few.apps = 3
        few.starts = 3
        harness.source.database.players.first { $0.uid == 21 }?.season = many
        harness.source.database.players.first { $0.uid == 22 }?.season = few

        let most = try harness.answer("search_players", ["club": "Rivals", "sort": "starts", "limit": 1])
        XCTAssertEqual(most["order"], "Starts")
        XCTAssertEqual(most.rowsByName.first?["uid"], 21)
        XCTAssertEqual(most.rowsByName.first?["Starts"], 20)
        let fewest = try harness.answer("search_players", ["club": "Rivals", "sort": "Starts", "descending": false, "limit": 1])
        XCTAssertEqual(fewest.rowsByName.first?["uid"], 22)
        let subs = try harness.answer("search_players", ["club": "Rivals", "sort": "Sub appearances", "limit": 1])
        XCTAssertEqual(subs["order"], "Sub appearances")
        let total = try harness.answer("search_players", ["club": "Rivals", "sort": "Appearances", "limit": 1])
        XCTAssertEqual(total["order"], "Appearances: starts and sub appearances together")
        XCTAssertEqual(total.rowsByName.first?["uid"], 21)
        XCTAssertTrue(try harness.refusal("search_staff", ["sort": "Starts"]).contains("Starts"))
    }

    func testACutListSaysSo() throws {
        let harness = Harness()
        let two = try harness.answer("recommend_signings", ["upgrades_only": false, "limit": 2])
        XCTAssertTrue(two["status"]?.string?.hasSuffix("Showing the first 2.") ?? false, two["status"]?.text ?? "")
        let all = try harness.answer("recommend_signings", ["upgrades_only": false])
        XCTAssertFalse(all["status"]?.string?.contains("Showing") ?? true)
    }

    func testWithNoSaveTheCurrencyIsntGuessed() throws {
        let harness = Harness()
        harness.settings.currencyName = "Norwegian Krone"
        harness.source.problem = .notRunning
        let units = try XCTUnwrap(try harness.answer("game_status")["units"])
        XCTAssertNil(units["currency"])
        XCTAssertNil(units["symbol"])
        XCTAssertEqual(units["wages"], "p/w")
    }

    func testNoAnswerTalksAboutTheAppsMouse() throws {
        let harness = Harness()
        for (tool, arguments) in [("recommend_signings", ["upgrades_only": false]), ("find_bargains", ["only_join": false]),
                                  ("squad_overview", [:]), ("staff_overview", [:]), ("club_overview", [:])] as [(String, JSON)] {
            let text = try harness.answer(tool, arguments).text
            XCTAssertNil(text.range(of: "click", options: .caseInsensitive), "\(tool): \(text)")
        }
        XCTAssertEqual(Output.prose("Top 10 who would join Molde FK. Double-click a player for the full profile."), "Top 10 who would join Molde FK.")
        XCTAssertEqual(Output.prose("In FM: offer him for loan. Right-click to add to a shortlist."), "In FM: offer him for loan.")
        XCTAssertEqual(Output.prose("Double-click for the full profile; right-click to compare."), "")
    }

    func testTheFindersGiveFMsKeennessFromTheAnswersTheyAlreadyHave() throws {
        let engine = FakeEngine()
        let harness = Harness(engine: engine)
        let signings = try harness.answer("recommend_signings", ["upgrades_only": false])
        XCTAssertTrue(signings.columnNames.suffix(2) == ["Transfer interest", "Loan interest"])
        let first = try XCTUnwrap(signings.rowsByName.first)
        XCTAssertEqual(first["Transfer interest"], "Interested")
        XCTAssertEqual(first["Loan interest"], "Doubtful")
        // One question to FM for each of the rival club's twelve players, the finder's own, and none more for the columns.
        XCTAssertEqual(engine.interestCalls, 12)
        let bargains = try harness.answer("find_bargains", ["kind": "contracts_ending"])
        XCTAssertTrue(bargains.columnNames.contains("Transfer interest"))
        XCTAssertEqual(engine.interestCalls, 12, "the bargains asked nothing the session didn't already know")
    }

    func testARowTheFinderNeverAskedAboutHasNoKeennessAndAsksNothing() throws {
        let engine = FakeEngine()
        let harness = Harness(engine: engine)
        let bargains = try harness.answer("find_bargains", ["kind": "contracts_ending", "only_join": false])
        XCTAssertFalse(bargains.rowsByName.isEmpty)
        XCTAssertEqual(engine.interestCalls, 0, "the keenness columns read what's known; they never ask")
        for row in bargains.rowsByName {
            XCTAssertEqual(row["Transfer interest"], .null)
            XCTAssertEqual(row["Loan interest"], .null)
        }
    }

    func testAPlayerHisClubWontLoanIsNotAvailableForLoanNotUninterested() throws {
        let harness = Harness()
        harness.source.database.players.filter { $0.clubFull == World.rivals }.forEach { $0.statusFlags = 64 }
        let signings = try harness.answer("recommend_signings", ["upgrades_only": false])
        XCTAssertFalse(signings.rowsByName.isEmpty)
        for row in signings.rowsByName {
            XCTAssertEqual(row["Loan interest"], "Not available for loan")
            XCTAssertEqual(row["Transfer interest"], "Interested")
        }
        XCTAssertEqual(try harness.answer("person", ["uid": 21])["Would join your club"]?["loan"], "Not available for loan")
    }

    func testALeagueFilterShowsWhoseLeagueItIs() throws {
        let harness = Harness()
        for tool in ["search_players", "search_staff"] {
            let found = try harness.answer(tool, ["league": "Mock"])
            let league = try XCTUnwrap(found.columnNames.firstIndex(of: "League"), tool)
            XCTAssertEqual(found.columnNames[league + 1], "Club nation", tool)
            XCTAssertEqual(found.rowsByName.first?["Club nation"], "Mockovia", tool)
        }
        XCTAssertFalse(try harness.answer("search_players").columnNames.contains("League"))
    }

    func testNamesAreClearWhereFMsNamesClash() throws {
        let harness = Harness()
        let loaned = try XCTUnwrap(harness.source.database.players.first { $0.uid == 22 })
        loaned.loanClub = "Loan Town"
        loaned.loanClubFull = "Loan Town"
        harness.source.database.players.first { $0.uid == 23 }?.statusFlags = 64
        harness.source.database.players.first { $0.uid == 24 }?.statusFlags = 2

        let search = try harness.answer("search_players", ["club": "Rivals", "sort": "League"])
        XCTAssertTrue(search.columnNames.contains("On loan at"))
        XCTAssertEqual(search.rowsByName.first { $0["uid"] == 22 }?["On loan at"], "Loan Town")
        let league = try XCTUnwrap(search.columnNames.firstIndex(of: "League"))
        XCTAssertEqual(search.columnNames[league + 1], "Club nation")
        XCTAssertEqual(search.rowsByName.first?["Club nation"], "Mockovia")

        let person = try harness.answer("person", ["uid": 21])
        XCTAssertEqual(person["General"]?["League"], "Mock League")
        XCTAssertEqual(person["General"]?["Club nation"], "Mockovia")

        let rivals = try harness.answer("squad", ["club": .string(World.rivals)]).rowsByName
        XCTAssertEqual(rivals.first { $0["uid"] == 23 }?["Loan status"], "Not available for loan")
        XCTAssertEqual(rivals.first { $0["uid"] == 24 }?["Loan status"], "Listed for loan")
        XCTAssertEqual(rivals.first { $0["uid"] == 25 }?["Loan status"], .null)
    }

    func testCompareLeavesOutInterestForTheUsersOwnPlayers() throws {
        let harness = Harness()
        let mixed = try harness.answer("compare", ["uids": [1, 21]])["rows"]?.array ?? []
        let interest = try XCTUnwrap(mixed.first { $0.array?.first == "Interest" })
        XCTAssertEqual(interest.array?[1], .null, "he's already at the user's club")
        XCTAssertEqual(interest.array?[2], "Transfer, loan")
        let own = try harness.answer("compare", ["uids": [1, 2]])["rows"]?.array ?? []
        XCTAssertFalse(own.contains { $0.array?.first == "Interest" })
    }

    func testTheSquadOverviewSaysNothingAboutTheHiresItLeavesOut() throws {
        let footnote = try Harness().answer("squad_overview")["footnote"]?.string ?? ""
        XCTAssertFalse(footnote.isEmpty)
        XCTAssertFalse(footnote.contains("Each pick"), footnote)
        XCTAssertEqual(Toolbox.withoutHires("Stars are FM's. Each pick fits your budget on the wage they earn now."), "Stars are FM's.")
    }

    func testTheMCPHasFMsRoleRatingsAndStaffLimits() {
        // Without these, the squad overview and the staff limits are off whatever FM answers.
        XCTAssertTrue((RulesEngine.self as Any) is PositionalRoleEngine.Type)
        XCTAssertTrue((RulesEngine.self as Any) is StaffLimitsEngine.Type)
    }

    func testAMisspeltArgumentIsSaidNotIgnored() throws {
        let harness = Harness()
        XCTAssertTrue(try harness.refusal("game_status", ["refresh": "yes"]).contains("true or false"))
        XCTAssertTrue(try harness.refusal("squad", ["squads": "U19"]).contains("doesn't take squads"))
        XCTAssertTrue(try harness.refusal("person", ["uid": "one"]).contains("whole number"))
    }

    // MARK: Searches

    func testSearchPlayersFiltersAndOrders() throws {
        let harness = Harness()
        let rivals = try harness.answer("search_players", ["club": "Rivals", "age_max": 25, "limit": 3])
        XCTAssertEqual(rivals["found"], 12)
        XCTAssertEqual(rivals["shown"], 3)
        XCTAssertEqual(rivals["order"], "CA")
        XCTAssertTrue(rivals.columnNames.contains("Club"))

        let byValue = try harness.answer("search_players", ["position": "DC", "sort": "value", "limit": 2])
        XCTAssertEqual(byValue.rowsByName.map { $0["uid"] }, [32, 31])
        let cheapestFirst = try harness.answer("search_players", ["sort": "Value", "descending": false, "limit": 1])
        XCTAssertEqual(cheapestFirst.rowsByName.first?["uid"], 1)

        let rule = try harness.answer("search_players", ["rules": [["attribute": "consistency", "at_least": 19]], "club": "Testing"])
        XCTAssertEqual(rule["found"], 13)
        XCTAssertTrue(rule.columnNames.contains("Consistency"))
        XCTAssertEqual(try harness.answer("search_players", ["rules": [["attribute": "Finishing", "at_least": 11]]])["found"], 0)
        XCTAssertEqual(try harness.answer("search_players", ["ca_min": 150])["found"], 12)
        XCTAssertEqual(try harness.answer("search_players", ["value_max": 1_000_000])["found"], 10)
        XCTAssertEqual(try harness.answer("search_players", ["wage_max": 999])["found"], 0)
        XCTAssertEqual(try harness.answer("search_players", ["personality": "resolute"])["found"], 25)
        XCTAssertTrue(try harness.refusal("search_players", ["rules": [["attribute": "Flying", "at_least": 3]]]).contains("Flying"))
        XCTAssertTrue(try harness.refusal("search_players", ["personality": "Grumpy"]).contains("Resolute"))
        XCTAssertTrue(try harness.refusal("search_players", ["position": "Winger"]).contains("AMR"))
    }

    func testSeasonStatFiltersUseTheGamesFigures() throws {
        let harness = Harness()
        XCTAssertEqual(try harness.answer("search_players", ["apps_min": 10, "rating_min": 7.0])["found"], 25)
        XCTAssertEqual(try harness.answer("search_players", ["goals_min": 4])["found"], 0)
    }

    func testClauseMaxIsTheClauseTheUsersClubWouldPay() throws {
        let harness = Harness()
        let found = try harness.answer("search_players", ["clause_max": 1_000_000])
        // The rival's clause for buyers from abroad doesn't apply to a club from the same nation; the injured player's is too dear.
        XCTAssertEqual(found["found"], 0)
        let dearer = try harness.answer("search_players", ["clause_max": 3_000_000])
        XCTAssertEqual(dearer.rowsByName.map { $0["uid"] }, [13])
        XCTAssertEqual(dearer.rowsByName.first?["Release clause"], "£3M")
        harness.source.database.players.first { $0.uid == 21 }?.clubNation = "Elsewhere"
        harness.source.current = false
        XCTAssertEqual(try harness.answer("search_players", ["clause_max": 1_000_000]).rowsByName.map { $0["uid"] }, [21])
    }

    func testSearchStaffRanksByCoachingStars() throws {
        let harness = Harness()
        let coaches = try harness.answer("search_staff", ["job": "coach", "rank_by": "Attacking tactical", "min_stars": 4])
        XCTAssertEqual(coaches["found"], 2)
        XCTAssertEqual(coaches["order"], "Attacking tactical stars")
        XCTAssertTrue(coaches.columnNames.contains("Att Tac"))
        XCTAssertEqual(try harness.answer("search_staff")["found"], 3)
        XCTAssertEqual(try harness.answer("search_staff")["order"], "World reputation")
        XCTAssertTrue(try harness.refusal("search_staff", ["min_stars": 4]).contains("rank_by"))
        XCTAssertTrue(try harness.refusal("search_staff", ["job": "Kit man"]).contains("Coaching staff"))
        XCTAssertEqual(try harness.answer("search_staff", ["rules": [["attribute": "Adaptability", "at_most": 12]]])["found"], 3)
    }

    // MARK: Shortlists

    func testShortlistsFromFMsFolder() throws {
        let harness = Harness()
        XCTAssertEqual(try harness.answer("shortlists")["shortlists"]?.array, [])
        try harness.saveShortlist("Targets", isStaff: false, uids: [21, 22, 4_000_000])
        try harness.saveShortlist("Coaches", isStaff: true, uids: [502])
        let lists = try harness.answer("shortlists")["shortlists"]?.array ?? []
        XCTAssertEqual(Set(lists.compactMap { $0["name"]?.string }), ["Targets", "Coaches"])
        XCTAssertEqual(try harness.answer("shortlists", ["kind": "staff"])["shortlists"]?.array?.count, 1)

        let targets = try harness.answer("shortlist", ["name": "targets"])
        XCTAssertEqual(targets["people"], 2)
        XCTAssertEqual(targets["not_in_this_save"], 1)
        XCTAssertEqual(targets.rowsByName.map { $0["uid"] }, [21, 22])
        let first = try harness.answer("shortlist", ["name": "Targets", "limit": 1])
        XCTAssertEqual(first["people"], 2, "the whole list's size")
        XCTAssertEqual(first["shown"], 1)
        XCTAssertEqual(first.rowsByName.map { $0["uid"] }, [21])
        let coaches = try harness.answer("shortlist", ["name": "Coaches"])
        XCTAssertEqual(coaches["kind"], "staff")
        XCTAssertTrue(try harness.refusal("shortlist", ["name": "Nope"]).contains("Targets"))
    }

    // MARK: FM Starship's analysis

    func testClubOverview() throws {
        let harness = Harness()
        let overview = try harness.answer("club_overview")
        XCTAssertEqual(overview["club"], .string(World.club))
        XCTAssertEqual(overview["facts"]?["Transfer budget"], "£5M")
        XCTAssertNotNil(overview["prospects"]?.array)
        XCTAssertTrue(try harness.refusal("club_overview", ["club": .string(World.rivals)]).contains("human manager"))
    }

    func testSquadOverviewFollowsTheTactic() throws {
        let harness = Harness()
        let overview = try harness.answer("squad_overview")
        XCTAssertEqual(overview["club"], .string(World.club))
        XCTAssertEqual(overview["rows"]?.array?.count, 11)
        XCTAssertEqual(overview.columnNames, ["uid", "Position", "Playing now", "Rating", "Standing", "Notes"])
        XCTAssertNil(overview["head"], "the headline is said once")

        XCTAssertEqual(try harness.answer("game_status")["clubs"]?.array?.first?["tactic"], "found: 4-4-2")

        harness.source.database.tactics = [:]
        harness.source.current = false
        XCTAssertTrue(try harness.refusal("squad_overview").contains("Tactics screen"))
        XCTAssertTrue(try harness.answer("game_status")["clubs"]?.array?.first?["tactic"]?.string?.hasPrefix("not found") ?? false)
    }

    func testStaffOverview() throws {
        let overview = try Harness().answer("staff_overview")
        XCTAssertEqual(overview["club"], .string(World.club))
        XCTAssertNotNil(overview["headline"]?.string)
        XCTAssertEqual(overview["training"]?.array?.count, Names.areasLong.count)
        XCTAssertFalse(overview.columnNames.contains("Best who'd join"))
    }

    func testCompare() throws {
        let harness = Harness()
        let compared = try harness.answer("compare", ["uids": [1, 21]])
        XCTAssertEqual(compared["people"]?.array?.count, 2)
        let rows = compared["rows"]?.array ?? []
        XCTAssertTrue(rows.contains { $0.array?.first == "Current ability" })
        XCTAssertTrue(rows.contains { $0.array?.first == "Consistency" })
        XCTAssertTrue(try harness.refusal("compare", ["uids": [1]]).contains("two to four"))
        XCTAssertTrue(try harness.refusal("compare", ["uids": [1, 501]]).contains("not both"))
        XCTAssertTrue(try harness.refusal("compare", ["uids": [1, 21], "club": "Testing United"]).contains("human manager"),
                      "a misspelt club isn't taken for no club")
    }

    func testRecommendedSigningsAndBargains() throws {
        let harness = Harness()
        let signings = try harness.answer("recommend_signings", ["upgrades_only": false])
        XCTAssertFalse(signings.rowsByName.isEmpty)
        XCTAssertTrue(signings.rowsByName.allSatisfy { ($0["uid"]?.int ?? 0) > 20 }, "nobody from the user's own club")
        XCTAssertTrue(signings.columnNames.contains("CA"))
        let bargains = try harness.answer("find_bargains", ["kind": "contracts_ending", "only_join": false])
        XCTAssertNotNil(bargains["columns"])
        let two = try harness.answer("recommend_signings", ["upgrades_only": false, "limit": 2])
        XCTAssertEqual(two.rowsByName.count, 2)
        XCTAssertEqual(two["found"], 10)
        XCTAssertEqual(two["shown"], 2)
        let one = try harness.answer("find_bargains", ["kind": "contracts_ending", "only_join": false, "limit": 1])
        XCTAssertEqual(one.rowsByName.count, 1)
        XCTAssertTrue(try harness.refusal("recommend_signings", ["limit": 11]).contains("1 to 10"))
        XCTAssertTrue(try harness.refusal("find_bargains", ["kind": "cheap"]).contains("wonderkids"))
    }
}
