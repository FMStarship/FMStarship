import CA64
import Foundation

/// FM's own rules, run in the sandbox. Each feature is found by class name where possible, so a
/// patch that moves code keeps working; anything not found leaves that feature switched off.
public final class RulesEngine: GameRulesEngine {
    /// Only valid for one build of game_plugin: the engine refuses to start on any other. fmprobe takes its
    /// addresses from here too, so a patch only changes them here.
    package enum Mac27 {
        package static let fingerprint = "3273c947b3b3e8a3"
        package static let interestManagerGlobal: Int64 = 0x576ed40
        package static let statusFunction: Int64 = 0xd52c30
        package static let interestSlot = 30
        package static let staffRuleSlot = 20
        package static let statFunction: Int64 = 0xf81790
        package static let statsContainerSlot = 65
        package static let personStatsSlot = 0x668 / 8
        package static let statFallback = 0.0
        package static let roleInPossession: Int64 = 0x14f2478
        package static let roleOutOfPossession: Int64 = 0x150628c
        package static let roleBand: Int64 = 0x14f2c70
        package static let roleListInPossession: Int64 = 0x4a206a8
        package static let roleListOutOfPossession: Int64 = 0x4a22cec
        package static let preferredJob: Int64 = 0x4a0924c
        package static let staffNumbersGlobal: Int64 = 0x576ebb8
        package static let staffAllowedSlot = 8
        package static let staffCurrentSlot = 7
        package static let staffModeFlags: Int64 = 0x5770988
        package static let injuryInfo: Int64 = 0x1554344
        package static let bagSet: Int64 = 0x4411348
        package static let bagClear: Int64 = 0x44115d8
        package static let injuryDaysKey: UInt64 = 0x5050_4d69  // "PPMi" in the bag FM fills for its injury text
        package static let shapeName: Int64 = 0x4a7ac4c
    }

    public static let transfer: UInt64 = 4
    public static let loan: UInt64 = 3
    /// The stats scope that totals a player's season for his club.
    public static let clubTotal = 5
    /// First team, reserves, youth.
    public static let staffLevels = [1, 3, 4]

