import Foundation
import StarshipAnalysis
import StarshipCore

/// Fixtures, results and league tables. Nothing in them is hidden in FM: they're all on FM's fixtures, table and match
/// screens. They're read on the first question about a team, and only given once its league results add up to its row in
/// the league table.
extension Toolbox {
    static let fixtureColumns = ["date", "kick_off", "competition", "stage", "round", "venue", "opponent", "score", "result",
                                 "aggregate", "attendance", "scorers", "opponent_scorers"]
    static let resultColumns = fixtureColumns.filter { $0 != "kick_off" }
    static let tableColumns = ["position", "club", "played", "won", "drawn", "lost", "goals_for", "goals_against",
                               "goal_difference", "points", "home", "away"]
    static let matchPlayerColumns = ["Name", "Minutes", "Rating", "Goals", "Assists", "Yellow cards", "Red cards", "xG"]

    /// The team a match tool is about, and its matches: a human manager's club, or a club in the user's league or one the
    /// user's club has a fixture with. Those are the teams FM Starship can find without reading the whole save again.
    func matchTeam(_ named: String?, _ context: CallContext) throws -> (name: String, matches: TeamMatches) {
        guard let source = context.read.matches else {
            throw ToolError("FM Starship can't read fixtures, results or league tables from this save.")
        }
        let own = try context.ownClub(nil)
        var team = own.team, name = own.name
        if let named, named.caseInsensitiveCompare(own.name) != .orderedSame {
            if let human = context.humanClubs.first(where: { $0.name.caseInsensitiveCompare(named) == .orderedSame }) {
                (team, name) = (human.team, human.name)
            } else {
                let ours = try teamMatches(context.read, team: own.team, source: source)
                var known: [(team: Int64, name: String)] = (ours.table?.rows ?? []).map { ($0.team, $0.name) }
                for match in ours.fixtures { known += [(match.home, match.homeName), (match.away, match.awayName)] }
                known = known.filter { !$0.name.isEmpty }
                guard let found = known.first(where: { $0.name.caseInsensitiveCompare(named) == .orderedSame }) else {
                    let near = Set(known.map(\.name).filter { $0.localizedCaseInsensitiveContains(named) }).sorted().prefix(8)
                    throw ToolError("FM Starship can find the matches of \(own.name), the clubs in its league and the clubs it plays, "
                                    + "by their full names as FM shows them. \(named) isn't one of them."
                                    + (near.isEmpty ? "" : " Did you mean: \(near.joined(separator: ", "))?"))
                }
                (team, name) = found
            }
        }
        return (name, try teamMatches(context.read, team: team, source: source))
    }

    private func teamMatches(_ read: GameRead, team: Int64, source: MatchSource) throws -> TeamMatches {
        guard let matches = cachedMatches(read, team: team, source: source) else {
            throw ToolError("This build of FM keeps its fixtures differently, so FM Starship can't find them. Fixtures, results "
                            + "and league tables are switched off until FM Starship is updated.")
        }
        return matches
    }

    static func failedSentence(_ club: String, _ why: String) -> String {
        "FM Starship's check of \(club)'s matches failed: \(why). A league with play-offs or a split can do this, since FM "
            + "Starship doesn't follow those yet, so fixtures, results and the league table are switched off rather than guessed."
    }

    /// Why results can't be given when there's nothing to check them against.
    static func uncheckedSentence(_ club: String, _ check: TeamMatches.Check) -> String {
        check == .nothingPlayed
            ? "\(club) hasn't played a league match yet this season, so FM Starship can't check its results against the league "
                + "table, and leaves them out until it has."
            : "\(club)'s competition has no league table FM Starship can read, so it can't check the results against one, and leaves them out."
    }

    // MARK: Fixtures

    func fixtures(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let (club, matches) = try matchTeam(try args.string("club"), context)
        if case .failed(let why) = matches.check { throw ToolError(Self.failedSentence(club, why)) }
        let to = try Self.date(args, "to")
        let from = try Self.date(args, "from") ?? (to == nil ? context.db.gameDate : nil)
        let limit = try args.int("limit", in: 1...100) ?? 25
        if let from, let to, to < from { throw ToolError("to is before from.") }
        let found = matches.fixtures.filter { match in (from.map { match.date >= $0 } ?? true) && (to.map { match.date <= $0 } ?? true) }
        let checked = matches.check == .passed
        let rows = found.prefix(limit).map { row($0, team: matches.team, columns: Self.fixtureColumns, scores: checked, context) }
        var pairs: [(String, JSON?)] = [("club", .string(club)), ("from", from.map { .string(Output.iso($0)) }),
                                        ("to", to.map { .string(Output.iso($0)) }), ("found", .int(found.count))]
        if found.count > limit { pairs.append(("shown", .int(limit))) }
        pairs += [("columns", .array(Self.fixtureColumns.map { .string($0) })), ("rows", .array(rows))]
        if !checked, found.contains(where: \.played) { pairs.append(("note", .string(Self.uncheckedSentence(club, matches.check)))) }
        return .object(dropping: pairs)
    }

