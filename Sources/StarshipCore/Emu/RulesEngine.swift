import CA64
import Foundation

/// FM's own rules, run in the sandbox. Each feature is found by class name where possible, so a
/// patch that moves code keeps working; anything not found leaves that feature switched off.
public final class RulesEngine: GameRulesEngine {
    /// Only valid for one build of game_plugin: the engine refuses to start on any other. fmprobe takes its
    /// addresses from here too, so a patch only changes them here.
    package enum Mac27 {
        package static let fingerprint = "2deadc731af61095"
        package static let interestManagerGlobal: Int64 = 0x57b2ea8
        package static let statusFunction: Int64 = 0xd64e80
        package static let interestSlot = 30
        package static let staffRuleSlot = 20
        /// `GAME_PERSON`, whose slot `jobPickSlot` the staff rule asks which job, and at which team, it weighs up a person for.
        package static let personGlobal: Int64 = 0x57b2e68
        package static let jobPickSlot = 0x150 / 8
        /// The club's team at a staff-rule level (3 reserves, 4 youth), as the rule finds it.
        package static let teamAtLevel: Int64 = 0x12402f4
        package static let statFunction: Int64 = 0xf973c8
        package static let statsContainerSlot = 65
        package static let personStatsSlot = 0x668 / 8
        package static let statFallback = 0.0
        package static let roleInPossession: Int64 = 0x150a680
        package static let roleOutOfPossession: Int64 = 0x151e4ac
        package static let roleBand: Int64 = 0x150ae78
        package static let roleListInPossession: Int64 = 0x4a5acc0
        package static let roleListOutOfPossession: Int64 = 0x4a5cb98
        package static let preferredJob: Int64 = 0x4a436f8
        package static let staffNumbersGlobal: Int64 = 0x57b2d20
        package static let staffAllowedSlot = 8
        package static let staffCurrentSlot = 7
        package static let staffModeFlags: Int64 = 0x57b4b18
        package static let injuryInfo: Int64 = 0x156c068
        package static let bagSet: Int64 = 0x4447b98
        package static let bagClear: Int64 = 0x4447e28
        package static let injuryDaysKey: UInt64 = 0x5050_4d69  // "PPMi" in the bag FM fills for its injury text
        package static let shapeName: Int64 = 0x4ab2570
        package static let conditionSlot = 0x450 / 8
        package static let sharpnessSlot = 0x458 / 8
        package static let trainedAtClub: Int64 = 0xd1e590
        package static let trainedInNation: Int64 = 0xd1c1c4
        package static let disciplineGlobal: Int64 = 0x57b5998
        package static let countUntilNextBan: Int64 = 0x3d07978
        package static let squadRuleValue: Int64 = 0x150efa0
        /// FM's table of squad-rule types: {name, value} pairs, ending at the value 65535.
        package static let squadRuleNames: Int64 = 0x5753938
        /// FM's three names for a squad rule's direction, as {name, value} pairs.
        package static let squadRuleDirections: Int64 = 0x5755e38
    }

