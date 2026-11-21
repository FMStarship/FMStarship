import Foundation

public enum ReadError: Error, CustomStringConvertible {
    case classesNotFound(String)
    case noPlayers

    public var description: String {
        switch self {
        case .classesNotFound(let names): return "This FM version keeps its data differently (\(names) not found). FM Starship needs an update."
        case .noPlayers: return "No players found. Is a save loaded?"
        }
    }
}

/// Reads every person in the game. Port of FM Moleman's GameReader onto the Mac layout: one
/// parallel sweep of the heap finds the records, then names and clubs are resolved.
public final class GameReader {
    private final class Pending {
        let person: Person
        var full: Int64 = 0, first: Int64 = 0, second: Int64 = 0, common: Int64 = 0, nation: Int64 = 0
        var contract: Int64 = 0, currentTeam: Int64 = 0, injuryList: Int64 = 0
        var identity: Int64 = 0
        /// A player who also has a staff record: where its staff part is, and the contract's job.
        var staffPart: Int64 = 0
        var job: UInt8 = 0
        var stale = false
        var state = RawState()
        /// Its contract pointer leads nowhere readable: a leftover copy, left out, and no vote on whether its region is dead.
        var unreadable = false
        init(_ person: Person) { self.person = person }
    }

    /// A player's state as stored, before the self-checks say whether it can be used.
    struct RawState {
        var condition = 0, sharpness = 0
        var fitnessDay = 0, fitnessYear = 0
        var morale = 0
        /// Nil without a contract.
        var playingTime: Int?
        /// False where the record holding them wasn't read, as for a free agent.
        var bansRead = false
        /// The list of bans isn't one: an offset has moved.
        var bansMalformed = false
        var bans: [StoredBan] = []
    }

    private struct ScanPart {
        var people: [(Int64, Pending)] = []
        var humans: [Int64] = []
        var currencies: [Int64] = []
        var teams: [(index: UInt32, type: Int, address: Int64)] = []
        var transferManagers: [Int64] = []
        var managers: [Int64] = []
        var tacticSessions: [Int64] = []
        var tacticArrays: [Int64] = []
        var loanContracts: [Int64] = []
    }

    private struct Club {
        var short = "", full = "", league = "", nation = "", nationCode = ""
        var object: Int64 = 0
        var womens = false
        var region = ""
        var area: Int64 = 0
    }

