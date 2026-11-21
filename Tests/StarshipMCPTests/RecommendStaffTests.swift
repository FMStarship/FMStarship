import StarshipAnalysis
import StarshipCore
@testable import StarshipMCP
import StarshipSearch
import XCTest

/// recommend_staff: the app's Recommended staff, narrowed to who FM says would join.
final class RecommendStaffTests: XCTestCase {
    override func tearDown() {
        GameRules.engine = nil
        super.tearDown()
    }

    /// Besides the world's own staff, a coach out of work, a better coach at Rivals FC who wouldn't come, and an assistant
    /// manager there who doesn't coach.
    private func harness(_ engine: FakeEngine? = FakeEngine(), hidden: Bool = true, reveal: Reveal = .exact) -> Harness {
        let harness = Harness(hidden: hidden, reveal: reveal, engine: engine)
        let free = World.staff(503, name: "Free Coach", job: "", block: 503, at: "")
        free.wage = 0
        let stays = World.staff(505, name: "Stays Put", job: "Coach", block: 505, at: World.rivals)
        stays.stars = [5, 5, 5, 3, 2.5, 2.5, 1, 2, 2]
        let assistant = World.staff(504, name: "Rival Assistant", job: "Assistant Manager", block: 504, at: World.rivals)
        // No training stars, so he's no coach: the coaches' pool takes anyone in a coaching job, as the app's does.
        assistant.stars = [Double](repeating: 0, count: 9)
        for person in [free, stays, assistant] { person.prepare() }
        harness.source.database.staff += [free, stays, assistant]
        engine?.staffWontJoin = [505]
        return harness
    }

    private func uids(_ answer: JSON) -> [Int] { answer.rowsByName.compactMap { $0["uid"]?.int } }

    func testTheListIsThoseFMSaysWouldJoin() throws {
        let answer = try harness().answer("recommend_staff", ["role": "Coach"])
        XCTAssertEqual(answer["role"], "Coach")
        XCTAssertEqual(answer["team"], "First team")
        XCTAssertEqual(Set(uids(answer)), [502, 503], "not the coach who wouldn't come, nor the club's own")
        XCTAssertTrue(answer.rowsByName.allSatisfy { $0["Would join"] == "First team" })
        let interest = answer["interest"]?.string ?? ""
        XCTAssertTrue(interest.hasPrefix("Everyone listed is someone FM says would join Testing FC's first team and take the job of coach. "),
                      interest)
        XCTAssertTrue(interest.contains("Takes job is the same rule of FM's asked about the job of coach at the first team"), interest)
        XCTAssertTrue(answer.rowsByName.allSatisfy { $0["Takes job"] == "Yes" })
        XCTAssertNil(answer["wants_job_note"], "a coach's preference is a coach's")
        XCTAssertTrue(answer["head"]?.string?.hasPrefix("You have 1 coach;") ?? false, answer["head"]?.text ?? "")
        XCTAssertTrue(answer["status"]?.string?.contains("who'd join your first team") ?? false)
        XCTAssertEqual(Array(answer.columnNames.prefix(4)), ["uid", "Name", "Age", "Job now"])
        XCTAssertTrue(answer.columnNames.contains("vs your best"))
        XCTAssertTrue(answer["wage_max"]?.string?.contains("wage room") ?? false, "the box starts at the wage room, and says so")
        XCTAssertTrue(answer["not_available"]?.string?.contains("staff limits") ?? false)
    }

    func testWithOnlyJoinFalseEveryoneIsListedWithFMsAnswer() throws {
        let engine = FakeEngine()
        let answer = try harness(engine).answer("recommend_staff", ["role": "Coach", "only_join": false])
        XCTAssertEqual(uids(answer).first, 505, "the best coach first, though he wouldn't come")
        let byUID = Dictionary(uniqueKeysWithValues: answer.rowsByName.map { ($0["uid"]?.int ?? 0, $0) })
        XCTAssertEqual(byUID[505]?["Would join"], "No")
        XCTAssertEqual(byUID[502]?["Would join"], "First team")
        XCTAssertTrue(answer["interest"]?.string?.hasPrefix("Not narrowed to who'd join.") ?? false)
        XCTAssertFalse(answer["status"]?.string?.contains("join") ?? true)
    }

