import Foundation

/// Each competition's squad rules as FM holds them, and FM's own per-player values for them, for an answer about a squad.
/// Only on the build FM's rules were checked on, as they are. One of these goes with each read, and keeps what it has worked
/// out.
///
/// A competition's rules are reached by the path FM's import code writes: its `ActualComp.fixtureRulesSlot` picks one of the
/// `FixtureRules` its rules owner holds, and that holds the rules now. Each rule names its type by a number in FM's own table
/// of names, which the rules engine reads, so FM Starship holds no list of its own. Whether a player counts toward a rule is
/// FM's own `PLAYER::get_squad_selection_rule_value`, run in the sandbox.
///
/// FM keeps no list of who is registered for a competition for a club like Molde, so this counts whichever players it's
/// given. It never says who is registered.
///
/// The read is checked before anything is given, and switched off with the reason when the check fails: FM's tables must
/// read back as FM's, each rule set must carry its own entry and owner, and FM's per-player values must count everyone at
/// the human clubs toward squad size and agree with FM's own home-grown tests (`RulesEngine.homeGrown`) for each of them.
/// The rules can be on while the values are off, and are then given without counts.
public final class SquadRulesReader {
    /// More rule sets than this for one owner isn't a list of them.
    static let mostRuleSets = 256
    /// More rules than this in one rule set isn't a list of them.
    static let mostRules = 64
    /// A limit of players outside this isn't one.
    static let limits = 0...1_000
    /// FM's names for a rule's direction, as FM's own table gives them.
    static let directionNames = [-1: "less_than", 0: "equals", 1: "more_than"]
    /// FM's names for the types the check asks for: squad size, and the three home-grown ones.
    static let sizeType = "max_squad_size"
    static let atClubType = "homegrown_players_from_club"
    static let inNationType = "homegrown_players_from_nation"
    static let notHomeGrownType = "non_homegrown_players_in_squad"

    private let game: GameProcess
    private let database: Database
    private let engine: GameRulesEngine?
    /// Each competition's `db::COMP` by database index, from a sweep of FM's fixtures, asked for once.
    private let sweep: () -> [UInt32: Int64]

    private var result: String??
    private var valuesResult: String??
    private var checkedText = ""
    private var types: [Int: [String]] = [:]
    private var recordsByIndex: [UInt32: Int64]?
    private var leagues: [UInt32: Int64] = [:]
    private var sets: [Int64: SquadRuleSet] = [:]

    public init(game: GameProcess, database: Database, engine: GameRulesEngine?, competitionRecords: @escaping () -> [UInt32: Int64]) {
        self.game = game
        self.database = database
        self.engine = engine
        sweep = competitionRecords
    }

    /// Why the rules are off for this read, once their check has run. Nil while they're on.
    public var off: String? {
        if result == nil { result = .some(check()) }
        return result ?? nil
    }

    /// Why FM's per-player values are off for this read, so the rules are given without counts. Nil while they're on.
    public var countsOff: String? {
        if let off { return "FM's squad rules are off: \(off)" }
        if valuesResult == nil { valuesResult = .some(checkValues()) }
        return valuesResult ?? nil
    }

    /// For `game_status`: on with what the check found, or off and why.
    public var status: String {
        if let off { return "off: \(off)" }
        if let countsOff { return "on, without counts: \(countsOff)" }
        return "on: \(checkedText)"
    }

    /// The competitions FM holds fixtures of, by database index.
    public func competitionNames() -> [UInt32: String] {
        records().compactMapValues { record in
            let name = game.lengthPrefixedString(game.readPointer(record &+ Int64(MacLayout.competitionName)))
            return name.isEmpty ? nil : name
        }
    }

    /// The database index of a team's league. Nil where it has none.
    public func league(of team: Int64) -> UInt32? {
        guard team > 0 else { return nil }
        let record = game.readPointer(team &+ Int64(MacLayout.Team.competition))
        guard record > 0, let index = compIndex(record) else { return nil }
        leagues[index] = record
        return index
    }

    /// FM's squad rules for one competition, by database index. Nil where it's off, or the competition's record isn't known.
    public func rules(competition index: UInt32) -> SquadRuleSet? {
        guard off == nil, let record = leagues[index] ?? records()[index] else { return nil }
        return ruleSet(record)
    }

