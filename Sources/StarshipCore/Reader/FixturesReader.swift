import Foundation

/// One goal from a result's list. FM marks each goal with a kind, but which kind is a penalty isn't known, so they're all
/// just goals here.
public struct MatchGoal: Sendable, Equatable {
    /// The scorer's `Person.index`.
    public var scorer: UInt32
    public var assist: UInt32?
    /// Which side the goal counts for.
    public var home: Bool
    public var minute: Int
    /// The minutes added on, as in 45+1.
    public var addedMinute: Int

    public init(scorer: UInt32, assist: UInt32?, home: Bool, minute: Int, addedMinute: Int) {
        self.scorer = scorer
        self.assist = assist
        self.home = home
        self.minute = minute
        self.addedMinute = addedMinute
    }
}

/// One match as FM keeps it: a fixture, and once it's played, its result.
public struct MatchFixture: Sendable {
    public var date: Date
    /// Minutes after midnight, or nil while FM hasn't set it.
    public var kickOff: Int?
    /// The season it belongs to, as FM numbers it: the year it starts in.
    public var season = 0
    /// 1 for the first round, for league fixtures only.
    public var round: Int?
    public var home: Int64
    public var away: Int64
    public var homeName = ""
    public var awayName = ""
    /// FM's names, in the game's language.
    public var competition = ""
    public var competitionIndex: UInt32 = 0
    public var stage = ""
    public var homeGoals: Int?
    public var awayGoals: Int?
    /// For the second leg of a two-legged tie.
    public var homeAggregate: Int?
    public var awayAggregate: Int?
    public var attendance: Int?
    /// Only when the list adds up to the score.
    public var goals: [MatchGoal] = []
    /// FM holds the match as played, but its copies disagree on the score, so the score is left out.
    public var scoreUnknown = false

    public var played: Bool { homeGoals != nil || scoreUnknown }

    public init(date: Date, home: Int64, away: Int64) {
        self.date = date
        self.home = home
        self.away = away
    }

    /// Kick-off as FM keeps it: the top seven bits of the date's day word, in quarter hours after 05:45. Fitted to two
    /// times read off FM's fixtures screen (37 is 15:00, 55 is 19:30); every match of a four-season save then lands on a
    /// usual kick-off. 0 is no time yet.
    static func kickOff(code: Int) -> Int? {
        let minutes = (code + 23) * 15
        return code == 0 || minutes >= 24 * 60 ? nil : minutes
    }
}

public struct TableRecord: Sendable, Equatable {
    public var played = 0, won = 0, drawn = 0, lost = 0, goalsFor = 0, goalsAgainst = 0, points = 0

    public init(played: Int = 0, won: Int = 0, drawn: Int = 0, lost: Int = 0, goalsFor: Int = 0, goalsAgainst: Int = 0, points: Int = 0) {
        self.played = played
        self.won = won
        self.drawn = drawn
        self.lost = lost
        self.goalsFor = goalsFor
        self.goalsAgainst = goalsAgainst
        self.points = points
    }

    /// Everything but points, which a deduction can change without a match.
    func sameMatches(as other: TableRecord) -> Bool {
        (played, won, drawn, lost, goalsFor, goalsAgainst) == (other.played, other.won, other.drawn, other.lost, other.goalsFor, other.goalsAgainst)
    }

    static func + (a: TableRecord, b: TableRecord) -> TableRecord {
        TableRecord(played: a.played + b.played, won: a.won + b.won, drawn: a.drawn + b.drawn, lost: a.lost + b.lost,
                    goalsFor: a.goalsFor + b.goalsFor, goalsAgainst: a.goalsAgainst + b.goalsAgainst, points: a.points + b.points)
    }

    var text: String { "P\(played) W\(won) D\(drawn) L\(lost) \(goalsFor)-\(goalsAgainst)" }
}

public struct LeagueTableRow: Sendable {
    public var team: Int64
    public var name: String
    public var position: Int
    public var overall: TableRecord
    public var home: TableRecord
    public var away: TableRecord