    public static let transfer: UInt64 = 4
    public static let loan: UInt64 = 3
    /// The stats scope that totals a player's season for his club.
    public static let clubTotal = 5
    /// The scopes that keep the club total's league, cup and continental matches apart, at the club he plays for now (his
    /// loan club while he's on loan). Checked in FM 27.1.0 on 20 Nov 2026 against the matches FM keeps for each of Molde's
    /// players: the Norwegian cup's and the Champions League's matched them, and the three add up to the club total. Other
    /// cups and continental competitions are expected in the same scopes but weren't checked.
    public static let league = 1, cup = 2, continental = 3
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
    /// The address of `GAME_PERSON`'s job-pick slot in its vtable. 0 when not found.
    private let jobPickEntry: Int64
    private let statFunction: Int64
    private let statsContainerFunction: Int64
    private let conditionFunction: Int64
    private let sharpnessFunction: Int64
    /// `GAME_DISCIPLINE`'s vtable, which the object at the end of `Mac27.disciplineGlobal`'s path must have. 0 when not found.
    private let disciplineVtable: Int64
    /// Team to HUMAN_NON_PLAYER object, for the staff rule.
    public var managers: [Int64: Int64] = [:]
    /// Team to the staff member whose eye the role stars are seen through.
    public var viewers: [Int64: Int64] = [:]
    /// The human clubs that are women's sides, from `Database.womensTeams`.
    public var womensTeams: Set<Int64> = []
    private let interestAnswers = InterestAnswers()
    private let teamNames = TeamNames()
    private let roleLock = NSLock()
    private let tablesLock = NSLock()
    private var tables: (types: [Int: [String]]?, directions: [Int: String]?)?
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
        let person = game.readPointer(game.pluginBase + Mac27.personGlobal)
        jobPickEntry = rtti.vtables("GAME_PERSON").first { $0.offsetToTop == 0 }
            .map { game.pluginBase + Int64($0.addressPoint) }
            .flatMap { person != 0 && game.readPointer(person) == $0 ? $0 + Int64(Mac27.jobPickSlot * 8) : nil } ?? 0
        let player = rtti.vtables("ACTUAL_PLAYER").first { $0.offsetToTop == 0 }
        func getter(_ slot: Int) -> Int64 {
            let function = player.map { rtti.word($0.addressPoint + slot * 8) } ?? 0
            return function > game.pluginBase && function < game.pluginBase + game.pluginSize ? function : 0
        }
        conditionFunction = getter(Mac27.conditionSlot)
        sharpnessFunction = getter(Mac27.sharpnessSlot)
        disciplineVtable = rtti.vtables("GAME_DISCIPLINE").first { $0.offsetToTop == 0 }.map { game.pluginBase + Int64($0.addressPoint) } ?? 0
    }

    private func status(_ player: Player, team: Int64) throws -> UInt64 {
        try sandbox.call(statusFunction, [UInt64(bitPattern: player.block), UInt64(bitPattern: team), 0, 0, 0, 0, 1, 0], stack: [0]) { a64_get_x($0, 0) & 255 }
    }

    private func score(_ player: Player, club: Int64, type: UInt64, status: UInt64) throws -> Int32 {
        try sandbox.call(interestFunction, [UInt64(bitPattern: manager), UInt64(bitPattern: player.block), UInt64(bitPattern: club), type, status, 0, 0, 0]) {
            Int32(truncatingIfNeeded: a64_get_x($0, 0))
        }
    }

    public func interest(player: Player, team: Int64) -> (transfer: JoinInterest, loan: JoinInterest)? {
        // FM's rule only weighs up the move, so without this it says a woman would join a men's club.
        guard player.isWoman == womensTeams.contains(team) else { return (.notInterested, .notInterested) }
        return interestAnswers.answer(player: player.block, team: team) { askInterest(player: player, team: team) }
    }

    private func askInterest(player: Player, team: Int64) -> (transfer: JoinInterest, loan: JoinInterest)? {
        let club = game.readPointer(team &+ Int64(MacLayout.Team.club))
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
                a64_write(cpu, person + 8, UInt64(bitPattern: staff.block &+ Int64(MacLayout.Staff.identity)), 8)
                a64_write(cpu, context + 8, UInt64(bitPattern: manager), 8)
                a64_write(cpu, context + 16, UInt64(bitPattern: team), 8)
                a64_write(cpu, context + 24, UInt64(bitPattern: manager &+ Int64(MacLayout.Human.managerIdentity)), 8)
            }, result: { a64_get_x($0, 0) & 255 != 0 })
        } catch {
            failureLock.lock()
            failure = "\(error)"
            failureLock.unlock()
            return nil
        }
    }

    /// What stands in for `GAME_PERSON`'s job pick, called as FM calls it with the answer's address in x3: it writes `job` as
    /// the answer's job byte and `team` as its team, returns 1, and sets the word at `jobPickAsked`. In order: x10 = team,
    /// w9 = job, out.job = w9, out.team = x10, w0 = 1, x11 = &asked, asked = w0, return; then the team, the job and asked.
    package static let jobPickCode: [UInt32] = [0x5800_010a, 0x1800_0129, 0x3900_0069, 0xf900_046a, 0x5280_0020, 0x1000_00cb,
                                                0xb900_0160, 0xd65f_03c0]
    package static let jobPickAsked: UInt64 = 44

    package static func writeJobPick(_ cpu: OpaquePointer, at address: UInt64, job: Int, team: Int64) {
        for (i, word) in jobPickCode.enumerated() { a64_write(cpu, address + UInt64(i * 4), UInt64(word), 4) }
        a64_write(cpu, address + 32, UInt64(bitPattern: team), 8)
        a64_write(cpu, address + 40, UInt64(job), 4)
        a64_write(cpu, address + jobPickAsked, 0, 4)
    }

    public var supportsStaffJobInterest: Bool { staffFunction != 0 && jobPickEntry != 0 }

    /// The staff rule asked about one job. The rule asks `GAME_PERSON` which job, and at which team, to weigh a person up for,
    /// then runs FM's own checks and its own score for that job against its own bar. Here that one call, in the sandbox's
    /// private copy of FM's memory, answers `job` at the club's team at `level` instead, so every check and the score are
    /// still FM's. It only counts as an answer when the rule got as far as asking: FM's yes without asking says nothing about
    /// the job.
    public func staffJobInterest(staff: Staff, team: Int64, job: Int, level: Int) -> Bool? {
        guard staffFunction != 0, jobPickEntry != 0, let manager = managers[team], manager != 0, (2...254).contains(job) else { return nil }
        // The team the job is at, as FM's own pick gives it: the rule looks for a manager there before offering a manager's job.
        let club = game.readPointer(team &+ Int64(MacLayout.Team.club))
        var at = team
        if level != RulesEngine.staffLevels[0] {
            guard club != 0, let found: Int64 = try? sandbox.call(game.pluginBase + Mac27.teamAtLevel, [UInt64(bitPattern: club), UInt64(level)],
                                                                   result: { Int64(bitPattern: a64_get_x($0, 0)) }) else { return nil }
            // No such team at the club: the rule says no without asking.
            if found == 0 { return false }
            at = found
        }
        let rule = UInt64(A64_SCRATCH), person = rule + 0x100, context = rule + 0x200, pick = rule + 0x300
        do {
            let (answer, asked) = try sandbox.call(staffFunction, [rule, person, context], prepare: { cpu in
                a64_write(cpu, rule + 24, UInt64(level), 1)
                a64_write(cpu, rule + 25, 1, 1)
                a64_write(cpu, person + 8, UInt64(bitPattern: staff.block &+ Int64(MacLayout.Staff.identity)), 8)
                a64_write(cpu, context + 8, UInt64(bitPattern: manager), 8)
                a64_write(cpu, context + 16, UInt64(bitPattern: team), 8)
                a64_write(cpu, context + 24, UInt64(bitPattern: manager &+ Int64(MacLayout.Human.managerIdentity)), 8)
                RulesEngine.writeJobPick(cpu, at: pick, job: job, team: at)
                a64_write(cpu, UInt64(bitPattern: self.jobPickEntry), pick, 8)
            }, result: { cpu in (a64_get_x(cpu, 0) & 255 != 0, a64_read(cpu, pick + RulesEngine.jobPickAsked, 4) != 0) })
            return answer && !asked ? nil : answer
        } catch {
            failureLock.lock()
            failure = "\(error)"
            failureLock.unlock()
            return nil
        }
    }

    public var supportsInjuryDays: Bool { true }

    public func preferredJob(staff: Staff) -> Int? {
        let block = game.readPointer(staff.block &+ Int64(MacLayout.Staff.jobPreferences))
        guard block != 0 else { return nil }
        return try? sandbox.call(game.pluginBase + Mac27.preferredJob, [UInt64(bitPattern: block), UInt64(bitPattern: staff.block)]) { Int(a64_get_x($0, 0) & 255) }
    }
    public func jobPreferences(staff: Staff) -> [UInt8]? {
        let block = game.readPointer(staff.block &+ Int64(MacLayout.Staff.jobPreferences))
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
                                    [UInt64(bitPattern: player.block), positions, roles, 2, UInt64(bitPattern: viewer), 0, 1, 0]) { Int32(truncatingIfNeeded: a64_get_x($0, 0)) }
        }
        return try sandbox.call(game.pluginBase + Mac27.roleInPossession,
                                [UInt64(bitPattern: player.block), positions, roles, 0, 0, 2, UInt64(bitPattern: viewer), 0], stack: [1, 0]) { Int32(truncatingIfNeeded: a64_get_x($0, 0)) }
    }

    /// Half-stars as (lowest, highest): a scout's view of a player is a band, not a point.
    private func band(_ player: Player, rating: Int32, team: Int64) throws -> (Int, Int) {
        let out = UInt64(A64_SCRATCH) + 0xc14
        return try sandbox.call(game.pluginBase + Mac27.roleBand, [UInt64(bitPattern: player.block), UInt64(UInt32(bitPattern: rating)), UInt64(bitPattern: team), out, 0]) { cpu in
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
        // A leftover copy of a player can hold anything here, so values read are only added to with &+, and the method has
        // to be FM's own code before it's run: a garbage one trapped converting it on the Molde save (Oct 2029).
        let identity = player.block &+ game.readPointer(vtable &- 0x18)
        let method = game.readPointer(game.readPointer(identity) &+ Int64(Mac27.personStatsSlot * 8))
        guard method > game.pluginBase, method < game.pluginBase &+ game.pluginSize, method & 3 == 0 else { return 0 }
        let holder: UInt64 = try sandbox.call(method, [UInt64(bitPattern: identity)]) { a64_get_x($0, 0) }
        guard holder != 0 else { return 0 }
        return try sandbox.call(statsContainerFunction, [UInt64(bitPattern: manager), holder, 1]) { a64_get_x($0, 0) }
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
        let function = game.readPointer(game.readPointer(object) &+ Int64(slot * 8))
        let out = UInt64(A64_SCRATCH) + 0x800
        return try sandbox.call(function, [UInt64(bitPattern: object), out, UInt64(bitPattern: club), mode]) { cpu in
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
        let club = game.readPointer(team &+ Int64(MacLayout.Team.club))
        guard club != 0, game.readPointer(game.pluginBase + Mac27.staffNumbersGlobal) != 0,
              let allowed = try? staffTable(slot: Mac27.staffAllowedSlot, mode: 0, club: club),
              let current = try? staffTable(slot: Mac27.staffCurrentSlot, mode: 3, club: club),
              let flags = game.read(game.pluginBase + Mac27.staffModeFlags, count: 2) else { return nil }
        let end = game.readPointer(club &+ 32)
        var teams: [(object: Int64, type: Int)] = []
        var slot = game.readPointer(club &+ 24)
        while slot != 0, slot < end, teams.count < 32 {
            let object = game.readPointer(slot)
            teams.append((object, Int(game.read(object &+ Int64(MacLayout.Team.type), count: 1)?.first ?? 0)))
            slot &+= 8
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
            a64_read_bytes(cpu, text &+ 4, &bytes, bytes.count)
            return String(decoding: bytes, as: UTF8.self)
        } ?? nil
    }

    /// The last five ratings, oldest first. Plain data, so this needs no emulation.
    public func form(player: Player) -> String? {
        typealias H = MacLayout.History
        let history = game.readPointer(player.block &+ Int64(MacLayout.Player.injuries))
        guard history != 0 else { return "" }
        let list = game.readPointer(history &+ Int64(H.matches))
        guard list != 0 else { return "" }
        let begin = game.readPointer(list), end = game.readPointer(list &+ 8)
        guard begin != 0, end >= begin else { return "" }
        var matches: [(year: Int, day: Int, rating: Int)] = []
        for slot in stride(from: begin, to: min(end, begin &+ 0x200), by: 8) {
            let games = game.readPointer(slot)
            guard games != 0, let count = game.read(games &+ 16, count: 1)?.first else { continue }
            for i in 0..<min(Int(count), 20) {
                let entry = game.readPointer(games &+ 24 &+ Int64(8 * i))
                guard entry != 0, let b = game.read(entry, count: 24) else { continue }
                let result = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Int64.self) }
                guard result != 0, let rating = game.read(result &+ 21, count: 2), rating[0] != 0, rating[1] != 0 else { continue }
                matches.append((Int(b[18]) | Int(b[19]) << 8, (Int(b[16]) | Int(b[17]) << 8) & 0x1ff, Int(rating[1])))
            }
        }
        return matches.sorted { ($0.year, $0.day) < ($1.year, $1.day) }.suffix(5)
            .map { String(format: "%.1f", Double($0.rating) / 10) }.joined(separator: " ")
    }

    /// The player's recent matches, each with his minutes, rating, goals, assists, cards and xG. Plain data from the
    /// same record as `form`, so it's on where form is.
    public func matchHistory(player: Player) -> MatchHistory? {
        // The engine is only made on the checked build, so FM's type of competition can be read too.
        FixturesReader.history(player: player.block, in: game, types: true) { self.teamNames.name($0, in: self.game) }
    }

    /// Condition and sharpness through FM's own getters, which first make the call FM makes to bring a player up to date.
    /// On 27.1.0 they gave the stored values unchanged for 4,000 players FM last updated 1 to 15+ days before, so for those
    /// it's FM's last update. Anything the call changes only happens in the sandbox's copy.
    public func fitness(player: Player) -> Fitness? {
        guard conditionFunction != 0, sharpnessFunction != 0 else { return nil }
        do {
            func ask(_ function: Int64) throws -> Int {
                try sandbox.call(function, [UInt64(bitPattern: player.block), 1]) { Int(Int16(truncatingIfNeeded: a64_get_x($0, 0))) }
            }
            let fitness = Fitness(condition: try ask(conditionFunction), sharpness: try ask(sharpnessFunction))
            guard Fitness.range.contains(fitness.condition), Fitness.range.contains(fitness.sharpness) else { return nil }
            return fitness
        } catch {
            failureLock.lock()
            failure = "\(error)"
            failureLock.unlock()
            return nil
        }
    }

    /// FM's own two tests, as its home-grown rule runs them: trained at the club, else trained in the club's nation.
    public func homeGrown(player: Player) -> HomeGrown? {
        let club = player.clubObject
        guard club != 0 else { return nil }
        let nation = game.readPointer(club &+ Int64(MacLayout.Club.nation))
        let out = UInt64(A64_SCRATCH)
        do {
            func ask(_ function: Int64, _ place: Int64) throws -> Bool {
                try sandbox.call(game.pluginBase + function, [UInt64(bitPattern: player.block), UInt64(bitPattern: place), out]) { a64_get_x($0, 0) & 0xff != 0 }
            }
            if try ask(Mac27.trainedAtClub, club) { return .club }
            guard nation != 0 else { return nil }
            return try ask(Mac27.trainedInNation, nation) ? .nation : .no
        } catch {
            failureLock.lock()
            failure = "\(error)"
            failureLock.unlock()
            return nil
        }
    }

    /// FM's one `GAME_DISCIPLINE`, by the path FM's own code takes to it, and only when it has that class's vtable.
    public var discipline: Int64? {
        typealias D = MacLayout.Discipline
        guard disciplineVtable != 0 else { return nil }
        let holder = game.readPointer(game.readPointer(game.pluginBase &+ Mac27.disciplineGlobal) &+ D.holder)
        let object = holder > 0 ? game.readPointer(holder &+ D.object) : 0
        guard object > 0, game.readPointer(object) == disciplineVtable else { return nil }
        return object
    }

    /// `DISCIPLINE::get_count_until_next_ban`, which FM's own "one booking from a ban" check calls. It's handed a copy of
    /// the player's count as FM's memory holds it now, since the sandbox keeps the pages it has copied and FM may have
    /// played a match since. Nil, with the failure kept, when the call doesn't finish.
    public func nextBan(rules: Int, bookingCount: [UInt8]?) -> NextBan? {
        guard let discipline, (0...Int(UInt16.max)).contains(rules) else { return nil }
        if let bookingCount, bookingCount.count != MacLayout.BookingCount.size { return nil }
        let count = UInt64(A64_SCRATCH), out = count + 0x40
        do {
            return try sandbox.call(game.pluginBase + Mac27.countUntilNextBan,
                                    [UInt64(bitPattern: discipline), bookingCount == nil ? 0 : count, UInt64(rules), out, out + 8, 0, out + 16, out + 24],
                                    stack: [UInt64.max, 0, 0, 0], prepare: { cpu in
                if let bookingCount { a64_write_bytes(cpu, count, bookingCount, bookingCount.count) }
                for slot in 0..<4 { a64_write(cpu, out + UInt64(slot * 8), 0, 8) }
            }) { cpu in
                NextBan(left: Int(a64_read(cpu, out, 2)), length: Int(a64_read(cpu, out + 8, 1)),
                        count: Int(a64_read(cpu, out + 16, 2)), lastBanAt: Int(a64_read(cpu, out + 24, 2)))
            }
        } catch {
            failureLock.lock()
            failure = "\(error)"
            failureLock.unlock()
            return nil
        }
    }

    /// FM's names for its squad-rule types, read once from its table, which must end where FM's does, at 65535, and name
    /// `max_squad_size` 9, as on the build it was checked on.
    public var squadRuleTypes: [Int: [String]]? { squadRuleTables().types }

    public var squadRuleDirections: [Int: String]? { squadRuleTables().directions }

    private func squadRuleTables() -> (types: [Int: [String]]?, directions: [Int: String]?) {
        tablesLock.lock()
        defer { tablesLock.unlock() }
        if let tables { return tables }
        var types: [Int: [String]]?
        if let entries = Self.nameTable(game, at: game.pluginBase &+ Mac27.squadRuleNames, most: 2_048, endValue: 65_535) {
            var found: [Int: [String]] = [:]
            for entry in entries where !entry.name.isEmpty { found[Int(entry.value), default: []].append(entry.name) }
            if found[9]?.contains("max_squad_size") == true { types = found }
        }
        var directions: [Int: String]?
        if let entries = Self.nameTable(game, at: game.pluginBase &+ Mac27.squadRuleDirections, most: 3, endValue: nil) {
            directions = Dictionary(entries.map { (Int(Int8(truncatingIfNeeded: $0.value)), $0.name) }, uniquingKeysWith: { first, _ in first })
        }
        tables = (types, directions)
        return (types, directions)
    }

    /// One of FM's tables of {C string, i64} pairs: `most` of them, or up to and without the one whose value is `endValue`,
    /// which must come within `most`. Nil where a pair can't be read.
    static func nameTable(_ game: GameProcess, at address: Int64, most: Int, endValue: Int64?) -> [(name: String, value: Int64)]? {
        guard most > 0, let bytes = game.read(address, count: most * 16) else { return nil }
        var entries: [(name: String, value: Int64)] = []
        for index in 0..<most {
            let name = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 16, as: Int64.self) }
            let value = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 16 + 8, as: Int64.self) }
            if let endValue, value == endValue { return entries }
            guard name > 0, let text = game.read(name, count: 96) ?? game.read(name, count: 24) else { return nil }
            entries.append((String(decoding: text.prefix { $0 != 0 }, as: UTF8.self), value))
        }
        return endValue == nil ? entries : nil
    }

    /// `PLAYER::get_squad_selection_rule_value`, asked as FM's own eligibility check asks it: the player, the type, the
    /// team, -1 twice, the group and the competition. It ran for 46 players and 15 types on 27.1.0 without a fault, and its
    /// home-grown answers matched `homeGrown` for all of them.
    public func squadRuleValue(player: Player, type: Int, team: Int64, group: Int, competition: Int64) -> Int? {
        guard player.block > 0, team > 0, competition > 0, (0...Int(UInt16.max)).contains(type), (-128...127).contains(group) else { return nil }
        do {
            return try sandbox.call(game.pluginBase &+ Mac27.squadRuleValue,
                                    [UInt64(bitPattern: player.block), UInt64(type), UInt64(bitPattern: team), UInt64.max, UInt64.max,
                                     UInt64(bitPattern: Int64(group)), UInt64(bitPattern: competition), 0],
                                    stack: [0, 0, 0, 0, 0, 0, 0, 0]) { Int(Int32(truncatingIfNeeded: a64_get_x($0, 0))) }
        } catch {
            failureLock.lock()
            failure = "\(error)"
            failureLock.unlock()
            return nil
        }
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
            try sandbox.call(game.pluginBase + Mac27.injuryInfo, [UInt64(bitPattern: injury.record), UInt64(bitPattern: player.block), 0, bag],
                             maxSteps: 5_000_000, prepare: { cpu in
                a64_set_watch(cpu, 0, UInt64(self.game.pluginBase + Mac27.bagSet))
                a64_set_watch(cpu, 1, UInt64(self.game.pluginBase + Mac27.bagClear))
                a64_set_watch_handler(cpu, { context, cpu, key, value in
                    if key & 0xffff_ffff == Mac27.injuryDaysKey {
                        Unmanaged<Found>.fromOpaque(context!).takeUnretainedValue().days = Int(Int32(truncatingIfNeeded: a64_read(cpu!, value &+ 8, 4)))
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

/// Team names, read once each: a squad's histories name the same few opponents many times.
final class TeamNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [Int64: String] = [:]

    func name(_ team: Int64, in game: GameProcess) -> String {
        if let known = lock.withLock({ names[team] }) { return known }
        let name = GameReader.clubName(team: team, in: game)
        lock.withLock { names[team] = name }
        return name
    }
}
