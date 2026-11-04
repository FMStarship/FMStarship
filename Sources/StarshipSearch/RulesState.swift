import Foundation
import StarshipCore

/// Whether a person would join the chosen club, per contract level.
public typealias PlayerInterest = (transfer: Bool, loan: Bool)
public typealias StaffInterest = (firstTeam: Bool, reserves: Bool, youth: Bool)

/// Asks `GameRules.engine` and remembers the answers. Each one means running game code, so a list reads what
/// is already known (`known`, `text`) and a background pass does the asking (`check`, `checkAll`).
/// Without an engine everything answers nil or "", which the app shows as "not available".
public final class RulesState: @unchecked Sendable {
    public static let shared = RulesState()

    /// The team being recruited for, and its name. Zero means none. Both change through `pickClub`.
    public private(set) var team: Int64 = 0
    public private(set) var clubName = ""

    /// Human clubs in the loaded save, as `fill` found them.
    public private(set) var clubs: [String] = []
    /// False when there's only one club to choose from.
    public private(set) var clubPickerEnabled = false
    public private(set) var interestEnabled = false
    public private(set) var interestNote = ""
    public private(set) var staffInterestEnabled = false
    public private(set) var staffInterestNote = ""

    public private(set) var failures = 0
    public private(set) var lastFailure = ""

    private static let staffLevels = [1, 3, 4]

    private struct Key: Hashable {
        let index: UInt32
        let team: Int64
    }

    private let lock = NSLock()
    private var interestCache: [Key: PlayerInterest] = [:]
    private var staffCache: [Key: StaffInterest] = [:]
    private var injuryDays: [UInt32: Int] = [:]
    private var clubObjects: [String: Int64] = [:]
    private var managers: [Int64: Int64] = [:]

    public init() {}

    /// Forgets every answer. Call after changing `GameRules.engine` or loading a save.
    public func reset() {
        lock.withLock {
            interestCache.removeAll()
            staffCache.removeAll()
            injuryDays.removeAll()
        }
    }

    /// The manager of the chosen team, or zero.
    public var manager: Int64 { managers[team] ?? 0 }

    /// Reads the human clubs out of a loaded save and picks one: the saved `interestClub`, else the first.
    public func fill(_ database: Database) {
        var names: [String] = []
        var objects: [String: Int64] = [:]
        var managersFound: [Int64: Int64] = [:]
        for club in database.humanClubs {
            if !club.name.isEmpty, objects[club.name] == nil {
                objects[club.name] = club.team
                names.append(club.name)
            }
            if club.manager > 0, managersFound[club.team] == nil { managersFound[club.team] = club.manager }
        }
        clubObjects = objects
        clubs = names
        managers = managersFound

        let live = GameRules.engine != nil
        let usable = live && !names.isEmpty
        interestEnabled = usable
        clubPickerEnabled = usable && names.count > 1
        if !live {
            interestNote = "Needs the live game (FM26 or FM27): press Load Save."
        } else if names.isEmpty {
            interestNote = "No human-managed club found in this save."
        } else if names.count > 1 {
            interestNote = "This save has \(names.count) human managers: pick whose club."
        } else {
            interestNote = ""
        }

        team = 0
        let saved = names.firstIndex(of: Settings.current.interestClub) ?? 0
        pickClub(usable ? names[saved] : nil)

        staffInterestEnabled = live && !managersFound.isEmpty
        staffInterestNote = staffInterestEnabled
            ? "Staff who'd come to work for your club (set in the players' Interest section)."
            : "Needs the live game (FM26 or FM27): press Load Save."
    }

    /// Chooses the club by name. An unknown name clears the choice. The caller re-runs the search.
    public func pickClub(_ name: String?) {
        let picked = name.flatMap { clubObjects[$0] } ?? 0
        if picked == team { return }
        team = picked
        clubName = picked == 0 ? "" : name ?? ""
        if picked != 0, let name { Settings.current.interestClub = name }
    }

    // MARK: Players

    /// The answer if it has already been worked out.
    public func known(_ player: Player) -> PlayerInterest? {
        guard team != 0 else { return nil }
        let key = Key(index: player.index, team: team)
        return lock.withLock { interestCache[key] }
    }

    /// The answer, asking the game if need be. Retries once, as a call can fail while the game is busy.
    public func check(_ player: Player) -> PlayerInterest? {
        let team = self.team
        guard let engine = GameRules.engine, team != 0, player.block != 0 else { return nil }
        let key = Key(index: player.index, team: team)
        if let cached = lock.withLock({ interestCache[key] }) { return cached }

        guard let levels = engine.interest(player: player, team: team)
                ?? engine.interest(player: player, team: team) else {
            lock.withLock {
                failures += 1
                lastFailure = "No interest answer for \(player.name)"
            }
            return nil
        }
        let answer: PlayerInterest = (levels.transfer.wouldJoin, levels.loan.wouldJoin)
        lock.withLock { interestCache[key] = answer }
        return answer
    }

