import Foundation
import StarshipAnalysis
import StarshipCore
import StarshipFiles
@testable import StarshipMCP
import StarshipSearch
import XCTest

/// FM's rules as a test wants them: everyone answers, and nothing runs FM's code.
final class FakeEngine: GameRulesEngine, PositionalRoleEngine, StaffLimitsEngine {
    /// False to stand in for FM giving no role table, as when one of its rules fails.
    var roleRatings = true
    /// When set, only these players get a role table, as when FM's rules fail for some players and not others.
    var ratedPlayers: Set<UInt32>?

    /// Three stars in every role, in and out of possession, wherever they play.
    func roleRows(player: Player, position: Int, team: Int64) -> [RoleRow]? {
        guard roleRatings, ratedPlayers?.contains(player.uid) ?? true else { return nil }
        return (0..<64).flatMap { role in
            [RoleRow(role: Names.rolesIp[role] ?? "Role \(role)", outOfPossession: false, minHalfStars: 6, maxHalfStars: 6, rating: 50),
             RoleRow(role: Names.rolesOop[role] ?? "Role \(role)", outOfPossession: true, minHalfStars: 6, maxHalfStars: 6, rating: 50)]
        }
    }

    var supportsInjuryDays: Bool { true }
    /// How many times FM was asked whether a player would join. The finders ask from several threads at once.
    private var calls = 0
    private let lock = NSLock()
    var interestCalls: Int { lock.withLock { calls } }
    func interest(player: Player, team: Int64) -> (transfer: JoinInterest, loan: JoinInterest)? {
        lock.withLock { calls += 1 }
        return (.interested, .doubtful)
    }
    /// Staff FM says wouldn't join at any level, staff FM gives no answer for, and false for FM not answering about staff at all.
    var staffWontJoin: Set<UInt32> = []
    var staffUnanswered: Set<UInt32> = []
    var staffAnswers = true
    /// The staff FM was asked about.
    private var askedStaff: Set<UInt32> = []
    var staffAsked: Set<UInt32> { lock.withLock { askedStaff } }
    func staffInterest(staff: Staff, team: Int64, level: Int) -> Bool? {
        lock.withLock { _ = askedStaff.insert(staff.uid) }
        return staffAnswers && !staffUnanswered.contains(staff.uid) ? staffJoinLevels.contains(level) && !staffWontJoin.contains(staff.uid) : nil
    }
    /// FM's staff-rule levels at which people would join: the first team only, unless a test says otherwise.
    var staffJoinLevels: Set<Int> = [1]
    /// The team FM's staff rule asks about at each of its levels, and the board's limits, whose teams name the levels. Neither
    /// is known unless a test sets them, as when FM can't tell.
    var levelTeams: [Int: TeamAtLevel] = [:]
    var limits: StaffLimits?
    /// FM's levels whose team can't be told, as when the call fails, and how many times FM was asked for a level's team.
    var failingLevelTeams: Set<Int> = []
    private var levelTeamAsks = 0
    var levelTeamCalls: Int { lock.withLock { levelTeamAsks } }
    func staffLevelTeam(team: Int64, level: Int) -> TeamAtLevel? {
        lock.withLock { levelTeamAsks += 1 }
        return failingLevelTeams.contains(level) ? nil : levelTeams[level]
    }
    func staffLimits(team: Int64) -> StaffLimits? { limits }

