import Foundation
import StarshipAnalysis
import StarshipCore
import StarshipFiles
import StarshipSearch

/// A call that can't be answered, in one sentence the agent can pass on.
struct ToolError: Error {
    let sentence: String
    init(_ sentence: String) { self.sentence = sentence }
}

/// A call's arguments, checked against what the tool takes, so a misspelt one is said, not ignored.
struct Arguments {
    private let values: JSON
    private let tool: String

    init(_ values: JSON, tool: String, allowed: [String]) throws {
        self.values = values
        self.tool = tool
        if case .object(let pairs) = values {
            let unknown = pairs.map(\.0).filter { !allowed.contains($0) }
            if !unknown.isEmpty {
                let takes = allowed.isEmpty ? "no arguments" : allowed.joined(separator: ", ")
                throw ToolError("\(tool) doesn't take \(unknown.joined(separator: ", ")). It takes \(takes).")
            }
        }
    }

    func has(_ key: String) -> Bool { values[key].map { $0 != .null } ?? false }

    func string(_ key: String) throws -> String? {
        guard let value = values[key], value != .null else { return nil }
        guard let text = value.string else { throw ToolError("\(key) must be text.") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func int(_ key: String, in range: ClosedRange<Int>? = nil) throws -> Int? {
        guard let value = values[key], value != .null else { return nil }
        guard let number = value.int else { throw ToolError("\(key) must be a whole number.") }
        if let range, !range.contains(number) { throw ToolError("\(key) must be from \(range.lowerBound) to \(range.upperBound).") }
        return number
    }

    func number(_ key: String) throws -> Double? {
        guard let value = values[key], value != .null else { return nil }
        guard let number = value.double, number.isFinite, number >= 0 else { throw ToolError("\(key) must be a number, 0 or more.") }
        return number
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = values[key], value != .null else { return nil }
        guard let flag = value.bool else { throw ToolError("\(key) must be true or false.") }
        return flag
    }

    func array(_ key: String) throws -> [JSON]? {
        guard let value = values[key], value != .null else { return nil }
        guard let items = value.array else { throw ToolError("\(key) must be a list.") }
        return items
    }

    /// One of a fixed set of words, matched without case.
    func choice(_ key: String, _ choices: [String]) throws -> String? {
        guard let text = try string(key) else { return nil }
        guard let found = choices.first(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) else {
            throw ToolError("\(key) must be one of: \(choices.joined(separator: ", ")).")
        }
        return found
    }
}

/// Everything a call works from: the read, the user's settings now, and their club.
final class CallContext {
    let read: GameRead
    let visibility: Visibility
    private let toolbox: Toolbox

    init(read: GameRead, visibility: Visibility, toolbox: Toolbox) {
        self.read = read
        self.visibility = visibility
        self.toolbox = toolbox
    }

    var db: Database { read.database }

    /// The clubs human managers run in this save, the user's first: the club they last chose in FM Starship, else the first.
    var humanClubs: [ChosenClub] {
        let clubs = ChosenClub.humanClubs(in: db)
        guard let chosen = clubs.firstIndex(where: { $0.name == Settings.current.interestClub }) else { return clubs }
        return [clubs[chosen]] + clubs.enumerated().filter { $0.offset != chosen }.map(\.element)
    }

    /// The user's club, or the one they name, which must be a human manager's.
    func ownClub(_ named: String?) throws -> ChosenClub {
        let clubs = humanClubs
        guard let first = clubs.first else { throw ToolError("No club in this save is run by a human manager.") }
        guard let named else { return first }
        guard let club = clubs.first(where: { $0.name.caseInsensitiveCompare(named) == .orderedSame }) else {
            throw ToolError("\(named) isn't run by a human manager in this save. Clubs with one: \(clubs.map(\.name).joined(separator: ", ")).")
        }
        return club
    }

    /// The analysis seen from a club, kept while the read, the settings and the club stay the same.
    func session(for club: ChosenClub) -> AnalysisSession { toolbox.session(read: read, club: club, visibility: visibility) }

    /// The player or member of staff with this uid. A player/manager or player/coach is both under one uid: `kind`
    /// ("player" or "staff") picks a side, and with none he's the player.
    func person(_ uid: Int, kind: String? = nil) throws -> Person {
        guard uid >= 0, uid <= Int(UInt32.max) else { throw ToolError("Nobody in this save has uid \(uid).") }
        let people = toolbox.people(read)
        let player = people.players[UInt32(uid)], staff = people.staff[UInt32(uid)]
        switch kind {
        case "player":
            if let player { return player }
            throw ToolError(staff == nil ? "Nobody in this save has uid \(uid)." : "uid \(uid) is a member of staff, not a player.")
        case "staff":
            if let staff { return staff }
            throw ToolError(player == nil ? "Nobody in this save has uid \(uid)." : "uid \(uid) is a player, not a member of staff.")
        default:
            guard let person = player ?? staff else { throw ToolError("Nobody in this save has uid \(uid).") }
            return person
        }
    }

    /// The staff side of a player who is also a member of staff, as a player/manager is.
    func staffSide(of player: Player) -> Staff? { toolbox.people(read).staff[player.uid] }
}

/// FM Starship's tools for an agent. Every call reads the user's settings first, so Hidden attributes and Ability are
/// as the user last set them in the app or in FM Starship's tab inside FM.
public final class Toolbox: ToolProvider {
    private let connection: GameConnection
    private let settings: () -> Settings
    let shortlistRoots: () -> [URL]

    private struct SessionKey: Equatable {
        let read: Int
        let visibility: Visibility
        let team: Int64
        let symbol: String
        let perPound: Double
        let wages: Int
        let feet: Bool
    }

    private var sessionKey: SessionKey?
    private var cachedSession: AnalysisSession?
    private var peopleRead: Int?
    private var playersByUID: [UInt32: Player] = [:]
    private var staffByUID: [UInt32: Staff] = [:]
    private var indexRead: Int?
    private var peopleByIndex: [UInt32: Player] = [:]
    private var matchesRead: Int?
    private var matchesByTeam: [Int64: (matches: TeamMatches?, at: Date)] = [:]
    private var namesRead: Int?
    private var namesByIndex: [UInt32: String] = [:]
    private var reportsRead: Int?
    private var reportsFound: [ScoutReport]?
    /// The time now, which a test can move on.
    var clock: () -> Date = Date.init
    /// Where the app keeps its development records, which `development` only reads. A test points it at a folder of its own.
    var developmentStore = DevelopmentStore()

    /// `settings` gives the settings as they are now: the live server reads FM Starship's settings file each call.
    public init(source: GameSource, settings: @escaping () -> Settings, shortlistRoots: @escaping () -> [URL]) {
        connection = GameConnection(source: source)
        self.settings = settings
        self.shortlistRoots = shortlistRoots
    }

    /// The running game, the user's own settings and FM's own shortlist folder.
    public static func live() -> Toolbox {
        Toolbox(source: LiveGame(), settings: {
            Settings.load()
            return Settings.current
        }, shortlistRoots: { ShortlistFile.fmFolderRoots() })
    }

    public var definitions: [JSON] { Self.tools.map(\.definition) }

    public func call(_ name: String, arguments: JSON) -> ToolResult? {
        guard let tool = Self.tools.first(where: { $0.name == name }) else { return nil }
        Settings.current = settings()
        Units.apply()
        let visibility = Visibility(Settings.current)
        do {
            let args = try Arguments(arguments, tool: name, allowed: tool.parameters.map(\.name))
            if name == "game_status" { return .answer(status(refresh: try args.bool("refresh") ?? false, visibility)) }
            if name == "shortlists" { return .answer(try shortlists(args)) }
            let read = try connection.read(refresh: false)
            let context = CallContext(read: read, visibility: visibility, toolbox: self)
            return .answer(try tool.run(self)(args, context))
        } catch let error as ToolError {
            return .problem(error.sentence)
        } catch let problem as GameProblem {
            return .problem(problem.sentence)
        } catch {
            return .problem("FM Starship couldn't answer that: \(error)")
        }
    }

    func session(read: GameRead, club: ChosenClub, visibility: Visibility) -> AnalysisSession {
        let key = SessionKey(read: read.number, visibility: visibility, team: club.team, symbol: Units.money.symbol,
                             perPound: Units.money.perPound, wages: Units.wages.rawValue, feet: Units.height == .feetInches)
        if key == sessionKey, let cachedSession, cachedSession.db === read.database { return cachedSession }
        RulesState.shared.pickClub(club.name)
        let session = AnalysisSession(db: read.database, club: club, display: visibility.display, library: FMData.library)
        sessionKey = key
        cachedSession = session
        return session
    }

    /// Players and staff by uid, kept apart as the app keeps them: a player/manager is in both under one uid.
    func people(_ read: GameRead) -> (players: [UInt32: Player], staff: [UInt32: Staff]) {
        if peopleRead != read.number || (playersByUID.isEmpty && staffByUID.isEmpty) {
            var players: [UInt32: Player] = [:], staff: [UInt32: Staff] = [:]
            for person in read.database.staff { staff[person.uid] = person }
            for person in read.database.players { players[person.uid] = person }
            playersByUID = players
            staffByUID = staff
            peopleRead = read.number
        }
        return (playersByUID, staffByUID)
    }

    /// Players by the index FM's goal lists name them by.
    func playersByIndex(_ read: GameRead) -> [UInt32: Player] {
        if indexRead != read.number || peopleByIndex.isEmpty {
            var all: [UInt32: Player] = [:]
            for player in read.database.players { all[player.index] = player }
            peopleByIndex = all
            indexRead = read.number
        }
        return peopleByIndex
    }

    /// A team's matches, swept for once for each read of the save, except on match day, and never kept after a failed check,
    /// which a sweep part way through a match can give.
    func cachedMatches(_ read: GameRead, team: Int64, source: MatchSource) -> TeamMatches? {
        if matchesRead != read.number {
            matchesByTeam = [:]
            matchesRead = read.number
        }
        let now = clock()
        if let known = matchesByTeam[team],
           Self.stillStands(known.matches, today: read.database.gameDate, age: now.timeIntervalSince(known.at)) {
            return known.matches
        }
        let found = source.matches(team: team)
        if case .failed = found?.check {
            matchesByTeam[team] = nil
        } else {
            matchesByTeam[team] = (found, now)
        }
        return found
    }

    /// Competitions by database index, swept for once for each read of the save: a new competition comes with a new date.
    func competitionNames(_ read: GameRead) -> [UInt32: String] {
        guard let source = read.matches else { return [:] }
        if namesRead != read.number {
            namesByIndex = source.competitionNames()
            namesRead = read.number
        }
        return namesByIndex
    }

    /// FM's opposition reports, swept for once for each read of the save: FM writes them as the days go by. Nil when they
    /// can't be read.
    func scoutReports(_ read: GameRead) -> [ScoutReport]? {
        guard let source = read.selection else { return nil }
        if reportsRead != read.number {
            reportsFound = source.scoutReports(players: playersByIndex(read))
            reportsRead = read.number
        }
        return reportsFound
    }

    /// How long a sweep stands while it holds a match due today or earlier that isn't played yet.
    static let matchDayWait: TimeInterval = 60

    /// A sweep stands as long as the read, unless it holds a match that's due and not played: the game date doesn't move
    /// while FM plays it, so the user may have played it since. Then it stands for `matchDayWait`.
    static func stillStands(_ matches: TeamMatches?, today: Date?, age: TimeInterval) -> Bool {
        guard let matches, let today, matches.fixtures.contains(where: { !$0.played && $0.date <= today }) else { return true }
        return age < matchDayWait
    }

    // MARK: Game status

    private func status(refresh: Bool, _ visibility: Visibility) -> JSON {
        // Made after the read, which sets the save's currencies, so they're the units this call's answers are in. With no
        // save read, the user's currency isn't known yet, so it's left out rather than given as the pound.
        func settings(currencyKnown: Bool) -> [(String, JSON?)] {
            var units: [(String, JSON)] = []
            if currencyKnown { units += [("currency", .string(Units.money.name)), ("symbol", .string(Units.money.symbol))] }
            units += [("wages", .string(Units.wageSuffix)), ("height", .string(Units.height == .feetInches ? "ft/in" : "cm"))]
            return [("hidden_attributes", .string(visibility.showHidden ? "on" : "off")),
                    ("ability", .string(visibility.abilityText)), ("units", .object(units))]
        }
        let read: GameRead
        do {
            read = try connection.read(refresh: refresh)
        } catch let problem as GameProblem {
            return .object(dropping: [("fm", .string(problem == .notRunning ? "not running" : problem == .noSave ? "no save loaded"
                                                     : problem == .withoutStarship ? "running without FM Starship" : "unreadable")),
                                      ("what_to_do", .string(problem.sentence))] + settings(currencyKnown: false))
        } catch {
            return .object(dropping: [("fm", "unreadable"), ("what_to_do", .string("\(error)"))] + settings(currencyKnown: false))
        }
        let db = read.database
        let context = CallContext(read: read, visibility: visibility, toolbox: self)
        let clubs: [JSON] = context.humanClubs.map { club in
            let manager = club.manager == 0 ? nil : db.staff.first { $0.block == club.manager }
            let budget = db.budgets[club.team]
            return .object(dropping: [
                ("name", .string(club.name)),
                ("manager", manager.map { .string($0.name) }),
                ("transfer_budget", budget.flatMap { Output.text(Units.moneyText(Double($0.transfer))) }),
                ("wage_room", budget.flatMap { Output.text(Units.wageText($0.wageRoom, withSuffix: true)) }),
                ("tactic", .string(db.tactics[club.team].map { "found: \($0.shape(in: FMData.library))" }
                                   ?? "not found, so squad_overview can't answer")),
            ])
        }
        let rules: String = read.engine == nil
            ? "off: FM Starship hasn't been checked on this build of FM, so season stats, form, who'd join, role stars, injury days and home-grown status are switched off rather than guessed"
            : "on"
        let age = connection.readAt.map { Int(Date().timeIntervalSince($0).rounded()) }
        let next = context.humanClubs.first.flatMap { nextFixture(read, club: $0, today: db.gameDate) }
        return .object(dropping: [
            ("fm", "running with FM Starship"),
            ("build", Output.text(db.build)),
            ("game_date", db.gameDate.map { .string(Output.iso($0)) }),
            ("clubs", .array(clubs)),
            ("club_used", context.humanClubs.first.map { .string($0.name) }),
            (next?.0 ?? "next_fixture", next?.1),
            ("players", .int(db.players.count)),
            ("staff", .int(db.staff.count)),
            ("read_seconds_ago", age.map { .int($0) }),
            ("rules", .string(rules)),
            ("player_state", Self.stateStatus(db, read.engine, read.bookings)),
            ("self_checks", db.checkProblems.map { .string("failed: \($0)") }),
        ] + settings(currencyKnown: true))
    }

    // MARK: Shortlists

    private func shortlists(_ args: Arguments) throws -> JSON {
        let kind = try args.choice("kind", ["players", "staff"])
        let roots = shortlistRoots()
        var entries: [ShortlistEntry] = []
        if kind != "staff" { entries += ShortlistFile.list(isStaff: false, roots: roots) }
        if kind != "players" { entries += ShortlistFile.list(isStaff: true, roots: roots) }
        let lists: [JSON] = entries.sorted { $0.modified > $1.modified }.map { entry in
            ["name": .string(entry.shortlist.name), "kind": .string(entry.shortlist.isStaff ? "staff" : "players"),
             "people": .int(entry.shortlist.uids.count), "changed": .string(Output.iso(entry.modified))]
        }
        return .object([("shortlists", .array(lists))]
                       + (lists.isEmpty ? [("note", "No shortlists found in FM's own folder.")] : []))
    }
}
