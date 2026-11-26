import Foundation

/// One side's figures in a match's summary.
public struct MatchSideStats: Sendable, Equatable {
    /// Per cent of the match.
    public var possession: Int
    /// xG × 100, as FM keeps it.
    public var xG100: Int
    public var shots: Int
    public var shotsOnTarget: Int
    public var fouls: Int
    public var goals: Int

    public var xG: Double { Double(xG100) / 100 }

    public init(possession: Int, xG100: Int, shots: Int, shotsOnTarget: Int, fouls: Int, goals: Int) {
        self.possession = possession
        self.xG100 = xG100
        self.shots = shots
        self.shotsOnTarget = shotsOnTarget
        self.fouls = fouls
        self.goals = goals
    }
}

/// A match's team stats, from the summary FM keeps in its post-match news about the user's club: the club's side and
/// the opponent's.
public struct MatchStats: Sendable, Equatable {
    public var date: Date
    /// The user's club's team, and the one it played.
    public var team: Int64
    public var opponent: Int64
    /// The club was at home.
    public var home: Bool
    public var ours: MatchSideStats
    public var theirs: MatchSideStats

    public init(date: Date, team: Int64, opponent: Int64, home: Bool, ours: MatchSideStats, theirs: MatchSideStats) {
        self.date = date
        self.team = team
        self.opponent = opponent
        self.home = home
        self.ours = ours
        self.theirs = theirs
    }
}

/// The team stats of the user's club's recent matches. FM keeps them only in its post-match news about the club, such as
/// the match report, so only for matches whose news is still in memory: the last few weeks'. FM keeps no list of them, so
/// the reader sweeps for the summary by its shape: the club's team, another team, and possession that adds up to 100.
public final class MatchStatsReader {
    private let game: GameProcess
    private let resultVt: Int64
    /// The summary's layout was found on one build of game_plugin and isn't covered by anything FM Starship can check on
    /// another, so it's only read on that one, as FM's rules are.
    public let checkedBuild: Bool

    /// `checkedBuild` stands in for the fingerprint, for tests.
    public init(game: GameProcess, rtti: Rtti, checkedBuild: Bool? = nil) {
        self.game = game
        self.checkedBuild = checkedBuild ?? (GameBuild.fingerprint(pluginPath: game.pluginPath) == RulesEngine.Mac27.fingerprint)
        let table = rtti.vtables("FIXTURE_RESULT").first { $0.offsetToTop == 0 }
        resultVt = table.map { game.pluginBase &+ Int64($0.addressPoint) } ?? 0
    }

    /// Every summary of the team's matches that FM holds, one for each match and different figures, oldest first. Each news
    /// item about a match holds a copy. A copy whose date can't be read takes it from a copy with the same figures. Nil on a
    /// build of FM that hasn't been checked.
    public func stats(team: Int64) -> [MatchStats]? {
        guard checkedBuild, team != 0 else { return nil }
        typealias S = MacLayout.MatchSummary
        let teamVt = game.readPointer(team)
        guard teamVt != 0 else { return nil }
        let lock = NSLock()
        var found: [Int64] = []
        let pieces = game.pieces(size: 1 << 23, overlap: 0x100, writableOnly: true)
        DispatchQueue.concurrentPerform(iterations: pieces.count) { i in
            let (address, count) = pieces[i]
            let hits: [Int64] = game.withBytes(address, count: count) { raw in
                var hits: [Int64] = []
                var o = Int((8 - address % 8) % 8)
                while o + S.size <= count {
                    if raw.loadUnaligned(fromByteOffset: o + S.team, as: Int64.self) == team {
                        let ours = raw.loadUnaligned(fromByteOffset: o + S.possession, as: UInt32.self)
                        let theirs = raw.loadUnaligned(fromByteOffset: o + S.possession + 4, as: UInt32.self)
                        if ours <= 100, theirs <= 100, ours + theirs == 100 { hits.append(address + Int64(o)) }
                    }
                    o += 8
                }
                return hits
            } ?? []
            guard !hits.isEmpty else { return }
            lock.lock()
            found += hits
            lock.unlock()
        }

        // The figures of one copy, and its date where it can be read.
        struct Copy: Hashable {
            let opponent: Int64, home: Bool, ours: [Int], theirs: [Int]
        }
        // For each set of figures, the dates its copies' results give, and those their scorelines give.
        var dates: [Copy: (results: Set<Date>, scorelines: Set<Date>)] = [:]
        for address in Set(found).sorted() {
            guard let b = game.read(address, count: S.size) else { continue }
            let opponent = le64(b, S.opponent)
            guard opponent != 0, opponent != team, game.readPointer(opponent) == teamVt, b[S.away] <= 1 else { continue }
            let ours = [Int(le32(b, S.possession)), le16(b, S.xG), Int(b[S.shots]), Int(b[S.shotsOnTarget]), Int(b[S.fouls]), Int(b[S.goals])]
            let theirs = [Int(le32(b, S.possession + 4)), le16(b, S.xG + 2), Int(b[S.theirShots]), Int(b[S.theirShotsOnTarget]),
                          Int(b[S.theirFouls]), Int(b[S.theirGoals])]
            // More on target than shots isn't a match's summary.
            guard ours[3] <= ours[2], theirs[3] <= theirs[2] else { continue }
            let copy = Copy(opponent: opponent, home: b[S.away] == 0, ours: ours, theirs: theirs)
            var known = dates[copy] ?? ([], [])
            if let date = resultDate(b, team: team, opponent: opponent) {
                known.results.insert(date)
            } else if let date = scorelineDate(address) {
                known.scorelines.insert(date)
            }
            dates[copy] = known
        }
        var stats: [MatchStats] = []
        for (copy, known) in dates {
            // A result's date wins. No date, or two for the same figures: it can't be told which match it is.
            let date = known.results.isEmpty ? known.scorelines : known.results
            guard date.count == 1, let date = date.first else { continue }
            func side(_ v: [Int]) -> MatchSideStats {
                MatchSideStats(possession: v[0], xG100: v[1], shots: v[2], shotsOnTarget: v[3], fouls: v[4], goals: v[5])
            }
            stats.append(MatchStats(date: date, team: team, opponent: copy.opponent, home: copy.home, ours: side(copy.ours), theirs: side(copy.theirs)))
        }
        return stats.sorted { ($0.date, $0.opponent) < ($1.date, $1.opponent) }
    }