    public init(team: Int64, name: String, position: Int, overall: TableRecord, home: TableRecord, away: TableRecord) {
        self.team = team
        self.name = name
        self.position = position
        self.overall = overall
        self.home = home
        self.away = away
    }
}

public struct LeagueTable: Sendable {
    public var competition: String
    public var competitionIndex: UInt32
    /// In FM's order, first to last.
    public var rows: [LeagueTableRow]

    public init(competition: String, competitionIndex: UInt32, rows: [LeagueTableRow]) {
        self.competition = competition
        self.competitionIndex = competitionIndex
        self.rows = rows
    }
}

/// A team's fixtures and results, its league's table, and whether the two agree.
public struct TeamMatches: Sendable {
    public enum Check: Sendable, Equatable {
        /// The team's league results this season add up to its row in the table.
        case passed
        /// They don't, or the table's home and away don't add up to its overall: an offset has moved, or FM's copies
        /// of a match were read wrong. Says what was found, for a log.
        case failed(String)
        /// The team's competition has no league table, so there's nothing to check the results against.
        case noTable
        /// The table has no match played yet this season, so there's nothing to check the results against.
        case nothingPlayed
    }

    public var team: Int64
    /// Oldest first.
    public var fixtures: [MatchFixture]
    public var table: LeagueTable?
    public var check: Check

    public init(team: Int64, fixtures: [MatchFixture], table: LeagueTable?, check: Check) {
        self.team = team
        self.fixtures = fixtures
        self.table = table
        self.check = check
    }
}

/// One match in a player's history, from the record FM keeps for his form.
public struct PlayerMatch: Sendable {
    public var date: Date
    /// The team he was in.
    public var team: Int64
    public var opponent: Int64
    public var opponentName = ""
    /// The competition's database index, as `MatchFixture.competitionIndex`.
    public var competitionIndex: UInt32 = 0
    /// False when he was in the squad and didn't come on: FM keeps no record of his match then.
    public var played = false
    public var minutes = 0
    public var rating: Double?
    public var goals = 0
    public var assists = 0
    public var yellow = 0
    public var red = 0
    /// Outfield players only.
    public var xG: Double?

    public init(date: Date, team: Int64, opponent: Int64) {
        self.date = date
        self.team = team
        self.opponent = opponent
    }
}

/// A player's recent matches, newest first. FM keeps only the last `MacLayout.FormGroup.kept` for each team he's played for.
public struct MatchHistory: Sendable {
    public var matches: [PlayerMatch]
    /// For each team whose list is full, the oldest match still in it: anything older is gone.
    public var fullFrom: [Int64: Date]

    public init(matches: [PlayerMatch] = [], fullFrom: [Int64: Date] = [:]) {
        self.matches = matches
        self.fullFrom = fullFrom
    }

    /// How many matches FM keeps for each player and team.
    public static let kept = MacLayout.FormGroup.kept
}

/// A team's fixtures, results and league table, read from memory when asked for, apart from `GameReader.readAll`: one sweep
/// of a couple of seconds for one team. FM keeps no list of them it can be walked through, so the sweep looks for every
/// `sicomps::FIXTURE` and `sicomps::FIXTURE_RESULT` naming the team, and checks what it found against the league table.
public final class FixturesReader {
    private let game: GameProcess
    private let fixtureVt: Int64
    private let resultVt: Int64
    private let leagueStageVt: Int64
    /// Attendance, kick-off and aggregate aren't covered by the self-check, so they're only read on the build of
    /// game_plugin they were found on, as FM's rules are.
    private let checkedBuild: Bool

    /// `checkedBuild` stands in for the fingerprint, for tests.
    public init?(game: GameProcess, rtti: Rtti, checkedBuild: Bool? = nil) {
        self.game = game
        self.checkedBuild = checkedBuild ?? (GameBuild.fingerprint(pluginPath: game.pluginPath) == RulesEngine.Mac27.fingerprint)
        func vt(_ name: String) -> Int64 {
            guard let table = rtti.vtables(name).first(where: { $0.offsetToTop == 0 }) else { return 0 }
            return game.pluginBase + Int64(table.addressPoint)
        }
        fixtureVt = vt("FIXTURE")
        resultVt = vt("FIXTURE_RESULT")
        leagueStageVt = vt("LEAGUE_STAGE")
        guard fixtureVt != 0, resultVt != 0 else { return nil }
    }

