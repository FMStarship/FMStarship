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

    public init(database: Database, engine: GameRulesEngine?, number: Int = 0) {
        self.database = database
        self.engine = engine
        self.number = number
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
    private var reads = 0

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
            let (database, engine) = try GameReader.connect(to: process, status: { _ in }, log: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
            game = process
            clubsAtRead = clubs(database, in: process)
            reads += 1
            return GameRead(database: database, engine: engine, number: reads)
        } catch ReadError.noPlayers {
            throw GameProblem.noSave
        } catch {
            throw GameProblem.failed("\(error)")
        }
    }

    public func isCurrent(_ read: GameRead) -> Bool {
        guard let game, GameProcess.runningPID() == game.pid else { return false }
        let database = read.database
        return GameReader.gameDate(of: database, in: game) == database.gameDate && clubs(database, in: game) == clubsAtRead
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
        Units.setCurrencies(database.currencies)
        database.prepare()
        guard let engine = read.engine else { return }
        let players = database.players.filter { $0.block > 0 && $0.season == nil }
        // Only a fresh look at the first few: if the game answers none of them, it won't answer the rest.
        let probe = players.prefix(32)
        guard probe.isEmpty || probe.contains(where: { engine.seasonStats(player: $0, season: RulesEngine.clubTotal) != nil }) else { return }
        var found = [SeasonStats?](repeating: nil, count: players.count)
        var forms = [String](repeating: "", count: players.count)
        found.withUnsafeMutableBufferPointer { results in
            forms.withUnsafeMutableBufferPointer { formResults in
                let results = results, formResults = formResults
                DispatchQueue.concurrentPerform(iterations: players.count) { index in
                    results[index] = engine.seasonStats(player: players[index], season: RulesEngine.clubTotal)
                    if (results[index]?.apps ?? 0) > 0 { formResults[index] = engine.form(player: players[index]) ?? "" }
                }
            }
        }
        for (index, player) in players.enumerated() where (found[index]?.apps ?? 0) > 0 {
            player.season = found[index]
            player.form = forms[index]
        }
    }
}