    /// Thread-safe memo for values shared by many people (names, clubs).
    private final class Memo<Value> {
        private var values: [Int64: Value] = [:]
        private let lock = NSLock()
        func value(_ key: Int64, _ make: () -> Value) -> Value {
            lock.lock()
            if let found = values[key] { lock.unlock(); return found }
            lock.unlock()
            let made = make()
            lock.lock()
            values[key] = made
            lock.unlock()
            return made
        }
        var all: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return Array(values.values)
        }
        var keys: [Int64] {
            lock.lock()
            defer { lock.unlock() }
            return Array(values.keys)
        }
    }

    private let game: GameProcess
    private let status: (String) -> Void
    private let names = Memo<String>()
    private let nations = Memo<String>()
    private let continents = Memo<String>()
    private let clubs = Memo<Club>()
    private let injuryNames = Memo<String>()
    private var teamTypes: [Int64: Int] = [:]
    private let clock: ReadClock
    /// Runs before the staff parts of players are read, so a test can change a contract between its two reads, as FM can.
    var beforeStaffViews: () -> Void = {}

    public init(game: GameProcess, status: @escaping (String) -> Void) {
        self.game = game
        self.status = status
        clock = ReadClock(game)
    }

    public static func read(status: @escaping (String) -> Void) throws -> Database {
        try GameReader(game: GameProcess(), status: status).readAll()
    }

    /// Role stars are seen through a member of staff: the assistant manager, else the best judge at the club.
    private static func roleViewer(for club: String, in database: Database) -> Staff? {
        let board: Set<String> = ["Chairperson", "President", "Director", "Owner", "Managing Director"]
        let judge = "Judging Player Ability"
        let staff = database.staff.filter { $0.clubFull == club }
        return staff.first { $0.job == "Assistant Manager" }
            ?? staff.max { $0.a(judge) < $1.a(judge) }
            ?? database.staff.filter { !board.contains($0.job) }.max { $0.a(judge) < $1.a(judge) }
    }

    /// Reads the game and sets up its rules. A nil engine leaves those features switched off.
    /// Inside FM, as the plugin, straight from memory; from the app, through the agent.
    /// `log` is told how long each part took.
    public static func connect(status: @escaping (String) -> Void, log: (String) -> Void = { _ in }) throws -> (database: Database, engine: RulesEngine?) {
        try connect(to: GameProcess.runsInsideGame ? GameProcess.insideGame() : GameProcess(), status: status, log: log)
    }

    public static func connect(to game: GameProcess, status: @escaping (String) -> Void,
                               log: (String) -> Void = { _ in }) throws -> (database: Database, engine: RulesEngine?) {
        let reader = GameReader(game: game, status: status)
        let database = try reader.readAll()
        // A read that fails only leaves a hole, so FM closing part way through has to be caught here.
        guard GameProcess.runningPID() == game.pid else { throw AgentError.connectionLost }
        status("Setting up the game's rules...")
        let engine = RulesEngine(game: game, rtti: Rtti(game))
        engine?.womensTeams = database.womensTeams
        for human in database.humanClubs {
            engine?.managers[human.team] = human.manager
            engine?.viewers[human.team] = roleViewer(for: human.name, in: database)?.block
        }
        if let engine {
            for (team, tactic) in database.tactics {
                database.tactics[team]?.fmShape = engine.shapeName(tactic.slots.map { ($0.position, $0.side) })
                database.tactics[team]?.fmShapeWithoutBall = engine.shapeName(tactic.slots.map { ($0.positionWithoutBall, $0.sideWithoutBall) })
            }
        }
        reader.clock.lap("engine set-up")
        log("Read \(database.players.count) players and \(database.staff.count) staff: \(reader.clock.line)")
        return (database, engine)
    }

    public func readAll() throws -> Database {
        status("Finding the game's data...")
        let rtti = Rtti(game)
        func vt(_ name: String) -> Int64 {
            guard let table = rtti.vtables(name).first(where: { $0.offsetToTop == 0 }) else { return 0 }
            return game.pluginBase + Int64(table.addressPoint)
        }
        let playerVt = vt("ACTUAL_PLAYER"), staffVt = vt("ACTUAL_NON_PLAYER")
        let humanVt = vt("CLUB_HUMAN_MANAGER_DETAILS"), currencyVt = vt("CURRENCY_RECORD"), teamVt = vt("TEAM")
        let transferManagerVt = vt("TRANSFER_MANAGER"), humanManagerVt = vt("HUMAN_NON_PLAYER")
        let tacticSessionVt = vt("TACTIC_EDIT_SESSION"), tacticArrayVt = vt("PREPARED_TACTICS_CREATOR_ARRAY")
        let loanContractVt = vt("LOAN_CONTRACT"), bTeamContractVt = vt("B_CLUB_CONTRACT")
        // Players FM has also given a staff record. Without them the read only misses those people, so it isn't required.
        let playerCoachVt = vt("ACTUAL_PLAYER_AND_NON_PLAYER")
        guard playerVt != 0, staffVt != 0 else { throw ReadError.classesNotFound("players or staff") }
        clock.lap("classes")
        // All of these lie in game_plugin, so one unsigned comparison against their range rules out nearly every word.
        let found = [playerVt, staffVt, playerCoachVt, humanVt, currencyVt, teamVt, transferManagerVt, humanManagerVt,
                     tacticSessionVt, tacticArrayVt, loanContractVt, bTeamContractVt].filter { $0 != 0 }
        let lowestVt = found.min() ?? 0, vtSpan = UInt64(bitPattern: (found.max() ?? 0) &- lowestVt)

        let pieces = game.pieces(size: 1 << 23, overlap: 0x400, writableOnly: true)
        var parts = [ScanPart?](repeating: nil, count: pieces.count)
        let total = max(1, pieces.reduce(Int64(0)) { $0 + Int64($1.count) })
        let lock = NSLock()
        var scanned: Int64 = 0

        parts.withUnsafeMutableBufferPointer { output in
            let slots = UncheckedSendablePointer(output)
            DispatchQueue.concurrentPerform(iterations: pieces.count) { i in
                let (address, count) = pieces[i]
                // A piece lies in one region, so this holds for all of it.
                let people = !game.inSmallHeap(address)
                let swept: ScanPart? = game.withBytes(address, count: count) { raw in
                    var part = ScanPart()
                    var o = Int((8 - address % 8) % 8)
                    while o + 8 <= count {
                        let word = raw.loadUnaligned(fromByteOffset: o, as: Int64.self)
                        if UInt64(bitPattern: word &- lowestVt) > vtSpan { o += 8; continue }
                        let at = address + Int64(o)
                        if word == playerVt, people {
                            if let record = record(raw, o, count, at, MacLayout.Player.size) {
                                part.people.append((at, parsePlayer(record, at)))
                            }
                        } else if word == staffVt, people {
                            if let record = record(raw, o, count, at, MacLayout.Staff.size),
                               let staff = parseStaff(record, at) {
                                part.people.append((at, staff))
                            }
                        } else if word == playerCoachVt, playerCoachVt != 0, people {
                            typealias L = MacLayout.PlayerCoach
                            if let record = record(raw, o, count, at, L.size) {
                                let item = parsePlayer(record, at, person: L.person, identity: L.identity)
                                item.staffPart = at &+ Int64(L.staff)
                                part.people.append((at, item))
                            }
                        } else if word == humanVt, humanVt != 0 {
                            part.humans.append(at)
                        } else if word == currencyVt, currencyVt != 0 {
                            part.currencies.append(at)
                        } else if word == humanManagerVt, humanManagerVt != 0 {
                            part.managers.append(at)
                        } else if word == transferManagerVt, transferManagerVt != 0 {
                            part.transferManagers.append(at)
                        } else if word == tacticSessionVt, tacticSessionVt != 0 {
                            part.tacticSessions.append(at)
                        } else if word == tacticArrayVt, tacticArrayVt != 0 {
                            part.tacticArrays.append(at)
                        } else if word == loanContractVt || word == bTeamContractVt, word != 0 {
                            part.loanContracts.append(at)
                        } else if word == teamVt, teamVt != 0, o + 48 <= count {
                            let index = raw.loadUnaligned(fromByteOffset: o + MacLayout.Team.index, as: UInt32.self)
                            part.teams.append((index, Int(raw[o + MacLayout.Team.type]), at))
                        }
                        o += 8
                    }
                    return part
                }
                guard let part = swept else { return }
                slots.value[i] = part
                lock.lock()
                let before = scanned
                scanned += Int64(count)
                if before >> 30 != scanned >> 30 { status("Reading your save... \(scanned * 100 / total)%") }
                lock.unlock()
            }
        }

        var seen = Set<Int64>()
        var pending: [Pending] = []
        var humans = Set<Int64>(), currencies = Set<Int64>(), managers = Set<Int64>()
        var teamIndex: [UInt32: Int] = [:]
        var transferManagers: [Int64] = []
        var tacticSessions = Set<Int64>(), tacticArrays = Set<Int64>(), loanContracts = Set<Int64>()
        for part in parts.compactMap({ $0 }) {
            transferManagers += part.transferManagers
            tacticSessions.formUnion(part.tacticSessions)
            tacticArrays.formUnion(part.tacticArrays)
            loanContracts.formUnion(part.loanContracts)
            for (address, person) in part.people where seen.insert(address).inserted { pending.append(person) }
            humans.formUnion(part.humans)
            managers.formUnion(part.managers)
            currencies.formUnion(part.currencies)
            for team in part.teams {
                teamIndex[team.index] = team.type
                teamTypes[team.address] = team.type
            }
        }
        clock.lap("sweep")
        guard !pending.isEmpty else { throw ReadError.noPlayers }

        status("Reading names and clubs for \(pending.count.formatted()) people...")
        DispatchQueue.concurrentPerform(iterations: pending.count) { resolve(pending[$0]) }
        pending = GameReader.liveRecords(pending)
        // After `liveRecords`, so they count once in its regions and stay out of its free agents.
        pending += staffViews(pending)
        clock.lap("resolve")
        applyLoans(pending, contracts: loanContracts.sorted(), bTeamContract: bTeamContractVt)

        for item in pending where !item.person.club.isEmpty && !(item.person is Staff) && item.person.squad.isEmpty {
            let index = item.person.teamIndex & 0x7f_ffff
            item.person.squad = Names.squadName(index == 0x7f_ffff ? 0 : teamIndex[index] ?? 0)
        }

        status("Naming regions...")
        var areaNames: [Int64: String] = [:]
        for club in clubs.all where club.area != 0 && areaNames[club.area] == nil {
            if let name = Names.areaAnchorCodes[club.nationCode] { areaNames[club.area] = name }
        }
        for item in pending where item.person.areaRecord != 0 {
            item.person.area = areaNames[item.person.areaRecord] ?? item.person.clubNation
        }

        let database = Database()
        database.build = (try? buildName()) ?? ""
        database.readAt = Date()
        database.gameDate = transferManagers.compactMap(readGameDate).max()
        database.dateRecords = transferManagers.sorted()
        database.nationRecords = nations.keys.sorted()
        readCurrencies(currencies.sorted(), into: database)
        readHumans(humans.sorted(), managers: managers.sorted(), into: database)
        separateSides(pending.map(\.person), in: database)
        if let today = database.gameDate { applyInjuries(pending, today: today) }
        readTactics(sessions: tacticSessions.sorted(), arrays: tacticArrays.sorted(), people: pending.map(\.person), into: database)
        clock.lap("loans, humans, tactics")
        applyState(pending, today: database.gameDate, into: database)
        clock.lap("player state")

        status("Applying the game's rules...")
        for person in pending.map(\.person) {
            if person.index == .max || (person.name.trimmingCharacters(in: .whitespaces).isEmpty && person.fullName.isEmpty) {
                database.unnamed += 1
                continue
            }
            if let date = database.gameDate, let birth = person.birth,
               let now = GameDate.calendar.dateComponents([.year], from: date).year,
               let born = GameDate.calendar.dateComponents([.year], from: birth).year,
               let dayNow = GameDate.calendar.ordinality(of: .day, in: .year, for: date),
               let dayBorn = GameDate.calendar.ordinality(of: .day, in: .year, for: birth) {
                person.age = now - born - (dayNow < dayBorn ? 1 : 0)
            }
            if let player = person as? Player {
                Rules.apply(player, determination: player.a("Determination"), leadership: player.a("Leadership"))
                database.players.append(player)
            } else if let staff = person as? Staff {
                Rules.apply(staff, determination: staff.a("Determination"), leadership: nil)
                Rules.coachStars(staff)
                database.staff.append(staff)
            }
        }
        status("Self-checks...")
        database.prepare()
        database.checks = GameReader.selfCheck(database)
        clock.lap("post-processing")
        return database
    }

    /// A whole record: from this buffer when it fits, else read separately.
    private func record(_ raw: UnsafeRawBufferPointer, _ offset: Int, _ count: Int, _ address: Int64, _ size: Int) -> [UInt8]? {
        offset + size <= count ? Array(raw[offset..<offset + size]) : game.read(address, count: size)
    }

    private func buildName() throws -> String {
        let info = URL(fileURLWithPath: game.pluginPath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any]
        return "Football Manager 27 " + (plist?["CFBundleShortVersionString"] as? String ?? "")
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    private static func i16(_ b: [UInt8], _ o: Int) -> Int { Int(Int16(truncatingIfNeeded: u16(b, o))) }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    private static func i64(_ b: [UInt8], _ o: Int) -> Int64 {
        b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int64.self) }
    }

    /// Stored PA: positive is exact; negative is FM's "range" encoding.
    static func potential(_ raw: Int) -> Int {
        if raw >= 0 { return raw }
        let band = -raw < 15 ? Double(-raw) : Double(-raw) / 10.0
        return Int(min(200, max(1, (20.0 * band - 15.0).rounded())))
    }

    static func to20(_ value: UInt8) -> UInt8 { value == 0 ? 0 : UInt8(max(1, Int(Double(value) / 5.0 + 0.5))) }

    private func applyPerson(_ b: [UInt8], _ person: Person, _ item: Pending, person base: Int, identity: Int) {
        typealias P = MacLayout.Person
        typealias I = MacLayout.Identity
        item.identity = person.block + Int64(identity)
        person.index = GameReader.u32(b, identity + I.index)
        person.uid = GameReader.u32(b, identity + I.uid)
        person.flags = b[identity + I.flags]
        person.isWoman = b[identity + I.sex] & I.woman != 0
        person.birthDay = GameReader.u16(b, base + P.birthDay)
        person.birthYear = GameReader.u16(b, base + P.birthYear)
        person.pers = Array(b[(base + P.personality)..<(base + P.personality + 8)])
        item.full = GameReader.i64(b, base + P.fullName)
        item.first = GameReader.i64(b, base + P.firstName)
        item.second = GameReader.i64(b, base + P.secondName)
        item.common = GameReader.i64(b, base + P.commonName)
        item.nation = GameReader.i64(b, base + P.nation)
        item.contract = GameReader.i64(b, base + P.contract)
    }

    /// A player who holds a staff job too, a player/manager or a player/coach, is also in the staff lists, read from the
    /// staff part of the same record. Those who only play don't count as staff, as FM doesn't offer them as staff.
    private func staffViews(_ live: [Pending]) -> [Pending] {
        beforeStaffViews()
        let coaches = live.filter { $0.staffPart != 0 && $0.job & 0xfe != 0 }
        let views: [Pending] = coaches.compactMap { item in
            guard let b = game.read(item.staffPart, count: MacLayout.Staff.size) else { return nil }
            return parseStaff(b, item.staffPart)
        }
        DispatchQueue.concurrentPerform(iterations: views.count) { resolve(views[$0]) }
        // A view whose contract couldn't be read again has no job, club or wage, so it's left out with the stale ones.
        // `job` is only set once the contract names this person as its owner.
        return views.filter { !$0.stale && $0.job & 0xfe != 0 }
    }

    private func parsePlayer(_ b: [UInt8], _ address: Int64,
                             person: Int = MacLayout.Player.person, identity: Int = MacLayout.Player.identity) -> Pending {
        typealias L = MacLayout.Player
        let a = L.attributes
        let player = Player()
        let item = Pending(player)
        player.block = address
        player.ca = GameReader.u16(b, a + L.ca)
        player.pa = GameReader.potential(GameReader.i16(b, a + L.pa))
        let value = GameReader.u32(b, a + L.value)
        player.value = value == .max ? 0 : Int64(value)
        player.pos = Array(b[(a + L.positions)..<(a + L.positions + 15)])
        player.raw = Array(b[(a + L.raw)..<(a + L.raw + 54)])
        player.height = GameReader.u16(b, a + L.height)
        player.topRoles = Array(b[(a + L.topRoles)..<(a + L.topRoles + 6)])
        player.traitBits = UInt64(bitPattern: GameReader.i64(b, person + MacLayout.Person.traits))
        applyPerson(b, player, item, person: person, identity: identity)
        item.currentTeam = GameReader.i64(b, L.currentTeam)
        item.injuryList = GameReader.i64(b, L.injuries)
        GameReader.storedState(b, into: &item.state)
        return item
    }

    /// Condition, sharpness, the day they were brought up to date and morale, from a whole player record.
    private static func storedState(_ b: [UInt8], into state: inout RawState) {
        typealias L = MacLayout.Player
        state.condition = i16(b, L.condition)
        state.sharpness = i16(b, L.sharpness)
        state.fitnessDay = u16(b, L.fitnessUpdated) & 0x1ff
        state.fitnessYear = u16(b, L.fitnessUpdated + 2)
        state.morale = Int(Int8(bitPattern: b[L.morale]))
    }

    private func parseStaff(_ b: [UInt8], _ address: Int64) -> Pending? {
        typealias L = MacLayout.Staff
        let staff = Staff()
        let item = Pending(staff)
        staff.block = address
        staff.ca = GameReader.u16(b, L.ca)
        staff.pa = GameReader.potential(GameReader.i16(b, L.pa))
        staff.repCurrent = GameReader.u16(b, L.repCurrent)
        staff.repHome = GameReader.u16(b, L.repHome)
        staff.repWorld = GameReader.u16(b, L.repWorld)
        for i in 0..<52 {
            let stored = b[L.attributes + i]
            // The first block is stored 1-20 already, the rest 1-100, and one mid-block value, Determination, is 1-100.
            // Counted from the first attribute, so the rule moves with `MacLayout.Staff.attributes`.
            staff.attr[i] = i >= 26 || i == 13 ? GameReader.to20(stored) : stored
        }
        applyPerson(b, staff, item, person: L.person, identity: L.identity)
        guard staff.index != 0 || staff.uid != 0, staff.index < 10_000_000 else { return nil }
        return item
    }

    private func name(_ address: Int64) -> String {
        address == 0 ? "" : names.value(address) { game.nameEntry(address) }
    }

    private func nationName(_ address: Int64) -> String {
        address == 0 ? "" : nations.value(address) {
            game.lengthPrefixedString(game.readPointer(address &+ Int64(MacLayout.Nation.name)))
        }
    }

    private func continentName(_ nation: Int64) -> String {
        nation == 0 ? "" : continents.value(nation) {
            let continent = game.readPointer(nation &+ Int64(MacLayout.Nation.continent))
            return continent == 0 ? "" : game.lengthPrefixedString(game.readPointer(continent &+ Int64(MacLayout.continentName)))
        }
    }

    private func club(_ team: Int64) -> Club {
        team == 0 ? Club() : clubs.value(team) {
            typealias T = MacLayout.Team
            typealias C = MacLayout.Club
            // `team` and everything read from it can be anything on a leftover record, so offsets go on with &+.
            let object = game.readPointer(team &+ Int64(T.club))
            let competition = game.readPointer(team &+ Int64(T.competition))
            guard object != 0 else { return Club() }
            let nation = game.readPointer(object &+ Int64(C.nation))
            var club = Club()
            club.short = game.lengthPrefixedString(game.readPointer(object &+ Int64(C.shortName)))
            club.full = game.lengthPrefixedString(game.readPointer(object &+ Int64(C.fullName)))
            if competition != 0 {
                club.league = game.lengthPrefixedString(game.readPointer(competition &+ Int64(MacLayout.competitionName)))
            }
            club.nation = nationName(nation)
            club.nationCode = nation == 0 ? "" : game.lengthPrefixedString(game.readPointer(nation &+ Int64(MacLayout.Nation.code)))
            club.object = object
            club.womens = game.read(object &+ Int64(C.womens), count: 1)?.first == 1
            club.region = continentName(nation)
            club.area = nation == 0 ? 0 : game.readPointer(nation &+ Int64(MacLayout.Nation.area))
            return club
        }
    }

    /// The head of a player's history record: the injuries' vector, then the bans', in one read.
    static let historyHead = MacLayout.History.bans + 24

    private func readInjuries(_ head: [UInt8]) -> [Injury]? {
        let begin = GameReader.i64(head, 0), end = GameReader.i64(head, 8)
        guard begin > 0, end > begin, end - begin <= 0x200 else { return nil }
        var result: [Injury] = []
        for slot in stride(from: begin, to: end, by: 8) {
            let record = game.readPointer(slot)
            guard record != 0, let b = game.read(record, count: 48) else { continue }
            let day = GameReader.u16(b, 32) & 0x1ff, year = GameReader.u16(b, 34)
            guard (1900...2200).contains(year), (1...366).contains(day) else { continue }
            let kind = GameReader.i64(b, 8)
            let injury = Injury()
            injury.record = record
            injury.name = kind == 0 ? "" : injuryNames.value(kind) {
                let text = game.lengthPrefixedString(game.readPointer(kind &+ 32))
                return text.prefix(1).uppercased() + text.dropFirst()
            }
            injury.date = GameDate.date(year: year, dayOfYear: day) ?? .distantPast
            injury.length = GameReader.i16(b, 40)
            result.append(injury)
        }
        return result.isEmpty ? nil : result
    }

    /// The bans in a player's history record, from its head, and whether their list isn't one. One read for each ban.
    static func readBans(_ head: [UInt8], in game: GameProcess) -> (malformed: Bool, bans: [StoredBan]) {
        typealias B = MacLayout.Ban
        let at = MacLayout.History.bans
        let begin = i64(head, at), end = i64(head, at + 8), capacity = i64(head, at + 16)
        if begin == 0, end == 0, capacity == 0 { return (false, []) }
        guard begin > 0, end >= begin, capacity >= end, (end - begin) % 8 == 0, end - begin <= 0x200 else { return (true, []) }
        var bans: [StoredBan] = []
        for slot in stride(from: begin, to: end, by: 8) {
            let entry = game.readPointer(slot)
            guard entry != 0, let b = game.read(entry, count: B.size) else { return (true, []) }
            var ban = StoredBan()
            ban.association = u32(b, B.association)
            ban.scope = Int(b[B.scope])
            ban.match = i64(b, B.match)
            ban.day = u16(b, B.day) & 0x1ff
            ban.year = u16(b, B.year)
            ban.kind = b[B.kind]
            ban.rules = u16(b, B.rules)
            ban.bookingsAt = Int(b[B.bookingsAt])
            ban.matches = Int(b[B.matches])
            ban.served = Int(b[B.served])
            bans.append(ban)
        }
        return (false, bans)
    }

    private func resolve(_ item: Pending) {
        typealias C = MacLayout.Contract
        let person = item.person
        person.fullName = item.full == 0 ? "" : game.lengthPrefixedString(item.full)
        person.firstName = name(item.first)
        person.secondName = name(item.second)
        person.commonName = name(item.common)
        person.nation = nationName(item.nation)
        guard item.contract != 0 else { return }
        // A live person's contract can always be read. One that can't, such as text where the pointer should be, is a
        // leftover copy: kept as contracted, it got past the dead-copy check below and gave three copies with uid 0. It
        // isn't counted as stale, since a few of them could then make a region with real free agents look dead.
        guard let b = game.read(item.contract, count: C.size) else {
            item.unreadable = true
            return
        }

        // FM can hold a second, dead copy of the world. Its records still point at the live contracts,
        // but a contract only names the live person as its owner.
        if GameReader.i64(b, C.owner) != item.identity {
            item.stale = true
            return
        }

        item.job = b[C.job]
        person.wage = Int(GameReader.u32(b, C.wage))
        person.teamIndex = GameReader.u32(b, C.teamIndex)
        person.statusFlags = b[C.statusFlags]
        person.listedDay = GameReader.u16(b, C.listedDay) & 0x1ff
        person.listedYear = GameReader.u16(b, C.listedYear)
        person.endDay = GameReader.u16(b, C.endDay)
        person.endYear = GameReader.u16(b, C.endYear)

        let begin = GameReader.i64(b, C.clausesBegin), end = GameReader.i64(b, C.clausesEnd)
        if begin != 0, end > begin, UInt64(bitPattern: end &- begin) <= 0x400, let clauses = game.read(begin, count: Int(end &- begin)) {
            for o in stride(from: 0, to: clauses.count - 7, by: 8) {
                let amount = Int64(GameReader.u32(clauses, o))
                guard amount != 0xffff_ffff else { continue }
                switch GameReader.u16(clauses, o + 6) {
                case 0: person.releaseClause = amount
                case 16: person.releaseForeign = amount
                case 18: person.releaseDomestic = amount
                default: break
                }
            }
        }

        var home = club(GameReader.i64(b, C.team))
        if home.full.isEmpty { home = club(GameReader.i64(b, C.fallbackTeam)) }
        person.club = home.short
        person.clubFull = home.full
        person.league = home.league
        person.clubNation = home.nation
        person.clubObject = home.object
        person.region = home.region
        person.areaRecord = home.area

        if let player = person as? Player {
            item.state.playingTime = Int(Int8(bitPattern: b[C.playingTime]))
            item.state.bansRead = true
            if item.injuryList != 0 {
                if let head = game.read(item.injuryList, count: GameReader.historyHead) {
                    player.injuries = readInjuries(head)
                    (item.state.bansMalformed, item.state.bans) = GameReader.readBans(head, in: game)
                } else {
                    item.state.bansMalformed = true
                }
            }
            if item.currentTeam != 0, let type = teamType(item.currentTeam) {
                let current = club(item.currentTeam)
                if current.object != 0, current.object != person.clubObject {
                    person.loanClub = current.short
                    person.loanClubFull = current.full
                    person.loanClubObject = current.object
                } else {
                    person.squad = Names.squadName(type)
                }
            }
        }
        if let staff = person as? Staff {
            // The lowest bit is "plays", which only a player's job has, so a player/manager's staff job is Manager.
            staff.job = Names.jobs[Int(b[C.job] & 0xfe)] ?? ""
            staff.secondJob = Int(b[C.secondJob])
            let team = GameReader.i64(b, C.fallbackTeam)
            if team != 0, !person.club.isEmpty, let type = game.read(team &+ Int64(MacLayout.Team.type), count: 1) {
                staff.squad = Names.squadName(Int(type[0]))
            }
        }
    }

    /// A loan has a contract of its own, which starts like the permanent one but names the club the player is at.
    /// So does a spell at the club's own B team, where FM keeps that team as a separate club (Spain, the MLS). FM can
    /// keep an old loan around, so only the latest for the club they're with now counts.
    private func applyLoans(_ pending: [Pending], contracts: [Int64], bTeamContract: Int64) {
        typealias C = MacLayout.Contract
        var onLoan: [Int64: Pending] = [:]
        for item in pending where !item.person.loanClub.isEmpty { onLoan[item.identity] = item }
        for contract in contracts {
            guard let b = game.read(contract, count: C.endYear + 2), let item = onLoan[GameReader.i64(b, C.owner)] else { continue }
            let club = item.person.loanClubObject
            guard self.club(GameReader.i64(b, C.team)).object == club || self.club(GameReader.i64(b, C.fallbackTeam)).object == club else { continue }
            if GameReader.i64(b, 0) == bTeamContract {
                item.person.isAtOwnBTeam = true
                continue
            }
            let year = GameReader.u16(b, C.endYear), day = GameReader.u16(b, C.endDay) & 0x1ff
            if (year, day) > (item.person.loanEndYear, item.person.loanEndDay) {
                item.person.loanEndYear = year
                item.person.loanEndDay = day
            }
        }
    }

    /// A player's current injury is the one with the longest time still to run.
    private func applyInjuries(_ pending: [Pending], today: Date) {
        for case let player as Player in pending.map(\.person) {
            for injury in player.injuries ?? [] where injury.length > 0 {
                guard let back = GameDate.calendar.date(byAdding: .day, value: injury.length - 1, to: injury.date) else { continue }
                let days = GameDate.calendar.dateComponents([.day], from: today, to: back).day ?? 0
                guard days > 0, player.injury == nil || days > player.injuryDays else { continue }
                player.injury = injury
                player.injuryDays = days
                player.injuryText = injury.name
            }
        }
    }

    private func teamType(_ team: Int64) -> Int? { teamTypes[team] }

    /// Condition, sharpness, morale, playing time and bans, for the fields that pass their checks. Condition and
    /// sharpness are only kept when FM brought them up to date today: on any other day they're FM's for that day. Bans
    /// are kept as FM stores them: what they're for takes more reads, which `PlayerStateReader` makes when it's asked.
    private func applyState(_ pending: [Pending], today: Date?, into database: Database) {
        let players = pending.compactMap { item in (item.person as? Player).map { (player: $0, state: item.state) } }
        database.stateOff = GameReader.checkState(players.filter { $0.player.clubObject != 0 }.map(\.state))
        for (player, state) in players { GameReader.apply(state, to: player, today: today, in: database) }
    }

    private static func apply(_ state: RawState, to player: Player, today: Date?, in database: Database) {
        player.fitness = nil
        player.fitnessUpdated = nil
        player.fitnessNeedsCatchUp = false
        if database.stateIsOn(.fitness), let updated = GameDate.checked(year: state.fitnessYear, dayOfYear: state.fitnessDay) {
            if updated == today, Fitness.range.contains(state.condition), Fitness.range.contains(state.sharpness) {
                player.fitness = Fitness(condition: state.condition, sharpness: state.sharpness)
            } else if updated != today {
                player.fitnessUpdated = updated
                player.fitnessNeedsCatchUp = true
            }
        }
        player.morale = database.stateIsOn(.morale) && moraleRange.contains(state.morale) ? state.morale : nil
        player.playingTime = database.stateIsOn(.playingTime) ? state.playingTime.flatMap { playingTimeRange.contains($0) ? $0 : nil } : nil
        player.storedBans = database.stateIsOn(.bans) && state.bansRead && !state.bansMalformed
            ? state.bans.filter { $0.isReal && $0.left > 0 } : nil
    }

    /// A player's state as FM's memory holds it now, for an answer about him: FM can play a match and change it without
    /// the game date moving, so a read of the whole save can be out of date. The whole read's checks still decide which
    /// fields are on. A few reads, and one for each ban. Nothing changes when his record is no longer his.
    public static func refreshState(_ player: Player, in database: Database, game: GameProcess) {
        typealias L = MacLayout.Player
        guard player.block > 0, let b = game.read(player.block, count: L.size),
              u32(b, L.identity + MacLayout.Identity.uid) == player.uid else { return }
        var state = RawState()
        storedState(b, into: &state)
        let contract = i64(b, L.person + MacLayout.Person.contract)
        if contract > 0, let owner = game.read(contract &+ Int64(MacLayout.Contract.owner), count: 8),
           i64(owner, 0) == player.block + Int64(L.identity), let byte = game.read(contract &+ Int64(MacLayout.Contract.playingTime), count: 1) {
            state.playingTime = Int(Int8(bitPattern: byte[0]))
            state.bansRead = true
            let history = i64(b, L.injuries)
            if history > 0 {
                if let head = game.read(history, count: historyHead) {
                    (state.bansMalformed, state.bans) = readBans(head, in: game)
                } else {
                    state.bansMalformed = true
                }
            }
        }
        apply(state, to: player, today: database.gameDate, in: database)
    }

    /// FM's getters have nothing to catch up for a player brought up to date today, so they must give the stored values.
    /// A sample of those is asked, which checks the getters' slots and the stored offsets together: if any differ, or a
    /// getter doesn't answer, condition and sharpness are off for the read. Nil when there's nothing to say.
    @discardableResult
    public static func checkFitnessGetters(_ database: Database, engine: GameRulesEngine, sample: Int = 50) -> String? {
        guard database.stateIsOn(.fitness) else { return nil }
        let today = database.players.filter { $0.fitness != nil }.prefix(sample)
        let wrong = today.filter { $0.fitness != engine.fitness(player: $0) }.count
        guard wrong > 0 else { return nil }
        let reason = "its check failed: FM's own getters gave other values than FM stored for \(wrong) of \(today.count) players brought up to date today"
        database.stateOff[.fitness] = reason
        for player in database.players {
            player.fitness = nil
            player.fitnessUpdated = nil
            player.fitnessNeedsCatchUp = false
        }
        return reason
    }

    /// A read this big always has bans.
    static let bigSave = 10_000
    static let moraleRange = 1...20
    static let playingTimeRange = -100...100

    /// Each field is off when more than one player in a hundred at a club has a value it can't have, or when a big save
    /// has only one value for it, which is a moved offset's zeroes.
    static func checkState(_ states: [RawState]) -> [PlayerStateField: String] {
        var off: [PlayerStateField: String] = [:]
        func failed(_ bad: Int, of count: Int, _ what: String) -> String? {
            bad * 100 > count ? "its check failed: \(bad.formatted()) of \(count.formatted()) players at a club have \(what)" : nil
        }
        func same<T: Hashable>(_ values: [T]) -> Bool { values.count >= 100 && Set(values).count == 1 }
        let sameText = "its check failed: every player at a club has the same value"

        let fitnessBad = states.filter { state in
            !Fitness.range.contains(state.condition) || !Fitness.range.contains(state.sharpness)
                || GameDate.checked(year: state.fitnessYear, dayOfYear: state.fitnessDay) == nil
        }.count
        off[.fitness] = failed(fitnessBad, of: states.count, "a condition or sharpness outside 0-10000, or no real date for them")
            ?? (same(states.map(\.condition)) && same(states.map(\.sharpness)) ? sameText : nil)

        off[.morale] = failed(states.filter { !moraleRange.contains($0.morale) }.count, of: states.count, "a morale outside 1-20")
            ?? (same(states.map(\.morale)) ? sameText : nil)

        let playingTimes = states.compactMap(\.playingTime)
        off[.playingTime] = failed(playingTimes.filter { !playingTimeRange.contains($0) }.count, of: playingTimes.count,
                                   "a playing time happiness outside −100 to 100")
            ?? (same(playingTimes) ? sameText : nil)

        let read = states.filter(\.bansRead)
        let bans = read.flatMap(\.bans)
        let badBans = bans.filter { !$0.isReal }.count
        if let malformed = failed(read.filter(\.bansMalformed).count, of: read.count, "a list of bans that isn't one") {
            off[.bans] = malformed
        } else if badBans * 10 > bans.count {
            off[.bans] = "its check failed: \(badBans.formatted()) of \(bans.count.formatted()) bans have no real date or length"
        } else if read.count >= bigSave, !bans.contains(where: \.isReal) {
            // Unserved old bans pile up, so a real save always has some. None at all is an offset on empty lists.
            off[.bans] = "its check failed: none of \(read.count.formatted()) players at a club has a ban"
        }
        return off
    }

    /// Regions holding a dead copy of the world: most of their contracts name someone else as the owner.
    static func deadRegions(confirmed: [Int64: Int], stale: [Int64: Int]) -> Set<Int64> {
        Set(stale.filter { $0.value > confirmed[$0.key] ?? 0 }.keys)
    }

    /// Drops dead copies. Free agents have no contract to ask, so for those keep one record per person,
    /// from the region that holds the most confirmed records, and none from a dead region. One found only there
    /// is someone FM no longer has: its pointers lead into freed memory, where FM's rules can loop for ever.
    private static func liveRecords(_ pending: [Pending]) -> [Pending] {
        let live = pending.filter { !$0.stale && !$0.unreadable }
        var confirmed: [Int64: Int] = [:], stale: [Int64: Int] = [:]
        for item in pending where item.contract != 0 && !item.unreadable {
            if item.stale { stale[item.person.block >> 32, default: 0] += 1 } else { confirmed[item.person.block >> 32, default: 0] += 1 }
        }
        let dead = deadRegions(confirmed: confirmed, stale: stale)
        var best: [UInt32: Pending] = [:]
        var result: [Pending] = []
        for item in live {
            if item.contract != 0 { result.append(item); continue }
            guard !dead.contains(item.person.block >> 32) else { continue }
            let uid = item.person.uid
            if let other = best[uid] {
                let mine = confirmed[item.person.block >> 32] ?? 0, theirs = confirmed[other.person.block >> 32] ?? 0
                if mine > theirs { best[uid] = item }
            } else {
                best[uid] = item
            }
        }
        let contracted = Set(result.map(\.person.uid))
        result += best.values.filter { !contracted.contains($0.person.uid) }
        return result
    }

    private func readGameDate(_ transferManager: Int64) -> Date? { GameReader.gameDate(transferManager, in: game) }

    private static func gameDate(_ transferManager: Int64, in game: GameProcess) -> Date? {
        guard transferManager != 0, let b = game.read(transferManager + Int64(MacLayout.gameDate), count: 4) else { return nil }
        return GameDate.checked(year: GameReader.u16(b, 2), dayOfYear: GameReader.u16(b, 0))
    }

    /// The game date as the game's memory holds it now, read where `database` found it: two small reads, where reading
    /// again takes seconds. Nil once that memory holds no date, as when FM has let go of the save that was read.
    public static func gameDate(of database: Database, in game: GameProcess) -> Date? {
        database.dateRecords.compactMap { gameDate($0, in: game) }.max()
    }

    /// The clubs run by human managers, and their budgets.
    private func readHumans(_ details: [Int64], managers: [Int64], into database: Database) {
        typealias F = MacLayout.Finance
        for detail in details {
            let team = game.readPointer(detail + Int64(MacLayout.Human.team))
            guard team != 0, !database.humanClubs.contains(where: { $0.team == team }) else { continue }
            let club = game.readPointer(team &+ Int64(MacLayout.Team.club))
            guard club != 0 else { continue }
            let name = game.lengthPrefixedString(game.readPointer(club &+ Int64(MacLayout.Club.fullName)))
            // The manager whose contract is with this team. Keeps the part pointer FM's rules expect.
            let manager = managers.first { object in
                let contract = game.readPointer(object + Int64(MacLayout.Human.managerPerson + MacLayout.Person.contract))
                guard contract != 0 else { return false }
                return game.readPointer(contract &+ Int64(MacLayout.Contract.team)) == team
                    || game.readPointer(contract &+ Int64(MacLayout.Contract.fallbackTeam)) == team
            } ?? (managers.count == 1 ? managers[0] : 0)
            database.humanClubs.append((team, name, manager))
            let finance = game.readPointer(club &+ Int64(F.clubOffset))
            guard finance != 0, let record = game.read(finance, count: F.wageSpent + 4) else { continue }
            database.budgets[team] = GameReader.budget(record)
        }
    }

    /// The full name of a team's club as the game's memory holds it now, or "" if there's none there. FM Starship inside
    /// FM uses it to notice FM loading another save: once FM has let go of the save that was read, the team the read
    /// found is gone from that address, or something else is there.
    public static func clubName(team: Int64, in game: GameProcess) -> String {
        // Once FM has let the save go, whatever is at `team` now can be anything, so offsets go on with &+.
        let club = game.readPointer(team &+ Int64(MacLayout.Team.club))
        return club == 0 ? "" : game.lengthPrefixedString(game.readPointer(club &+ Int64(MacLayout.Club.fullName)))
    }

    /// What a club has left to spend, from the start of its CLUB_FINANCE record.
    static func budget(_ finance: [UInt8]) -> (transfer: Int64, wageRoom: Int) {
        typealias F = MacLayout.Finance
        let transfer = Int64(Int32(bitPattern: GameReader.u32(finance, F.transferBudget)))
        let wageRoom = Int(Int32(bitPattern: GameReader.u32(finance, F.wageRoom))) - Int(Int32(bitPattern: GameReader.u32(finance, F.wageSpent)))
        return (transfer, max(0, wageRoom))
    }

    /// FM keeps a club's men and women as two clubs, usually with one name, and everything here tells clubs apart by
    /// name. So where the two clash, the women's side gets a name of its own, and a club's squad stays its own.
    private func separateSides(_ people: [Person], in database: Database) {
        let known = clubs.all
        guard GameReader.sidesAgree(people, womensClubs: Set(known.filter(\.womens).map(\.object))) else {
            people.forEach { $0.isWoman = false }
            return
        }
        database.knowsSides = true
        let mens = known.filter { !$0.womens }
        let names = Set(mens.map(\.full) + mens.map(\.short)).subtracting([""])
        let clashing = Set(known.filter { $0.womens && (names.contains($0.full) || names.contains($0.short)) }.map(\.object))
        for person in people {
            if clashing.contains(person.clubObject) {
                person.club += GameReader.womensSuffix
                person.clubFull += GameReader.womensSuffix
            }
            if clashing.contains(person.loanClubObject) {
                person.loanClub += GameReader.womensSuffix
                person.loanClubFull += GameReader.womensSuffix
            }
        }
        for index in database.humanClubs.indices {
            let club = club(database.humanClubs[index].team)
            guard club.womens else { continue }
            database.womensTeams.insert(database.humanClubs[index].team)
            if clashing.contains(club.object) { database.humanClubs[index].name += GameReader.womensSuffix }
        }
    }

    private static let womensSuffix = " Women"

    /// Men play for men's clubs and women for women's, so if the people and the clubs disagree, the offsets have moved.
    /// One odd record shouldn't switch this off, so it takes more than that.
    static func sidesAgree(_ people: [Person], womensClubs: Set<Int64>) -> Bool {
        let placed = people.filter { $0 is Player && $0.clubObject != 0 }
        return placed.filter { $0.isWoman != womensClubs.contains($0.clubObject) }.count * 1000 <= placed.count
    }

    /// The eleven each human has picked. The tactics screen's own arrays come first: the others are
    /// copies made for matches, and can be older.
    private func readTactics(sessions: [Int64], arrays: [Int64], people: [Person], into database: Database) {
        typealias T = MacLayout.Tactic
        var byIndex: [UInt32: Player] = [:]
        for case let player as Player in people { byIndex[player.index] = player }

        let edited = sessions.filter { game.readPointer($0 + Int64(T.sessionOwner)) != 0 }
            .flatMap { session in T.sessionArrays.map { session + $0 } }
        let candidates = edited + arrays.filter { !edited.contains($0) }
        for human in database.humanClubs {
            let tactic = candidates.lazy.compactMap { GameReader.tactic(at: $0, in: self.game, players: byIndex) }.first { tactic in
                tactic.slots.filter { $0.player?.clubFull == human.name || $0.player?.loanClub == human.name }.count >= 9
            }
            if let tactic { database.tactics[human.team] = tactic }
        }
    }

    /// A PREPARED_TACTICS_CREATOR_ARRAY's eleven, with their places and roles, and its bench. Nil when its creator's places
    /// don't read as a tactic, as for a dead copy. Pointers read from memory are only added to with &+, so a bad one can't trap.
    static func tactic(at array: Int64, in game: GameProcess, players: [UInt32: Player]) -> Tactic? {
        typealias T = MacLayout.Tactic
        let creator = game.readPointer(game.readPointer(array &+ T.arrayCreators))
        guard creator != 0, let ids = game.read(array &+ T.arrayPlayers, count: T.places * 4),
              let withBall = game.read(creator &+ T.withBall, count: T.slots * Int(T.slotSize)),
              let withoutBall = game.read(creator &+ T.withoutBall, count: T.slots * Int(T.slotSize)) else { return nil }
        func id(_ slot: Int) -> UInt32? {
            let id = ids.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: slot * 4, as: UInt32.self) }
            return id == T.empty ? nil : id
        }

        func place(_ bytes: [UInt8], _ slot: Int) -> (position: Int, side: TacticSlot.Side, role: Int)? {
            let at = slot * Int(T.slotSize)
            let word = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt64.self) }
            let roles = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at + T.slotRole, as: UInt64.self) } & ~T.notRoles
            let bits = word & 0x7fff
            guard bits.nonzeroBitCount == 1, roles.nonzeroBitCount == 1,
                  let position = Names.posToGame.firstIndex(of: bits.trailingZeroBitCount) else { return nil }
            let side: TacticSlot.Side = word & T.left != 0 ? .left : word & T.right != 0 ? .right : .centre
            return (position, side, roles.trailingZeroBitCount)
        }

        var slots: [TacticSlot] = []
        for slot in 0..<T.slots {
            guard let with = place(withBall, slot), let without = place(withoutBall, slot) else { return nil }
            let index = id(slot)
            slots.append(TacticSlot(player: index.flatMap { players[$0] }, position: with.position, positionWithoutBall: without.position,
                                    side: with.side, sideWithoutBall: without.side, role: with.role, roleWithoutBall: without.role,
                                    index: index))
        }
        guard slots.first?.position == 0 else { return nil }
        let bench = (T.slots..<T.places).map { slot in id(slot).map { BenchPlace(index: $0, player: players[$0]) } }
        return Tactic(slots: slots, bench: bench, array: array)
    }

    private func readCurrencies(_ addresses: [Int64], into database: Database) {
        typealias C = MacLayout.Currency
        for address in addresses {
            guard let b = game.read(address, count: 64) else { continue }
            let name = game.lengthPrefixedString(GameReader.i64(b, C.name))
            let symbol = game.lengthPrefixedString(GameReader.i64(b, C.symbol))
            let rate = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: C.rate, as: Float.self) }
            guard !name.isEmpty, rate > 0, rate < 10_000_000 else { continue }
            guard !database.currencies.contains(where: { $0.name == name }) else { continue }
            let shown = symbol.isEmpty ? (name.split(separator: " ").last.map { "\($0) " } ?? "") : symbol
            database.currencies.append(Currency(name: name, symbol: shown, rate: Double(rate)))
        }
    }

    static func selfCheck(_ database: Database) -> String {
        var problems: [String] = []
        let players = database.players
        let named = players.filter { !$0.name.isEmpty && !$0.name.contains("\u{fffd}") }.count
        if players.count < 1000 { problems.append("only \(players.count) players") }
        if players.contains(where: { $0.pa < $0.ca || $0.pa > 200 }) { problems.append("PA below CA") }
        if Set(players.map(\.uid)).count != players.count { problems.append("duplicate players") }
        if Set(database.staff.map(\.uid)).count != database.staff.count { problems.append("duplicate staff") }
        if Double(named) < Double(players.count) * 0.95 { problems.append("names unreadable") }
        if Double(players.filter { !$0.club.isEmpty }.count) < Double(players.count) * 0.5 { problems.append("clubs missing") }
        return problems.isEmpty ? "PASS" : "FAIL: " + problems.joined(separator: ", ")
    }
}

/// concurrentPerform writes each slot from exactly one iteration.
private struct UncheckedSendablePointer<T>: @unchecked Sendable {
    let value: UnsafeMutableBufferPointer<T>
    init(_ value: UnsafeMutableBufferPointer<T>) { self.value = value }
}