    /// The team's fixtures and results, its league's table, and the check of one against the other.
    public func teamMatches(team: Int64) -> TeamMatches {
        var fixtures = self.fixtures(team: team)
        let table = leagueTable(team: team)
        let league = leagueIndex(team: team)
        for index in fixtures.indices where league == nil || fixtures[index].competitionIndex != league {
            fixtures[index].round = nil
        }
        return TeamMatches(team: team, fixtures: fixtures, table: table, check: Self.check(fixtures, team: team, table: table))
    }

    /// Every fixture and result of one team that FM holds in memory, one per match, oldest first.
    public func fixtures(team: Int64) -> [MatchFixture] {
        typealias F = MacLayout.Fixture
        let lock = NSLock()
        var found: [Int64: Bool] = [:]
        let pieces = game.pieces(size: 1 << 23, overlap: 0x100, writableOnly: true)
        let fixtureVt = fixtureVt, resultVt = resultVt
        DispatchQueue.concurrentPerform(iterations: pieces.count) { i in
            let (address, count) = pieces[i]
            let hits: [(Int64, Bool)] = game.withBytes(address, count: count) { raw in
                var hits: [(Int64, Bool)] = []
                var o = Int((8 - address % 8) % 8)
                while o + F.away + 8 <= count {
                    let word = raw.loadUnaligned(fromByteOffset: o, as: Int64.self)
                    if word == fixtureVt || word == resultVt,
                       raw.loadUnaligned(fromByteOffset: o + F.home, as: Int64.self) == team
                        || raw.loadUnaligned(fromByteOffset: o + F.away, as: Int64.self) == team {
                        hits.append((address + Int64(o), word == resultVt))
                    }
                    o += 8
                }
                return hits
            } ?? []
            guard !hits.isEmpty else { return }
            lock.lock()
            for (at, result) in hits { found[at] = result }
            lock.unlock()
        }

        var names: [Int64: String] = [:]
        var fixtureNames: [Int64: (competition: String, index: UInt32, stage: String)] = [:]
        struct Key: Hashable { let home: Int64, away: Int64, date: Date }
        var copies: [Key: [MatchFixture]] = [:]
        for (address, result) in found.sorted(by: { $0.key < $1.key }) {
            guard let fixture = decode(address, result: result, names: &names, fixtureNames: &fixtureNames) else { continue }
            copies[Key(home: fixture.home, away: fixture.away, date: fixture.date), default: []].append(fixture)
        }
        return copies.values.compactMap(Self.choose).sorted { ($0.date, $0.kickOff ?? 0) < ($1.date, $1.kickOff ?? 0) }
    }

    /// FM keeps from one to eight copies of a match, some made for its screens. A result wins over a fixture, and when two
    /// results disagree on the score, the score is left out.
    static func choose(_ copies: [MatchFixture]) -> MatchFixture? {
        guard let first = copies.first else { return nil }
        let results = copies.filter { $0.homeGoals != nil && $0.awayGoals != nil }
        var chosen = results.first ?? first
        let scores = Set(results.map { [$0.homeGoals ?? -1, $0.awayGoals ?? -1, $0.homeAggregate ?? -1, $0.awayAggregate ?? -1] })
        if scores.count > 1 {
            chosen.homeGoals = nil
            chosen.awayGoals = nil
            chosen.homeAggregate = nil
            chosen.awayAggregate = nil
            chosen.attendance = nil
            chosen.goals = []
            chosen.scoreUnknown = true
        } else if chosen.goals.isEmpty, let listed = results.first(where: { !$0.goals.isEmpty }) {
            chosen.goals = listed.goals
        }
        return chosen
    }

