import Foundation

/// The scout's predicted line-up for another team, from FM's opposition report: a news item, so only there while FM keeps it.
public struct ScoutReport {
    /// The report's date, as FM's news gives it.
    public let date: Date
    public let tactic: Tactic

    public init(date: Date, tactic: Tactic) {
        self.date = date
        self.tactic = tactic
    }
}

/// The matchday squad the user has picked, read again when it's asked for, since FM's date doesn't move while they pick it,
/// and FM's scout reports on other teams, swept for apart from `GameReader.readAll`.
public final class SelectionReader {
    private let game: GameProcess
    private let reportVt: Int64

    public init(game: GameProcess, rtti: Rtti) {
        self.game = game
        let table = rtti.vtables("SCOUT_TEAM_REPORT_NEWS").first { $0.offsetToTop == 0 }
        reportVt = table.map { game.pluginBase + Int64($0.addressPoint) } ?? 0
    }

    /// The tactic as FM's array holds it now. Nil when it no longer reads as one.
    public func tactic(again tactic: Tactic, players: [UInt32: Player]) -> Tactic? {
        guard tactic.array != 0, var found = GameReader.tactic(at: tactic.array, in: game, players: players) else { return nil }
        found.fmShape = tactic.fmShape
        found.fmShapeWithoutBall = tactic.fmShapeWithoutBall
        return found
    }

    /// Whether this build of FM has the class the reports are found by.
    public var findsReports: Bool { reportVt != 0 }

    /// Every opposition report FM holds, newest first, one for each date and line-up: FM keeps two copies of each.
    public func scoutReports(players: [UInt32: Player]) -> [ScoutReport] {
        typealias S = MacLayout.ScoutReport
        guard reportVt != 0 else { return [] }
        let lock = NSLock()
        var found = Set<Int64>()
        let pieces = game.pieces(size: 1 << 23, overlap: 0x100, writableOnly: true)
        let reportVt = reportVt
        DispatchQueue.concurrentPerform(iterations: pieces.count) { i in
            let (address, count) = pieces[i]
            let hits: [Int64] = game.withBytes(address, count: count) { raw in
                var hits: [Int64] = []
                var o = Int((8 - address % 8) % 8)
                while o + 8 <= count {
                    if raw.loadUnaligned(fromByteOffset: o, as: Int64.self) == reportVt { hits.append(address + Int64(o)) }
                    o += 8
                }
                return hits
            } ?? []
            guard !hits.isEmpty else { return }
            lock.lock()
            found.formUnion(hits)
            lock.unlock()
        }
        var reports: [ScoutReport] = []
        struct Key: Hashable { let date: Date, players: [UInt32?] }
        var seen = Set<Key>()
        for report in found.sorted() {
            guard let day = game.read(report &+ S.day, count: 2), let year = game.read(report &+ S.year, count: 2),
                  let date = GameDate.checked(year: Int(year[0]) | Int(year[1]) << 8, dayOfYear: (Int(day[0]) | Int(day[1]) << 8) & 0x1ff),
                  let tactic = S.tactics.lazy.compactMap({ GameReader.tactic(at: report &+ $0 &+ S.tacticArray, in: self.game, players: players) }).first
            else { continue }
            guard seen.insert(Key(date: date, players: tactic.slots.map(\.index) + tactic.bench.map { $0?.index })).inserted else { continue }
            reports.append(ScoutReport(date: date, tactic: tactic))
        }
        return reports.sorted { $0.date > $1.date }
    }
}
