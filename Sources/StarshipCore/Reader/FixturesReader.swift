import Foundation

/// One goal from a result's list. FM marks each goal with a kind: one is an own goal, and which is a penalty isn't known.
public struct MatchGoal: Sendable, Equatable {
    /// The scorer's `Person.index`.
    public var scorer: UInt32
    public var assist: UInt32?
    /// Which side the goal counts for.
    public var home: Bool
    public var minute: Int
    /// The minutes added on, as in 45+1.
    public var addedMinute: Int
    /// FM's kind says the scorer put it in his own net.
    public var ownGoal: Bool

    public init(scorer: UInt32, assist: UInt32?, home: Bool, minute: Int, addedMinute: Int, ownGoal: Bool = false) {
        self.scorer = scorer
        self.assist = assist
        self.home = home
        self.minute = minute
        self.addedMinute = addedMinute
        self.ownGoal = ownGoal
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
    /// Whether FM's type of competition makes it a friendly: nil where the type couldn't be read, or is one FM Starship
    /// hasn't seen. Only read on the build of game_plugin it was found on.
    public var friendly: Bool?
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
    /// For a match not played yet that FM holds on more than one day, where which is current couldn't be told: each of
    /// those days, oldest first. `date` is then the latest of them, so the match is listed once, but it isn't the match's
    /// date. Empty otherwise.
    public var possibleDates: [Date] = []
    /// One of the copies is FM's own, as against a copy its screens keep. Only read on the checked build.
    var ownCopy = false

    public var played: Bool { homeGoals != nil || scoreUnknown }
    /// FM holds more than one day for it, and which is current couldn't be told.
    public var dateUnknown: Bool { !possibleDates.isEmpty }

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

/// Where a league stage's places lead, as FM's settings for the stage count them: from the top and from the bottom.
public struct LeagueLines: Sendable, Equatable {
    /// Straight on: promotion, or for a league phase the next stage.
    public var through: Int
    /// The places after those, to a play-off for promotion or the next stage.
    public var playOff: Int
    /// The places above the relegated ones, to a relegation play-off.
    public var relegationPlayOff: Int
    /// The bottom places.
    public var relegated: Int

    public init(through: Int, playOff: Int, relegationPlayOff: Int, relegated: Int) {
        self.through = through
        self.playOff = playOff
        self.relegationPlayOff = relegationPlayOff
        self.relegated = relegated
    }
}

/// The table of one league stage of a competition, such as the Champions League's league phase, with every club's
/// matches in it, and whether the two agree.
public struct CompetitionTable: Sendable {
    public var table: LeagueTable
    /// The name the stage's fixtures give it, in the game's language: "" for a league whose fixtures name none.
    public var stage: String
    /// The season the stage's matches are of, as `MatchFixture.season`.
    public var season: Int
    /// The stage's matches this season, of every club in the table, oldest first.
    public var fixtures: [MatchFixture]
    /// Nil where FM's settings for the stage couldn't be read, or on a build of game_plugin they weren't read on.
    public var lines: LeagueLines?
    /// `TeamMatches.Check.noTable` doesn't come up: there's no `CompetitionTable` without a table.
    public var check: TeamMatches.Check

    public init(table: LeagueTable, stage: String, season: Int, fixtures: [MatchFixture], lines: LeagueLines?, check: TeamMatches.Check) {
        self.table = table
        self.stage = stage
        self.season = season
        self.fixtures = fixtures
        self.lines = lines
        self.check = check
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
    /// The team he was in, by its club's name: empty for a national team.
    public var teamName = ""
    /// That team's type, as `Names.squadName` names it: 0 the first team, 11 the U19s. Nil where it couldn't be read.
    public var teamType: Int?
    /// The competition's database index, as `MatchFixture.competitionIndex`.
    public var competitionIndex: UInt32 = 0
    /// The competition's name when it's his team's own league, which names a reserve league's matches that no fixture in
    /// memory names. Empty otherwise: `FixturesReader.competitionNames` names the rest.
    public var competitionName = ""
    /// Whether FM's type of competition makes it a friendly, as `MatchFixture.friendly`: only for his team's own league,
    /// whose record the history reads. Nil otherwise: `FixturesReader.friendlyByCompetition` gives the rest.
    public var friendly: Bool?
    /// Why a player didn't play, as FM's entry says.
    public enum Absence: String, Sendable {
        case unusedSubstitute = "unused substitute"
        case notInSquad = "not in the matchday squad"
        case suspended
        case injured
    }

    /// False when he didn't play. FM keeps an entry with no record of his match for every first-team player who didn't:
    /// on the bench, left out, suspended or injured.
    public var played = false
    /// Why he didn't play, as FM's entry says. Nil when he played, or for a reason FM Starship doesn't know.
    public var absence: Absence?
    public var minutes = 0
    public var rating: Double?
    public var goals = 0
    public var assists = 0
    public var yellow = 0
    public var red = 0
    /// Outfield players only.
    public var xG: Double?
    /// Goalkeepers only: the xG of the shots he faced.
    public var xGFaced: Double?
    public var shots = 0
    public var shotsOnTarget = 0
    public var fouls = 0

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
    private let leagueSettingsVt: Int64
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
        leagueSettingsVt = vt("LEAGUE_SETTINGS")
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

    /// Every fixture and result of one team that FM holds in memory, one per match, oldest first. A match that was moved
    /// is listed once, as `oneDay` says.
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
        var fixtureNames: [Int64: (competition: String, index: UInt32, friendly: Bool?, stage: String)] = [:]
        struct Key: Hashable { let home: Int64, away: Int64, date: Date }
        var copies: [Key: [MatchFixture]] = [:]
        for (address, result) in found.sorted(by: { $0.key < $1.key }) {
            guard let fixture = decode(address, result: result, names: &names, fixtureNames: &fixtureNames) else { continue }
            copies[Key(home: fixture.home, away: fixture.away, date: fixture.date), default: []].append(fixture)
        }
        return Self.oneDay(copies.values.compactMap(Self.choose)).sorted { ($0.date, $0.kickOff ?? 0) < ($1.date, $1.kickOff ?? 0) }
    }

    /// FM keeps copies its screens made of a match before it was moved, on the days it had then, so a match not played
    /// yet can turn up on more than one day. It's listed once: on the day of FM's own copy, where one day has it; else on
    /// its one day not known to be past; else with each day it could be on in `possibleDates`. A day is known to be past
    /// when the team has played a match after it. A copy not played that's older than a played copy of the match is
    /// dropped. A match is known by its competition, season, round and teams; friendlies, whose season FM leaves at 0, so
    /// that one year's can't be told from the next's, and matches whose competition isn't known, are left as they are.
    static func oneDay(_ matches: [MatchFixture]) -> [MatchFixture] {
        struct Match: Hashable { let competition: UInt32, season: Int, round: Int?, home: Int64, away: Int64 }
        let lastPlayed = matches.filter(\.played).map(\.date).max()
        var kept: [MatchFixture] = []
        var days: [Match: [MatchFixture]] = [:]
        for match in matches {
            guard match.season != 0, match.competitionIndex != 0 else { kept.append(match); continue }
            days[Match(competition: match.competitionIndex, season: match.season, round: match.round, home: match.home, away: match.away),
                 default: []].append(match)
        }
        for list in days.values {
            let played = list.filter(\.played)
            kept += played
            var waiting = list.filter { !$0.played }
            if let latest = played.map(\.date).max() { waiting.removeAll { $0.date < latest } }
            guard waiting.count > 1 else { kept += waiting; continue }
            waiting.sort { $0.date < $1.date }
            let own = waiting.filter(\.ownCopy)
            if own.count == 1 { kept += own; continue }
            if own.count > 1 { waiting = own }
            // A day that's past isn't the match's day when there's a later one.
            if let lastPlayed, let last = waiting.last { waiting.removeAll { $0.date < lastPlayed && $0.date < last.date } }
            guard var latest = waiting.last else { continue }
            if waiting.count > 1 { latest.possibleDates = waiting.map(\.date) }
            kept.append(latest)
        }
        return kept
    }

    /// The name of every competition FM holds a fixture or result of, by database index, from one sweep: a player's match
    /// records only hold the index. A competition with no fixture left in memory, such as an old season's, isn't named.
    /// Where two names come out for one index, as a copy in freed memory could give, the one most fixtures carry wins.
    public func competitionNames() -> [UInt32: String] {
        var votes: [UInt32: [String: Int]] = [:]
        for (comp, fixtures) in fixturesByComp() {
            let name = game.lengthPrefixedString(game.readPointer(comp &+ Int64(MacLayout.competitionName)))
            guard !name.isEmpty else { continue }
            votes[compIndex(comp), default: [:]][name, default: 0] += fixtures
        }
        return votes.compactMapValues { names in names.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key }
    }

    /// Each competition's `db::COMP` by database index, from the same kind of sweep: of two records with one index, the
    /// one more fixtures name, as for its name. Only named ones.
    public func competitionRecords() -> [UInt32: Int64] {
        var best: [UInt32: (comp: Int64, fixtures: Int)] = [:]
        for (comp, fixtures) in fixturesByComp() {
            guard !game.lengthPrefixedString(game.readPointer(comp &+ Int64(MacLayout.competitionName))).isEmpty else { continue }
            let index = compIndex(comp)
            if let known = best[index], (known.fixtures, comp) >= (fixtures, known.comp) { continue }
            best[index] = (comp, fixtures)
        }
        return best.mapValues(\.comp)
    }

    /// Whether each competition is a friendly, by FM's type of competition, from the same sweep as `competitionRecords`: a
    /// player's match records only hold the index. A competition whose type couldn't be read, or isn't one FM Starship has
    /// seen, is left out.
    public func friendlyByCompetition() -> [UInt32: Bool] {
        competitionRecords().compactMapValues(friendly)
    }

    /// Whether FM's type of competition makes it a friendly. Nil for a type FM Starship hasn't seen.
    static func friendly(type: UInt8) -> Bool? {
        if MacLayout.Comp.friendlyTypes.contains(type) { return true }
        return MacLayout.Comp.competitiveTypes.contains(type) ? false : nil
    }

    /// A competition record's type, as `friendly(type:)` reads it. Only on the checked build, as the field isn't covered by
    /// the self-check.
    private func friendly(_ comp: Int64) -> Bool? {
        guard checkedBuild, comp != 0, let b = game.read(comp &+ MacLayout.Comp.type, count: 1), let type = b.first else { return nil }
        return Self.friendly(type: type)
    }

    /// How many fixtures and results name each competition record, from one sweep.
    private func fixturesByComp() -> [Int64: Int] {
        typealias F = MacLayout.Fixture
        let lock = NSLock()
        var fixturesByName: [Int64: Int] = [:]
        let pieces = game.pieces(size: 1 << 23, overlap: 0x100, writableOnly: true)
        let fixtureVt = fixtureVt, resultVt = resultVt
        DispatchQueue.concurrentPerform(iterations: pieces.count) { i in
            let (address, count) = pieces[i]
            let found: [Int64: Int] = game.withBytes(address, count: count) { raw in
                var found: [Int64: Int] = [:]
                var o = Int((8 - address % 8) % 8)
                while o + F.name + 8 <= count {
                    let word = raw.loadUnaligned(fromByteOffset: o, as: Int64.self)
                    if word == fixtureVt || word == resultVt {
                        let name = raw.loadUnaligned(fromByteOffset: o + F.name, as: Int64.self)
                        if name != 0 { found[name, default: 0] += 1 }
                    }
                    o += 8
                }
                return found
            } ?? [:]
            guard !found.isEmpty else { return }
            lock.lock()
            fixturesByName.merge(found, uniquingKeysWith: +)
            lock.unlock()
        }
        // The pieces overlap, so a fixture in an overlap counts twice. That only weighs the vote, and both copies agree.
        var fixturesByComp: [Int64: Int] = [:]
        for (name, fixtures) in fixturesByName {
            let comp = game.readPointer(name &+ MacLayout.FixtureName.comp)
            if comp != 0 { fixturesByComp[comp, default: 0] += fixtures }
        }
        return fixturesByComp
    }

    /// FM keeps from one to eight copies of a match, some made for its screens. A result wins over a fixture, and when two
    /// results disagree on the score, the score is left out.
    static func choose(_ copies: [MatchFixture]) -> MatchFixture? {
        guard let first = copies.first else { return nil }
        let results = copies.filter { $0.homeGoals != nil && $0.awayGoals != nil }
        var chosen = results.first ?? first
        chosen.ownCopy = copies.contains(where: \.ownCopy)
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
                        fixtureNames: inout [Int64: (competition: String, index: UInt32, friendly: Bool?, stage: String)]) -> MatchFixture? {
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
        if checkedBuild { fixture.ownCopy = b[F.flags] & F.ownCopy != 0 }
        for team in [fixture.home, fixture.away] where names[team] == nil { names[team] = GameReader.clubName(team: team, in: game) }
        fixture.homeName = names[fixture.home] ?? ""
        fixture.awayName = names[fixture.away] ?? ""
        let name = le64(b, F.name)
        if name != 0 {
            if fixtureNames[name] == nil {
                typealias N = MacLayout.FixtureName
                let comp = game.readPointer(name &+ N.comp)
                let stage = game.readPointer(name &+ N.stage)
                fixtureNames[name] = (comp == 0 ? "" : game.lengthPrefixedString(game.readPointer(comp &+ Int64(MacLayout.competitionName))),
                                      comp == 0 ? 0 : compIndex(comp), friendly(comp),
                                      stage == 0 ? "" : game.lengthPrefixedString(game.readPointer(stage &+ N.stageText)))
            }
            if let named = fixtureNames[name] {
                fixture.competition = named.competition
                fixture.competitionIndex = named.index
                fixture.friendly = named.friendly
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
        let begin = game.readPointer(vector), end = game.readPointer(vector &+ 8)
        guard begin > 0, end > begin, (end - begin) % Int64(G.size) == 0, end - begin <= 64 * Int64(G.size),
              let e = game.read(begin, count: Int(end - begin)) else { return [] }
        var goals: [MatchGoal] = []
        for k in stride(from: 0, to: e.count, by: G.size) where G.countedKinds.contains(e[k + G.kind]) {
            let assist = le32(e, k + G.assist)
            goals.append(MatchGoal(scorer: le32(e, k + G.scorer), assist: assist == .max ? nil : assist,
                                   home: e[k + G.side] == 0, minute: Int(e[k + G.minute]), addedMinute: Int(e[k + G.addedMinute]),
                                   ownGoal: e[k + G.kind] == G.ownGoalKind))
        }
        guard goals.filter(\.home).count == home, goals.filter({ !$0.home }).count == away else { return [] }
        return goals
    }

    private func compIndex(_ comp: Int64) -> UInt32 {
        // The sweep reads `comp` from any fixture-like object, freed copies too, so it's only added to with &+.
        guard let b = game.read(comp &+ MacLayout.Comp.index, count: 4) else { return 0 }
        return le32(b, 0)
    }

    /// The database index of the team's league.
    private func leagueIndex(team: Int64) -> UInt32? {
        let comp = game.readPointer(team &+ Int64(MacLayout.Team.competition))
        return comp == 0 ? nil : compIndex(comp)
    }

    /// The table of the team's league, in FM's order: TEAM → COMP → ACTUAL_COMP → its LEAGUE_STAGE → that stage's rows.
    /// Nil for a competition with no league stage.
    public func leagueTable(team: Int64) -> LeagueTable? {
        leagueStage(comp: game.readPointer(team &+ Int64(MacLayout.Team.competition)), team: team)?.table
    }

    /// The league stage of a competition that the team is in, and its table in FM's order: COMP → ACTUAL_COMP → its
    /// LEAGUE_STAGEs → the one whose rows have the team.
    private func leagueStage(comp: Int64, team: Int64) -> (stage: Int64, table: LeagueTable)? {
        guard leagueStageVt != 0, comp != 0 else { return nil }
        let actual = game.readPointer(comp &+ MacLayout.Comp.actual)
        guard actual != 0 else { return nil }
        let stages = actual &+ MacLayout.ActualComp.stages
        let begin = game.readPointer(stages), end = game.readPointer(stages &+ 8)
        guard begin > 0, end > begin, end - begin <= 0x100 else { return nil }
        // A competition can have more than one league stage, such as two groups: the table is the one the team is in.
        for slot in stride(from: begin, to: end, by: 8) {
            let stage = game.readPointer(slot)
            guard stage != 0, game.readPointer(stage) == leagueStageVt, let rows = tableRows(stage),
                  rows.contains(where: { $0.team == team }) else { continue }
            return (stage, LeagueTable(competition: game.lengthPrefixedString(game.readPointer(comp &+ Int64(MacLayout.competitionName))),
                                       competitionIndex: compIndex(comp), rows: rows))
        }
        return nil
    }

    /// The table of the league stage the team is in of one competition, by database index, such as the Champions League's
    /// league phase, with every club's matches in that stage this season and the check of one against the other. One sweep
    /// for the competition's fixtures. Nil when FM holds no fixture of the competition, or none of its league stages has the
    /// team.
    ///
    /// The stage's matches are the ones whose fixtures name the stage FM's settings for it name, so a competition's
    /// qualifying rounds, play-offs and knockouts are left out. Where the settings can't be read, the stage most of its
    /// clubs' matches name stands in.
    public func competitionTable(team: Int64, competitionIndex: UInt32) -> CompetitionTable? {
        var byName: [Int64: [Int64: Bool]] = [:]
        var votes: [Int64: Int] = [:]
        for (name, found) in fixtureAddressesByName() {
            let comp = game.readPointer(name &+ MacLayout.FixtureName.comp)
            guard comp != 0, compIndex(comp) == competitionIndex else { continue }
            byName[name] = found
            votes[comp, default: 0] += found.count
        }
        // Of two records with the index, as a copy in freed memory could give, the one more fixtures name first.
        let records = votes.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.map(\.key)
        guard let found = records.lazy.compactMap({ self.leagueStage(comp: $0, team: team) }).first else { return nil }
        let (stage, table) = found

        var names: [Int64: String] = [:]
        var fixtureNames: [Int64: (competition: String, index: UInt32, friendly: Bool?, stage: String)] = [:]
        struct Key: Hashable { let home: Int64, away: Int64, date: Date }
        var copies: [Key: [MatchFixture]] = [:]
        for (address, result) in byName.values.flatMap({ $0 }).sorted(by: { $0.key < $1.key }) {
            guard let fixture = decode(address, result: result, names: &names, fixtureNames: &fixtureNames) else { continue }
            copies[Key(home: fixture.home, away: fixture.away, date: fixture.date), default: []].append(fixture)
        }
        let clubs = Set(table.rows.map(\.team))
        let theirs = copies.values.compactMap(Self.choose).filter { clubs.contains($0.home) || clubs.contains($0.away) }

        typealias S = MacLayout.LeagueSettings
        let settings = game.readPointer(stage &+ MacLayout.LeagueStage.settings)
        let settingsRead = leagueSettingsVt != 0 && settings != 0 && game.readPointer(settings) == leagueSettingsVt
        let stageName: String
        if settingsRead {
            let name = game.readPointer(settings &+ S.stageName)
            stageName = name == 0 ? "" : game.lengthPrefixedString(game.readPointer(name &+ MacLayout.FixtureName.stageText))
        } else {
            let latest = theirs.map(\.season).max() ?? 0
            let stages = Dictionary(grouping: theirs.filter { $0.season == latest }, by: \.stage)
            stageName = stages.max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key ?? ""
        }
        let inStage = theirs.filter { $0.stage == stageName }
        let season = inStage.map(\.season).max() ?? 0
        let fixtures = inStage.filter { $0.season == season }.sorted { ($0.date, $0.kickOff ?? 0) < ($1.date, $1.kickOff ?? 0) }
        return CompetitionTable(table: table, stage: stageName, season: season, fixtures: fixtures,
                                lines: settingsRead && checkedBuild ? lines(settings, clubs: table.rows.count) : nil,
                                check: Self.check(stage: fixtures, table: table))
    }

    /// Where a league stage's places lead, from its settings: nil unless the settings' count of clubs is the table's and the
    /// places fit in it. Only on the checked build, as the self-check doesn't cover them.
    private func lines(_ settings: Int64, clubs: Int) -> LeagueLines? {
        typealias S = MacLayout.LeagueSettings
        guard let count = game.read(settings &+ S.clubs, count: 1)?.first, Int(count) == clubs,
              let b = game.read(settings &+ S.places, count: 4), b.reduce(0, { $0 + Int($1) }) <= clubs else { return nil }
        return LeagueLines(through: Int(b[0]), playOff: Int(b[1]), relegationPlayOff: Int(b[2]), relegated: Int(b[3]))
    }

    /// Every fixture and result FM holds that names a fixture name, by that name, from one sweep.
    private func fixtureAddressesByName() -> [Int64: [Int64: Bool]] {
        typealias F = MacLayout.Fixture
        let lock = NSLock()
        var byName: [Int64: [Int64: Bool]] = [:]
        let pieces = game.pieces(size: 1 << 23, overlap: 0x100, writableOnly: true)
        let fixtureVt = fixtureVt, resultVt = resultVt
        DispatchQueue.concurrentPerform(iterations: pieces.count) { i in
            let (address, count) = pieces[i]
            let hits: [(name: Int64, at: Int64, result: Bool)] = game.withBytes(address, count: count) { raw in
                var hits: [(name: Int64, at: Int64, result: Bool)] = []
                var o = Int((8 - address % 8) % 8)
                while o + F.name + 8 <= count {
                    let word = raw.loadUnaligned(fromByteOffset: o, as: Int64.self)
                    if word == fixtureVt || word == resultVt {
                        let name = raw.loadUnaligned(fromByteOffset: o + F.name, as: Int64.self)
                        if name != 0 { hits.append((name, address + Int64(o), word == resultVt)) }
                    }
                    o += 8
                }
                return hits
            } ?? []
            guard !hits.isEmpty else { return }
            lock.lock()
            // The pieces overlap, so a fixture in an overlap is found twice, at the same address.
            for hit in hits { byName[hit.name, default: [:]][hit.at] = hit.result }
            lock.unlock()
        }
        return byName
    }

    /// A league stage's rows, in FM's order.
    private func tableRows(_ stage: Int64) -> [LeagueTableRow]? {
        let rowList = stage &+ MacLayout.LeagueStage.rows
        let first = game.readPointer(rowList), last = game.readPointer(rowList &+ 8)
        guard first > 0, last > first, last - first <= 0x200 else { return nil }
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
        if let why = rowsProblem(table) { return .failed(why) }
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

    /// The self-check of a competition's table, stronger than `check`'s of one team: every club's results in the stage this
    /// season must add up to its row, overall, home and away, and the rows' matches to twice the matches played. A result
    /// with a club the table doesn't have fails it, as does one whose score isn't known. Points as in `check`.
    ///
    /// `fixtures` are the stage's this season, of the clubs in the table, as `competitionTable` gives them.
    public static func check(stage fixtures: [MatchFixture], table: LeagueTable) -> TeamMatches.Check {
        if let why = rowsProblem(table) { return .failed(why) }
        let clubs = Set(table.rows.map(\.team))
        var home: [Int64: TableRecord] = [:], away: [Int64: TableRecord] = [:]
        var played = 0
        func record(_ us: Int, _ them: Int) -> TableRecord {
            TableRecord(played: 1, won: us > them ? 1 : 0, drawn: us == them ? 1 : 0, lost: us < them ? 1 : 0, goalsFor: us, goalsAgainst: them)
        }
        for match in fixtures where match.played {
            guard let h = match.homeGoals, let a = match.awayGoals else {
                return .failed("the copies of \(match.homeName) v \(match.awayName) disagree on the score")
            }
            guard clubs.contains(match.home), clubs.contains(match.away) else {
                return .failed("\(match.homeName) v \(match.awayName) is a result of the stage with a club its table doesn't have")
            }
            played += 1
            home[match.home] = (home[match.home] ?? TableRecord()) + record(h, a)
            away[match.away] = (away[match.away] ?? TableRecord()) + record(a, h)
        }
        guard played > 0 || table.rows.contains(where: { $0.overall.played > 0 }) else { return .nothingPlayed }
        for row in table.rows {
            let (h, a) = (home[row.team] ?? TableRecord(), away[row.team] ?? TableRecord())
            for (what, sum, says) in [("home", h, row.home), ("away", a, row.away), ("overall", h + a, row.overall)]
            where !sum.sameMatches(as: says) {
                return .failed("\(row.name)'s \(what) results in the stage add up to \(sum.text), and the table says \(says.text)")
            }
        }
        let rowsPlayed = table.rows.reduce(0) { $0 + $1.overall.played }
        guard rowsPlayed == 2 * played else {
            return .failed("the table's rows have \(rowsPlayed) matches between them, not twice the \(played) results of the stage")
        }
        return .passed
    }

    /// What's wrong with a table on its own: a row whose home and away don't add up to its overall, or with more points
    /// than its wins and draws give. Nil when nothing is.
    private static func rowsProblem(_ table: LeagueTable) -> String? {
        for other in table.rows where !(other.home + other.away).sameMatches(as: other.overall) {
            return "\(other.name)'s home and away records, \((other.home + other.away).text), don't add up to its overall \(other.overall.text)"
        }
        for other in table.rows where other.overall.points > 3 * other.overall.won + other.overall.drawn {
            return "\(other.name) has \(other.overall.points) points from \(other.overall.won) wins and \(other.overall.drawn) draws"
        }
        return nil
    }

    /// A player's recent matches, from the record FM keeps for his form: plain data, so no emulation. `name` names a team.
    /// `types` reads FM's type of competition for his team's own league, only on the checked build.
    public static func history(player block: Int64, in game: GameProcess, types: Bool = false, name: (Int64) -> String) -> MatchHistory {
        typealias G = MacLayout.FormGroup
        typealias E = MacLayout.FormEntry
        typealias M = MacLayout.MatchRecord
        var history = MatchHistory()
        // Pointers read from FM's memory are only added to with &+, so a bad one can't trap.
        let record = game.readPointer(block &+ Int64(MacLayout.Player.injuries))
        guard record != 0 else { return history }
        let list = game.readPointer(record &+ Int64(MacLayout.History.matches))
        guard list != 0 else { return history }
        let begin = game.readPointer(list), end = game.readPointer(list &+ 8)
        guard begin > 0, end >= begin else { return history }
        for slot in stride(from: begin, to: min(end, begin &+ 0x200), by: 8) {
            let group = game.readPointer(slot)
            guard group != 0, let head = game.read(group, count: G.entries) else { continue }
            let team = le64(head, G.team)
            let teamName = name(team)
            let teamType = game.read(team &+ Int64(MacLayout.Team.type), count: 1)?.first.map(Int.init)
            let league = league(of: team, in: game, type: types)
            let count = min(Int(head[G.count]), G.kept)
            var oldest: Date?
            for i in 0..<count {
                let entry = game.readPointer(group &+ Int64(G.entries + 8 * i))
                guard entry != 0, let b = game.read(entry, count: E.size),
                      let date = GameDate.checked(year: le16(b, E.year), dayOfYear: le16(b, E.day) & 0x1ff) else { continue }
                oldest = min(oldest ?? date, date)
                var match = PlayerMatch(date: date, team: team, opponent: le64(b, E.opponent))
                match.opponentName = name(match.opponent)
                match.teamName = teamName
                match.teamType = teamType
                match.competitionIndex = le32(b, E.competition)
                if let league, league.index == match.competitionIndex {
                    match.competitionName = league.name
                    match.friendly = league.friendly
                }
                let stats = le64(b, E.record)
                if stats == 0 { match.absence = absence(b[E.reason]) }
                if stats != 0, let r = game.read(stats, count: M.size) {
                    match.played = true
                    match.minutes = Int(r[M.minutes])
                    match.rating = r[M.rating] == 0 ? nil : Double(r[M.rating]) / 10
                    match.goals = Int(r[M.goals])
                    match.assists = Int(r[M.assists])
                    match.yellow = Int(r[M.yellow])
                    match.red = Int(r[M.red])
                    match.shots = Int(r[M.shots])
                    match.shotsOnTarget = Int(r[M.shotsOnTarget])
                    match.fouls = Int(r[M.fouls])
                    if r[M.position] != 0 {
                        match.xG = Double(le16(r, M.xG)) / 100
                    } else {
                        match.xGFaced = Double(le16(r, M.xG)) / 100
                    }
                }
                history.matches.append(match)
            }
            if count == G.kept, let oldest { history.fullFrom[team] = oldest }
        }
        history.matches.sort { $0.date > $1.date }
        return history
    }

    /// FM's reason byte, where its meaning is known.
    static func absence(_ reason: UInt8) -> PlayerMatch.Absence? {
        typealias E = MacLayout.FormEntry
        switch reason {
        case E.unusedSubstitute: return .unusedSubstitute
        case E.notInSquad: return .notInSquad
        case E.suspended: return .suspended
        case E.injured: return .injured
        default: return nil
        }
    }

    /// A team's own league: its database index and name, and with `type` whether FM's type of competition makes it a friendly.
    private static func league(of team: Int64, in game: GameProcess, type: Bool) -> (index: UInt32, name: String, friendly: Bool?)? {
        let comp = game.readPointer(team &+ Int64(MacLayout.Team.competition))
        guard comp != 0, let b = game.read(comp &+ MacLayout.Comp.index, count: 4) else { return nil }
        let name = game.lengthPrefixedString(game.readPointer(comp &+ Int64(MacLayout.competitionName)))
        let friendly = type ? game.read(comp &+ MacLayout.Comp.type, count: 1)?.first.flatMap(Self.friendly(type:)) : nil
        return name.isEmpty ? nil : (le32(b, 0), name, friendly)
    }
}

// Little-endian fields of a record read into bytes.
private func le16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
private func le32(_ b: [UInt8], _ o: Int) -> UInt32 { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
private func le64(_ b: [UInt8], _ o: Int) -> Int64 { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int64.self) } }