    /// One rule counted against these players, for `team`, by FM's own value for each of them. A rule of squad size counts
    /// everyone, as FM's value did for everyone at the human clubs in the check.
    public func count(_ rule: SquadRule, in set: SquadRuleSet, players: [Player], team: Int64) -> SquadRuleCount {
        if let countsOff { return SquadRuleCount(rule: rule, players: nil, notCounted: countsOff) }
        if let why = rule.notCounted { return SquadRuleCount(rule: rule, players: nil, notCounted: why) }
        if rule.isSize { return SquadRuleCount(rule: rule, players: players) }
        guard let engine else { return SquadRuleCount(rule: rule, players: nil, notCounted: "FM's own rules are off on this build") }
        var counted: [Player] = []
        var unanswered = 0
        var odd: (player: Player, value: Int)?
        for player in players {
            guard let value = engine.squadRuleValue(player: player, type: rule.type, team: team, group: set.group, competition: set.record) else {
                unanswered += 1
                continue
            }
            if value == 1 { counted.append(player) } else if value != 0, odd == nil { odd = (player, value) }
        }
        if let odd {
            return SquadRuleCount(rule: rule, players: nil,
                                  notCounted: "FM's value for it was \(odd.value) for \(odd.player.name), not 0 or 1, so what it counts isn't known")
        }
        if unanswered > 0 {
            return SquadRuleCount(rule: rule, players: nil,
                                  notCounted: "FM's rules didn't answer for \(unanswered) of \(players.count) players")
        }
        return SquadRuleCount(rule: rule, players: counted)
    }

    // MARK: Reads

    private func records() -> [UInt32: Int64] {
        if let known = recordsByIndex { return known }
        let found = sweep()
        recordsByIndex = found
        return found
    }

    private func compIndex(_ record: Int64) -> UInt32? {
        game.read(record &+ MacLayout.Comp.index, count: 4).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
    }

    /// A competition's rule set, by the path FM's import code writes, read once.
    private func ruleSet(_ record: Int64) -> SquadRuleSet {
        if let known = sets[record] { return known }
        let found = readRuleSet(record)
        sets[record] = found
        return found
    }

