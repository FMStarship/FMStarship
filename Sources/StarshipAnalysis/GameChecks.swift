import Foundation
import StarshipCore

/// Whether a player would come, as the game itself would answer.
public struct JoinAnswer: Equatable {
    public var transfer: Bool
    public var loan: Bool

    public init(transfer: Bool, loan: Bool) {
        self.transfer = transfer
        self.loan = loan
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
    private var preferences: [UInt32: [UInt8]] = [:]
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

    public func staffText(_ person: Staff) -> String {
        guard let answer = staffKnown(person) else { return "" }
        let levels = [answer.firstTeam ? "First team" : nil, answer.reserves ? "Reserves" : nil, answer.youth ? "Youth" : nil]
        let text = levels.compactMap { $0 }.joined(separator: ", ")
        return text.isEmpty ? "No" : text
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
