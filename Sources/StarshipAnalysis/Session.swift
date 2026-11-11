import Foundation
import StarshipCore

/// The club the user runs: `InterestState.Team`, `.ClubName` and `.Manager` in the original.
public struct ChosenClub: Equatable {
    public var team: Int64
    public var name: String
    /// The manager's person record; 0 when the user isn't known to manage the club.
    public var manager: Int64

    public init(team: Int64 = 0, name: String = "", manager: Int64 = 0) {
        self.team = team
        self.name = name
        self.manager = manager
    }

    public static func humanClubs(in db: Database) -> [ChosenClub] {
        db.humanClubs.map { ChosenClub(team: $0.team, name: $0.name, manager: $0.manager) }
    }
}

/// How current and potential ability are shown.
public enum AbilityReveal: Int, CaseIterable {
    case numbers, stars, hidden
}

public struct DisplayOptions {
    /// Always `.hidden` while `showHidden` is off: CA and PA are hidden in FM too.
    public private(set) var reveal: AbilityReveal
    public private(set) var showHidden: Bool
    public var units: MoneyUnits
    /// Inside FM, where FM Starship's tab has a Hidden attributes switch of its own, so the hints point there.
    public var insideGame: Bool

    /// No default for `reveal` or `showHidden`, so every caller says what the settings are.
    public init(reveal: AbilityReveal, showHidden: Bool, units: MoneyUnits = MoneyUnits(), insideGame: Bool = false) {
        self.reveal = showHidden ? reveal : .hidden
        self.showHidden = showHidden
        self.units = units
        self.insideGame = insideGame
    }

    /// False while CA and PA are off, so a screen can leave out whatever would give them away.
    public var showsAbility: Bool { reveal != .hidden }

    /// What to press to see something that needs CA and PA. Inside FM, both are at the top right of FM Starship's tab.
    public var abilityHint: String {
        switch (showHidden, insideGame) {
        case (false, false): return "Switch on Hidden attributes (the eye in the toolbar)"
        case (false, true): return "Switch on Hidden attributes at the top right of FM Starship's tab"
        case (true, false): return "Set Ability in the toolbar to Exact or Stars"
        case (true, true): return "Set Ability to Exact or Stars at the top right of FM Starship's tab"
        }
    }

    /// The table to show: while CA and PA are off, without their columns, those worked out from them, and `others`.
    public func fit(_ table: AnalysisTable, also others: Set<String> = []) -> AnalysisTable {
        showsAbility ? table : table.removing(AnalysisTable.abilityColumns.union(others))
    }

    public func ability(_ value: Int) -> String {
        switch reveal {
        case .stars: return NetFormat.fixed(abilityStars(value), min: 1, max: 1) + "★"
        case .hidden: return "-"
        case .numbers: return "\(value)"
        }
    }

    /// "CA 117", however ability is being shown. Nil while it's hidden, so a sentence can leave it out.
    public func labelled(_ label: String, _ value: Int) -> String? {
        reveal == .hidden ? nil : "\(label) \(ability(value))"
    }

    /// The value at the precision being shown, for drawing it: a bar must not give away more than the numbers beside it.
    public func shown(_ value: Int) -> Int {
        reveal == .numbers ? value : Int(abilityStars(value) * 40)
    }

    func abilityStars(_ value: Int) -> Double {
        (Double(value) / 200 * 10).rounded(.toNearestOrEven) / 2
    }
}

/// One load of the game seen from one club. Everything in this target is computed from a session.
public final class AnalysisSession {
    public let db: Database
    public let club: ChosenClub
    public var display: DisplayOptions
    public let checks: GameChecks
    /// FM's tactics, from the game's files. Nil when they can't be read.
    public let library: TacticLibrary?
    private let curve: DevelopmentCurve

    /// Mentality is hidden, so it only counts while the user shows hidden attributes.
    public var development: DevelopmentCurve { display.showHidden ? curve : curve.hidingMentality() }

    public init(db: Database, club: ChosenClub, display: DisplayOptions, library: TacticLibrary? = nil) {
        self.db = db
        self.club = club
        self.display = display
        self.library = library
        self.checks = GameChecks(club: club)
        curve = DevelopmentCurve(players: db.players, usesHidden: true)
    }

    /// `db.GameDate ?? DateTime.Today`.
    public var today: Date { db.gameDate ?? GameDate.calendar.startOfDay(for: Date()) }

    /// Whether the player is on the same side as this club. Men's clubs only sign men, and women's clubs only women.
    public func canSign(_ player: Player) -> Bool { player.isWoman == db.womensTeams.contains(club.team) }

    /// `db.Budgets[Team]`.
    public var budget: (transfer: Int64, wageRoom: Int)? { db.budgets[club.team] }

    /// The `(int)Average` of the eleven highest CAs, as both the planner and My Club measure the squad.
    static func level(of players: [Player]) -> Int {
        guard !players.isEmpty else { return 0 }
        let best = players.stableSorted { $0.ca > $1.ca }.prefix(11)
        return Int(best.reduce(0.0) { $0 + Double($1.ca) } / Double(best.count))
    }
}

extension Date {
    var addingOneYear: Date { GameDate.calendar.date(byAdding: .year, value: 1, to: self) ?? self }
    var addingEighteenMonths: Date { GameDate.calendar.date(byAdding: .month, value: 18, to: self) ?? self }
    var startOfGameDay: Date { GameDate.calendar.startOfDay(for: self) }
}

extension Sequence {
    /// LINQ's OrderBy keeps equal items in source order, which the rankings depend on.
    func stableSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in
            if areInIncreasingOrder(a.element, b.element) { return true }
            if areInIncreasingOrder(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }

    func chunked(_ size: Int) -> Chunks<Self> { Chunks(self, size: size) }
}

/// LINQ's Chunk, lazy so that an expensive filter upstream only runs for what is looked at.
struct Chunks<Base: Sequence>: Sequence, IteratorProtocol {
    private var iterator: Base.Iterator
    private let size: Int

    init(_ base: Base, size: Int) {
        iterator = base.makeIterator()
        self.size = size
    }

    mutating func next() -> [Base.Element]? {
        var chunk: [Base.Element] = []
        chunk.reserveCapacity(size)
        while chunk.count < size, let item = iterator.next() { chunk.append(item) }
        return chunk.isEmpty ? nil : chunk
    }
}

/// `Parallel.For` with a capped degree of parallelism.
func parallelFor(count: Int, workers: Int, _ body: (Int) -> Void) {
    guard count > 0 else { return }
    let workers = min(workers, count)
    guard workers > 1 else {
        for i in 0..<count { body(i) }
        return
    }
    let lock = NSLock()
    var next = 0
    DispatchQueue.concurrentPerform(iterations: workers) { _ in
        while true {
            lock.lock()
            let i = next
            next += 1
            lock.unlock()
            if i >= count { return }
            body(i)
        }
    }
}

func parallelMap<T, R>(_ items: [T], workers: Int, _ transform: (T) -> R) -> [R] {
    var results = [R?](repeating: nil, count: items.count)
    results.withUnsafeMutableBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        parallelFor(count: items.count, workers: workers) { base[$0] = transform(items[$0]) }
    }
    return results.map { $0! }
}