    /// Molde's teams as FM has them: a first team (the world's own), a second team that plays in a senior league, and a U19.
    /// FM's staff rule asks about the U19 at its reserves level and its youth level alike.
    static let secondTeam: Int64 = 20, under19: Int64 = 21
    func likeMolde() {
        let teams = [StaffLimits.Team(object: World.team, type: 0), StaffLimits.Team(object: FakeEngine.secondTeam, type: 16),
                     StaffLimits.Team(object: FakeEngine.under19, type: 11)]
        let row = [UInt8](repeating: 2, count: 9)
        limits = StaffLimits(allowed: [UInt8](repeating: 1, count: 11), current: [UInt8](repeating: 0, count: 11), teams: teams,
                             teamAllowed: [row, row, row], teamCurrent: [row, row, row], modeA: 0, modeB: 1)
        levelTeams = [1: TeamAtLevel(object: World.team, type: 0), 3: TeamAtLevel(object: FakeEngine.under19, type: 11),
                      4: TeamAtLevel(object: FakeEngine.under19, type: 11)]
    }
    /// False for a build where FM can't be asked about one job; staff FM says wouldn't take the job they're asked about,
    /// staff FM gives no answer about a job for, and true for FM answering without weighing the job up, as it does for a
    /// whole club in some game modes.
    var staffJobAnswers = true
    var staffWontTake: Set<UInt32> = []
    var staffJobUnanswered: Set<UInt32> = []
    var staffJobNotAsked = false
    /// Each job question: who, the job and the team it's at.
    private var askedJobs: [(uid: UInt32, job: Int, at: Int64)] = []
    var staffJobsAsked: [(uid: UInt32, job: Int, at: Int64)] { lock.withLock { askedJobs } }
    var supportsStaffJobInterest: Bool { staffJobAnswers }
    func staffJobInterest(staff: Staff, team: Int64, job: Int, at: Int64) -> StaffJobAnswer? {
        lock.withLock { askedJobs.append((staff.uid, job, at)) }
        guard staffJobAnswers, !staffJobUnanswered.contains(staff.uid) else { return nil }
        if staffJobNotAsked { return .notAsked }
        return staffWontTake.contains(staff.uid) ? .refuses : .takes
    }
    func preferredJob(staff: Staff) -> Int? { nil }
    func jobPreferences(staff: Staff) -> [UInt8]? { nil }
    func roleRows(player: Player, team: Int64) -> [RoleRow]? { nil }
    /// Ten appearances this season: seven in the league, two in the cup and one in Europe, where Rivals FC aren't.
    func seasonStats(player: Player, season: Int) -> SeasonStats? {
        if failingScopes.contains(season) { return nil }
        var stats = SeasonStats()
        switch season {
        case RulesEngine.clubTotal:
            (stats.starts, stats.subs, stats.minutes, stats.goals, stats.assists, stats.rating, stats.yellow, stats.red) = (9, 1, 900, 3, 2, 7.05, 2, 1)
        case RulesEngine.league:
            (stats.starts, stats.subs, stats.minutes, stats.goals, stats.assists, stats.rating, stats.yellow, stats.red) = (6, 1, 630, 0, 1, 6.8, 2, 1)
        case RulesEngine.cup:
            (stats.starts, stats.subs, stats.minutes, stats.goals, stats.assists, stats.rating) = (2, 0, 180, 3, 0, 8.4)
        case RulesEngine.continental where player.clubFull == World.club:
            (stats.starts, stats.subs, stats.minutes, stats.assists, stats.rating) = (1, 0, 90, 1, 7)
        default:
            return stats
        }
        stats.apps = stats.starts + stats.subs
        // A league goal in a match FM has played since the read.
        if goalSinceRead, season == RulesEngine.clubTotal || season == RulesEngine.league { stats.goals += 1 }
        return stats
    }
    var goalSinceRead = false
    /// Scopes FM's stats function fails for, as when the sandbox can't run it.
    var failingScopes: Set<Int> = []
    /// More matches in a player's record, ahead of the league ones, newest first.
    var moreMatches: [UInt32: [PlayerMatch]] = [:]
    /// For each player, the teams whose list of his matches is full, from the oldest kept.
    var fullFrom: [UInt32: [Int64: Date]] = [:]
    func form(player: Player) -> String? { "7.1 6.8 7.4" }
    func injuryReturnDays(player: Player) -> Int? { 14 }
    /// FM's getters, caught up to today: the stored values for a player FM brought up to date today, as FM's own give.
    func fitness(player: Player) -> Fitness? {
        if gettersDisagree { return Fitness(condition: 1, sharpness: 2) }
        return player.fitness ?? Fitness(condition: 9_440, sharpness: 8_020)
    }
    /// True for getters in the wrong vtable slots, which give other numbers than FM stored.
    var gettersDisagree = false
    /// First 1 was trained at the club, First 2 in its nation, and nobody else.
    func homeGrown(player: Player) -> HomeGrown? { player.uid == 1 ? .club : player.uid == 2 ? .nation : .no }

    /// The club's first eleven played both league matches, number 9 scoring in each and number 11 coming off after 64
    /// minutes in the second, where 12 sat on the bench. Number 13's last 20 matches start after the first one.
    func matchHistory(player: Player) -> MatchHistory? {
        guard player.clubFull == World.club else { return MatchHistory() }
        let uid = Int(player.uid)
        func match(_ day: Int, opponent: Int64, played: Bool = true) -> PlayerMatch {
            var match = PlayerMatch(date: GameDate.date(year: 2026, dayOfYear: day) ?? Date(), team: World.team, opponent: opponent)
            match.teamName = World.club
            match.opponentName = opponent == World.otherTeam ? World.otherTown : World.rivals
            match.competitionIndex = World.leagueIndex
            match.competitionName = "Mock League"
            guard played else { return match }
            match.played = true
            match.minutes = day == World.secondMatch && uid == 11 ? 64 : 90
            match.rating = Double(60 + uid) / 10
            match.goals = uid == 9 ? 1 : 0
            match.assists = uid == 10 && day == World.firstMatch ? 1 : 0
            match.yellow = uid == 4 ? 1 : 0
            match.xG = uid == 1 ? nil : Double(uid) / 20
            match.xGFaced = uid == 1 ? 0.85 : nil
            // 15 shots, 3 on target and 3 fouls, as `World.matchStats` has them.
            match.shots = max(0, uid - 6)
            match.shotsOnTarget = uid >= 9 ? 1 : 0
            match.fouls = uid % 3 == 0 ? 1 : 0
            return match
        }
        switch uid {
        case 1...11: return MatchHistory(matches: (moreMatches[player.uid] ?? []) + [match(World.secondMatch, opponent: World.otherTeam),
                                                                                        match(World.firstMatch, opponent: World.rivalsTeam)],
                                         fullFrom: fullFrom[player.uid] ?? [:])
        case 12: return MatchHistory(matches: (moreMatches[player.uid] ?? []) + [match(World.secondMatch, opponent: World.otherTeam, played: false)])
        case 13: return MatchHistory(fullFrom: [World.team: GameDate.date(year: 2026, dayOfYear: World.firstMatch + 2) ?? Date()])
        default: return MatchHistory()
        }
    }
}

/// Fixtures, results and tables built by hand, as `MatchSource` gives them. Counts its sweeps.
final class FakeMatches: MatchSource {
    var teams: [Int64: TeamMatches]
    /// False for a build of FM whose fixture classes weren't found.
    var classesFound = true
    private(set) var sweeps = 0

    init(_ teams: [Int64: TeamMatches]) {
        self.teams = teams
    }