    func testAWrongRoleIsAnsweredWithTheList() throws {
        let harness = harness()
        let wrong = try harness.refusal("recommend_staff", ["role": "Kit Man"])
        XCTAssertTrue(wrong.contains("Assistant Manager") && wrong.contains("Set Piece Coach"), wrong)
        XCTAssertTrue(try harness.refusal("recommend_staff").contains("needs a role"))
        XCTAssertTrue(try harness.refusal("recommend_staff", ["role": "Coach", "level": "senior"]).contains("first_team, reserves, youth"))
        XCTAssertEqual(try harness.answer("recommend_staff", ["role": "assistant manager"])["role"], "Assistant Manager")
    }

    func testALevel() throws {
        let harness = harness()
        // FM says yes for the first team only.
        let reserves = try harness.answer("recommend_staff", ["role": "Coach", "level": "reserves"])
        XCTAssertEqual(reserves["team"], "Reserves")
        XCTAssertTrue(uids(reserves).isEmpty)
        XCTAssertTrue(reserves["interest"]?.string?.hasPrefix("Nobody FM says would join Testing FC's Reserves and take the job of coach "
                                                              + "passes these settings.") ?? false,
                      "the team's own name, as the screen writes it: \(reserves["interest"]?.text ?? "")")
        XCTAssertTrue(reserves["status"]?.string?.contains("only_join false") ?? false, reserves["status"]?.text ?? "")
        let open = try harness.answer("recommend_staff", ["role": "Coach", "level": "reserves", "only_join": false])
        XCTAssertFalse(uids(open).isEmpty)
        // A club-wide job takes the level for who'd join.
        let assistant = try harness.answer("recommend_staff", ["role": "Assistant Manager", "level": "youth"])
        XCTAssertEqual(assistant["team"], "Youth team")
        XCTAssertTrue(uids(assistant).isEmpty)
        let first = uids(try harness.answer("recommend_staff", ["role": "Assistant Manager"]))
        XCTAssertTrue(first.contains(504) && !first.contains(505), "\(first)")
        XCTAssertTrue(try harness.refusal("recommend_staff", ["role": "Manager"]).contains("reserves or youth"))
        XCTAssertEqual(try harness.answer("recommend_staff", ["role": "Manager", "level": "youth"])["team"], "Youth team")
    }

    func testWhenFMCouldntBeAskedTheListIsntPresentedAsWhoWouldCome() throws {
        let engine = FakeEngine()
        engine.staffAnswers = false
        let unanswered = try harness(engine).answer("recommend_staff", ["role": "Coach"])
        let said = unanswered["interest"]?.string ?? ""
        XCTAssertTrue(said.hasPrefix("FM gave no answer about who'd join for any of the 3 people it was asked about, so this list isn't narrowed"), said)
        XCTAssertTrue(said.contains("If asking again gives the same, FM can't answer it for Testing FC"), said)
        XCTAssertTrue(uids(unanswered).contains(505))
        XCTAssertTrue(unanswered.rowsByName.allSatisfy { $0["Would join"] == .null })
        XCTAssertFalse(unanswered["status"]?.string?.contains("join") ?? true)

        let noRules = try harness(nil).answer("recommend_staff", ["role": "Coach"])
        XCTAssertTrue(noRules["interest"]?.string?.contains("FM's rules are off") ?? false)
        XCTAssertTrue(uids(noRules).contains(505))

        let noManager = harness()
        noManager.source.database.humanClubs = [(team: 1, name: World.club, manager: 0)]
        let answer = try noManager.answer("recommend_staff", ["role": "Coach"])
        XCTAssertTrue(answer["interest"]?.string?.contains("found no manager at Testing FC") ?? false)
        XCTAssertFalse(answer["status"]?.string?.contains("join") ?? true)
    }

    func testWageAgeAndLimit() throws {
        let harness = harness()
        let cheap = try harness.answer("recommend_staff", ["role": "Coach", "wage_max": 1500])
        XCTAssertEqual(uids(cheap), [503], "only the coach out of work, whose wage is to agree")
        XCTAssertNil(cheap["wage_max"])
        XCTAssertTrue(uids(try harness.answer("recommend_staff", ["role": "Coach", "age_max": 40])).isEmpty)
        let one = try harness.answer("recommend_staff", ["role": "Coach", "limit": 1])
        XCTAssertEqual(uids(one).count, 1)
        XCTAssertNil(one["found"], "FM is asked until one would join, not 25")
        XCTAssertTrue(try harness.refusal("recommend_staff", ["role": "Coach", "limit": 26]).contains("1 to 25"))
    }

    /// 610 coaches at Rivals FC who wouldn't come, as good as the world's own and ranked after them.
    private func addCrowd(_ harness: Harness, _ engine: FakeEngine) {
        let crowd = (0..<610).map { i in
            let person = World.staff(UInt32(1000 + i), name: "Crowd \(i)", job: "Coach", block: Int64(1000 + i), at: World.rivals)
            person.prepare()
            return person
        }
        harness.source.database.staff += crowd
        engine.staffWontJoin.formUnion(crowd.map(\.uid))
    }

