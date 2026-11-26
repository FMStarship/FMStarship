import Foundation

/// Each player's yellow cards toward a ban, by FM's own count and FM's own answer, for an answer about him. FM keeps a
/// player's count for each disciplinary rule set he has played under this season (`MacLayout.BookingCount`), and works out
/// how many more bring a ban with `DISCIPLINE::get_count_until_next_ban`, which runs in the sandbox. Only on the build FM's
/// rules were checked on, as they are. One of these goes with each read, and keeps what it has worked out.
///
/// A rule set is named by the competitions that play under it (`ActualComp.rulesSlot`): first the ones his team plays in,
/// its league and the competitions in its recent matches, else others FM holds fixtures of. FM resets the counts, at the
/// change of season for a league and after the qualifying rounds for UEFA's competitions, at points FM Starship hasn't found.
///
/// The read is checked before anything is given, and switched off with the reason when the check fails: the rule sets must
/// carry their own numbers, players' lists of counts must be lists of counts, FM's answer must go by the count read, and FM's
/// answers must agree with the bans for bookings given in the last `checkDays` days under the rule sets of the human clubs'
/// competitions, each of which must have come at a step of FM's.
public final class BookingsReader {
    /// How far back the check takes bans for bookings. A ban given before a reset no longer matches the count, so the
    /// check only looks at recent ones.
    public static let checkDays = 30
    /// How far back a team's matches show the competitions it plays in.
    public static let playsDays = 120
    /// More yellow cards than this under one rule set in a season isn't a count.
    static let mostCount = 60
    /// More counts than this for one player isn't a list of them.
    static let mostCounts = 64
    /// How many players at a club, past the human clubs' and the banned, the check looks at.
    static let sample = 1_000

    private let game: GameProcess
    private let database: Database
    private let engine: GameRulesEngine?
    /// Each competition's `db::COMP` by database index, from a sweep of FM's fixtures, asked for once.
    private let sweep: () -> [UInt32: Int64]

    private struct RuleSet { let address: Int64, plain: Bool }
    private struct Competition { let index: UInt32, name: String, record: Int64 }
    /// One of a player's counts, as its 16 bytes.
    private struct Count {
        let rules: Int
        let bytes: [UInt8]
        var value: Int { Int(bytes[MacLayout.BookingCount.count]) }
    }

    private var result: String??
    private var checkedText = ""
    private var ruleSets: [Int: RuleSet] = [:]
    private var recordsByIndex: [UInt32: Int64]?
    private var rulesOfRecord: [Int64: Int?] = [:]
    private var competitionsByRules: [Int: [Competition]]?
    private var plays: [Int64: [Competition]] = [:]

    public init(game: GameProcess, database: Database, engine: GameRulesEngine?, competitionRecords: @escaping () -> [UInt32: Int64]) {
        self.game = game
        self.database = database
        self.engine = engine
        sweep = competitionRecords
    }

    /// Why it's off for this read, once its check has run. Nil while it's on.
    public var off: String? {
        if result == nil { result = .some(check()) }
        return result ?? nil
    }

    /// For `game_status`: on with what the check found, or off and why.
    public var status: String { off.map { "off: \($0)" } ?? "on: \(checkedText)" }