    func matches(team: Int64) -> TeamMatches? {
        sweeps += 1
        guard classesFound else { return nil }
        return teams[team] ?? TeamMatches(team: team, fixtures: [], table: nil, check: .noTable)
    }

    /// The club's match stats one sweep of FM's news finds. Nil for a build of FM they haven't been checked on.
    var stats: [MatchStats]? = World.matchStats()
    private(set) var statsSweeps = 0

    func matchStats(team: Int64) -> [MatchStats]? {
        statsSweeps += 1
        return stats?.filter { $0.team == team }
    }

    /// The competitions one sweep of FM's memory names.
    var names: [UInt32: String] = [World.leagueIndex: "Mock League", World.cupIndex: "Mock Cup"]
    private(set) var nameSweeps = 0

    func competitionNames() -> [UInt32: String] {
        nameSweeps += 1
        return classesFound ? names : [:]
    }

    /// The table of a competition's league stage, by database index, as one sweep finds it for a club in it.
    var tables: [UInt32: CompetitionTable] = [:]
    private(set) var tableSweeps = 0

    func competitionTable(team: Int64, competitionIndex: UInt32) -> CompetitionTable? {
        tableSweeps += 1
        guard let found = tables[competitionIndex], found.table.rows.contains(where: { $0.team == team }) else { return nil }
        return found
    }

    /// Whether each competition is a friendly by FM's type, as one sweep finds: the league and the cup aren't.
    var friendlies: [UInt32: Bool] = [World.leagueIndex: false, World.cupIndex: false]
    private(set) var friendlySweeps = 0

    func friendlyByCompetition() -> [UInt32: Bool] {
        friendlySweeps += 1
        return classesFound ? friendlies : [:]
    }
}

/// Players' state as `PlayerStateSource` gives it: bans worked out by hand, and what FM's memory holds now, which a test
/// can change between calls. Counts the players it reads again.
final class FakeStates: PlayerStateSource {
    var bans: [UInt32: [Ban]]
    /// What a player's record says now, applied when he's read again.
    var now: [UInt32: (Player) -> Void] = [:]
    private(set) var refreshed: [UInt32] = []

    init(_ bans: [UInt32: [Ban]]) {
        self.bans = bans
    }

    func refresh(_ player: Player) {
        refreshed.append(player.uid)
        now[player.uid]?(player)
    }

    func bans(of player: Player) -> [Ban]? { player.storedBans == nil ? nil : bans[player.uid] ?? [] }
}

/// Yellow cards toward a ban as `BookingSource` gives them: worked out by hand, or off with a reason.
final class FakeBookings: BookingSource {
    var bookings: [UInt32: [Booking]]
    var off: String?

    init(_ bookings: [UInt32: [Booking]]) {
        self.bookings = bookings
    }

    var status: String { off.map { "off: \($0)" } ?? "on: FM's own count and answer, checked against 3 of 3 bans for bookings" }
    func bookings(of player: Player) -> [Booking]? { off == nil ? bookings[player.uid] ?? [] : nil }
}

/// The matchday squad and scout reports as `SelectionSource` gives them: the line-up as FM holds it now, which a test can
/// change between calls, and the reports it sets. Counts its sweeps for reports.
final class FakeSelection: SelectionSource {
    /// The line-up now, from the one the read found. Nil for one that can't be read again.
    var now: ((Tactic) -> Tactic?) = { $0 }
    var reports: [ScoutReport]? = []
    private(set) var sweeps = 0

    func tactic(again tactic: Tactic, players: [UInt32: Player]) -> Tactic? { now(tactic) }

    func scoutReports(players: [UInt32: Player]) -> [ScoutReport]? {
        sweeps += 1
        return reports
    }
}

/// The user's inbox as `InboxSource` gives it, which a test can change between calls. Counts its reads, and its sweeps for
/// FM's transfer timeline, which holds `events`.
final class FakeInbox: InboxSource {
    var result: Inbox
    var events: [TransferEvent]? = []
    private(set) var reads = 0
    private(set) var sweeps = 0
    private(set) var asked: (manager: Int64, teams: [UInt32: Int], today: Date?)?

    init(_ result: Inbox) {
        self.result = result
    }

    func inbox(manager: Int64, teams: [UInt32: Int], today: Date?) -> Inbox {
        reads += 1
        asked = (manager, teams, today)
        return result
    }

    func transferEvents() -> [TransferEvent]? {
        sweeps += 1
        return events
    }
}

/// Squad rules as `SquadRulesSource` gives them: the league's and the cup's by hand, and FM's values by uid. Counts the
/// values it's asked for.
final class FakeSquadRules: SquadRulesSource {
    var off: String?
    var countsOff: String?
    var sets: [UInt32: SquadRuleSet] = World.squadRules()
    /// FM's value for a player under a type, by FM's first name for it.
    var value: (UInt32, String) -> Int = World.squadRuleValue
    private(set) var asked: [(rule: String, players: [UInt32], team: Int64)] = []

    var status: String {
        if let off { return "off: \(off)" }
        if let countsOff { return "on, without counts: \(countsOff)" }
        return "on: FM's own rules and per-player values, checked against squad size and FM's own home-grown tests for 13 players at \(World.club)"
    }

    func competitionNames() -> [UInt32: String] { sets.mapValues(\.name) }
    func league(of team: Int64) -> UInt32? { team == World.team ? World.leagueIndex : nil }
    func rules(competition index: UInt32) -> SquadRuleSet? { off == nil ? sets[index] : nil }