    private func decode(_ address: Int64, result: Bool, names: inout [Int64: String],
                        fixtureNames: inout [Int64: (competition: String, index: UInt32, stage: String)]) -> MatchFixture? {
        typealias F = MacLayout.Fixture
        typealias R = MacLayout.FixtureResult
        guard let b = game.read(address, count: result ? R.size : F.size) else { return nil }
        let dateWord = le16(b, F.date)
        guard let date = GameDate.checked(year: le16(b, F.year), dayOfYear: dateWord & 0x1ff) else { return nil }
        var fixture = MatchFixture(date: date, home: le64(b, F.home), away: le64(b, F.away))
        guard fixture.home != 0, fixture.away != 0 else { return nil }
        if checkedBuild { fixture.kickOff = MatchFixture.kickOff(code: dateWord >> 9) }
        fixture.season = le16(b, F.season)
        fixture.round = Int(b[F.round]) + 1
        for team in [fixture.home, fixture.away] where names[team] == nil { names[team] = GameReader.clubName(team: team, in: game) }
        fixture.homeName = names[fixture.home] ?? ""
        fixture.awayName = names[fixture.away] ?? ""
        let name = le64(b, F.name)
        if name != 0 {
            if fixtureNames[name] == nil {
                typealias N = MacLayout.FixtureName
                let comp = game.readPointer(name + N.comp)
                let stage = game.readPointer(name + N.stage)
                fixtureNames[name] = (comp == 0 ? "" : game.lengthPrefixedString(game.readPointer(comp + Int64(MacLayout.competitionName))),
                                      comp == 0 ? 0 : compIndex(comp),
                                      stage == 0 ? "" : game.lengthPrefixedString(game.readPointer(stage + N.stageText)))
            }
            if let named = fixtureNames[name] {
                fixture.competition = named.competition
                fixture.competitionIndex = named.index
                fixture.stage = named.stage
            }
        }
        // FM also keeps half-made copies of a result, whose match number is still unset and whose score reads 0-0.
        guard result, le32(b, R.matchNumber) != .max, b[R.homeGoals] != 0xff, b[R.awayGoals] != 0xff else { return fixture }
        fixture.homeGoals = Int(b[R.homeGoals])
        fixture.awayGoals = Int(b[R.awayGoals])
        // A tie's aggregate includes this leg, so one below the leg's score isn't an aggregate.
        if checkedBuild, b[R.homeAggregate] != 0xff, b[R.awayAggregate] != 0xff,
           b[R.homeAggregate] >= b[R.homeGoals], b[R.awayAggregate] >= b[R.awayGoals] {
            fixture.homeAggregate = Int(b[R.homeAggregate])
            fixture.awayAggregate = Int(b[R.awayAggregate])
        }
        if checkedBuild { fixture.attendance = Int(le32(b, R.attendance)) }
        fixture.goals = goals(le64(b, R.goals), home: fixture.homeGoals ?? 0, away: fixture.awayGoals ?? 0)
        return fixture
    }

    /// The goals that count, from a result's list. Nothing unless they add up to the score.
    private func goals(_ vector: Int64, home: Int, away: Int) -> [MatchGoal] {
        typealias G = MacLayout.Goal
        guard vector != 0, home + away > 0 else { return [] }
        let begin = game.readPointer(vector), end = game.readPointer(vector + 8)
        guard begin != 0, end > begin, (end - begin) % Int64(G.size) == 0, end - begin <= 64 * Int64(G.size),
              let e = game.read(begin, count: Int(end - begin)) else { return [] }
        var goals: [MatchGoal] = []
        for k in stride(from: 0, to: e.count, by: G.size) where G.countedKinds.contains(e[k + G.kind]) {
            let assist = le32(e, k + G.assist)
            goals.append(MatchGoal(scorer: le32(e, k + G.scorer), assist: assist == .max ? nil : assist,
                                   home: e[k + G.side] == 0, minute: Int(e[k + G.minute]), addedMinute: Int(e[k + G.addedMinute])))
        }
        guard goals.filter(\.home).count == home, goals.filter({ !$0.home }).count == away else { return [] }
        return goals
    }