    public let game: GameProcess
    private let sandbox: Sandbox
    /// The process this engine reads. Its addresses mean nothing in any other run of the game.
    public var pid: Int32 { game.pid }
    /// How many of FM's pages the sandbox has copied so far. It keeps them for as long as the engine lasts.
    public var cachedPages: Int { sandbox.cachedPages }
    private let manager: Int64
    private let interestFunction: Int64
    private let statusFunction: Int64
    private let staffFunction: Int64
    private let statFunction: Int64
    private let statsContainerFunction: Int64
    /// Team to HUMAN_NON_PLAYER object, for the staff rule.
    public var managers: [Int64: Int64] = [:]
    /// Team to the staff member whose eye the role stars are seen through.
    public var viewers: [Int64: Int64] = [:]
    /// The human clubs that are women's sides, from `Database.womensTeams`.
    public var womensTeams: Set<Int64> = []
    private let interestAnswers = InterestAnswers()
    private let roleLock = NSLock()
    private var roleMasks: [Int: UInt64] = [:]
    private let failureLock = NSLock()
    private var failure: String?
    public var lastFailure: String? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return failure
    }

    public init?(game: GameProcess, rtti: Rtti) {
        guard GameBuild.fingerprint(pluginPath: game.pluginPath) == Mac27.fingerprint,
              let sandbox = try? Sandbox(game: game) else { return nil }
        self.game = game
        self.sandbox = sandbox
        statusFunction = game.pluginBase + Mac27.statusFunction
        manager = game.readPointer(game.pluginBase + Mac27.interestManagerGlobal)
        guard let vtable = rtti.vtables("GAME_ACTUAL_PLAYER").first(where: { $0.offsetToTop == 0 }),
              manager != 0, game.readPointer(manager) == game.pluginBase + Int64(vtable.addressPoint) else { return nil }
        interestFunction = rtti.word(vtable.addressPoint + Mac27.interestSlot * 8)
        guard interestFunction > game.pluginBase, interestFunction < game.pluginBase + game.pluginSize else { return nil }
        statFunction = game.pluginBase + Mac27.statFunction
        statsContainerFunction = rtti.word(vtable.addressPoint + Mac27.statsContainerSlot * 8)
        staffFunction = rtti.vtables("PERSON_NON_PLAYER_INTERESTED_FILTER_RULE").first { $0.offsetToTop == 0 }
            .map { rtti.word($0.addressPoint + Mac27.staffRuleSlot * 8) } ?? 0
    }

    private func status(_ player: Player, team: Int64) throws -> UInt64 {
        try sandbox.call(statusFunction, [UInt64(player.block), UInt64(team), 0, 0, 0, 0, 1, 0], stack: [0]) { a64_get_x($0, 0) & 255 }
    }

    private func score(_ player: Player, club: Int64, type: UInt64, status: UInt64) throws -> Int32 {
        try sandbox.call(interestFunction, [UInt64(manager), UInt64(player.block), UInt64(club), type, status, 0, 0, 0]) {
            Int32(truncatingIfNeeded: a64_get_x($0, 0))
        }
    }

    public func interest(player: Player, team: Int64) -> (transfer: JoinInterest, loan: JoinInterest)? {
        // FM's rule only weighs up the move, so without this it says a woman would join a men's club.
        guard player.isWoman == womensTeams.contains(team) else { return (.notInterested, .notInterested) }
        return interestAnswers.answer(player: player.block, team: team) { askInterest(player: player, team: team) }
    }

    private func askInterest(player: Player, team: Int64) -> (transfer: JoinInterest, loan: JoinInterest)? {
        let club = game.readPointer(team + Int64(MacLayout.Team.club))
        guard let status = try? status(player, team: team), club != 0,
              let transfer = try? score(player, club: club, type: RulesEngine.transfer, status: status) else { return nil }
        if player.loanUnavailable { return (JoinInterest(score: transfer), .notInterested) }
        guard let loan = try? score(player, club: club, type: RulesEngine.loan, status: status) else { return nil }
        return (JoinInterest(score: transfer), JoinInterest(score: loan))
    }

    /// The filter rule FM itself uses: a rule object plus two context blocks, built in scratch memory.
    public func staffInterest(staff: Staff, team: Int64, level: Int) -> Bool? {
        guard staffFunction != 0, let manager = managers[team], manager != 0 else { return nil }
        let rule = UInt64(A64_SCRATCH), person = rule + 0x100, context = rule + 0x200
        do {
            return try sandbox.call(staffFunction, [rule, person, context], prepare: { cpu in
                a64_write(cpu, rule + 24, UInt64(level), 1)
                a64_write(cpu, rule + 25, 1, 1)
                a64_write(cpu, person + 8, UInt64(staff.block + Int64(MacLayout.Staff.identity)), 8)
                a64_write(cpu, context + 8, UInt64(manager), 8)
                a64_write(cpu, context + 16, UInt64(team), 8)
                a64_write(cpu, context + 24, UInt64(manager + Int64(MacLayout.Human.managerIdentity)), 8)
            }, result: { a64_get_x($0, 0) & 255 != 0 })
        } catch {
            failureLock.lock()
            failure = "\(error)"
            failureLock.unlock()
            return nil
        }
    }

    public var supportsInjuryDays: Bool { true }

    public func preferredJob(staff: Staff) -> Int? {
        let block = game.readPointer(staff.block + Int64(MacLayout.Staff.jobPreferences))
        guard block != 0 else { return nil }
        return try? sandbox.call(game.pluginBase + Mac27.preferredJob, [UInt64(block), UInt64(staff.block)]) { Int(a64_get_x($0, 0) & 255) }
    }
    public func jobPreferences(staff: Staff) -> [UInt8]? {
        let block = game.readPointer(staff.block + Int64(MacLayout.Staff.jobPreferences))
        return block == 0 ? nil : game.read(block, count: 15)
    }

    /// The roles FM offers at a position. FM's position numbering, from Names.posToGame.
    private func roleMask(position: Int, outOfPossession: Bool) -> UInt64? {
        roleLock.lock()
        defer { roleLock.unlock() }
        let key = position * 2 + (outOfPossession ? 1 : 0)
        if let known = roleMasks[key] { return known }
        let scratch = UInt64(A64_SCRATCH) + 0xc00
        let function = game.pluginBase + (outOfPossession ? Mac27.roleListOutOfPossession : Mac27.roleListInPossession)
        guard let mask: UInt64 = try? sandbox.call(function, [UInt64(position), scratch, scratch + 8, 0], prepare: { cpu in
            a64_write(cpu, scratch, UInt64(1) << UInt64(position & 31), 4)
            a64_write(cpu, scratch + 8, 0x1a03_0001, 4)
        }, result: { a64_get_x($0, 0) }) else { return nil }
        roleMasks[key] = mask
        return mask
    }

    private func rating(_ player: Player, position: Int, role: Int, outOfPossession: Bool, viewer: Int64) throws -> Int32 {
        let positions = UInt64(1) << UInt64(position), roles = UInt64(1) << UInt64(role)
        if outOfPossession {
            return try sandbox.call(game.pluginBase + Mac27.roleOutOfPossession,
                                    [UInt64(player.block), positions, roles, 2, UInt64(viewer), 0, 1, 0]) { Int32(truncatingIfNeeded: a64_get_x($0, 0)) }
        }
        return try sandbox.call(game.pluginBase + Mac27.roleInPossession,
                                [UInt64(player.block), positions, roles, 0, 0, 2, UInt64(viewer), 0], stack: [1, 0]) { Int32(truncatingIfNeeded: a64_get_x($0, 0)) }
    }

    /// Half-stars as (lowest, highest): a scout's view of a player is a band, not a point.
    private func band(_ player: Player, rating: Int32, team: Int64) throws -> (Int, Int) {
        let out = UInt64(A64_SCRATCH) + 0xc14
        return try sandbox.call(game.pluginBase + Mac27.roleBand, [UInt64(player.block), UInt64(UInt32(bitPattern: rating)), UInt64(team), out, 0]) { cpu in
            (min(10, max(0, Int(a64_read(cpu, out, 1)) - 10)), min(10, max(0, Int(a64_read(cpu, out + 1, 1)) - 10)))
        }
    }

    /// Every role at one position, as the player's profile in FM shows it.
    public func roleTable(player: Player, position: Int, team: Int64) -> [RoleRow]? {
        guard let viewer = viewers[team], viewer != 0 else { return nil }
        let gamePosition = Names.posToGame[position]
        var rows: [RoleRow] = []
        for outOfPossession in [false, true] {
            guard let mask = roleMask(position: gamePosition, outOfPossession: outOfPossession) else { return nil }
            let names = outOfPossession ? Names.rolesOop : Names.rolesIp
            for role in 0..<64 where mask >> UInt64(role) & 1 == 1 {
                guard let value = try? rating(player, position: gamePosition, role: role, outOfPossession: outOfPossession, viewer: viewer),
                      let (low, high) = try? band(player, rating: value, team: team) else { return nil }
                rows.append(RoleRow(role: names[role] ?? "Role \(role)", outOfPossession: outOfPossession,
                                    minHalfStars: low, maxHalfStars: high, rating: Int(value)))
            }
        }
        return rows
    }

    public func roleRows(player: Player, team: Int64) -> [RoleRow]? {
        guard let best = (0..<15).max(by: { player.pos[$0] < player.pos[$1] }) else { return nil }
        return roleTable(player: player, position: best, team: team)
    }

    /// FM's season figures live in a container reached through the person, then read by id.
    private func statsContainer(_ player: Player) throws -> UInt64 {
        let vtable = game.readPointer(player.block)
        guard vtable != 0 else { return 0 }
        let identity = player.block + game.readPointer(vtable - 0x18)
        let method = game.readPointer(game.readPointer(identity) + Int64(Mac27.personStatsSlot * 8))
        guard method != 0 else { return 0 }
        let holder: UInt64 = try sandbox.call(method, [UInt64(identity)]) { a64_get_x($0, 0) }
        guard holder != 0 else { return 0 }
        return try sandbox.call(statsContainerFunction, [UInt64(manager), holder, 1]) { a64_get_x($0, 0) }
    }

    /// FM27 inserted eight new stats at 60, so everything from there up moved.
    private static func statID(_ id: Int) -> UInt64 { UInt64(id >= 60 ? id + 8 : id) }

    private struct BadStat: Error, CustomStringConvertible {
        let id: Int, value: Double
        var description: String { "stat \(id) came back as \(value)" }
    }

    /// A stat as a whole number. Nil for an answer that isn't one, which `Int(_:)` would crash on.
    static func wholeStat(_ value: Double) -> Int? { Int(exactly: value.rounded(.towardZero)) }

    private func stat(_ container: UInt64, _ id: Int, scope: Int) throws -> Double {
        let value: Double = try sandbox.call(statFunction, [container, RulesEngine.statID(id), UInt64(scope), 0], prepare: { cpu in
            a64_set_v_low(cpu, 0, Mac27.statFallback.bitPattern)
        }, result: { Double(bitPattern: a64_get_v_low($0, 0)) })
        guard RulesEngine.wholeStat(value) != nil else { throw BadStat(id: id, value: value) }
        return value
    }

    public func seasonStats(player: Player, season scope: Int) -> SeasonStats? {
        do {
            let container = try statsContainer(player)
            guard container != 0 else { return nil }
            func count(_ id: Int) throws -> Int { Int(try stat(container, id, scope: scope)) }
            var s = SeasonStats()
            s.apps = try count(76)
            guard s.apps > 0 else { return s }
            s.starts = try count(60)
            s.subs = try count(61)
            s.minutes = try count(74)
            s.goals = try count(62)
            s.assists = try count(66)
            s.rating = try stat(container, 78, scope: scope)
            s.playerOfTheMatch = try count(69)
            s.yellow = try count(67)
            s.red = try count(68)
            s.cleanSheets = try count(72)
            s.conceded = try count(63)
            s.xG = try stat(container, 110, scope: scope) * Double(s.minutes) / 90
            s.xA = try stat(container, 111, scope: scope) * Double(s.minutes) / 90
            s.passPercent = try count(114)
            s.shotsOnTargetPercent = try count(113)
            s.tacklePercent = try count(115)
            s.tackles = try count(7)
            s.dribbles = try count(10)
            s.fouls = try count(11)
            s.fouled = try count(12)
            return s
        } catch {
            failureLock.lock()
            failure = "\(error)"
            failureLock.unlock()
            return nil
        }
    }

    /// One of the game's staff tables: a row of totals, plus one row per team at the club.
    private func staffTable(slot: Int, mode: UInt64, club: Int64) throws -> (totals: [UInt8], teams: [[UInt8]]) {
        let object = game.readPointer(game.pluginBase + Mac27.staffNumbersGlobal)
        let function = game.readPointer(game.readPointer(object) + Int64(slot * 8))
        let out = UInt64(A64_SCRATCH) + 0x800
        return try sandbox.call(function, [UInt64(object), out, UInt64(club), mode]) { cpu in
            var head = [UInt8](repeating: 0, count: 24)
            a64_read_bytes(cpu, out, &head, 24)
            let list = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self) }
            var rows: [[UInt8]] = []
            if list != 0 {
                let base = a64_read(cpu, list, 8), count = a64_read(cpu, list &+ 8, 4)
                for index in 0..<min(count, 32) {
                    var row = [UInt8](repeating: 0, count: 9)
                    a64_read_bytes(cpu, base &+ 16 &* index &+ 4, &row, 9)
                    rows.append(row)
                }
            }
            return (Array(head.prefix(11)), rows)
        }
    }

    /// Board limits and who is in post, as raw tables. `team` is any team at the club.
    public func staffNumbers(team: Int64) -> (allowed: [UInt8], current: [UInt8], teams: [(object: Int64, type: Int)],
                                              teamAllowed: [[UInt8]], teamCurrent: [[UInt8]], modeA: Int, modeB: Int)? {
        let club = game.readPointer(team + Int64(MacLayout.Team.club))
        guard club != 0, game.readPointer(game.pluginBase + Mac27.staffNumbersGlobal) != 0,
              let allowed = try? staffTable(slot: Mac27.staffAllowedSlot, mode: 0, club: club),
              let current = try? staffTable(slot: Mac27.staffCurrentSlot, mode: 3, club: club),
              let flags = game.read(game.pluginBase + Mac27.staffModeFlags, count: 2) else { return nil }
        let end = game.readPointer(club + 32)
        var teams: [(object: Int64, type: Int)] = []
        var slot = game.readPointer(club + 24)
        while slot != 0, slot < end, teams.count < 32 {
            let object = game.readPointer(slot)
            teams.append((object, Int(game.read(object + Int64(MacLayout.Team.type), count: 1)?.first ?? 0)))
            slot += 8
        }
        return (allowed.totals, current.totals, teams, allowed.teams, current.teams, Int(flags[0]), Int(flags[1]))
    }

    /// FM's number for each place in a shape.
    private static let shapePlaces: [String: Int16] = [
        "GK": -15, "DR": -13, "DC (R)": -12, "DC": -11, "DC (L)": -10, "DL": -9, "WBR": -8, "DM (R)": -7, "DM": -6, "DM (L)": -5, "WBL": -4,
        "MR": -3, "MC (R)": -2, "MC": -1, "MC (L)": 0, "ML": 1, "AMR": 2, "AMC (R)": 3, "AMC": 4, "AMC (L)": 5, "AML": 6,
        "ST (R)": 8, "ST": 9, "ST (L)": 10,
    ]

    /// What FM calls a shape, in the language the game is set to. FM works the name out from the eleven places,
    /// which it wants in order, so this also names a shape nobody has saved as a preset.
    public func shapeName(_ places: [(position: Int, side: TacticSlot.Side)]) -> String? {
        let numbers = places.compactMap { Self.shapePlaces[TacticSlot.label(position: $0.position, side: $0.side)] }
        guard numbers.count == 11 else { return nil }
        let shape = UInt64(A64_SCRATCH), name = shape + 0x100
        return try? sandbox.call(game.pluginBase + Mac27.shapeName, [shape], prepare: { cpu in
            for (index, number) in numbers.sorted().enumerated() {
                a64_write(cpu, shape + UInt64(index * 2), UInt64(UInt16(bitPattern: number) & 0x3f), 2)
            }
            a64_set_x(cpu, 8, name)
        }) { cpu -> String? in
            let text = a64_read(cpu, name, 8), length = a64_read(cpu, text, 4)
            guard text != 0, length > 0, length < 64 else { return nil }
            var bytes = [UInt8](repeating: 0, count: Int(length))
            a64_read_bytes(cpu, text + 4, &bytes, bytes.count)
            return String(decoding: bytes, as: UTF8.self)
        } ?? nil
    }

    /// The last five ratings, oldest first. Plain data, so this needs no emulation.
    public func form(player: Player) -> String? {
        typealias H = MacLayout.History
        let history = game.readPointer(player.block + Int64(MacLayout.Player.injuries))
        guard history != 0 else { return "" }
        let list = game.readPointer(history + Int64(H.matches))
        guard list != 0 else { return "" }
        let begin = game.readPointer(list), end = game.readPointer(list + 8)
        guard begin != 0, end >= begin else { return "" }
        var matches: [(year: Int, day: Int, rating: Int)] = []
        for slot in stride(from: begin, to: min(end, begin + 0x200), by: 8) {
            let games = game.readPointer(slot)
            guard games != 0, let count = game.read(games + 16, count: 1)?.first else { continue }
            for i in 0..<min(Int(count), 20) {
                let entry = game.readPointer(games + 24 + Int64(8 * i))
                guard entry != 0, let b = game.read(entry, count: 24) else { continue }
                let result = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Int64.self) }
                guard result != 0, let rating = game.read(result + 21, count: 2), rating[0] != 0, rating[1] != 0 else { continue }
                matches.append((Int(b[18]) | Int(b[19]) << 8, (Int(b[16]) | Int(b[17]) << 8) & 0x1ff, Int(rating[1])))
            }
        }
        return matches.sorted { ($0.year, $0.day) < ($1.year, $1.day) }.suffix(5)
            .map { String(format: "%.1f", Double($0.rating) / 10) }.joined(separator: " ")
    }

    /// Days until the player is back, by FM's own reckoning. FM writes this into a "bag" of values for its
    /// injury text, so the two bag functions are watched rather than run, and the one value picked out.
    public func injuryReturnDays(player: Player) -> Int? {
        guard let injury = player.injury else { return nil }
        final class Found { var days: Int? }
        let found = Found()
        let bag = UInt64(A64_SCRATCH) + 0x400
        let context = Unmanaged.passUnretained(found).toOpaque()
        do {
            try sandbox.call(game.pluginBase + Mac27.injuryInfo, [UInt64(injury.record), UInt64(player.block), 0, bag],
                             maxSteps: 5_000_000, prepare: { cpu in
                a64_set_watch(cpu, 0, UInt64(self.game.pluginBase + Mac27.bagSet))
                a64_set_watch(cpu, 1, UInt64(self.game.pluginBase + Mac27.bagClear))
                a64_set_watch_handler(cpu, { context, cpu, key, value in
                    if key & 0xffff_ffff == Mac27.injuryDaysKey {
                        Unmanaged<Found>.fromOpaque(context!).takeUnretainedValue().days = Int(Int32(truncatingIfNeeded: a64_read(cpu!, value + 8, 4)))
                    }
                }, context)
            }) { _ in () }
        } catch {
            failureLock.lock()
            failure = "\(error)"
            failureLock.unlock()
            return nil
        }
        return found.days
    }
}

/// FM's interest answers for one engine, by player record and team. RulesState and GameChecks each keep their own
/// answers, so without this a player that both ask about costs FM's rule twice. A failure isn't kept, so the next
/// ask tries again.
final class InterestAnswers {
    typealias Answer = (transfer: JoinInterest, loan: JoinInterest)
    private struct Key: Hashable {
        let player: Int64
        let team: Int64
    }

    private let lock = NSLock()
    private var answers: [Key: Answer] = [:]

    /// Asks outside the lock, so the threads checking a list don't wait on each other's rule calls.
    func answer(player: Int64, team: Int64, ask: () -> Answer?) -> Answer? {
        let key = Key(player: player, team: team)
        if let known = lock.withLock({ answers[key] }) { return known }
        guard let answer = ask() else { return nil }
        lock.withLock { answers[key] = answer }
        return answer
    }
}
