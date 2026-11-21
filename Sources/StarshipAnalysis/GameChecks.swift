import Foundation
import StarshipCore

/// Whether a player would come, as the game itself would answer, and how keen he is.
public struct JoinAnswer: Equatable {
    public var transferInterest: JoinInterest
    public var loanInterest: JoinInterest

    public var transfer: Bool { transferInterest.wouldJoin }
    public var loan: Bool { loanInterest.wouldJoin }

    public init(transfer: JoinInterest, loan: JoinInterest) {
        transferInterest = transfer
        loanInterest = loan
    }
}

/// Whether a member of staff would come, per team level.
public struct StaffJoinAnswer: Equatable {
    public var firstTeam: Bool
    public var reserves: Bool
    public var youth: Bool

    public init(firstTeam: Bool, reserves: Bool, youth: Bool) {
        self.firstTeam = firstTeam
        self.reserves = reserves
        self.youth = youth
    }

    public func wouldJoin(level: Int) -> Bool {
        level == 0 ? firstTeam : level == 1 ? reserves : youth
    }
}

/// The questions only the game can answer, asked through `GameRules.engine` and remembered, as
/// `Emu.InterestState` and `Emu.InjuryState` do. The engine must answer from several threads at
/// once: the batches below run in parallel, as they do in the original.
public final class GameChecks {
    /// The levels the game's staff-interest check is called with, for first team, reserves and youth.
    public static let staffLevels = [1, 3, 4]
    static let board = ["Chairperson", "President", "Director", "Owner", "Managing Director"]
    /// `ScopeNames` index of "Club total", the only scope the screens here read.
    static let clubTotalScope = 5

    public let club: ChosenClub

    private let lock = NSLock()
    private var players: [UInt32: JoinAnswer] = [:]
    private var staff: [UInt32: StaffJoinAnswer] = [:]
    /// Per person, by `jobKey`: whether FM says they'd take that job.
    private var staffJobs: [UInt32: [Int: StaffJobAnswer]] = [:]
    /// By `jobKey`: the team those answers were asked at. `jobTeam` can name another team later in the session, once the
    /// board's limits can be read, and then the answers are dropped.
    private var staffJobTeams: [Int: Int64] = [:]
    private var preferences: [UInt32: [UInt8]] = [:]
    /// `jobTeam` and `levelTeams`, once each has been answered in full: they depend only on the club.
    private var jobTeams: [Int64?]?
    private var levelTeamsMemo: [TeamAtLevel?]?
    private var injuries: [UInt32: Int] = [:]
    private var failed = 0

    public init(club: ChosenClub) {
        self.club = club
    }

    private var engine: GameRulesEngine? { GameRules.engine }

    /// False when players' interest can't be asked: "Only players who'd join" is off.
    public var canCheckInterest: Bool { engine != nil && club.team != 0 }

    /// Staff interest also needs the user to be the club's manager.
    public var canCheckStaffInterest: Bool { canCheckInterest && club.manager != 0 }

    /// Whether FM can also be asked whether someone would take a particular job.
    public var canCheckStaffJob: Bool { canCheckStaffInterest && engine?.supportsStaffJobInterest == true }

    /// Whether FM can be asked about a job at team level `level` (0 first team, 1 reserves, 2 youth): it needs the team.
    public func canCheckStaffJob(level: Int) -> Bool { canCheckStaffJob && jobTeam(level: level) != nil }

    /// The team a job at `level` is at, as FM Starship names the levels: the club's team, then the reserve and youth teams of
    /// the board's staff limits. This is the team FM's approach scores the job at. Without the limits it's the team FM's own
    /// staff rule asks about at that level, as Would join is then used as it is. Nil when neither is known, or with no such team.
    public func jobTeam(level: Int) -> Int64? {
        guard (0..<3).contains(level) else { return nil }
        if let known = locked({ jobTeams }) { return known[level] }
        let limits = StaffLimits.read(team: club.team)
        // Without the limits nothing is kept, so they're read again next time.
        guard let limits else {
            if level == 0 { return club.team }
            guard let team = levelTeams[level], team.object != 0 else { return nil }
            return team.object
        }
        let teams: [Int64?] = (0..<3).map { level in
            if level == 0 { return club.team }
            let index = limits.teamFor(level)
            return index >= 0 && index < limits.teams.count && limits.teams[index].object != 0 ? limits.teams[index].object : nil
        }
        locked { jobTeams = teams }
        return teams[level]
    }

    /// The team FM's staff rule asks Would join about at each level, first team, reserves and youth. Nil where it can't be told,
    /// which is asked again next time.
    public var levelTeams: [TeamAtLevel?] {
        if let known = locked({ levelTeamsMemo }) { return known }
        let teams = GameChecks.staffLevels.map { level in engine.flatMap { $0.staffLevelTeam(team: club.team, level: level) } }
        if !teams.contains(nil) { locked { levelTeamsMemo = teams } }
        return teams
    }

