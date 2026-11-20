import Foundation

/// A player's state for an answer about him: brought up to FM's memory now, and his bans with what they're for. A read
/// of the save keeps bans as FM stores them, since working out what they're for takes more reads than the app needs. One
/// of these goes with each read, and keeps what it has read.
///
/// FM hangs a ban on an association and one of its rule sets, which can cover several competitions, and doesn't say which
/// rule set is which. So a ban's competition is FM Starship's reasoning from FM's records, not FM's own answer:
/// - A red card's ban names the match, so its competition.
/// - A ban for bookings is given after the match that brought the last yellow card, so it takes the competition of the
///   match the player was last booked in, on the day it was given or the week before, where that competition's name is
///   known: his team's league, or one some red card names.
/// - Otherwise the competitions other bans under the same association's same rule set were for, among the ones his team
///   plays in, where that leaves exactly one.
/// - Otherwise, a rule set that has given a ban in a team's own league is that association's league rules, so a ban from
///   the association of his team's league under it is for his team's league.
/// A ban counts for his club, as FM's squad screen counts it, when it's for a competition his team plays in: its league,
/// or one in his recent matches for it.
public final class PlayerStateReader {
    private let game: GameProcess
    private let database: Database

    private struct Competition { let index: UInt32, name: String }
    private struct Team { let club: Int64, name: String, league: Competition?, nation: UInt32? }
    private struct Named { let competition: Competition, isLeague: Bool, opponent: String }

    private var competitions: [Int64: Competition?] = [:]
    private var teams: [Int64: Team] = [:]
    private var namesByIndex: [UInt32: String] = [:]
    private var histories: [Int64: [PlayerMatch]] = [:]
    private var associationNames: [UInt32: String]?
    /// For each association, each rule set's competitions as other bans show them, and whether one was a team's league.
    private var rules: [UInt32: [Int: [UInt32: (name: String, isLeague: Bool)]]] = [:]

    public init(game: GameProcess, database: Database) {
        self.game = game
        self.database = database
    }

    /// Reads his state again, as `GameReader.refreshState` does, and forgets his matches.
    public func refresh(_ player: Player) {
        GameReader.refreshState(player, in: database, game: game)
        histories[player.block] = nil
    }

    /// His bans, oldest first, with what FM Starship could work out about each. Nil when bans are off or weren't read.
    public func bans(of player: Player) -> [Ban]? {
        guard database.stateIsOn(.bans), let stored = player.storedBans else { return nil }
        let team = self.team(game.readPointer(player.block &+ Int64(MacLayout.Player.currentTeam)))
        let league = team?.league
        var plays = Set(history(player).filter { $0.team != 0 && self.team($0.team)?.club == team?.club }.map(\.competitionIndex))
        if let league { plays.insert(league.index) }
        return stored.sorted { ($0.year, $0.day) < ($1.year, $1.day) }.map { stored in
            var ban = Ban(issued: stored.issued ?? .distantPast, matches: stored.matches, served: stored.served)
            ban.association = stored.association
            ban.associationName = associationName(stored.association)
            ban.scope = stored.scope
            ban.reason = stored.kind == MacLayout.Ban.bookings ? .bookings : MacLayout.Ban.redCards.contains(stored.kind) ? .redCard : nil
            let known = rules(stored.association)
            ban.domestic = league.map { league in known.values.contains { $0[league.index] != nil } } == true
                || (team?.nation != nil && team?.nation == stored.association)
            if let named = direct(stored, player) {
                ban.competition = named.competition.name
                ban.competitionIndex = named.competition.index
                ban.opponent = named.opponent
            } else if let candidates = known[stored.scope] {
                let theirs = candidates.filter { plays.contains($0.key) }
                if theirs.count == 1, let only = theirs.first {
                    ban.competition = only.value.name
                    ban.competitionIndex = only.key
                } else if ban.domestic, let league, candidates.values.contains(where: \.isLeague) {
                    ban.competition = league.name
                    ban.competitionIndex = league.index
                }
            }
            ban.countsForClub = ban.competitionIndex.map { plays.contains($0) } ?? false
            return ban
        }
    }

    // MARK: Reads, each kept

    /// Pointers read from FM's memory are only added to with &+, so a bad one can't trap.
    private func competition(_ comp: Int64) -> Competition? {
        guard comp > 0 else { return nil }
        if let known = competitions[comp] { return known }
        var found: Competition?
        if let b = game.read(comp &+ MacLayout.Comp.index, count: 4) {
            let name = game.lengthPrefixedString(game.readPointer(comp &+ Int64(MacLayout.competitionName)))
            let index = b.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            if !name.isEmpty {
                found = Competition(index: index, name: name)
                namesByIndex[index] = name
            }
        }
        competitions[comp] = found
        return found
    }