    // MARK: Results

    func results(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let (club, matches) = try matchTeam(try args.string("club"), context)
        switch matches.check {
        case .passed: break
        case .failed(let why): throw ToolError(Self.failedSentence(club, why))
        case .noTable, .nothingPlayed: throw ToolError(Self.uncheckedSentence(club, matches.check))
        }
        let played = matches.fixtures.filter(\.played).reversed()
        if let day = try Self.date(args, "date") {
            guard let match = played.first(where: { $0.date == day }) else {
                let near = played.prefix(5).map { Output.iso($0.date) }
                throw ToolError("\(club) has no result on \(Output.iso(day))."
                                + (near.isEmpty ? "" : " Its latest: \(near.joined(separator: ", "))."))
            }
            return try oneResult(match, club: club, matches: matches, context)
        }
        let limit = try args.int("limit", in: 1...50) ?? 10
        let rows = played.prefix(limit).map { row($0, team: matches.team, columns: Self.resultColumns, scores: true, context) }
        var pairs: [(String, JSON)] = [("club", .string(club)), ("found", .int(played.count))]
        if played.count > limit { pairs.append(("shown", .int(limit))) }
        return .object(pairs + [("columns", .array(Self.resultColumns.map { .string($0) })), ("rows", .array(Array(rows))),
                                ("note", "Newest first. Ask with date for one match's players.")])
    }

    /// One result, with how each of the club's players did in it.
    private func oneResult(_ match: MatchFixture, club: String, matches: TeamMatches, _ context: CallContext) throws -> JSON {
        let cells = row(match, team: matches.team, columns: Self.resultColumns, scores: true, context).array ?? []
        var pairs: [(String, JSON)] = [("club", .string(club))]
        for (name, value) in zip(Self.resultColumns, cells) where value != .null { pairs.append((name, value)) }
        guard let engine = context.read.engine else {
            pairs.append(("players", "Not available: players' match records come with FM's rules, which are off on this build of FM."))
            return .object(pairs)
        }
        var played: [(Player, PlayerMatch)] = [], unused: [Player] = [], gone = 0
        let squad = context.db.players.filter { $0.clubFull == club || $0.loanClubFull == club }
        for player in squad {
            guard let history = engine.matchHistory(player: player) else { continue }
            if let record = history.matches.first(where: { $0.team == matches.team && $0.date == match.date }) {
                if record.played { played.append((player, record)) } else { unused.append(player) }
            } else if let from = history.fullFrom[matches.team], from > match.date {
                gone += 1
            }
        }
        played.sort { ($0.1.minutes, $0.1.rating ?? 0) > ($1.1.minutes, $1.1.rating ?? 0) }
        let rows: [JSON] = played.map { player, record in
            .array([.int(Int(player.uid)), .string(player.name), .int(record.minutes), record.rating.map { .double($0) } ?? .null,
                    .int(record.goals), .int(record.assists), .int(record.yellow), .int(record.red), record.xG.map { .double($0) } ?? .null])
        }
        pairs += [("columns", .array((["uid"] + Self.matchPlayerColumns).map { .string($0) })), ("rows", .array(rows))]
        if !unused.isEmpty { pairs.append(("unused_substitutes", .array(unused.map { .string($0.name) }))) }
        var note = "Only players at \(club) now are listed. xG is left out for goalkeepers."
        if gone > 0 {
            note += " FM keeps only each player's last \(MatchHistory.kept) matches for a team, and this match has gone from "
                + (gone == 1 ? "one player's," : "\(gone) players',") + " so they may be missing."
        }
        pairs.append(("note", .string(note)))
        return .object(pairs)
    }

    // MARK: League table

    func leagueTable(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let (club, matches) = try matchTeam(try args.string("club"), context)
        if case .failed(let why) = matches.check { throw ToolError(Self.failedSentence(club, why)) }
        guard let table = matches.table, table.rows.contains(where: { $0.team == matches.team }) else {
            throw ToolError(Self.uncheckedSentence(club, .noTable))
        }
        func record(_ r: TableRecord) -> JSON {
            .string("P\(r.played) W\(r.won) D\(r.drawn) L\(r.lost) \(r.goalsFor)-\(r.goalsAgainst) \(r.points)pts")
        }
        let rows: [JSON] = table.rows.map { row in
            let o = row.overall
            return .array([.int(row.position), .string(row.name), .int(o.played), .int(o.won), .int(o.drawn), .int(o.lost),
                           .int(o.goalsFor), .int(o.goalsAgainst), .int(o.goalsFor - o.goalsAgainst), .int(o.points),
                           record(row.home), record(row.away)])
        }
        var pairs: [(String, JSON?)] = [("competition", Output.text(table.competition)), ("club", .string(club)),
                                        ("position", table.rows.first { $0.team == matches.team }.map { .int($0.position) }),
                                        ("columns", .array(Self.tableColumns.map { .string($0) })), ("rows", .array(rows))]
        if matches.check == .nothingPlayed { pairs.append(("note", .string("\(club) hasn't played a league match yet this season."))) }
        return .object(dropping: pairs)
    }