    /// Whether Would join at `level` is FM's answer about the team FM Starship names at that level. It isn't where FM's level
    /// finds another team, as for Molde, whose reserves level is its U19 and not Molde 2. True when either can't be told.
    public func wouldJoinFits(level: Int) -> Bool {
        guard level > 0, level < 3, let asked = levelTeams[level], let named = jobTeam(level: level) else { return true }
        return asked.object == named
    }

    /// The name of the team FM's staff rule asks about at `level`, such as "U19". Nil where it can't be told or there's none.
    public func levelTeamName(level: Int) -> String? {
        guard (0..<3).contains(level), let team = levelTeams[level], team.object != 0 else { return nil }
        return level == 0 ? "First team" : Names.squadName(team.type)
    }

    /// Whether FM's reserves and youth levels ask about the same team.
    public var reservesAreYouth: Bool {
        guard let reserves = levelTeams[1], let youth = levelTeams[2] else { return false }
        return reserves.object != 0 && reserves.object == youth.object
    }

    /// How many questions the engine couldn't answer.
    public var failures: Int { locked { failed } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Players

    public func known(_ player: Player) -> JoinAnswer? {
        locked { players[player.index] }
    }

    public func check(_ player: Player) -> JoinAnswer? {
        guard let engine, club.team != 0, player.block != 0 else { return nil }
        if let answer = known(player) { return answer }
        guard let answer = engine.interest(player: player, team: club.team) else {
            locked { failed += 1 }
            return nil
        }
        let result = JoinAnswer(transfer: answer.transfer, loan: answer.loan)
        locked { players[player.index] = result }
        return result
    }

    /// One batch of a ranked list. Nil means the game can't answer at all, not that nobody would join.
    func check(batch: [Player]) -> [JoinAnswer?]? {
        guard canCheckInterest else { return nil }
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
        let answers = parallelMap(batch, workers: workers) { self.check($0) }
        return locked { players.isEmpty } ? nil : answers
    }

    public func text(_ player: Player) -> String {
        guard let answer = known(player) else { return "" }
        if answer.transfer { return answer.loan ? "Transfer, loan" : "Transfer" }
        return answer.loan ? "Loan" : "No"
    }

    // MARK: Staff

    public func staffKnown(_ person: Staff) -> StaffJoinAnswer? {
        locked { staff[person.index] }
    }

    public func staffCheck(_ person: Staff) -> StaffJoinAnswer? {
        guard let engine, canCheckStaffInterest, person.block != 0 else { return nil }
        if let answer = staffKnown(person) { return answer }
        let answer: StaffJoinAnswer
        if GameChecks.board.contains(person.job) {
            answer = StaffJoinAnswer(firstTeam: false, reserves: false, youth: false)
        } else {
            let levels = GameChecks.staffLevels
            guard let first = engine.staffInterest(staff: person, team: club.team, level: levels[0]),
                  let reserves = engine.staffInterest(staff: person, team: club.team, level: levels[1]),
                  let youth = engine.staffInterest(staff: person, team: club.team, level: levels[2]) else {
                locked { failed += 1 }
                return nil
            }
            answer = StaffJoinAnswer(firstTeam: first, reserves: reserves, youth: youth)
        }
        locked { staff[person.index] = answer }
        return answer
    }

    public func checkAllStaff(_ people: [Staff], isCancelled: () -> Bool = { false }) {
        let todo = people.filter { staffKnown($0) == nil }
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
        parallelFor(count: todo.count, workers: workers) { i in
            if !isCancelled() { _ = self.staffCheck(todo[i]) }
        }
    }

    /// One batch of a ranked list. False means the game can't answer at all, not that nobody would join.
    func checkStaff(batch: [Staff], isCancelled: () -> Bool) -> Bool {
        checkAllStaff(batch, isCancelled: isCancelled)
        return locked { !staff.isEmpty }
    }

    /// The teams FM says they'd join, named as the teams FM asked about: "First team, U19".
    public func staffText(_ person: Staff) -> String {
        guard let answer = staffKnown(person) else { return "" }
        let teams = levelTeams
        return TeamAtLevel.joinText(answers: [answer.firstTeam, answer.reserves, answer.youth],
                                    teams: teams.contains(nil) ? nil : teams)
    }

    private static func jobKey(job: Int, level: Int) -> Int { job * 4 + level }

    /// FM's answer, already asked, to whether they'd take `job` (from `Names.jobs`) at team level `level` (0 first team,
    /// 1 reserves, 2 youth).
    public func staffJobKnown(_ person: Staff, job: Int, level: Int) -> StaffJobAnswer? {
        locked { staffJobs[person.index]?[GameChecks.jobKey(job: job, level: level)] }
    }

    /// Whether FM says they'd take `job` at team level `level`: FM's staff search rule, the one behind `staffCheck`, asked
    /// about this job at `at`, `jobTeam(level:)` as `checkStaffJob` found it, rather than the job and team FM picks for them.
    /// Nil when FM can't be asked or the call failed; `.notAsked` when FM answered without weighing the job up, which asking
    /// again doesn't change.
    private func staffJobCheck(_ person: Staff, job: Int, level: Int, at: Int64) -> StaffJobAnswer? {
        guard let engine, canCheckStaffJob, person.block != 0 else { return nil }
        if let answer = staffJobKnown(person, job: job, level: level) { return answer }
        let answer: StaffJobAnswer
        if GameChecks.board.contains(person.job) {
            answer = .refuses
        } else {
            guard let asked = engine.staffJobInterest(staff: person, team: club.team, job: job, at: at) else {
                locked { failed += 1 }
                return nil
            }
            answer = asked
        }
        let key = GameChecks.jobKey(job: job, level: level)
        // Kept only while the job is still asked at this team, as another batch may have moved it on meanwhile.
        locked { if staffJobTeams[key] == at { staffJobs[person.index, default: [:]][key] = answer } }
        return answer
    }

    /// Asks FM whether each of `people` would take `job` at team level `level`, for those not yet known.
    public func checkStaffJob(_ people: [Staff], job: Int, level: Int, isCancelled: () -> Bool = { false }) {
        // The team is worked out once, so a batch never asks about two teams and the limits aren't read for each person.
        guard canCheckStaffJob, let at = jobTeam(level: level) else { return }
        let key = GameChecks.jobKey(job: job, level: level)
        locked {
            // Answers asked at another team, as before the board's limits could be read, aren't about this one.
            if let asked = staffJobTeams[key], asked != at {
                staffJobs = staffJobs.mapValues { $0.filter { $0.key != key } }
            }
            staffJobTeams[key] = at
        }
        let todo = people.filter { staffJobKnown($0, job: job, level: level) == nil }
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
        parallelFor(count: todo.count, workers: workers) { i in
            if !isCancelled() { _ = self.staffJobCheck(todo[i], job: job, level: level, at: at) }
        }
    }

    /// Whether FM has answered about `job` at `level` without weighing the job up, which it does for a whole club at once.
    public func staffJobNotWeighed(job: Int, level: Int) -> Bool {
        let key = GameChecks.jobKey(job: job, level: level)
        return locked { staffJobs.values.contains { $0[key] == .notAsked } }
    }

    /// "Yes" or "No" when FM has answered about the job, otherwise empty.
    public func staffJobText(_ person: Staff, job: Int, level: Int) -> String {
        switch staffJobKnown(person, job: job, level: level) {
        case .takes: return "Yes"
        case .refuses: return "No"
        case .notAsked, nil: return ""
        }
    }

    /// `RecommendStaffForm.Want`: how much he wants the job at `Names.prefJobs[index]`.
    public func wantsJob(_ person: Staff, preference index: Int) -> Int? {
        guard let engine, index >= 0 else { return nil }
        let cached = locked { preferences[person.index] }
        guard let prefs = cached ?? engine.jobPreferences(staff: person) else { return nil }
        if cached == nil { locked { preferences[person.index] = prefs } }
        return index < prefs.count ? Int(prefs[index]) : nil
    }

    public func preferredJob(_ person: Staff) -> String {
        guard let job = engine?.preferredJob(staff: person), job != 0 else { return "" }
        return Names.jobs[job] ?? ""
    }

    // MARK: Injuries and season stats

    /// `InjuryState.Known`: 0 when fit, nil when the exact length hasn't been worked out.
    public func injuryKnown(_ player: Player) -> Int? {
        guard player.injury != nil else { return 0 }
        return locked { injuries[player.index] }
    }

    /// `InjuryState.Check`.
    public func injuryCheck(_ player: Player) -> Int? {
        if let days = injuryKnown(player) { return days }
        guard let days = engine?.injuryReturnDays(player: player) else { return nil }
        locked { injuries[player.index] = days }
        player.injuryDays = days
        return days
    }

    /// `InjuryState.Check(p) ?? p.InjuryDays`.
    func daysOut(_ player: Player) -> Int {
        injuryCheck(player) ?? player.injuryDays
    }

    /// `StatsState.Ensure`.
    @discardableResult
    public func ensureSeason(_ player: Player) -> SeasonStats? {
        if let season = player.season { return season }
        guard let engine, player.block != 0 else { return nil }
        if let season = engine.seasonStats(player: player, season: GameChecks.clubTotalScope), season.apps > 0 {
            player.season = season
        }
        if player.form.isEmpty, let form = engine.form(player: player) { player.form = form }
        return player.season
    }
}
