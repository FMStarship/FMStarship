import Foundation
import StarshipAnalysis
import StarshipCore
import StarshipSearch

/// One read of the save, and FM's rules for it: nil where this build of FM hasn't been checked, so those features are off.
public struct GameRead {
    public let database: Database
    public let engine: GameRulesEngine?
    /// Tells this read from the next, which may have the same date.
    public let number: Int
    /// Fixtures, results and league tables, read when a tool asks for them. Nil where they can't be read.
    public let matches: MatchSource?
    /// Players' state as FM's memory holds it when a tool answers, and what their bans are for. Nil where it can't be read
    /// again, so a player's state is the read's and his bans aren't known.
    public let states: PlayerStateSource?
    /// Players' yellow cards toward a ban, by FM's own count. Nil where they can't be read.
    public let bookings: BookingSource?
    /// The user's matchday squad as FM holds it when a tool answers, and FM's scout reports. Nil where they can't be read again.
    public let selection: SelectionSource?
    /// The user's inbox as FM holds it when a tool answers. Nil where it can't be read.
    public let inbox: InboxSource?
    /// Each competition's squad rules and FM's per-player values for them. Nil where they can't be read.
    public let squadRules: SquadRulesSource?

    public init(database: Database, engine: GameRulesEngine?, number: Int = 0, matches: MatchSource? = nil, states: PlayerStateSource? = nil,
                bookings: BookingSource? = nil, selection: SelectionSource? = nil, inbox: InboxSource? = nil,
                squadRules: SquadRulesSource? = nil) {
        self.database = database
        self.engine = engine
        self.number = number
        self.matches = matches
        self.states = states
        self.bookings = bookings
        self.selection = selection
        self.inbox = inbox
        self.squadRules = squadRules
    }
}

/// Squad rules as `SquadRulesReader` gives them.
public protocol SquadRulesSource: AnyObject {
    /// On with what its check found, or off and why, for `game_status`. Asking runs the check.
    var status: String { get }
    /// Why the rules are off for this read, nil while they're on.
    var off: String? { get }
    /// Why FM's per-player values are off, so the rules come without counts. Nil while they're on.
    var countsOff: String? { get }
    /// The competitions FM holds fixtures of, by database index.
    func competitionNames() -> [UInt32: String]
    /// A team's league, by database index.
    func league(of team: Int64) -> UInt32?
    /// A competition's rules. Nil when they're off or its record isn't known.
    func rules(competition index: UInt32) -> SquadRuleSet?
    /// One rule counted against these players for `team`.
    func count(_ rule: SquadRule, in set: SquadRuleSet, players: [Player], team: Int64) -> SquadRuleCount
}

extension SquadRulesReader: SquadRulesSource {}

/// The user's inbox, as `InboxReader` gives it.
public protocol InboxSource: AnyObject {
    /// The inbox of the human manager at `manager` as FM holds it now: new items come in without the date moving.
    func inbox(manager: Int64, teams: [UInt32: Int], today: Date?) -> Inbox
    /// FM's transfer timeline as it holds it now, each entry once. Nil when it can't be read.
    func transferEvents() -> [TransferEvent]?
}

/// The running game's, through an `InboxReader` made on the first question.
final class LiveInbox: InboxSource {
    private let game: GameProcess
    private var reader: InboxReader?

    init(game: GameProcess) {
        self.game = game
    }

    private var found: InboxReader {
        if let reader { return reader }
        let made = InboxReader(game: game, rtti: Rtti(game))
        reader = made
        return made
    }

    func inbox(manager: Int64, teams: [UInt32: Int], today: Date?) -> Inbox {
        found.inbox(manager: manager, teams: teams, today: today)
    }

    func transferEvents() -> [TransferEvent]? { found.transferEvents() }
}

/// The matchday squad and the scout's reports, as `SelectionReader` gives them.
public protocol SelectionSource: AnyObject {
    /// The tactic as FM holds it now: the user can change the line-up without the date moving. Nil when it can't be read again.
    func tactic(again tactic: Tactic, players: [UInt32: Player]) -> Tactic?
    /// FM's opposition reports, newest first. Nil when this build of FM doesn't have the class they're found by.
    func scoutReports(players: [UInt32: Player]) -> [ScoutReport]?
}

/// The running game's, through a `SelectionReader` made on the first question.
final class LiveSelection: SelectionSource {
    private let game: GameProcess
    private var reader: SelectionReader?

    init(game: GameProcess) {
        self.game = game
    }

    private var found: SelectionReader {
        if let reader { return reader }
        let made = SelectionReader(game: game, rtti: Rtti(game))
        reader = made
        return made
    }

    func tactic(again tactic: Tactic, players: [UInt32: Player]) -> Tactic? { found.tactic(again: tactic, players: players) }

    func scoutReports(players: [UInt32: Player]) -> [ScoutReport]? {
        found.findsReports ? found.scoutReports(players: players) : nil
    }
}