    private func compIndex(_ comp: Int64) -> UInt32 {
        guard let b = game.read(comp + MacLayout.Comp.index, count: 4) else { return 0 }
        return le32(b, 0)
    }

    /// The database index of the team's league.
    private func leagueIndex(team: Int64) -> UInt32? {
        let comp = game.readPointer(team + Int64(MacLayout.Team.competition))
        return comp == 0 ? nil : compIndex(comp)
    }

    /// The table of the team's league, in FM's order: TEAM → COMP → ACTUAL_COMP → its LEAGUE_STAGE → that stage's rows.
    /// Nil for a competition with no league stage.
    public func leagueTable(team: Int64) -> LeagueTable? {
        guard leagueStageVt != 0 else { return nil }
        let comp = game.readPointer(team + Int64(MacLayout.Team.competition))
        guard comp != 0 else { return nil }
        let actual = game.readPointer(comp + MacLayout.Comp.actual)
        guard actual != 0 else { return nil }
        let stages = actual + MacLayout.ActualComp.stages
        let begin = game.readPointer(stages), end = game.readPointer(stages + 8)
        guard begin != 0, end > begin, end - begin <= 0x100 else { return nil }
        // A competition can have more than one league stage, such as two groups: the table is the one the team is in.
        for slot in stride(from: begin, to: end, by: 8) {
            let stage = game.readPointer(slot)
            guard stage != 0, game.readPointer(stage) == leagueStageVt, let rows = tableRows(stage),
                  rows.contains(where: { $0.team == team }) else { continue }
            return LeagueTable(competition: game.lengthPrefixedString(game.readPointer(comp + Int64(MacLayout.competitionName))),
                               competitionIndex: compIndex(comp), rows: rows)
        }
        return nil
    }

    /// A league stage's rows, in FM's order.
    private func tableRows(_ stage: Int64) -> [LeagueTableRow]? {
        let rowList = stage + MacLayout.LeagueStage.rows
        let first = game.readPointer(rowList), last = game.readPointer(rowList + 8)
        guard first != 0, last > first, last - first <= 0x200 else { return nil }
        typealias T = MacLayout.TableRow
        var rows: [LeagueTableRow] = []
        for slot in stride(from: first, to: last, by: 8) {
            let row = game.readPointer(slot)
            guard row != 0, let b = game.read(row, count: T.size) else { return nil }
            func record(_ o: Int) -> TableRecord {
                typealias R = T.Record
                return TableRecord(played: Int(b[o + R.played]), won: Int(b[o + R.won]), drawn: Int(b[o + R.drawn]),
                                   lost: Int(b[o + R.lost]), goalsFor: le16(b, o + R.goalsFor),
                                   goalsAgainst: le16(b, o + R.goalsAgainst), points: le16(b, o + R.points))
            }
            let teamObject = le64(b, T.team)
            rows.append(LeagueTableRow(team: teamObject, name: GameReader.clubName(team: teamObject, in: game), position: rows.count + 1,
                                       overall: record(T.overall), home: record(T.home), away: record(T.away)))
        }
        return rows
    }