    /// The match's date from its result, where the copy points at the match's stats and its result is of these two teams.
    private func resultDate(_ b: [UInt8], team: Int64, opponent: Int64) -> Date? {
        typealias S = MacLayout.MatchSummary
        typealias F = MacLayout.Fixture
        // Pointers read from FM's memory are only added to with &+, so a bad one can't trap.
        let matchStats = le64(b, S.matchStats)
        guard resultVt != 0, matchStats != 0 else { return nil }
        let result = game.readPointer(matchStats &+ S.matchStatsResult)
        guard result != 0, game.readPointer(result) == resultVt, let r = game.read(result, count: F.size),
              Set([le64(r, F.home), le64(r, F.away)]) == Set([team, opponent]) else { return nil }
        return GameDate.checked(year: le16(r, F.year), dayOfYear: le16(r, F.date) & 0x1ff)
    }

    /// The match's date from the news item's SCORELINE before the summary.
    private func scorelineDate(_ address: Int64) -> Date? {
        typealias S = MacLayout.MatchSummary
        guard let d = game.read(address &+ Int64(S.day), count: 4) else { return nil }
        return GameDate.checked(year: le16(d, 2), dayOfYear: le16(d, 0) & 0x1ff)
    }

    /// The self-check of one match's summary: the club's shots, shots on target, fouls, goals and xG must be what its
    /// players' match records add up to, both sides' goals the score, and the opponent's xG what the club's goalkeepers
    /// faced. xG within 0.01 either way, as each player's is rounded as the team's is. `records` are the club's players'
    /// records of the match, of those who played. Nil when it passes, else what disagreed.
    public static func check(_ stats: MatchStats, match: MatchFixture, records: [PlayerMatch]) -> String? {
        let home = match.home == stats.team
        guard home == stats.home else {
            return "FM's match stats have the club \(stats.home ? "at home" : "away"), and the fixture \(home ? "at home" : "away")"
        }
        guard let h = match.homeGoals, let a = match.awayGoals else { return "the match has no score" }
        let (us, them) = home ? (h, a) : (a, h)
        guard stats.ours.goals == us, stats.theirs.goals == them else {
            return "FM's match stats give \(stats.ours.goals)-\(stats.theirs.goals), and the score is \(us)-\(them)"
        }
        guard !records.isEmpty else { return "no player's record of the match is left to check them against" }
        var sums = [("shot", "shots", records.reduce(0) { $0 + $1.shots }, stats.ours.shots),
                    ("shot on target", "shots on target", records.reduce(0) { $0 + $1.shotsOnTarget }, stats.ours.shotsOnTarget),
                    ("foul", "fouls", records.reduce(0) { $0 + $1.fouls }, stats.ours.fouls)]
        // An own goal for the club is in no record of its players. Without the result's goal list, which is only kept when
        // it adds up to the score, it can't be told how many there were.
        if us == 0 || !match.goals.isEmpty {
            let ownGoals = match.goals.filter { $0.home == home && $0.ownGoal }.count
            sums.append(("goal", "goals", records.reduce(0) { $0 + $1.goals }, us - ownGoals))
        }
        for (one, many, players, team) in sums where players != team {
            return "the players' records add up to \(players) \(players == 1 ? one : many), and FM's match stats say \(team)"
        }
        func hundredths(_ values: [Double]) -> Int { values.reduce(0) { $0 + Int(($1 * 100).rounded()) } }
        let xG = hundredths(records.compactMap(\.xG))
        guard abs(xG - stats.ours.xG100) <= 1 else {
            return "the players' xG adds up to \(Self.text(xG)), and FM's match stats say \(Self.text(stats.ours.xG100))"
        }
        let faced = records.compactMap(\.xGFaced)
        guard !faced.isEmpty else { return "no goalkeeper's record of the match is left to check the opponent's xG against" }
        guard abs(hundredths(faced) - stats.theirs.xG100) <= 1 else {
            return "the goalkeepers faced \(Self.text(hundredths(faced))) xG, and FM's match stats give the opponent \(Self.text(stats.theirs.xG100))"
        }
        return nil
    }

    private static func text(_ hundredths: Int) -> String { String(format: "%.2f", Double(hundredths) / 100) }
}

// Little-endian fields of a record read into bytes.
private func le16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
private func le32(_ b: [UInt8], _ o: Int) -> UInt32 { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
private func le64(_ b: [UInt8], _ o: Int) -> Int64 { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int64.self) } }
