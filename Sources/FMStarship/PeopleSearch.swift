import Foundation
import StarshipCore
import StarshipSearch

/// `listUids` in the original: who a shortlist holds, less those already at your club. They stay in the file.
struct ShortlistFilter {
    let uids: Set<UInt32>
    let myClub: String

    func includes(_ person: Person) -> Bool {
        uids.contains(person.uid) && (myClub.isEmpty || person.clubFull != myClub)
    }
}

/// The game's "would he join" check, as one step of a search.
struct InterestStep<Row: Person> {
    let label: String
    let check: ([Row], CancelToken) -> Void
    let passes: (Row) -> Bool
    let answered: (Row) -> Bool
}

/// One run of a list, read up front so it can go off the main thread. The order is the original's: criteria,
/// column filters, the shortlist, the checks, then sorting.
struct PeopleSearch<Row: Person> {
    var people: [Row]
    var match: ([Row]) -> [Row]
    var columnFilters: [(col: Col, filter: ColumnFilter)]
    var shortlist: ShortlistFilter?
    var interest: InterestStep<Row>?
    var sortBy: Col?
    var descending: Bool
    /// `Columns.ordered`, which leaves columns that sort after the checks in the default order.
    var ordered: ([Row]) -> [Row]

    struct Outcome {
        let rows: [Row]
        /// People the game gave no answer for, who can't be said either way.
        let unanswered: Int
    }

    /// Nil when cancelled.
    func run(token: CancelToken, status: (String) -> Void, partial: ([Row]) -> Void) -> Outcome? {
        var rows = match(people)
        if !columnFilters.isEmpty { rows = rows.filter { ColumnFilter.matchesAll(columnFilters, $0) } }
        if let shortlist { rows = rows.filter(shortlist.includes) }
        if token.isCancelled { return nil }

        var unanswered = 0
        if let interest {
            guard let narrowed = progressive(ordered(rows), interest, token: token, status: status, partial: partial) else { return nil }
            rows = narrowed.rows
            unanswered = narrowed.unanswered
        }
        if sortBy?.name == "Days out" {
            workOutDaysOut(rows, token: token, status: status)
        }
        if token.isCancelled { return nil }

        if interest != nil, !Columns.sortsAfterChecks(sortBy) { return Outcome(rows: rows, unanswered: unanswered) }
        if let sortBy { return Outcome(rows: Columns.sortRows(rows, by: sortBy, descending: descending), unanswered: unanswered) }
        return Outcome(rows: ordered(rows), unanswered: unanswered)
    }

    /// Checks in growing batches so that the list fills as it goes: 300 first, doubling up to 6,000.
    private func progressive(_ rows: [Row], _ interest: InterestStep<Row>, token: CancelToken,
                             status: (String) -> Void, partial: ([Row]) -> Void) -> Outcome? {
        var found: [Row] = []
        var unanswered = 0
        var next = 0
        var size = 300
        while next < rows.count {
            if token.isCancelled { return nil }
            let batch = Array(rows[next..<min(next + size, rows.count)])
            interest.check(batch, token)
            if token.isCancelled { return nil }
            for row in batch {
                if interest.passes(row) {
                    found.append(row)
                } else if !interest.answered(row) {
                    unanswered += 1
                }
            }
            next += batch.count
            size = min(size * 2, 6000)
            status("\(interest.label)... \(next.formatted()) of \(rows.count.formatted()) checked, \(found.count.formatted()) found so far")
            if next < rows.count { partial(found) }
        }
        return Outcome(rows: found, unanswered: unanswered)
    }

    private func workOutDaysOut(_ rows: [Row], token: CancelToken, status: (String) -> Void) {
        guard GameRules.engine?.supportsInjuryDays == true else { return }
        let injured = rows.compactMap { $0 as? Player }.filter { $0.injury != nil }
        guard !injured.isEmpty else { return }
        status("Working out days out for injured players...")
        concurrently(injured, workers: RulesState.defaultWorkers, token: token) { _ = RulesState.shared.injuryCheck($0) }
    }
}

/// Runs `work` on each item from several threads, stopping early when cancelled.
func concurrently<Item>(_ items: [Item], workers: Int, token: CancelToken, _ work: (Item) -> Void) {
    let lock = NSLock()
    var next = 0
    DispatchQueue.concurrentPerform(iterations: max(1, min(workers, items.count))) { _ in
        while !token.isCancelled {
            lock.lock()
            let index = next
            next += 1
            lock.unlock()
            guard index < items.count else { return }
            work(items[index])
        }
    }
}