    /// His count under each rule set his team plays under, from 0 where he has none yet, and under any other where he has
    /// a card, each with FM's answer. His team's come first, its league's first of all. Nil when it's off or his list of
    /// counts can't be read.
    public func bookings(of player: Player) -> [Booking]? {
        guard off == nil, let engine, player.block > 0, let counts = counts(player.block) else { return nil }
        let team = game.readPointer(player.block &+ Int64(MacLayout.Player.currentTeam))
        let league = team > 0 ? game.readPointer(team &+ Int64(MacLayout.Team.competition)) : 0
        var theirs: [Int: [Competition]] = [:]
        for competition in competitions(of: team) {
            if let rules = rules(of: competition.record) { theirs[rules, default: []].append(competition) }
        }
        let own = Dictionary(counts.map { ($0.rules, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = Set(theirs.keys).union(counts.filter { $0.value > 0 }.map(\.rules))
        var bookings: [(booking: Booking, order: (Int, Int, String))] = []
        for rules in shown {
            let plain = ruleSets[rules]?.plain ?? false
            var next = plain ? engine.nextBan(rules: rules, bookingCount: own[rules]?.bytes) : nil
            // FM must have gone by the count as it is now, or its answer is for another.
            if let answer = next, answer.count != own[rules]?.value ?? 0 { next = nil }
            var booking: Booking
            if let mine = theirs[rules] {
                let names = mine.sorted { ($0.record == league ? 0 : 1, $0.name) < ($1.record == league ? 0 : 1, $1.name) }.map(\.name)
                booking = Booking(rules: rules, competitions: names, teamPlays: true, plain: plain, next: next)
            } else {
                let others = (usedBy()[rules] ?? []).map(\.name).sorted()
                booking = Booking(rules: rules, competitions: Array(others.prefix(3)), teamPlays: false, plain: plain, next: next)
                booking.moreCompetitions = max(0, others.count - 3)
            }
            let hasLeague = theirs[rules]?.contains { $0.record == league } == true
            bookings.append((booking, (booking.teamPlays ? (hasLeague ? 0 : 1) : 2, -(own[rules]?.value ?? 0), booking.competitions.first ?? "")))
        }
        return bookings.sorted { ($0.order.0, $0.order.1, $0.order.2, $0.booking.rules) < ($1.order.0, $1.order.1, $1.order.2, $1.booking.rules) }
            .map(\.booking)
    }

    // MARK: Reads

    /// A player's counts, or nil when they aren't a list of counts. Pointers from FM's memory are only added to with &+.
    private func counts(_ block: Int64) -> [Count]? {
        typealias B = MacLayout.BookingCount
        guard let head = game.read(block &+ Int64(MacLayout.Player.bookingCounts), count: 16) else { return nil }
        let begin = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int64.self) }
        let end = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Int64.self) }
        if begin == 0, end == 0 { return [] }
        guard begin > 0, end >= begin, (end &- begin) % 8 == 0, (end &- begin) / 8 <= Int64(Self.mostCounts) else { return nil }
        let slots = Int((end &- begin) / 8)
        guard slots > 0 else { return [] }
        guard let words = game.read(begin, count: slots * 8) else { return nil }
        var found: [Count] = []
        for slot in 0..<slots {
            let entry = words.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: slot * 8, as: Int64.self) }
            guard entry > 0, let bytes = game.read(entry, count: B.size) else { return nil }
            let rules = Int(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: B.rules, as: Int16.self) })
            guard ruleSets[rules] != nil, Int(bytes[B.count]) <= Self.mostCount, !found.contains(where: { $0.rules == rules }) else { return nil }
            found.append(Count(rules: rules, bytes: bytes))
        }
        return found
    }

    /// FM's rule sets by rules index, each of which must carry its own. Nil when they can't be read.
    private func readRuleSets(_ discipline: Int64) -> String? {
        typealias R = MacLayout.DisciplineRules
        let begin = game.readPointer(discipline &+ MacLayout.Discipline.rules)
        let end = game.readPointer(discipline &+ MacLayout.Discipline.rules &+ 8)
        guard begin > 0, end > begin, (end &- begin) % 8 == 0, (end &- begin) / 8 <= 4_096,
              let words = game.read(begin, count: Int(end &- begin)) else {
            return "its check failed: FM's list of disciplinary rule sets isn't one"
        }
        var wrong = 0
        for index in 0..<words.count / 8 {
            let address = words.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 8, as: Int64.self) }
            guard address > 0, let own = game.read(address &+ R.index, count: 2), let type = game.read(address &+ R.countType, count: 1),
                  Int(own[0]) | Int(own[1]) << 8 == index else {
                wrong += 1
                continue
            }
            ruleSets[index] = RuleSet(address: address, plain: type[0] == R.plainCount)
        }
        guard wrong == 0 else {
            ruleSets = [:]
            return "its check failed: \(wrong) of \(words.count / 8) of FM's disciplinary rule sets don't carry their own number"
        }
        return nil
    }

    /// The rules index a competition plays under, by the path FM's own check takes. Nil for none, or where the rule set
    /// found isn't the one FM keeps at that index.
    private func rules(of comp: Int64) -> Int? {
        guard comp > 0 else { return nil }
        if let known = rulesOfRecord[comp] { return known }
        var found: Int?
        let actual = game.readPointer(comp &+ MacLayout.Comp.actual)
        if actual > 0, let slot = game.read(actual &+ MacLayout.ActualComp.rulesSlot, count: 1).map({ Int64(Int8(bitPattern: $0[0])) }), slot >= 0 {
            let owner = game.readPointer(actual &+ MacLayout.ActualComp.rulesOwner)
            let holder = owner > 0 ? game.readPointer(owner &+ MacLayout.CompRules.holder) : 0
            let begin = holder > 0 ? game.readPointer(holder &+ MacLayout.CompRules.list) : 0
            let end = holder > 0 ? game.readPointer(holder &+ MacLayout.CompRules.list &+ 8) : 0
            if begin > 0, end > begin, slot < (end &- begin) / 8 {
                let ruleSet = game.readPointer(begin &+ slot &* 8)
                if ruleSet > 0, let own = game.read(ruleSet &+ MacLayout.DisciplineRules.index, count: 2) {
                    let index = Int(own[0]) | Int(own[1]) << 8
                    if ruleSets[index]?.address == ruleSet { found = index }
                }
            }
        }
        rulesOfRecord[comp] = .some(found)
        return found
    }

    private func competition(_ record: Int64) -> Competition? {
        guard record > 0, let b = game.read(record &+ MacLayout.Comp.index, count: 4) else { return nil }
        let name = game.lengthPrefixedString(game.readPointer(record &+ Int64(MacLayout.competitionName)))
        return name.isEmpty ? nil : Competition(index: b.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, name: name, record: record)
    }

    private func records() -> [UInt32: Int64] {
        if let known = recordsByIndex { return known }
        let found = sweep()
        recordsByIndex = found
        return found
    }

    /// Every competition FM holds fixtures of, by the rule set it plays under.
    private func usedBy() -> [Int: [Competition]] {
        if let known = competitionsByRules { return known }
        var found: [Int: [Competition]] = [:]
        for record in records().values {
            if let competition = competition(record), let rules = rules(of: record) { found[rules, default: []].append(competition) }
        }
        competitionsByRules = found
        return found
    }

    /// The competitions a team plays in: its league, and the ones in the matches its players' records keep for it from the
    /// last `playsDays` days.
    private func competitions(of team: Int64) -> [Competition] {
        guard team > 0 else { return [] }
        if let known = plays[team] { return known }
        var found: [Competition] = []
        if let league = competition(game.readPointer(team &+ Int64(MacLayout.Team.competition))) { found.append(league) }
        let club = game.readPointer(team &+ Int64(MacLayout.Team.club))
        if club > 0, let today = database.gameDate, let from = GameDate.calendar.date(byAdding: .day, value: -Self.playsDays, to: today) {
            var indexes = Set<UInt32>()
            for player in database.players where player.block > 0 && (player.clubObject == club || player.loanClubObject == club) {
                guard game.readPointer(player.block &+ Int64(MacLayout.Player.currentTeam)) == team else { continue }
                let matches = FixturesReader.history(player: player.block, in: game) { _ in "" }.matches
                indexes.formUnion(matches.filter { $0.team == team && $0.date >= from && $0.date <= today }.map(\.competitionIndex))
            }
            indexes.subtract(found.map(\.index))
            if !indexes.isEmpty {
                let byIndex = records()
                found += indexes.sorted().compactMap { byIndex[$0].flatMap(competition) }
            }
        }
        plays[team] = found
        return found
    }

    // MARK: The check

    private func check() -> String? {
        guard let engine else { return "it comes from FM's own rules, which are off on this build" }
        guard let discipline = engine.discipline else { return "FM's disciplinary rules weren't found where FM keeps them on this build" }
        if let failed = readRuleSets(discipline) { return failed }
        if let why = database.stateOff[.bans] { return "it's checked against the save's bans, which are off: \(why)" }
        guard let today = database.gameDate, let from = GameDate.calendar.date(byAdding: .day, value: -Self.checkDays, to: today) else {
            return "the read found no game date to check it against the save's bans"
        }

        // The human clubs' players, the players banned for bookings lately under their competitions' rule sets, and a
        // sample of everyone else at a club.
        let humanClubs = Set(database.humanClubs.map { game.readPointer($0.team &+ Int64(MacLayout.Team.club)) }.filter { $0 > 0 })
        var checkedRules = Set<Int>()
        for club in database.humanClubs {
            for competition in competitions(of: club.team) { if let rules = rules(of: competition.record) { checkedRules.insert(rules) } }
            // Every league plays under a rule set, so one that doesn't lead to one is a path that has moved.
            let league = game.readPointer(club.team &+ Int64(MacLayout.Team.competition))
            if league > 0, rules(of: league) == nil {
                return "its check failed: the rule set \(club.name)'s league plays under wasn't found where FM keeps it"
            }
        }
        let atClubs = database.players.filter { $0.block > 0 && $0.clubObject != 0 }
        var newest: [Int64: [Int: StoredBan]] = [:]
        for player in atClubs {
            for ban in player.storedBans ?? [] where ban.kind == MacLayout.Ban.bookings && ban.bookingsAt > 0 && checkedRules.contains(ban.rules) {
                guard let issued = ban.issued, issued >= from, issued <= today else { continue }
                if let other = newest[player.block]?[ban.rules], (other.year, other.day) > (ban.year, ban.day) { continue }
                newest[player.block, default: [:]][ban.rules] = ban
            }
        }
        let asked = atClubs.filter { humanClubs.contains($0.clubObject) || humanClubs.contains($0.loanClubObject) || newest[$0.block] != nil }
        let askedBlocks = Set(asked.map(\.block))
        let others = atClubs.filter { !askedBlocks.contains($0.block) }
        let step = max(1, others.count / Self.sample)
        let sampled = asked + stride(from: 0, to: others.count, by: step).map { others[$0] }

        var lists: [Int64: [Count]] = [:]
        var bad = 0, withCounts = 0
        for player in sampled {
            guard let found = counts(player.block) else { bad += 1; continue }
            lists[player.block] = found
            if !found.isEmpty { withCounts += 1 }
        }
        if bad * 100 > sampled.count {
            return "its check failed: \(bad.formatted()) of \(sampled.count.formatted()) players at a club have a list of yellow-card counts that isn't one"
        }
        if sampled.count >= 500, withCounts == 0 {
            return "its check failed: none of \(sampled.count.formatted()) players at a club has a yellow-card count"
        }

        // FM's answer must go by the count read, and say something a count can.
        var answers: [Int64: [Int: NextBan]] = [:]
        var asks = 0, unanswered = 0, wrong = 0
        for player in asked {
            for count in lists[player.block] ?? [] where ruleSets[count.rules]?.plain == true {
                asks += 1
                guard let next = engine.nextBan(rules: count.rules, bookingCount: count.bytes) else { unanswered += 1; continue }
                if next.count != count.value || next.left < 1 || next.length < 1 || next.lastBanAt > next.count { wrong += 1 }
                answers[player.block, default: [:]][count.rules] = next
            }
        }
        if wrong > 0 {
            return "its check failed: FM's own answer didn't fit the count read for \(wrong.formatted()) of \(asks.formatted()) counts"
        }
        if unanswered * 100 > asks {
            return "its check failed: FM's rules didn't answer for \(unanswered.formatted()) of \(asks.formatted()) counts"
        }

        // Each ban came at a count FM's answer says was a step, and the count hasn't gone back below it.
        var agree = 0, disagree = 0
        for (block, bans) in newest {
            for (rules, ban) in bans where ruleSets[rules]?.plain == true {
                if let next = answers[block]?[rules], next.count >= ban.bookingsAt, next.lastBanAt == ban.bookingsAt { agree += 1 } else { disagree += 1 }
            }
        }
        let scope = "given in the last \(Self.checkDays) days under the rule sets of your club's competitions"
        if disagree * 10 > agree + disagree {
            return "its check failed: FM's answers disagree with \(disagree) of \(agree + disagree) bans for bookings \(scope)"
        }
        checkedText = agree + disagree == 0
            ? "FM's own count and answer, checked against \(asks.formatted()) counts; no ban for bookings was \(scope), so none to check them against"
            : "FM's own count and answer, checked against \(asks.formatted()) counts and \(agree) of \(agree + disagree) bans for bookings \(scope)"
        return nil
    }
}