    public func text(_ player: Player) -> String {
        guard let known = known(player) else { return "" }
        switch (known.transfer, known.loan) {
        case (true, true): return "Transfer, loan"
        case (true, false): return "Transfer"
        case (false, true): return "Loan"
        case (false, false): return "No"
        }
    }

    /// Works out everyone not yet known, on several threads when `workers` allows it.
    public func checkAll(_ players: [Player], workers: Int = RulesState.defaultWorkers,
                         cancelled: () -> Bool = { false }, progress: (Int, Int) -> Void = { _, _ in }) {
        let todo = players.filter { known($0) == nil }
        Self.forEach(todo, workers: workers, reportEvery: 200, cancelled: cancelled, progress: progress) {
            _ = check($0)
        }
    }

    // MARK: Staff

    public func staffKnown(_ staff: Staff) -> StaffInterest? {
        guard team != 0 else { return nil }
        let key = Key(index: staff.index, team: team)
        return lock.withLock { staffCache[key] }
    }

    private static let boardJobs: Set<String> = ["Chairperson", "President", "Director", "Owner", "Managing Director"]

    public func staffCheck(_ staff: Staff) -> StaffInterest? {
        let team = self.team
        guard let engine = GameRules.engine, team != 0, manager != 0, staff.block != 0 else { return nil }
        let key = Key(index: staff.index, team: team)
        if let cached = lock.withLock({ staffCache[key] }) { return cached }

        // Boards aren't hired by managers. The original's list of board jobs is meant to answer "no".
        if Self.boardJobs.contains(staff.job) {
            let answer: StaffInterest = (false, false, false)
            lock.withLock { staffCache[key] = answer }
            return answer
        }
        let levels = Self.staffLevels
        guard let first = engine.staffInterest(staff: staff, team: team, level: levels[0]),
              let reserves = engine.staffInterest(staff: staff, team: team, level: levels[1]),
              let youth = engine.staffInterest(staff: staff, team: team, level: levels[2]) else { return nil }
        let answer: StaffInterest = (first, reserves, youth)
        lock.withLock { staffCache[key] = answer }
        return answer
    }

    public func staffText(_ staff: Staff) -> String {
        guard let known = staffKnown(staff) else { return "" }
        let levels = [known.firstTeam ? "First team" : nil, known.reserves ? "Reserves" : nil, known.youth ? "Youth" : nil]
        let text = levels.compactMap { $0 }.joined(separator: ", ")
        return text.isEmpty ? "No" : text
    }

    public func checkAllStaff(_ staff: [Staff], workers: Int = RulesState.defaultWorkers,
                              cancelled: () -> Bool = { false }, progress: (Int, Int) -> Void = { _, _ in }) {
        let todo = staff.filter { staffKnown($0) == nil }
        Self.forEach(todo, workers: workers, reportEvery: 100, cancelled: cancelled, progress: progress) {
            _ = staffCheck($0)
        }
    }

    // MARK: Injuries

    /// Days until a player is back: 0 if fit, nil if not worked out yet.
    public func injuryKnown(_ player: Player) -> Int? {
        guard player.injury != nil else { return 0 }
        return lock.withLock { injuryDays[player.index] }
    }

    public func injuryCheck(_ player: Player) -> Int? {
        if let known = injuryKnown(player) { return known }
        guard let engine = GameRules.engine, let days = engine.injuryReturnDays(player: player) else { return nil }
        lock.withLock { injuryDays[player.index] = days }
        player.injuryDays = days
        return days
    }

    // MARK: Background passes

    /// All cores but two, so the game stays responsive. Pass 1 if the engine can only take one call at a time.
    public static var defaultWorkers: Int { max(1, ProcessInfo.processInfo.processorCount - 2) }

    private static func forEach<Item>(_ items: [Item], workers: Int, reportEvery: Int, cancelled: () -> Bool,
                                      progress: (Int, Int) -> Void, _ work: (Item) -> Void) {
        let lock = NSLock()
        var next = 0
        var done = 0
        DispatchQueue.concurrentPerform(iterations: max(1, workers)) { _ in
            while !cancelled() {
                let index: Int? = lock.withLock {
                    guard next < items.count else { return nil }
                    next += 1
                    return next - 1
                }
                guard let index else { return }
                work(items[index])
                let finished = lock.withLock {
                    done += 1
                    return done
                }
                if finished % reportEvery == 0 { progress(finished, items.count) }
            }
        }
    }
}

public enum RoleState {
    /// The position a player is best at. The first such position wins a tie.
    public static func bestPos(_ player: Player) -> Int {
        var best = 0
        for position in 1..<15 where player.pos[position] > player.pos[best] { best = position }
        return best
    }
}

public enum FmStars {
    /// A staff member's stars for a job, as the game shows them, from their score for it.
    public static func text(score: Int, ca: Int) -> String {
        text(Double(Names.fmStars(score, ca)) / 2.0)
    }

    public static func text(_ stars: Double) -> String { Net.fixed(stars, min: 1, max: 1) + "★" }

    /// A job score with how keen that makes them: "16 - keen".
    public static func keenness(_ score: Int) -> String { "\(score) - \(Names.keenness(score))" }
}