    private func readRuleSet(_ record: Int64) -> SquadRuleSet {
        typealias F = MacLayout.FixtureRules
        let name = game.lengthPrefixedString(game.readPointer(record &+ Int64(MacLayout.competitionName)))
        var set = SquadRuleSet(index: compIndex(record) ?? 0, name: name, record: record, group: -1, rules: [])
        func unreadable(_ why: String) -> SquadRuleSet {
            set.unreadable = why
            return set
        }
        let actual = game.readPointer(record &+ MacLayout.Comp.actual)
        guard actual > 0, let slotByte = game.read(actual &+ MacLayout.ActualComp.fixtureRulesSlot, count: 1) else {
            return unreadable("its record didn't lead to the competition FM runs")
        }
        let slot = Int64(Int8(bitPattern: slotByte[0]))
        // No rule set: FM holds no squad rules for it.
        guard slot >= 0 else { return set }
        let owner = game.readPointer(actual &+ MacLayout.ActualComp.rulesOwner)
        let holder = owner > 0 ? game.readPointer(owner &+ MacLayout.CompRules.holder) : 0
        let begin = holder > 0 ? game.readPointer(holder &+ MacLayout.CompRules.fixtureRules) : 0
        let end = holder > 0 ? game.readPointer(holder &+ MacLayout.CompRules.fixtureRules &+ 8) : 0
        guard begin > 0, end > begin, (end &- begin) % 8 == 0, (end &- begin) / 8 <= Int64(Self.mostRuleSets), slot < (end &- begin) / 8 else {
            return unreadable("its rule set wasn't where FM keeps it")
        }
        let rules = game.readPointer(begin &+ slot &* 8)
        guard rules > 0, game.readPointer(rules &+ F.owner) == owner, let own = game.read(rules &+ F.slot, count: 1), Int64(own[0]) == slot,
              let group = game.read(rules &+ F.group, count: 1) else {
            return unreadable("the rule set found doesn't carry its own entry and owner, so it isn't the one FM keeps there")
        }
        set.group = Int(Int8(bitPattern: group[0]))
        let list = game.readPointer(rules &+ F.squadRules)
        guard list != 0 else { return set }
        guard list > 0 else { return unreadable("its list of squad rules isn't one") }
        let first = game.readPointer(list), last = game.readPointer(list &+ 8)
        if first == 0, last == 0 { return set }
        guard first > 0, last >= first, (last &- first) % 8 == 0, (last &- first) / 8 <= Int64(Self.mostRules),
              let words = game.read(first, count: Int(last &- first)) else {
            return unreadable("its list of squad rules isn't one")
        }
        typealias R = MacLayout.SquadRule
        for index in 0..<words.count / 8 {
            let address = words.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 8, as: Int64.self) }
            guard address > 0, let bytes = game.read(address, count: R.size) else { return unreadable("one of its squad rules couldn't be read") }
            let limit = Int(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: R.limit, as: Int32.self) })
            let type = Int(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: R.type, as: UInt16.self) })
            let direction: SquadRule.Direction
            switch Int8(bitPattern: bytes[R.direction]) {
            case -1: direction = .atMost
            case 0: direction = .exactly
            case 1: direction = .atLeast
            default: return unreadable("one of its squad rules has a direction FM's table doesn't name")
            }
            guard let names = types[type], !names.isEmpty else { return unreadable("one of its squad rules has a type FM's table doesn't name") }
            let conditional = bytes[R.condition..<(R.condition + R.conditionSize)].contains { $0 != 0 }
            let rule = SquadRule(type: type, names: names, limit: limit, direction: direction, conditional: conditional)
            // Others, such as a cap on wages, have limits of their own.
            if rule.notCounted == nil, !Self.limits.contains(limit) {
                return unreadable("one of its squad rules has a limit of \(limit) players")
            }
            set.rules.append(rule)
        }
        return set
    }

    // MARK: The checks

    private func check() -> String? {
        guard let engine else { return "they come from FM's own rules, which are off on this build" }
        guard let found = engine.squadRuleTypes else {
            return "FM's table of squad-rule types wasn't found where FM keeps it on this build, or didn't read back as one"
        }
        guard engine.squadRuleDirections == Self.directionNames else {
            return "FM's names for a rule's direction aren't less_than, equals and more_than where FM keeps them on this build"
        }
        types = found
        // Every human club's league must lead to a rule set that carries its own entry and owner, or the path has moved.
        for club in database.humanClubs {
            guard let index = league(of: club.team), let record = leagues[index] else { continue }
            if let why = ruleSet(record).unreadable {
                return "its check failed: the squad rules of \(club.name)'s league couldn't be read: \(why)"
            }
        }
        return nil
    }

    /// FM's per-player values for everyone at the human clubs: squad size must count them all, and the three home-grown types
    /// must agree with FM's own two tests.
    private func checkValues() -> String? {
        guard let engine else { return "they come from FM's own rules, which are off on this build" }
        func type(_ name: String) -> Int? { types.first { $0.value.contains(name) }?.key }
        guard let size = type(Self.sizeType), let atClub = type(Self.atClubType), let inNation = type(Self.inNationType),
              let notHomeGrown = type(Self.notHomeGrownType) else {
            return "its check failed: FM's table of squad-rule types doesn't name the ones the check asks for"
        }
        var asked = 0, unanswered = 0, wrong = 0, homeGrownAsked = 0
        var clubs: [String] = []
        for club in database.humanClubs {
            let object = game.readPointer(club.team &+ Int64(MacLayout.Team.club))
            guard object > 0, let index = league(of: club.team), let record = leagues[index] else { continue }
            let set = ruleSet(record)
            let players = database.players.filter { $0.block > 0 && $0.clubObject == object }
            guard !players.isEmpty else { continue }
            clubs.append(club.name)
            for player in players {
                func value(_ type: Int) -> Int? {
                    asked += 1
                    let found = engine.squadRuleValue(player: player, type: type, team: club.team, group: set.group, competition: record)
                    if found == nil { unanswered += 1 }
                    return found
                }
                if let counted = value(size), counted != 1 { wrong += 1 }
                guard let homeGrown = engine.homeGrown(player: player) else { continue }
                homeGrownAsked += 1
                let expected = [(atClub, homeGrown == .club), (inNation, homeGrown != .no), (notHomeGrown, homeGrown == .no)]
                for (type, yes) in expected {
                    if let found = value(type), found != (yes ? 1 : 0) { wrong += 1 }
                }
            }
        }
        guard asked > 0 else { return "its check failed: no player at a human club to check FM's values against" }
        if unanswered > 0 {
            return "its check failed: FM's rules didn't answer for \(unanswered.formatted()) of \(asked.formatted()) values"
        }
        if wrong > 0 {
            return "its check failed: \(wrong.formatted()) of \(asked.formatted()) of FM's values disagree with squad size or FM's own "
                + "home-grown tests for the players at \(clubs.joined(separator: " and "))"
        }
        guard homeGrownAsked > 0 else { return "its check failed: FM's home-grown tests didn't answer for anyone to check against" }
        checkedText = "FM's own rules and per-player values, checked against squad size and FM's own home-grown tests for "
            + "\(homeGrownAsked.formatted()) players at \(clubs.joined(separator: " and "))"
        return nil
    }
}