    // MARK: Next fixture, for game_status

    /// The club's next match, or why there's none to give.
    func nextFixture(_ read: GameRead, club: ChosenClub, today: Date?) -> (String, JSON)? {
        guard let source = read.matches, let matches = cachedMatches(read, team: club.team, source: source) else { return nil }
        if case .failed(let why) = matches.check { return ("fixtures", .string("off: " + Self.failedSentence(club.name, why))) }
        guard let next = matches.fixtures.first(where: { match in !match.played && (today.map { match.date >= $0 } ?? true) }) else { return nil }
        let home = next.home == club.team
        return ("next_fixture", .object(dropping: [
            ("date", .string(Output.iso(next.date))), ("kick_off", next.kickOff.map { .string(Self.time($0)) }),
            ("competition", Output.text(next.competition)), ("stage", Output.text(next.stage)),
            ("venue", .string(home ? "home" : "away")), ("opponent", Output.text(home ? next.awayName : next.homeName)),
        ]))
    }

    // MARK: Rows

    /// One match as a row of `columns`, from the team's side. Scores only when the check has passed.
    private func row(_ match: MatchFixture, team: Int64, columns: [String], scores: Bool, _ context: CallContext) -> JSON {
        let home = match.home == team
        let result = scores ? match : MatchFixture(date: match.date, home: match.home, away: match.away)
        func goals(ours: Bool) -> JSON? {
            let list = result.goals.filter { $0.home == (home == ours) }
            guard !list.isEmpty else { return nil }
            return .array(list.sorted { ($0.minute, $0.addedMinute) < ($1.minute, $1.addedMinute) }.map { goal in
                var text = goal.addedMinute > 0 ? "\(goal.minute)+\(goal.addedMinute)' " : "\(goal.minute)' "
                // A goal's scorer and assister are on the side it's for.
                let side = goal.home ? match.homeName : match.awayName
                text += playerName(goal.scorer, side: side, context)
                if let assist = goal.assist { text += ", assist " + playerName(assist, side: side, context) }
                return .string(text)
            })
        }
        func cell(_ name: String) -> JSON? {
            switch name {
            case "date": return .string(Output.iso(match.date))
            case "kick_off": return match.kickOff.map { .string(Self.time($0)) }
            case "competition": return Output.text(match.competition)
            case "stage": return Output.text(match.stage)
            case "round": return match.round.map { .int($0) }
            case "venue": return .string(home ? "H" : "A")
            case "opponent": return Output.text(home ? match.awayName : match.homeName)
            case "score":
                if scores, match.scoreUnknown { return "unknown" }
                guard let h = result.homeGoals, let a = result.awayGoals else { return nil }
                return .string("\(h)-\(a)")
            case "result":
                guard let h = result.homeGoals, let a = result.awayGoals else { return nil }
                let (us, them) = home ? (h, a) : (a, h)
                return .string(us > them ? "W" : us == them ? "D" : "L")
            case "aggregate":
                // With the teams' names, as "2-4" alone reads as the club's loss when it's away.
                guard let h = result.homeAggregate, let a = result.awayAggregate else { return nil }
                return .string("\(match.homeName) \(h)-\(a) \(match.awayName)")
            case "attendance": return result.attendance.map { .int($0) }
            case "scorers": return goals(ours: true)
            case "opponent_scorers": return goals(ours: false)
            default: return nil
            }
        }
        return .array(columns.map { cell($0) ?? .null })
    }

    static func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    /// A goal's scorer or assister, by the index FM's goal list keeps. One who isn't in the read is named by his side.
    private func playerName(_ index: UInt32, side: String, _ context: CallContext) -> String {
        if let name = playersByIndex(context.read)[index]?.name { return name }
        guard let first = side.first else { return "a player FM Starship can't name" }
        return ("AEIOUaeiou".contains(first) ? "an " : "a ") + side + " player FM Starship can't name"
    }

    /// A date argument, as YYYY-MM-DD.
    static func date(_ args: Arguments, _ key: String) throws -> Date? {
        guard let text = try args.string(key) else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, text.count == 10,
              let date = GameDate.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              Output.iso(date) == text else {
            throw ToolError("\(key) must be a date, as YYYY-MM-DD.")
        }
        return date
    }
}