    func count(_ rule: SquadRule, in set: SquadRuleSet, players: [Player], team: Int64) -> SquadRuleCount {
        asked.append((rule.name, players.map(\.uid), team))
        if let countsOff { return SquadRuleCount(rule: rule, players: nil, notCounted: countsOff) }
        if let why = rule.notCounted { return SquadRuleCount(rule: rule, players: nil, notCounted: why) }
        if rule.isSize { return SquadRuleCount(rule: rule, players: players) }
        return SquadRuleCount(rule: rule, players: players.filter { value($0.uid, rule.name) == 1 })
    }
}

/// A save built by hand, as `GameSource` gives it. It counts its reads, and can say the save has moved on.
final class FakeSource: GameSource {
    var database: Database
    var engine: GameRulesEngine?
    var problem: GameProblem?
    var current = true
    var matches: FakeMatches? = World.matches()
    var states: FakeStates? = FakeStates(World.bans())
    var bookings: FakeBookings? = FakeBookings(World.bookings())
    var selection: FakeSelection? = FakeSelection()
    var inbox: FakeInbox? = FakeInbox(.items(World.inbox()))
    var squadRules: FakeSquadRules? = FakeSquadRules()
    private(set) var reads = 0

    init(database: Database, engine: GameRulesEngine?) {
        self.database = database
        self.engine = engine
    }

    func read() throws -> GameRead {
        if let problem { throw problem }
        reads += 1
        return GameRead(database: database, engine: engine, number: reads, matches: matches, states: states, bookings: bookings, selection: selection,
                        inbox: inbox, squadRules: squadRules)
    }

    func isCurrent(_ read: GameRead) -> Bool { current }
}

/// One human club with a first team, a youngster, an injured player and staff, and a rival club. CAs, PAs, hidden
/// attributes and personality numbers are values nothing else in the save has, so a test can look for them anywhere.
enum World {
    static let club = "Testing FC"
    static let rivals = "Rivals FC"
    /// What no visible value is: CAs and PAs, hidden attributes (19) and personality numbers (17).
    static let hiddenNumbers = #"\b(171|183|137|197|139|177|19|17)\b"#

    static func player(_ uid: UInt32, name: String, age: Int, ca: Int, pa: Int, at club: String = World.club, squad: String = "First team") -> Player {
        let player = Player()
        player.uid = uid
        player.index = uid
        player.block = Int64(uid)
        player.commonName = name
        player.club = club
        player.clubFull = club
        player.clubNation = "Mockovia"
        player.nation = "Mockovia"
        player.league = "Mock League"
        player.squad = squad
        player.age = age
        player.ca = ca
        player.pa = pa
        player.value = Int64(uid) * 100_000
        player.wage = 1000
        player.endYear = 2027
        player.endDay = 100
        player.personality = "Resolute"
        player.media = "Reserved"
        player.pers = [UInt8](repeating: 17, count: 8)
        for index in player.raw.indices { player.raw[index] = 50 }
        for name in Names.hidden { player.raw[Names.playerIndex[name]!] = 95 }
        for position in player.pos.indices { player.pos[position] = 5 }
        player.pos[Names.positions.firstIndex(of: "DC")!] = 20
        return player
    }

    static func staff(_ uid: UInt32, name: String, job: String, block: Int64, at club: String = World.club) -> Staff {
        let staff = Staff()
        staff.uid = uid
        staff.index = uid
        staff.block = block
        staff.commonName = name
        staff.club = club
        staff.clubFull = club
        staff.clubNation = "Mockovia"
        staff.nation = "Mockovia"
        staff.league = "Mock League"
        staff.squad = "First team"
        staff.job = job
        staff.age = 45
        staff.ca = 171
        staff.pa = 183
        staff.wage = 2000
        staff.repWorld = 3000
        staff.personality = "Balanced"
        staff.pers = [UInt8](repeating: 17, count: 8)
        // FM shows a member of staff's Adaptability, so it's an ordinary number here.
        for name in Names.staffShownPersonality { staff.pers[Names.personalityIndex[name]!] = 12 }
        for index in staff.attr.indices { staff.attr[index] = 12 }
        for name in StaffFilter.hiddenRuleAttributes {
            if let index = Names.staffIndex[name] { staff.attr[index] = 19 }
        }
        staff.stars = [4.5, 3.5, 3, 3, 2.5, 2.5, 1, 2, 2]
        return staff
    }

    static func database() -> Database {
        var players = (1...11).map { player(UInt32($0), name: "First \($0)", age: 26, ca: 171, pa: 183) }
        let youngster = player(12, name: "Young Prospect", age: 18, ca: 137, pa: 197, squad: "U19")
        players.append(youngster)
        let injured = player(13, name: "Hurt Player", age: 26, ca: 171, pa: 183)
        let injury = Injury()
        injury.name = "Hamstring strain"
        injured.injury = injury
        injured.injuryText = injury.name
        injured.releaseClause = 3_000_000
        injured.traitBits = 1
        players.append(injured)
        players += (21...32).map { player(UInt32($0), name: "Rival \($0)", age: 24, ca: 139, pa: 177, at: World.rivals) }
        let cheap = players.first { $0.uid == 21 }!
        cheap.releaseForeign = 900_000
        for player in players {
            player.fitness = Fitness(condition: 10_000, sharpness: 9_650)
            player.morale = 12
            player.playingTime = 20
            player.storedBans = []
        }
        state(players)

        let db = Database()
        db.players = players
        db.staff = [staff(500, name: "The Manager", job: "Manager", block: 500),
                    staff(501, name: "Coach One", job: "Coach", block: 501),
                    staff(502, name: "Rival Coach", job: "Coach", block: 502, at: World.rivals)]
        db.gameDate = GameDate.checked(year: 2026, dayOfYear: 270)
        db.build = "27.1.0 (test)"
        db.checks = "PASS"
        db.stateOff = [:]
        db.humanClubs = [(team: 1, name: World.club, manager: 500)]
        db.humanTeams = [1: [firstTeamIndex: 0, youthTeamIndex: 11]]
        db.budgets = [1: (transfer: 5_000_000, wageRoom: 20_000)]
        db.tactics = [1: tactic(players)]
        db.prepare()
        return db
    }

