import Foundation
import StarshipCore

/// A played match's team stats for both sides, from the summary FM keeps in its post-match news about the user's club:
/// possession, xG, shots, shots on target, fouls and goals. Only once FM Starship's check of them has passed. Nothing in
/// them is hidden in FM: they're on its match stats screen.
extension Toolbox {
    static let teamStatsKeys = ["club", "possession", "xg", "shots", "shots_on_target", "fouls", "goals"]

    /// The checked team stats of a club's played matches, and why the others have none.
    struct CheckedStats {
        var stats: [Date: MatchStats] = [:]
        /// Matches FM has team stats for that failed the check, with what disagreed.
        var failed: [Date: String] = [:]
        /// Why there are none for any match.
        var off: String?
        /// The oldest match FM still has them for, checked or not.
        var oldest: Date?
        var count: Int { stats.count + failed.count }
    }

    /// The sweep for the user's club's match stats, made once for each read, and again when a match has been played since.
    func cachedMatchStats(_ read: GameRead, team: Int64, played: Int, source: MatchSource) -> [MatchStats]? {
        let key = [read.number, Int(truncatingIfNeeded: team), played]
        if statsKey != key {
            statsFound = source.matchStats(team: team)
            statsKey = key
        }
        return statsFound
    }

    /// Each played match of `matches` FM still has team stats for, checked against the club's players' match records.
    func checkedStats(club: String, matches: TeamMatches, _ context: CallContext) -> CheckedStats {
        var checked = CheckedStats()
        guard let own = try? context.ownClub(nil), own.team == matches.team else {
            checked.off = "FM keeps them only in its news about the user's club, so FM Starship has them only for that club's matches."
            return checked
        }
        guard let engine = context.read.engine else {
            checked.off = "FM Starship checks them against the players' match records, which come with FM's rules, and those are off on this build of FM."
            return checked
        }
        let played = matches.fixtures.filter(\.played)
        guard let source = context.read.matches,
              let found = cachedMatchStats(context.read, team: matches.team, played: played.count, source: source) else {
            checked.off = "This build of FM hasn't been checked for them, so they're off until FM Starship is updated."
            return checked
        }
        var records: [Date: [PlayerMatch]] = [:]
        for player in context.db.players where player.clubFull == club || player.loanClubFull == club {
            for record in engine.matchHistory(player: player)?.matches ?? [] where record.team == matches.team && record.played {
                records[record.date, default: []].append(record)
            }
        }
        for match in played {
            let opponent = match.home == matches.team ? match.away : match.home
            let copies = found.filter { $0.date == match.date && $0.opponent == opponent }
            guard let first = copies.first else { continue }
            checked.oldest = min(checked.oldest ?? match.date, match.date)
            if copies.count > 1 {
                checked.failed[match.date] = "FM holds \(copies.count) different copies of them"
            } else if let why = MatchStatsReader.check(first, match: match, records: records[match.date] ?? []) {
                checked.failed[match.date] = why
            } else {
                checked.stats[match.date] = first
            }
        }
        return checked
    }

    /// `team_stats` for one match: the club's side, then the opponent's, or why there are none.
    func teamStats(_ match: MatchFixture, club: String, checked: CheckedStats, today: Date?) -> JSON {
        if let off = checked.off { return .string("Not available: " + off) }
        if let why = checked.failed[match.date] {
            return .string("Not available: FM Starship's check of this match's team stats failed: \(why). They're left out rather than guessed.")
        }
        guard let stats = checked.stats[match.date] else { return .string("Not available: " + Self.statsKept(club, checked, today: today)) }
        func side(_ name: String, _ s: MatchSideStats) -> JSON {
            .object([("club", .string(name)), ("possession", .int(s.possession)), ("xg", .double(s.xG)), ("shots", .int(s.shots)),
                     ("shots_on_target", .int(s.shotsOnTarget)), ("fouls", .int(s.fouls)), ("goals", .int(s.goals))])
        }
        let home = match.home == stats.team
        return .array([side(club, stats.ours), side(home ? match.awayName : match.homeName, stats.theirs)])
    }

    /// How far back FM keeps team stats, from what it holds now.
    static func statsKept(_ club: String, _ checked: CheckedStats, today: Date?) -> String {
        let kept = "FM keeps a match's team stats only in its post-match news, which it clears after a few weeks, and not every match has them."
        guard let oldest = checked.oldest else { return kept + " It has them for none of \(club)'s matches now." }
        var text = kept + " It has them now for \(checked.count) of \(club)'s matches, back to \(Output.iso(oldest))"
        if let today, let days = GameDate.calendar.dateComponents([.day], from: oldest, to: today).day, days >= 7 {
            text += ", about the last \((days + 6) / 7) weeks"
        }
        return text + "."
    }
}