    /// The self-check: the team's league results this season must add up to its row in the table, and every row's home
    /// and away records to its overall one. Points are left out, since a deduction changes them without a match, but no
    /// row may have more than its wins and draws give.
    ///
    /// A competition can have stages after its league, such as play-offs, under the same competition. Until it's known
    /// how a fixture names its stage's table, only fixtures of the stage most of the team's league fixtures this season
    /// have are counted.
    public static func check(_ fixtures: [MatchFixture], team: Int64, table: LeagueTable?) -> TeamMatches.Check {
        guard let table, let row = table.rows.first(where: { $0.team == team }) else { return .noTable }
        for other in table.rows where !(other.home + other.away).sameMatches(as: other.overall) {
            return .failed("\(other.name)'s home and away records, \((other.home + other.away).text), don't add up to its overall \(other.overall.text)")
        }
        for other in table.rows where other.overall.points > 3 * other.overall.won + other.overall.drawn {
            return .failed("\(other.name) has \(other.overall.points) points from \(other.overall.won) wins and \(other.overall.drawn) draws")
        }
        guard row.overall.played > 0 else { return .nothingPlayed }
        let competition = fixtures.filter { $0.competitionIndex == table.competitionIndex }
        let season = competition.filter(\.played).map(\.season).max() ?? 0
        let thisSeason = competition.filter { $0.season == season }
        let stages = Dictionary(grouping: thisSeason, by: \.stage)
        let usual = stages.max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key ?? ""
        var sum = TableRecord()
        for match in thisSeason where match.played && match.stage == usual {
            guard let h = match.homeGoals, let a = match.awayGoals else {
                return .failed("the copies of \(match.homeName) v \(match.awayName) disagree on the score")
            }
            let (us, them) = match.home == team ? (h, a) : (a, h)
            sum = sum + TableRecord(played: 1, won: us > them ? 1 : 0, drawn: us == them ? 1 : 0, lost: us < them ? 1 : 0,
                                    goalsFor: us, goalsAgainst: them)
        }
        guard sum.sameMatches(as: row.overall) else {
            return .failed("\(row.name)'s league results add up to \(sum.text), and the table says \(row.overall.text)")
        }
        return .passed
    }

    /// A player's recent matches, from the record FM keeps for his form: plain data, so no emulation. `name` names a team.
    public static func history(player block: Int64, in game: GameProcess, name: (Int64) -> String) -> MatchHistory {
        typealias G = MacLayout.FormGroup
        typealias E = MacLayout.FormEntry
        typealias M = MacLayout.MatchRecord
        var history = MatchHistory()
        let record = game.readPointer(block + Int64(MacLayout.Player.injuries))
        guard record != 0 else { return history }
        let list = game.readPointer(record + Int64(MacLayout.History.matches))
        guard list != 0 else { return history }
        let begin = game.readPointer(list), end = game.readPointer(list + 8)
        guard begin != 0, end >= begin else { return history }
        for slot in stride(from: begin, to: min(end, begin + 0x200), by: 8) {
            let group = game.readPointer(slot)
            guard group != 0, let head = game.read(group, count: G.entries) else { continue }
            let team = le64(head, G.team)
            let count = min(Int(head[G.count]), G.kept)
            var oldest: Date?
            for i in 0..<count {
                let entry = game.readPointer(group + Int64(G.entries + 8 * i))
                guard entry != 0, let b = game.read(entry, count: E.size),
                      let date = GameDate.checked(year: le16(b, E.year), dayOfYear: le16(b, E.day) & 0x1ff) else { continue }
                oldest = min(oldest ?? date, date)
                var match = PlayerMatch(date: date, team: team, opponent: le64(b, E.opponent))
                match.opponentName = name(match.opponent)
                match.competitionIndex = le32(b, E.competition)
                let stats = le64(b, E.record)
                if stats != 0, let r = game.read(stats, count: M.size) {
                    match.played = true
                    match.minutes = Int(r[M.minutes])
                    match.rating = r[M.rating] == 0 ? nil : Double(r[M.rating]) / 10
                    match.goals = Int(r[M.goals])
                    match.assists = Int(r[M.assists])
                    match.yellow = Int(r[M.yellow])
                    match.red = Int(r[M.red])
                    if r[M.position] != 0 { match.xG = Double(le16(r, M.xG)) / 100 }
                }
                history.matches.append(match)
            }
            if count == G.kept, let oldest { history.fullFrom[team] = oldest }
        }
        history.matches.sort { $0.date > $1.date }
        return history
    }
}

// Little-endian fields of a record read into bytes.
private func le16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
private func le32(_ b: [UInt8], _ o: Int) -> UInt32 { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
private func le64(_ b: [UInt8], _ o: Int) -> Int64 { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int64.self) } }