    private func team(_ team: Int64) -> Team? {
        guard team > 0 else { return nil }
        if let known = teams[team] { return known }
        let club = game.readPointer(team &+ Int64(MacLayout.Team.club))
        guard club > 0 else { return nil }
        let found = Team(club: club, name: game.lengthPrefixedString(game.readPointer(club &+ Int64(MacLayout.Club.fullName))),
                         league: competition(game.readPointer(team &+ Int64(MacLayout.Team.competition))),
                         nation: nationIndex(game.readPointer(club &+ Int64(MacLayout.Club.nation))))
        teams[team] = found
        return found
    }

    private func nationIndex(_ nation: Int64) -> UInt32? {
        guard nation > 0, let b = game.read(nation &+ Int64(MacLayout.Nation.index), count: 4) else { return nil }
        return b.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    private func history(_ player: Player) -> [PlayerMatch] {
        if let known = histories[player.block] { return known }
        let found = FixturesReader.history(player: player.block, in: game) { _ in "" }.matches
        histories[player.block] = found
        return found
    }

    /// The association's nation's name, or "" where it isn't a nation the read found.
    private func associationName(_ association: UInt32) -> String {
        if associationNames == nil {
            var names: [UInt32: String] = [:]
            for nation in database.nationRecords {
                guard let index = nationIndex(nation), names[index] == nil else { continue }
                let name = game.lengthPrefixedString(game.readPointer(nation &+ Int64(MacLayout.Nation.name)))
                // A nation that couldn't be read mustn't take the place of the one that can.
                if !name.isEmpty { names[index] = name }
            }
            associationNames = names
        }
        return associationNames?[association] ?? ""
    }

    // MARK: Working it out

    /// What the ban's own record says: a red card's match, or the match he was last booked in before a ban for bookings.
    private func direct(_ ban: StoredBan, _ player: Player) -> Named? {
        let league = team(game.readPointer(player.block &+ Int64(MacLayout.Player.currentTeam)))?.league
        if ban.match > 0 {
            guard let found = competition(game.readPointer(game.readPointer(ban.match &+ MacLayout.BanMatch.name) &+ MacLayout.FixtureName.comp))
            else { return nil }
            let own = Set([player.clubObject, player.loanClubObject].filter { $0 != 0 })
            let home = game.readPointer(ban.match &+ MacLayout.BanMatch.home), away = game.readPointer(ban.match &+ MacLayout.BanMatch.away)
            let other = own.contains(team(home)?.club ?? 0) ? away : own.contains(team(away)?.club ?? 0) ? home : 0
            return Named(competition: found, isLeague: found.index == league?.index, opponent: team(other)?.name ?? "")
        }
        guard let issued = ban.issued, let weekBefore = GameDate.calendar.date(byAdding: .day, value: -7, to: issued) else { return nil }
        let booked = history(player).filter { $0.played && $0.yellow > 0 && $0.date <= issued && $0.date >= weekBefore }
        guard let last = booked.max(by: { $0.date < $1.date }),
              Set(booked.filter { $0.date == last.date }.map(\.competitionIndex)).count == 1 else { return nil }
        if let own = team(last.team)?.league, own.index == last.competitionIndex {
            return Named(competition: own, isLeague: true, opponent: "")
        }
        guard let name = namesByIndex[last.competitionIndex] else { return nil }
        return Named(competition: Competition(index: last.competitionIndex, name: name), isLeague: false, opponent: "")
    }

    /// The competitions each of the association's rule sets has given bans in, from every ban the read found under it. Red
    /// cards first, since they name competitions a ban for bookings may need.
    private func rules(_ association: UInt32) -> [Int: [UInt32: (name: String, isLeague: Bool)]] {
        if let known = rules[association] { return known }
        var found: [Int: [UInt32: (name: String, isLeague: Bool)]] = [:]
        let banned = database.players.compactMap { player in
            player.storedBans.map { bans in (player, bans.filter { $0.association == association }) }
        }.filter { !$0.1.isEmpty }
        for redCards in [true, false] {
            for (player, bans) in banned {
                for ban in bans where (ban.match > 0) == redCards {
                    guard let named = direct(ban, player) else { continue }
                    let before = found[ban.scope]?[named.competition.index]
                    found[ban.scope, default: [:]][named.competition.index] = (named.competition.name, named.isLeague || before?.isLeague == true)
                }
            }
        }
        rules[association] = found
        return found
    }
}