    func testFMIsAskedAboutTheBest600AtMostAndSaysSo() throws {
        let engine = FakeEngine()
        let harness = harness(engine)
        addCrowd(harness, engine)
        let answer = try harness.answer("recommend_staff", ["role": "Coach"])
        XCTAssertEqual(uids(answer), [502, 503])
        XCTAssertEqual(engine.staffAsked.count, 600, "the best 600 and no further")
        let said = answer["interest"]?.string ?? ""
        XCTAssertTrue(said.hasPrefix("Everyone listed is someone FM says would join Testing FC's first team and take the job of coach."), said)
        XCTAssertTrue(said.contains("FM was asked about the best 600 for the job who pass these settings and no further"), said)

        // Nobody to find: still not "Nobody", as FM wasn't asked about everyone. FM's answers last the session, so a new one.
        let noneEngine = FakeEngine()
        let noneHarness = self.harness(noneEngine)
        addCrowd(noneHarness, noneEngine)
        noneEngine.staffWontJoin.formUnion([502, 503])
        let none = try noneHarness.answer("recommend_staff", ["role": "Coach"])
        XCTAssertTrue(uids(none).isEmpty)
        XCTAssertTrue(none["interest"]?.string?.hasPrefix("None of those FM answered for would join") ?? false, none["interest"]?.text ?? "")

        // Without the cap nothing says it stopped short.
        let few = try self.harness().answer("recommend_staff", ["role": "Coach"])
        XCTAssertFalse(few["interest"]?.string?.contains("best 600") ?? true)
    }

    /// The app's screen gives neither a cap nor how many it wants, and looks as far as it takes to find 25.
    func testTheScreensSearchIsUncapped() throws {
        let engine = FakeEngine()
        let harness = harness(engine)
        addCrowd(harness, engine)
        GameRules.engine = engine
        let session = AnalysisSession(db: harness.source.database, club: ChosenClub(team: 1, name: World.club, manager: 500),
                                      display: DisplayOptions(reveal: .numbers, showHidden: true))
        let recommender = StaffRecommender(session: session)
        let role = try XCTUnwrap(StaffRoles.all.first { $0.name == "Coach" })
        let options = StaffSearchOptions(role: role, maxWage: "")
        let table = try XCTUnwrap(recommender.find(options))
        XCTAssertFalse(table.stoppedAtDeepest)
        XCTAssertEqual(engine.staffAsked.count, 613, "everyone ranked, as the screen has always looked")
        XCTAssertEqual(table.people.map(\.uid), [502, 503])
        let capped = try XCTUnwrap(recommender.find(options, wanted: 1, deepest: 2))
        XCTAssertFalse(capped.stoppedAtDeepest, "it found the one it wanted")
        XCTAssertEqual(capped.people.map(\.uid), [502])
        let short = try XCTUnwrap(recommender.find(options, wanted: 5, deepest: 3))
        XCTAssertTrue(short.stoppedAtDeepest, "two would join among the best three, fewer than five")
    }

    func testPeopleFMDidntAnswerForAreLeftOutAndSaidSo() throws {
        let engine = FakeEngine()
        let harness = harness(engine)
        engine.staffUnanswered = [502]
        let some = try harness.answer("recommend_staff", ["role": "Coach"])
        XCTAssertEqual(uids(some), [503])
        let expected = "Everyone listed is someone FM says would join Testing FC's first team and take the job of coach. FM didn't "
            + "answer for 1 of the people it was asked about, so they're left out; asking again may get their answers. FM's staff search"
        XCTAssertTrue(some["interest"]?.string?.hasPrefix(expected) ?? false, some["interest"]?.text ?? "")

        // A failure isn't remembered, so asking again gets the answer.
        engine.staffUnanswered = []
        let again = try harness.answer("recommend_staff", ["role": "Coach"])
        XCTAssertEqual(Set(uids(again)), [502, 503])
        XCTAssertFalse(again["interest"]?.string?.contains("didn't answer") ?? true)

        // FM answers about the coach who wouldn't come, but about nobody who would. A new session, as FM's answers last one.
        let noneEngine = FakeEngine()
        noneEngine.staffUnanswered = [502, 503]
        let none = try self.harness(noneEngine).answer("recommend_staff", ["role": "Coach"])
        XCTAssertTrue(uids(none).isEmpty)
        let said = none["interest"]?.string ?? ""
        XCTAssertFalse(said.hasPrefix("Nobody"), said)
        XCTAssertTrue(said.hasPrefix("None of those FM answered for would join Testing FC's first team and take the job of coach. FM "
                                     + "didn't answer for 2 of"), said)
    }