    /// A player/manager at Rivals FC, as FM keeps some: a player and a member of staff under one uid, as the reader reads
    /// him, with the staff side at its own block.
    static let playerCoach: UInt32 = 600

    static func addPlayerCoach(to db: Database) {
        let player = player(playerCoach, name: "Playing Manager", age: 34, ca: 171, pa: 183, at: rivals)
        player.fitness = Fitness(condition: 10_000, sharpness: 9_650)
        player.storedBans = []
        let staff = staff(playerCoach, name: "Playing Manager", job: "Manager", block: Int64(playerCoach) + 0x278, at: rivals)
        player.prepare()
        staff.prepare()
        db.players.append(player)
        db.staff.append(staff)
    }

    /// First 1 is tired and unhappy with his playing time. FM last brought First 2's condition up to date three days ago,
    /// so it takes FM's getters.
    static func state(_ players: [Player]) {
        let byUID = Dictionary(uniqueKeysWithValues: players.map { ($0.uid, $0) })
        let tired = byUID[1]!
        tired.fitness = Fitness(condition: 8_570, sharpness: 9_210)
        tired.morale = 2
        tired.playingTime = -89

        let stale = byUID[2]!
        stale.fitness = nil
        stale.fitnessNeedsCatchUp = true
        stale.fitnessUpdated = GameDate.date(year: 2026, dayOfYear: 267)
    }

    /// First 1 is banned in the league and the cup. The youngster has a ban from abroad, in a competition FM Starship
    /// couldn't name, and the injured player one at home that it couldn't name either.
    static func bans() -> [UInt32: [Ban]] {
        var bookings = Ban(issued: GameDate.date(year: 2026, dayOfYear: 244)!, matches: 1, served: 0)
        bookings.competition = "Mock League"
        bookings.associationName = "Mockovia"
        bookings.competitionIndex = leagueIndex
        bookings.reason = .bookings
        bookings.domestic = true
        bookings.countsForClub = true
        var red = Ban(issued: GameDate.date(year: 2026, dayOfYear: cupMatch)!, matches: 3, served: 1)
        red.competition = "Mock Cup"
        red.competitionIndex = cupIndex
        red.associationName = "Mockovia"
        red.reason = .redCard
        red.opponent = minnows
        red.domestic = true
        red.countsForClub = true

        var abroad = Ban(issued: GameDate.date(year: 2025, dayOfYear: 300)!, matches: 2, served: 0)
        abroad.associationName = "Fixtureland"
        abroad.reason = .bookings
        var unnamed = Ban(issued: GameDate.date(year: 2026, dayOfYear: 250)!, matches: 1, served: 0)
        unnamed.associationName = "Mockovia"
        unnamed.domestic = true
        unnamed.reason = .bookings
        return [1: [bookings, red], 12: [abroad], 13: [unnamed]]
    }

    /// First 1 has cards in the league and the cup, and one for his nation. First 4's league counts with the reserve league,
    /// and he has a card under a rule set FM Starship can't name, and a cup that counts points. Nobody else has any.
    static func bookings() -> [UInt32: [Booking]] {
        func next(_ count: Int, _ left: Int, last: Int = 0, length: Int = 1) -> NextBan {
            NextBan(left: left, length: length, count: count, lastBanAt: last)
        }
        var nations = Booking(rules: 0, competitions: ["Made-up Nations Cup", "Made-up Shield", "Made-up Trophy"], teamPlays: false,
                              next: next(1, 1))
        nations.moreCompetitions = 2
        return [
            1: [Booking(rules: 3, competitions: ["Mock League"], teamPlays: true, next: next(2, 2)),
                Booking(rules: 4, competitions: ["Mock Cup"], teamPlays: true, next: next(1, 1)),
                nations],
            4: [Booking(rules: 3, competitions: ["Mock League", "Mock Reserve League"], teamPlays: true, next: next(5, 1, last: 4, length: 2)),
                Booking(rules: 8, competitions: ["Mock Points Cup"], teamPlays: true, plain: false, next: nil),
                Booking(rules: 6, competitions: [], teamPlays: false, next: next(1, 1))],
        ]
    }

    // MARK: Squad rules

    static let continentalIndex: UInt32 = 30