/// A player's yellow cards toward a ban, as `BookingsReader` gives them.
public protocol BookingSource: AnyObject {
    /// On with what its check found, or off and why, for `game_status`. Asking runs the check.
    var status: String { get }
    /// Why it's off for this read, nil while it's on.
    var off: String? { get }
    /// Each rule set's count for him with FM's answer. Nil when it's off or his counts can't be read.
    func bookings(of player: Player) -> [Booking]?
}

extension BookingsReader: BookingSource {}

/// A player's state for an answer about him, as `PlayerStateReader` gives it.
public protocol PlayerStateSource: AnyObject {
    /// Reads his condition, sharpness, morale, playing time and bans again: FM can play a match without the date moving.
    func refresh(_ player: Player)
    /// His bans, with what FM Starship could work out about each. Nil when they're off or weren't read.
    func bans(of player: Player) -> [Ban]?
}

extension PlayerStateReader: PlayerStateSource {}

/// A team's fixtures, results and league table, swept for when a tool asks: a couple of seconds for one team, so not
/// with the save.
public protocol MatchSource: AnyObject {
    /// Nil when this build of FM doesn't have the classes they're found by.
    func matches(team: Int64) -> TeamMatches?
    /// Every competition with a fixture in FM's memory, by database index, which is all a player's match record holds.
    func competitionNames() -> [UInt32: String]
    /// Whether each competition with a fixture in FM's memory is a friendly, by FM's type of competition, by database index.
    /// A competition whose type isn't known is left out.
    func friendlyByCompetition() -> [UInt32: Bool]
    /// The team stats of the user's club's recent matches, from FM's post-match news, before FM Starship's check. Nil on a
    /// build of FM they haven't been checked on.
    func matchStats(team: Int64) -> [MatchStats]?
}

extension MatchSource {
    public func matchStats(team: Int64) -> [MatchStats]? { nil }
    public func friendlyByCompetition() -> [UInt32: Bool] { [:] }
}

/// The running game's, through `FixturesReader`, which is set up on the first question about a match.
final class LiveMatches: MatchSource {
    private let game: GameProcess
    private var reader: FixturesReader??

    init(game: GameProcess) {
        self.game = game
    }

    func matches(team: Int64) -> TeamMatches? {
        if reader == nil { reader = .some(FixturesReader(game: game, rtti: Rtti(game))) }
        guard let found = reader ?? nil else { return nil }
        return found.teamMatches(team: team)
    }

    func competitionNames() -> [UInt32: String] {
        if reader == nil { reader = .some(FixturesReader(game: game, rtti: Rtti(game))) }
        return (reader ?? nil)?.competitionNames() ?? [:]
    }

    func friendlyByCompetition() -> [UInt32: Bool] {
        if reader == nil { reader = .some(FixturesReader(game: game, rtti: Rtti(game))) }
        return (reader ?? nil)?.friendlyByCompetition() ?? [:]
    }

    private lazy var statsReader = MatchStatsReader(game: game, rtti: Rtti(game))

    func matchStats(team: Int64) -> [MatchStats]? { statsReader.stats(team: team) }

    /// Each competition's record by database index, for naming the rule sets yellow cards count under and finding a
    /// competition's squad rules.
    func competitionRecords() -> [UInt32: Int64] {
        if reader == nil { reader = .some(FixturesReader(game: game, rtti: Rtti(game))) }
        return (reader ?? nil)?.competitionRecords() ?? [:]
    }
}

/// Why there's nothing to read, in words for the player.
public enum GameProblem: Error, Equatable {
    case notRunning
    case withoutStarship
    case noSave
    case failed(String)

    public var sentence: String {
        switch self {
        case .notRunning:
            return "Football Manager isn't running. Start FM with FM Starship (from FM Starship, or with its launch option in Steam), load your save, and ask again."
        case .withoutStarship:
            return "Football Manager is running without FM Starship, so its save can't be read. Quit FM, start it from FM Starship or with FM Starship's launch option in Steam, load your save, and ask again."
        case .noSave:
            return "FM is running with FM Starship, but no save is loaded. Load your save in FM and ask again."
        case .failed(let why):
            return "FM Starship couldn't read the save: \(why)"
        }
    }
}

/// Where the save comes from: the running game, or in tests one built by hand.
public protocol GameSource: AnyObject {
    /// Reads the whole save. Throws a `GameProblem`.
    func read() throws -> GameRead
    /// Whether FM still has the save `read` came from loaded, at the same date. Two small reads, where `read` takes seconds.
    func isCurrent(_ read: GameRead) -> Bool
}

/// FM, through the agent FM Starship loads into it, the way the app and fmprobe read it. Nothing is asked of FM until a
/// tool needs the save.
public final class LiveGame: GameSource {
    private var game: GameProcess?
    /// The human clubs' names where the read found them, as the plugin tells another save from the one it read.
    private var clubsAtRead: [String] = []
    private var readAt = Date.distantPast
    private var reads = 0

    /// How long a read that found no game date stands, since the date can't say whether the save has moved on.
    static let undatedLimit: TimeInterval = 300

    public init() {}