    func testTheWageNoteIsTheCapUsed() throws {
        let harness = harness()
        harness.source.database.budgets = [1: (transfer: 5_000_000, wageRoom: 12_345)]
        let dear = World.staff(506, name: "Dear Coach", job: "Coach", block: 506, at: World.rivals)
        dear.stars = [5, 5, 5, 3, 2.5, 2.5, 1, 2, 2]
        dear.wage = 12_340
        dear.prepare()
        harness.source.database.staff.append(dear)
        let capped = try harness.answer("recommend_staff", ["role": "Coach"])
        XCTAssertFalse(uids(capped).contains(506), "the box starts at 12.3K, so 12,340 is over it")
        let note = capped["wage_max"]?.string ?? ""
        XCTAssertTrue(note.contains("12,300 p/w") && !note.contains("12,345"), note)
        XCTAssertEqual(uids(try harness.answer("recommend_staff", ["role": "Coach", "wage_max": 13000])).first, 506)

        harness.source.database.budgets = [1: (transfer: 5_000_000, wageRoom: 0)]
        let open = try harness.answer("recommend_staff", ["role": "Coach"])
        XCTAssertNil(open["wage_max"], "no wage room, no cap")
        XCTAssertTrue(uids(open).contains(506))
    }

    func testFMStarsGoWithAbility() throws {
        XCTAssertTrue(try harness().answer("recommend_staff", ["role": "Coach"]).columnNames.contains("FM stars"))
        XCTAssertFalse(try harness(hidden: true, reveal: .hidden).answer("recommend_staff", ["role": "Coach"]).columnNames.contains("FM stars"))
        XCTAssertFalse(try harness(hidden: false).answer("recommend_staff", ["role": "Coach"]).columnNames.contains("FM stars"))
    }

    // MARK: Whether they'd take the job

    func testSomeoneWhoWouldJoinButNotTakeTheJobIsLeftOut() throws {
        let engine = FakeEngine()
        let harness = harness(engine)
        engine.staffWontTake = [502]
        let answer = try harness.answer("recommend_staff", ["role": "Coach"])
        XCTAssertEqual(uids(answer), [503], "FM says 502 would join but wouldn't take the job")
        XCTAssertTrue(engine.staffJobsAsked.contains { $0.uid == 502 && $0.job == 2 && $0.level == 1 }, "coach, at the first team")
        XCTAssertFalse(engine.staffJobsAsked.contains { $0.uid == 505 }, "nobody FM says wouldn't join is asked about the job")

        let open = try harness.answer("recommend_staff", ["role": "Coach", "only_join": false])
        let byUID = Dictionary(uniqueKeysWithValues: open.rowsByName.map { ($0["uid"]?.int ?? 0, $0) })
        XCTAssertEqual(byUID[502]?["Would join"], "First team", "Would join stays FM's answer about the club and the team")
        XCTAssertEqual(byUID[502]?["Takes job"], "No")
        XCTAssertEqual(byUID[503]?["Takes job"], "Yes")
        XCTAssertEqual(byUID[505]?["Takes job"], .null, "only asked for those FM says would join")
        XCTAssertFalse(engine.staffJobsAsked.contains { $0.uid == 505 }, "FM's own job pick turns him down, so no question goes out")
        let said = open["interest"]?.string ?? ""
        XCTAssertTrue(said.hasPrefix("Not narrowed to who'd join.") && said.contains("Takes job is the same rule of FM's"), said)
        XCTAssertTrue(said.contains("Takes job is only asked for those FM says would join your first team, and left empty for the rest"), said)
    }

    func testWhenFMAnswersWithoutWeighingTheJobItsWhoWouldJoinAlone() throws {
        let engine = FakeEngine()
        engine.staffJobNotAsked = true
        let harness = harness(engine)
        let answer = try harness.answer("recommend_staff", ["role": "Coach"])
        XCTAssertEqual(Set(uids(answer)), [502, 503], "narrowed by who'd join, not left empty")
        XCTAssertTrue(answer.rowsByName.allSatisfy { $0["Takes job"] == .null })
        let said = answer["interest"]?.string ?? ""
        XCTAssertTrue(said.hasPrefix("Everyone listed is someone FM says would join Testing FC's first team. FM couldn't be asked whether "
                                     + "they'd take this job itself"), said)
        XCTAssertFalse(said.contains("asking again"), "asking again gives the same: \(said)")
        XCTAssertFalse(answer["status"]?.string?.contains("take the job") ?? true)

        let open = try harness.answer("recommend_staff", ["role": "Coach", "only_join": false])
        XCTAssertTrue(open.rowsByName.allSatisfy { $0["Takes job"] == .null })
        XCTAssertTrue(open["interest"]?.string?.contains("FM couldn't be asked whether they'd take this job itself") ?? false,
                      open["interest"]?.text ?? "")
    }