    /// The league's: a squad of at most 25, at most 11 on professional contracts, at least 3 trained in the nation, at most 10
    /// not home-grown, and at most 3 from outside the EU in a matchday squad. None for the cup. The continental cup's, which
    /// Testing FC doesn't play in: at most 25 and at least 2 goalkeepers.
    static func squadRules() -> [UInt32: SquadRuleSet] {
        [
            leagueIndex: SquadRuleSet(index: leagueIndex, name: "Mock League", record: 0x9000, group: 8, rules: [
                SquadRule(type: 1, names: ["max_squad_size"], limit: 25, direction: .atMost),
                SquadRule(type: 5, names: ["players_on_pt_or_ft_contract_in_squad"], limit: 11, direction: .atMost),
                SquadRule(type: 3, names: ["homegrown_players_0_21_from_nation", "homegrown_players_from_nation"], limit: 3, direction: .atLeast),
                SquadRule(type: 4, names: ["non_homegrown_players_in_squad"], limit: 10, direction: .atMost),
                SquadRule(type: 7, names: ["non_eec_players_in_match_squad"], limit: 3, direction: .atMost),
            ]),
            cupIndex: SquadRuleSet(index: cupIndex, name: "Mock Cup", record: 0x9100, group: -1, rules: []),
            continentalIndex: SquadRuleSet(index: continentalIndex, name: "Made-up Champions Cup", record: 0x9200, group: 0, rules: [
                SquadRule(type: 1, names: ["max_squad_size"], limit: 25, direction: .atMost),
                SquadRule(type: 6, names: ["goalkeepers_in_squad"], limit: 2, direction: .atLeast),
            ]),
        ]
    }

    /// First 1 to First 11 are on professional contracts. First 1 was trained at the club and First 2 in its nation, as
    /// `FakeEngine.homeGrown` says, and the youngster in its nation too; everyone else isn't home-grown. First 1 is the
    /// only goalkeeper.
    static func squadRuleValue(_ uid: UInt32, _ type: String) -> Int {
        switch type {
        case "players_on_pt_or_ft_contract_in_squad": return (1...11).contains(uid) ? 1 : 0
        case "homegrown_players_0_21_from_nation": return [1, 2, 12].contains(uid) ? 1 : 0
        case "non_homegrown_players_in_squad": return [1, 2, 12].contains(uid) ? 0 : 1
        case "goalkeepers_in_squad": return uid == 1 ? 1 : 0
        default: return 0
        }
    }

    // MARK: Inbox

    static let firstTeamIndex: UInt32 = 0x438
    static let youthTeamIndex: UInt32 = 0x4401

    /// Testing FC's inbox, oldest first, from 8 September: contracts running out, Hurt Player's injury report, a transfer for
    /// the youth team, a plea from First 5 sent through an agent, and the board's confidence from a chairman FM Starship
    /// doesn't read.
    static func inbox() -> [InboxItem] {
        func day(_ day: Int) -> Date { GameDate.checked(year: 2026, dayOfYear: day)! }
        let coach = NewsPerson(uid: 501, index: 501, isPlayer: false, name: "Coach One")
        let hurt = NewsPerson(uid: 13, index: 13, isPlayer: true, name: "Hurt Player")
        return [
            InboxItem(serial: 1000, date: day(251), className: "CONTRACT_EXPIRES_SOON_NEWS", team: firstTeamIndex, sender: coach,
                      senderJob: "Director of Football", subject: .contractsExpiring(indexes: [12, 501, 9999])),
            InboxItem(serial: 1001, date: day(256), className: "INJURY_REPORT_NEWS_ITEM", team: firstTeamIndex, sender: coach,
                      senderJob: "Head Physio", subject: .injury(player: hurt, injury: "Hamstring strain", on: day(256), days: 21)),
            InboxItem(serial: 1002, date: day(258), className: "TRANSFER_COMPLETED_NEWS", team: youthTeamIndex, sender: coach,
                      senderJob: "Director of Football",
                      subject: .transfer(person: NewsPerson(uid: 502, index: 502, isPlayer: false, name: "Rival Coach"), club: rivals)),
            InboxItem(serial: 1003, date: day(265), className: "PLAYER_COME_AND_GET_ME_PLEA_NEWS_ITEM", team: nil, sender: nil, fromAgent: true,
                      senderJob: nil, subject: .comeAndGetMe(player: NewsPerson(uid: 5, index: 5, isPlayer: true, name: "First 5"),
                                                             club: "Big Club FC")),
            InboxItem(serial: 1004, date: day(268), className: "BOARD_CONFIDENCE_UPDATE_NEWS", team: firstTeamIndex,
                      sender: NewsPerson(uid: 8888, index: 8888, isPlayer: false, name: "The Chairman"), senderJob: "Chairperson"),
        ]
    }

    /// A 4-4-2 with the first eleven in it, and the youngster and the injured player on the bench, with a gap between them.
    static func tactic(_ players: [Player], bench: [UInt32?] = [12, nil, 13]) -> Tactic {
        let places: [(String, TacticSlot.Side)] = [("GK", .centre), ("DR", .right), ("DC", .right), ("DC", .left), ("DL", .left),
                                                   ("MR", .right), ("MC", .right), ("MC", .left), ("ML", .left), ("ST", .right), ("ST", .left)]
        return Tactic(slots: places.enumerated().map { index, place in
            let position = Names.positions.firstIndex(of: place.0)!
            return TacticSlot(player: players.first { $0.uid == UInt32(index + 1) }, position: position, positionWithoutBall: position,
                              side: place.1, sideWithoutBall: place.1, role: 0, roleWithoutBall: 0)
        }, bench: (bench + Array(repeating: nil, count: 15 - bench.count)).map { index in
            index.map { index in BenchPlace(index: index, player: players.first { $0.index == index }) }
        }, array: 0x1000)
    }

    // MARK: Matches