    public func read() throws -> GameRead {
        game = nil
        guard GameProcess.runningPID() != nil else { throw GameProblem.notRunning }
        let process: GameProcess
        do {
            process = try GameProcess()
        } catch AgentError.notRunning {
            throw GameProblem.withoutStarship
        } catch {
            throw GameProblem.failed("\(error)")
        }
        do {
            let (database, engine) = try GameReader.connect(to: process, status: { _ in }, log: { try? FileHandle.standardError.write(contentsOf: Data(($0 + "\n").utf8)) })
            game = process
            clubsAtRead = clubs(database, in: process)
            readAt = Date()
            reads += 1
            let matches = LiveMatches(game: process)
            return GameRead(database: database, engine: engine, number: reads, matches: matches,
                            states: PlayerStateReader(game: process, database: database),
                            bookings: BookingsReader(game: process, database: database, engine: engine,
                                                     competitionRecords: { matches.competitionRecords() }),
                            selection: LiveSelection(game: process), inbox: LiveInbox(game: process),
                            squadRules: SquadRulesReader(game: process, database: database, engine: engine,
                                                         competitionRecords: { matches.competitionRecords() }))
        } catch ReadError.noPlayers {
            throw GameProblem.noSave
        } catch {
            throw GameProblem.failed("\(error)")
        }
    }

    public func isCurrent(_ read: GameRead) -> Bool {
        guard let game, GameProcess.runningPID() == game.pid else { return false }
        let database = read.database
        return Self.stillCurrent(dateNow: GameReader.gameDate(of: database, in: game), dateAtRead: database.gameDate,
                                 clubsNow: clubs(database, in: game), clubsAtRead: clubsAtRead, age: Date().timeIntervalSince(readAt))
    }

    /// Whether a read is still the save FM has loaded: the same clubs where they were, and the same date. A read that found
    /// no date can't tell a day going by, so it stands for `undatedLimit` only.
    static func stillCurrent(dateNow: Date?, dateAtRead: Date?, clubsNow: [String], clubsAtRead: [String], age: TimeInterval) -> Bool {
        guard clubsNow == clubsAtRead else { return false }
        guard let dateAtRead else { return age < undatedLimit }
        return dateNow == dateAtRead
    }

    private func clubs(_ database: Database, in game: GameProcess) -> [String] {
        database.humanClubs.map { GameReader.clubName(team: $0.team, in: game) }
    }
}

/// The read kept between calls. It's read again when the save has moved on or FM has restarted, and when a call asks.
final class GameConnection {
    private let source: GameSource
    private(set) var current: GameRead?
    private(set) var readAt: Date?

    init(source: GameSource) {
        self.source = source
    }

    func read(refresh: Bool) throws -> GameRead {
        if !refresh, let current, source.isCurrent(current) { return current }
        current = nil
        let read = try source.read()
        install(read)
        current = read
        readAt = Date()
        return read
    }

    /// As the app does after a read: the rules, the clubs, the currencies, then season stats and form for everyone.
    private func install(_ read: GameRead) {
        let database = read.database
        GameRules.engine = read.engine
        RulesState.shared.reset()
        RulesState.shared.fill(database)
        // The user's currency is one of the save's, so the units are set again once those are known, before anything
        // in this call is written out or a money argument is read.
        Units.setCurrencies(database.currencies)
        Units.apply()
        database.prepare()
        guard let engine = read.engine else { return }
        // FM's getters must give the stored values for players brought up to date today, or condition and sharpness are off.
        GameReader.checkFitnessGetters(database, engine: engine)
        let players = database.players.filter { $0.block > 0 && $0.season == nil }
        // Only a fresh look at the first few: if the game answers none of them, it won't answer the rest.
        let probe = players.prefix(32)
        guard probe.isEmpty || probe.contains(where: { engine.seasonStats(player: $0, season: RulesEngine.clubTotal) != nil }) else { return }
        var found = [SeasonStats?](repeating: nil, count: players.count)
        var forms = [String](repeating: "", count: players.count)
        found.withUnsafeMutableBufferPointer { results in
            forms.withUnsafeMutableBufferPointer { formResults in
                let results = results, formResults = formResults
                // Half the cores, as the app does, so FM, which runs on the same Mac, keeps the rest.
                let workers = max(1, min(players.count, ProcessInfo.processInfo.activeProcessorCount / 2))
                let lock = NSLock()
                var next = 0
                DispatchQueue.concurrentPerform(iterations: workers) { _ in
                    while true {
                        let index: Int = lock.withLock {
                            defer { next += 1 }
                            return next
                        }
                        guard index < players.count else { return }
                        results[index] = engine.seasonStats(player: players[index], season: RulesEngine.clubTotal)
                        if (results[index]?.apps ?? 0) > 0 { formResults[index] = engine.form(player: players[index]) ?? "" }
                    }
                }
            }
        }
        for (index, player) in players.enumerated() where (found[index]?.apps ?? 0) > 0 {
            player.season = found[index]
            player.form = forms[index]
        }
    }
}