    func testTheJobIsAskedInRankOrderUntilEnoughAreFound() throws {
        let engine = FakeEngine()
        let harness = harness(engine)
        let crowd = (0..<40).map { i in
            let person = World.staff(UInt32(2000 + i), name: "Joiner \(i)", job: "Coach", block: Int64(2000 + i), at: World.rivals)
            person.prepare()
            return person
        }
        harness.source.database.staff += crowd
        let answer = try harness.answer("recommend_staff", ["role": "Coach", "limit": 1])
        XCTAssertEqual(uids(answer).count, 1)
        XCTAssertLessThanOrEqual(engine.staffJobsAsked.count, 8, "one chunk of joiners, not the whole batch")
    }

    func testAJobIsAskedAboutWhereItIs() throws {
        let engine = FakeEngine()
        engine.staffJoinLevels = [1, 3, 4]
        let harness = harness(engine)
        _ = try harness.answer("recommend_staff", ["role": "Assistant Manager", "level": "reserves", "only_join": false])
        XCTAssertFalse(engine.staffJobsAsked.isEmpty)
        XCTAssertTrue(engine.staffJobsAsked.allSatisfy { $0.job == 20 && $0.level == 3 }, "a team's job at that team")
        let before = engine.staffJobsAsked.count
        let analyst = try harness.answer("recommend_staff", ["role": "Recruitment Analyst", "level": "reserves", "only_join": false])
        let asked = engine.staffJobsAsked.dropFirst(before)
        XCTAssertFalse(asked.isEmpty)
        XCTAssertTrue(asked.allSatisfy { $0.job == 58 && $0.level == 1 }, "a club's job where FM places it, with the first team")
        XCTAssertTrue(analyst["interest"]?.string?.contains("asked about the job of recruitment analyst at the first team") ?? false,
                      analyst["interest"]?.text ?? "")
    }

    func testNoAnswerAboutTheJobIsNeverAYes() throws {
        let engine = FakeEngine()
        let harness = harness(engine)
        engine.staffJobUnanswered = [502]
        let answer = try harness.answer("recommend_staff", ["role": "Coach"])
        XCTAssertEqual(uids(answer), [503])
        XCTAssertTrue(answer["interest"]?.string?.contains("FM didn't answer for 1 of the people it was asked about") ?? false,
                      answer["interest"]?.text ?? "")
    }

    func testWhenFMCantBeAskedAboutTheJobItSaysWhatWouldJoinMeans() throws {
        let engine = FakeEngine()
        engine.staffJobAnswers = false
        let answer = try harness(engine).answer("recommend_staff", ["role": "Coach"])
        XCTAssertEqual(Set(uids(answer)), [502, 503], "narrowed by who'd join only")
        XCTAssertTrue(answer.rowsByName.allSatisfy { $0["Takes job"] == .null })
        let said = answer["interest"]?.string ?? ""
        XCTAssertTrue(said.hasPrefix("Everyone listed is someone FM says would join Testing FC's first team. FM couldn't be asked whether "
                                     + "they'd take this job itself"), said)
        XCTAssertTrue(said.contains("Would join is FM's answer about the club and the team, not the job"), said)
        XCTAssertTrue(answer["not_available"]?.string?.contains("whether they'd take this job") ?? false)
        XCTAssertFalse(answer["status"]?.string?.contains("take the job") ?? true)
    }

    func testWantsJobSaysWhosePreferenceItIs() throws {
        let harness = harness()
        let analyst = try harness.answer("recommend_staff", ["role": "Recruitment Analyst", "only_join": false])
        XCTAssertEqual(analyst["wants_job_note"],
                       "Wants job is how keen they are to be a performance analyst: FM keeps no preference for recruitment analyst.")
        let physio = try harness.answer("recommend_staff", ["role": "Head Physio", "only_join": false])
        XCTAssertEqual(physio["wants_job_note"], "Wants job is how keen they are to be a physio: FM keeps one preference for physio and head physio.")
        XCTAssertNil(try harness.answer("recommend_staff", ["role": "Physio", "only_join": false])["wants_job_note"])
    }
}