    static let team: Int64 = 1, rivalsTeam: Int64 = 2, otherTeam: Int64 = 3, minnowsTeam: Int64 = 4
    static let otherTown = "Other Town", minnows = "Minnows FC"
    static let leagueIndex: UInt32 = 9, cupIndex: UInt32 = 12
    /// Days of 2026: 13 and 20 September, league; 23 September, cup; 4 October, league, and 11 October, cup, to come.
    static let firstMatch = 256, secondMatch = 263, cupMatch = 266, nextMatch = 277, laterMatch = 284

    static func fixture(_ day: Int, home: Int64, away: Int64, score: (Int, Int)? = nil, cup: Bool = false) -> MatchFixture {
        let names = [team: club, rivalsTeam: rivals, otherTeam: otherTown, minnowsTeam: minnows]
        var match = MatchFixture(date: GameDate.date(year: 2026, dayOfYear: day) ?? Date(), home: home, away: away)
        match.season = 2026
        match.homeName = names[home] ?? ""
        match.awayName = names[away] ?? ""
        match.competition = cup ? "Mock Cup" : "Mock League"
        match.competitionIndex = cup ? cupIndex : leagueIndex
        match.stage = cup ? "kvartfinale" : ""
        match.kickOff = 15 * 60
        if let score { (match.homeGoals, match.awayGoals) = score }
        return match
    }

    /// Testing FC beat Rivals FC 2-0 and drew 1-1 at Other Town in the league, and won 4-2 at Minnows FC in the cup.
    static func matches() -> FakeMatches {
        var first = fixture(firstMatch, home: team, away: rivalsTeam, score: (2, 0))
        first.round = 1
        first.attendance = 8_500
        // Scored by First 9, with First 10's assist, and First 11 in added time.
        first.goals = [MatchGoal(scorer: 9, assist: 10, home: true, minute: 23, addedMinute: 0),
                       MatchGoal(scorer: 11, assist: nil, home: true, minute: 45, addedMinute: 1)]
        var second = fixture(secondMatch, home: otherTeam, away: team, score: (1, 1))
        second.round = 2
        // Other Town's scorer isn't one of the save's players.
        second.goals = [MatchGoal(scorer: 9_999, assist: nil, home: true, minute: 60, addedMinute: 0),
                        MatchGoal(scorer: 9, assist: nil, home: false, minute: 80, addedMinute: 0)]
        var cupTie = fixture(cupMatch, home: minnowsTeam, away: team, score: (2, 4), cup: true)
        (cupTie.homeAggregate, cupTie.awayAggregate) = (3, 6)
        var next = fixture(nextMatch, home: team, away: otherTeam)
        next.round = 3
        next.kickOff = 20 * 60
        var later = fixture(laterMatch, home: team, away: minnowsTeam, cup: true)
        later.kickOff = nil

        func record(_ p: Int, _ w: Int, _ d: Int, _ l: Int, _ f: Int, _ a: Int) -> TableRecord {
            TableRecord(played: p, won: w, drawn: d, lost: l, goalsFor: f, goalsAgainst: a, points: 3 * w + d)
        }
        let none = record(0, 0, 0, 0, 0, 0)
        let table = LeagueTable(competition: "Mock League", competitionIndex: leagueIndex, rows: [
            LeagueTableRow(team: team, name: club, position: 1, overall: record(2, 1, 1, 0, 3, 1), home: record(1, 1, 0, 0, 2, 0),
                           away: record(1, 0, 1, 0, 1, 1)),
            LeagueTableRow(team: otherTeam, name: otherTown, position: 2, overall: record(1, 0, 1, 0, 1, 1), home: record(1, 0, 1, 0, 1, 1),
                           away: none),
            LeagueTableRow(team: rivalsTeam, name: rivals, position: 3, overall: record(1, 0, 0, 1, 0, 2), home: none,
                           away: record(1, 0, 0, 1, 0, 2)),
        ])
        let ours = [first, second, cupTie, next, later]
        return FakeMatches([
            team: TeamMatches(team: team, fixtures: ours, table: table, check: .passed),
            rivalsTeam: TeamMatches(team: rivalsTeam, fixtures: [first], table: table, check: .passed),
            otherTeam: TeamMatches(team: otherTeam, fixtures: [second, next], table: table, check: .passed),
        ])
    }

    /// FM's post-match news holds team stats for both league matches. Its figures for the 1-1 at Other Town are what the
    /// players' records add up to; the 2-0 against Rivals FC has two goals, and the records only one, so its check fails.
    static func matchStats() -> [MatchStats] {
        func side(_ possession: Int, _ xG100: Int, _ shots: Int, _ onTarget: Int, _ fouls: Int, _ goals: Int) -> MatchSideStats {
            MatchSideStats(possession: possession, xG100: xG100, shots: shots, shotsOnTarget: onTarget, fouls: fouls, goals: goals)
        }
        return [MatchStats(date: GameDate.date(year: 2026, dayOfYear: firstMatch) ?? Date(), team: team, opponent: rivalsTeam, home: true,
                           ours: side(64, 325, 15, 3, 3, 2), theirs: side(36, 85, 4, 2, 8, 0)),
                MatchStats(date: GameDate.date(year: 2026, dayOfYear: secondMatch) ?? Date(), team: team, opponent: otherTeam, home: false,
                           ours: side(46, 325, 15, 3, 3, 1), theirs: side(54, 85, 9, 4, 11, 1))]
    }

    // MARK: Development

    /// The days of 2026 FM Starship read the save on: 1 July, 1 August, 1 September and 20 September. The game is on 27 September.
    static let recordDays = [182, 213, 244, 263]

    /// One player's row in a record: every attribute 10 and the hidden ones 19, but for `changed`.
    static func record(_ name: String, ca: Int, pa: Int, _ changed: [String: UInt8] = [:]) -> DevelopmentStore.Row {
        var attr = [UInt8](repeating: 10, count: 54)
        for name in Names.hidden { attr[Names.playerIndex[name]!] = 19 }
        for (name, value) in changed { attr[Names.playerIndex[name]!] = value }
        return DevelopmentStore.Row(name: name, ca: ca, pa: pa, attr: attr)
    }

    /// FM Starship's record of Testing FC. The youngster's CA went from 137 to 171 and his Passing from 8 to 12, while his
    /// Pace went up and back. First 1's hidden Consistency went from 17 to 19 and his Stamina down from 12 to 10. Hurt Player
    /// came after the first record, and Rival 22 was at the club until August.
    static func history() -> [DevelopmentStore.Snap] {
        let youngster: [(ca: Int, passing: UInt8, pace: UInt8)] = [(137, 8, 10), (139, 9, 13), (139, 11, 12), (171, 12, 10)]
        return recordDays.enumerated().map { step, day in
            var snap = DevelopmentStore.Snap(gameDate: GameDate.date(year: 2026, dayOfYear: day)!)
            for uid in 2...11 { snap.players[UInt32(uid)] = record("First \(uid)", ca: 171, pa: 183) }
            let last = step == recordDays.count - 1
            snap.players[1] = record("First 1", ca: 171, pa: 183, last ? ["Consistency": 19, "Stamina": 10] : ["Consistency": 17, "Stamina": 12])
            let young = youngster[step]
            snap.players[12] = record("Young Prospect", ca: young.ca, pa: 197, ["Passing": young.passing, "Pace": young.pace])
            if step > 0 { snap.players[13] = record("Hurt Player", ca: 171, pa: 183) }
            if step < 2 { snap.players[22] = record("Rival 22", ca: 139, pa: 177) }
            return snap
        }
    }

    static func settings(hidden: Bool, reveal: Reveal = .exact) -> Settings {
        var settings = Settings()
        settings.showHidden = hidden
        settings.reveal = reveal.rawValue
        settings.unitsFollowFm = false
        settings.currencyName = "United Kingdom Pound"
        settings.wagePeriod = "week"
        settings.heightUnit = "cm"
        settings.interestClub = World.club
        return settings
    }
}

/// A toolbox on the made-up save, with settings the test can change between calls.
final class Harness {
    let source: FakeSource
    var settings: Settings
    let shortlists: URL
    /// The app's folder for development records, a temporary one, never the real one.
    let development: URL
    lazy var toolbox: Toolbox = {
        let toolbox = Toolbox(source: source, settings: { [unowned self] in self.settings }, shortlistRoots: { [unowned self] in [self.shortlists] })
        toolbox.developmentStore = DevelopmentStore(directory: development)
        return toolbox
    }()

    init(hidden: Bool = true, reveal: Reveal = .exact, engine: GameRulesEngine? = FakeEngine()) {
        source = FakeSource(database: World.database(), engine: engine)
        settings = World.settings(hidden: hidden, reveal: reveal)
        shortlists = FileManager.default.temporaryDirectory.appendingPathComponent("fmstarship-mcp-tests-\(UUID().uuidString)")
        development = FileManager.default.temporaryDirectory.appendingPathComponent("fmstarship-mcp-development-\(UUID().uuidString)")
    }

    deinit {
        try? FileManager.default.removeItem(at: shortlists)
        try? FileManager.default.removeItem(at: development)
    }

    /// Writes a club's development record where the app would, in the temporary folder.
    func saveDevelopment(_ snaps: [DevelopmentStore.Snap], club: String = World.club) throws {
        let url = DevelopmentStore(directory: development).path(db: source.database, club: club)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snaps).write(to: url)
    }

    func saveShortlist(_ name: String, isStaff: Bool, uids: [UInt32]) throws {
        let folder = shortlists.appendingPathComponent("cloud").appendingPathComponent(isStaff ? "staff shortlists" : "shortlists")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ShortlistFile.write(to: folder.appendingPathComponent("\(name).fmf"), name: name, isStaff: isStaff, uids: uids)
    }

    /// The tool's answer, which must be one.
    func answer(_ tool: String, _ arguments: JSON = [:], file: StaticString = #filePath, line: UInt = #line) throws -> JSON {
        let result = try XCTUnwrap(toolbox.call(tool, arguments: arguments), "no such tool", file: file, line: line)
        XCTAssertFalse(result.isError, result.text, file: file, line: line)
        return try JSON.parse(result.text)
    }

    /// The sentence a tool refuses with.
    func refusal(_ tool: String, _ arguments: JSON = [:], file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let result = try XCTUnwrap(toolbox.call(tool, arguments: arguments), "no such tool", file: file, line: line)
        XCTAssertTrue(result.isError, "expected a refusal: \(result.text)", file: file, line: line)
        return result.text
    }
}

extension JSON {
    /// A list's column names.
    var columnNames: [String] { self["columns"]?.array?.compactMap(\.string) ?? [] }

    /// A list's rows, each by column name.
    var rowsByName: [[String: JSON]] {
        let names = columnNames
        return (self["rows"]?.array ?? []).map { row in
            Dictionary(zip(names, row.array ?? []), uniquingKeysWith: { first, _ in first })
        }
    }
}
