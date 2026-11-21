import Foundation
import StarshipAnalysis
import StarshipCore

/// Fixtures, results and league tables. Nothing in them is hidden in FM: they're all on FM's fixtures, table and match
/// screens. They're read on the first question about a team. Its scores are given once its league results add up to its
/// row in the league table, or marked not checked when its competition has no table to check them against.
extension Toolbox {
    static let fixtureColumns = ["date", "kick_off", "competition", "stage", "round", "venue", "opponent", "score", "result",
                                 "aggregate", "attendance", "scorers", "opponent_scorers", "checked"]
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

    /// Why results are left out, or marked not checked, when there's nothing to check them against.
    static func uncheckedSentence(_ club: String, _ check: TeamMatches.Check) -> String {
        check == .nothingPlayed
            ? "\(club) hasn't played a league match yet this season, so FM Starship can't check its results against the league "
                + "table, and leaves them out until it has."
            : "\(club)'s competition has no league table FM Starship can read, such as a league FM runs in the background, so "
                + "FM Starship couldn't check these scores against one, and marks them checked: false. They're read the same way "
                + "as the scores of a league with a table, such as the user's, which are checked, but nothing has confirmed these."
    }

    /// A club with no league table to check its scores against gets them anyway, marked not checked.
    static func marksUnchecked(_ check: TeamMatches.Check) -> Bool { check == .noTable }

    /// What `competitive` couldn't leave out: matches whose competition's type FM Starship couldn't read. Nil when there are none.
    static func competitiveSentence(unknown: Int) -> String? {
        guard unknown > 0 else { return nil }
        return (unknown == 1 ? "One match is" : "\(unknown) matches are") + " kept in although competitive is set, because FM "
            + "Starship couldn't read whether " + (unknown == 1 ? "it's a friendly." : "they're friendlies.")
    }

    /// Why there's no league table to give.
    static func noTableSentence(_ club: String) -> String {
        "There's no league table FM Starship can read for \(club)'s competition."
    }

    // MARK: Fixtures

    func fixtures(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let (club, matches) = try matchTeam(try args.string("club"), context)
        if case .failed(let why) = matches.check { throw ToolError(Self.failedSentence(club, why)) }
        let to = try Self.date(args, "to")
        let from = try Self.date(args, "from") ?? (to == nil ? context.db.gameDate : nil)
        let limit = try args.int("limit", in: 1...100) ?? 25
        if let from, let to, to < from { throw ToolError("to is before from.") }
        let competitive = try args.bool("competitive") ?? false
        // A match whose day couldn't be told is in when any day it could be on is.
        let found = matches.fixtures.filter { match in
            (match.dateUnknown ? match.possibleDates : [match.date]).contains { day in
                (from.map { day >= $0 } ?? true) && (to.map { day <= $0 } ?? true)
            } && !(competitive && match.friendly == true)
        }
        let checked = matches.check == .passed, unchecked = Self.marksUnchecked(matches.check)
        let columns = Self.fixtureColumns
        let rows = found.prefix(limit).map {
            row($0, team: matches.team, columns: columns, scores: checked || unchecked, check: matches.check, context)
        }
        var pairs: [(String, JSON?)] = [("club", .string(club)), ("from", from.map { .string(Output.iso($0)) }),
                                        ("to", to.map { .string(Output.iso($0)) }), ("found", .int(found.count))]
        if found.count > limit { pairs.append(("shown", .int(limit))) }
        pairs += [("columns", .array(columns.map { .string($0) })), ("rows", .array(rows))]
        var notes: [String] = []
        if !checked, found.contains(where: \.played) { notes.append(Self.uncheckedSentence(club, matches.check)) }
        if competitive, let unknown = Self.competitiveSentence(unknown: found.filter { $0.friendly == nil }.count) { notes.append(unknown) }
        notes += found.prefix(limit).filter(\.dateUnknown).map(Self.dateUnknownSentence)
        if !notes.isEmpty { pairs.append(("note", .string(notes.joined(separator: " ")))) }
        return .object(dropping: pairs)
    }

    /// Why a match's date is left out.
    static func dateUnknownSentence(_ match: MatchFixture) -> String {
        let days = match.possibleDates.map { Output.iso($0) }
        return "FM holds more than one date for \(match.homeName) v \(match.awayName)"
            + (match.competition.isEmpty ? "" : " in \(match.competition)") + ", "
            + (days.dropLast().joined(separator: ", ") + " and " + (days.last ?? "")) + ", and FM Starship couldn't tell which "
            + "is current, so its date is left out rather than guessed."
    }

    /// The club's next match: the first not played yet from today on. Nil, with the match that stops it, when FM holds more
    /// than one date for a match that could come first.
    static func nextMatch(_ fixtures: [MatchFixture], today: Date?) -> (match: MatchFixture?, unsure: MatchFixture?) {
        func ahead(_ day: Date) -> Bool { today.map { day >= $0 } ?? true }
        let next = fixtures.first { !$0.played && !$0.dateUnknown && ahead($0.date) }
        let unsure = fixtures.first { match in
            !match.played && match.possibleDates.contains { day in ahead(day) && next.map { day <= $0.date } ?? true }
        }
        return unsure == nil ? (next, nil) : (nil, unsure)
    }

    // MARK: Results

    func results(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let (club, matches) = try matchTeam(try args.string("club"), context)
        switch matches.check {
        case .passed, .noTable: break
        case .failed(let why): throw ToolError(Self.failedSentence(club, why))
        case .nothingPlayed: throw ToolError(Self.uncheckedSentence(club, matches.check))
        }
        let unchecked = Self.marksUnchecked(matches.check)
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
        let competitive = try args.bool("competitive") ?? false
        let listed = competitive ? played.filter { $0.friendly != true } : Array(played)
        // Both sides' xG and shots, where FM still has the match's team stats: only for the user's club.
        let checked = checkedStats(club: club, matches: matches, context)
        let withStats = checked.off == nil
        let base = Self.resultColumns
        var columns = base
        if withStats { columns += ["xg", "shots", "opponent_xg", "opponent_shots"] }
        let rows: [JSON] = listed.prefix(limit).map { match in
            var cells = row(match, team: matches.team, columns: base, scores: true, check: matches.check, context).array ?? []
            if withStats {
                let stats = checked.stats[match.date]
                cells += [stats.map { .double($0.ours.xG) } ?? .null, stats.map { .int($0.ours.shots) } ?? .null,
                          stats.map { .double($0.theirs.xG) } ?? .null, stats.map { .int($0.theirs.shots) } ?? .null]
            }
            return .array(cells)
        }
        var pairs: [(String, JSON)] = [("club", .string(club)), ("found", .int(listed.count))]
        if listed.count > limit { pairs.append(("shown", .int(limit))) }
        var note = "Newest first. Ask with date for one match's players"
        note += withStats ? " and both sides' team stats. xg and shots are the club's and opponent_xg and opponent_shots the opponent's, where FM still "
            + "has the match's team stats "
            + "and FM Starship's check of them passed: " + Self.statsKept(club, checked, today: context.db.gameDate) : "."
        if unchecked { note += " " + Self.uncheckedSentence(club, matches.check) }
        if competitive, let unknown = Self.competitiveSentence(unknown: listed.filter { $0.friendly == nil }.count) { note += " " + unknown }
        return .object(pairs + [("columns", .array(columns.map { .string($0) })), ("rows", .array(rows)), ("note", .string(note))])
    }

    /// One result, with how each of the club's players did in it.
    private func oneResult(_ match: MatchFixture, club: String, matches: TeamMatches, _ context: CallContext) throws -> JSON {
        let cells = row(match, team: matches.team, columns: Self.resultColumns, scores: true, check: matches.check, context).array ?? []
        var pairs: [(String, JSON)] = [("club", .string(club))]
        for (name, value) in zip(Self.resultColumns, cells) where value != .null { pairs.append((name, value)) }
        let unchecked = Self.marksUnchecked(matches.check)
        pairs.append(("team_stats", teamStats(match, club: club, checked: checkedStats(club: club, matches: matches, context),
                                              today: context.db.gameDate)))
        guard let engine = context.read.engine else {
            pairs.append(("players", "Not available: players' match records come with FM's rules, which are off on this build of FM."))
            if unchecked { pairs.append(("note", .string(Self.uncheckedSentence(club, matches.check)))) }
            return .object(pairs)
        }
        var played: [(Player, PlayerMatch)] = [], didntPlay: [(Player, PlayerMatch)] = [], gone = 0
        let squad = context.db.players.filter { $0.clubFull == club || $0.loanClubFull == club }
        for player in squad {
            guard let history = engine.matchHistory(player: player) else { continue }
            if let record = history.matches.first(where: { $0.team == matches.team && $0.date == match.date }) {
                if record.played { played.append((player, record)) } else { didntPlay.append((player, record)) }
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
        // FM keeps an entry for every first-team player who didn't play, not only the substitutes who didn't come on.
        if !didntPlay.isEmpty {
            pairs.append(("didnt_play", .array(didntPlay.map { player, record in
                .string(player.name + (Self.absence(record, player).map { " (\($0))" } ?? ""))
            })))
        }
        var note = "Only players at \(club) now are listed. xG is left out for goalkeepers. didnt_play says why, where FM's record "
            + "does: an unused substitute, not in the matchday squad, suspended or injured. A name without one is a reason FM Starship "
            + "doesn't know."
        if gone > 0 {
            note += " FM keeps only each player's last \(MatchHistory.kept) matches for a team, and this match has gone from "
                + (gone == 1 ? "one player's," : "\(gone) players',") + " so they may be missing."
        }
        if unchecked { note += " " + Self.uncheckedSentence(club, matches.check) }
        pairs.append(("note", .string(note)))
        return .object(pairs)
    }

    // MARK: League table

    func leagueTable(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let (club, matches) = try matchTeam(try args.string("club"), context)
        if let named = try args.string("competition") { return try competitionTable(named, club: club, matches: matches, context) }
        if case .failed(let why) = matches.check { throw ToolError(Self.failedSentence(club, why)) }
        guard let table = matches.table, table.rows.contains(where: { $0.team == matches.team }) else {
            throw ToolError(Self.noTableSentence(club))
        }
        var pairs: [(String, JSON?)] = [("competition", Output.text(table.competition)), ("club", .string(club)),
                                        ("position", table.rows.first { $0.team == matches.team }.map { .int($0.position) }),
                                        ("columns", .array(Self.tableColumns.map { .string($0) })), ("rows", .array(Self.tableRows(table)))]
        if matches.check == .nothingPlayed { pairs.append(("note", .string("\(club) hasn't played a league match yet this season."))) }
        return .object(dropping: pairs)
    }

    static func tableRows(_ table: LeagueTable) -> [JSON] {
        func record(_ r: TableRecord) -> JSON {
            .string("P\(r.played) W\(r.won) D\(r.drawn) L\(r.lost) \(r.goalsFor)-\(r.goalsAgainst) \(r.points)pts")
        }
        return table.rows.map { row in
            let o = row.overall
            return .array([.int(row.position), .string(row.name), .int(o.played), .int(o.won), .int(o.drawn), .int(o.lost),
                           .int(o.goalsFor), .int(o.goalsAgainst), .int(o.goalsFor - o.goalsAgainst), .int(o.points),
                           record(row.home), record(row.away)])
        }
    }

    static let remainingColumns = ["date", "kick_off", "venue", "opponent"]

    /// The table of the league stage the club is in of a competition its fixtures name, such as the Champions League's
    /// league phase: checked club by club against every result of the stage, with where FM's places lead and the club's
    /// matches in the stage still to play from today.
    private func competitionTable(_ named: String, club: String, matches: TeamMatches, _ context: CallContext) throws -> JSON {
        let byName = Dictionary(grouping: matches.fixtures.filter { !$0.competition.isEmpty }, by: \.competition)
        guard let (name, theirs) = byName.first(where: { $0.key.caseInsensitiveCompare(named) == .orderedSame }).map({ ($0.key, $0.value) }),
              let source = context.read.matches else {
            throw ToolError("\(named) isn't a competition \(club)'s fixtures name. They name, as FM does in the game's language: "
                            + byName.keys.sorted().joined(separator: ", ") + ".")
        }
        // Two competitions can share a name, as two countries' second tiers can: the one more of the club's matches are in first.
        let indexes = Dictionary(grouping: theirs, by: \.competitionIndex)
            .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }.map(\.key)
        var found: CompetitionTable?
        for index in indexes where found == nil {
            found = cachedTable(context.read, team: matches.team, competitionIndex: index, source: source)
        }
        guard let found, let row = found.table.rows.first(where: { $0.team == matches.team }) else {
            throw ToolError("There's no league table FM Starship can read for \(club) in \(name): none of its stages FM holds is a "
                            + "league with \(club) in it.")
        }
        let stage = found.stage.isEmpty ? name : "\(name)'s \(found.stage)"
        if case .failed(let why) = found.check {
            throw ToolError("FM Starship's check of \(stage) table failed: \(why). Every row must add up to its club's results in "
                            + "the stage, and FM doesn't keep every result of every competition, so the table is switched off rather "
                            + "than guessed.")
        }
        let rows = found.table.rows
        var pairs: [(String, JSON?)] = [("competition", Output.text(found.table.competition)), ("stage", Output.text(found.stage)),
                                        ("club", .string(club)), ("position", .int(row.position)),
                                        ("points", .int(row.overall.points))]
        var notes: [String] = []
        if let lines = found.lines {
            // Each of FM's places that leads somewhere, with the club on its place nearest the middle of the table.
            // The reader only gives lines whose places fit in the table, so first ≤ last.
            let n = rows.count, top = lines.through, bottom = n - lines.relegated
            let zones: [(kind: String, first: Int, last: Int, count: Int)] = [
                ("through", 1, top, lines.through), ("play_off", top + 1, top + lines.playOff, lines.playOff),
                ("relegation_play_off", bottom - lines.relegationPlayOff + 1, bottom, lines.relegationPlayOff),
                ("relegated", bottom + 1, n, lines.relegated),
            ]
            let given: [JSON] = zones.compactMap { zone in
                guard zone.count > 0 else { return nil }
                let edge = zone.kind.hasPrefix("relegat") ? zone.first : zone.last
                guard let at = rows.first(where: { $0.position == edge }) else { return nil }
                return .object([("places", .string(zone.first == zone.last ? "\(edge)" : "\(zone.first)-\(zone.last)")),
                                ("to", .string(zone.kind)), ("line_position", .int(edge)), ("line_club", .string(at.name)),
                                ("line_points", .int(at.overall.points))])
            }
            if given.isEmpty {
                notes.append("FM's settings for this stage give no places that lead anywhere, so there are no lines to give.")
            } else {
                pairs.append(("lines", .array(given)))
            }
        } else {
            notes.append("FM's places for this stage couldn't be read on this build of FM, so where they lead isn't given.")
        }
        pairs += [("columns", .array(Self.tableColumns.map { .string($0) })), ("rows", .array(Self.tableRows(found.table)))]
        // From today, as `fixtures` gives them: FM keeps a moved match's old fixture too, under its old date.
        let today = context.db.gameDate
        let left = found.fixtures.filter { match in
            !match.played && (match.home == matches.team || match.away == matches.team) && today.map { match.date >= $0 } ?? true
        }
        pairs.append(("still_to_play", .object([
            ("columns", .array(Self.remainingColumns.map { .string($0) })),
            ("rows", .array(left.map { match in
                let home = match.home == matches.team
                return .array([.string(Output.iso(match.date)), match.kickOff.map { .string(Self.time($0)) } ?? .null,
                               .string(home ? "H" : "A"), Output.text(home ? match.awayName : match.homeName) ?? .null])
            })),
        ])))
        if found.check == .nothingPlayed { notes.append("No match of the stage has been played yet this season.") }
        if !notes.isEmpty { pairs.append(("note", .string(notes.joined(separator: " ")))) }
        return .object(dropping: pairs)
    }

    // MARK: Next fixture, for game_status

    /// The club's next match, or why there's none to give.
    func nextFixture(_ read: GameRead, club: ChosenClub, today: Date?) -> (String, JSON)? {
        guard let source = read.matches, let matches = cachedMatches(read, team: club.team, source: source) else { return nil }
        if case .failed(let why) = matches.check { return ("fixtures", .string("off: " + Self.failedSentence(club.name, why))) }
        let found = Self.nextMatch(matches.fixtures, today: today)
        if let unsure = found.unsure { return ("next_fixture", .string("unknown: " + Self.dateUnknownSentence(unsure))) }
        guard let next = found.match else { return nil }
        let home = next.home == club.team
        return ("next_fixture", .object(dropping: [
            ("date", .string(Output.iso(next.date))), ("kick_off", next.kickOff.map { .string(Self.time($0)) }),
            ("competition", Output.text(next.competition)), ("stage", Output.text(next.stage)),
            ("venue", .string(home ? "home" : "away")), ("opponent", Output.text(home ? next.awayName : next.homeName)),
        ]))
    }

    // MARK: Rows

    /// One match as a row of `columns`, from the team's side. Scores only when the check has passed or there's no table to
    /// check them against. The "checked" column is true for a played match whose score was checked against the league table,
    /// false for one that had no table to check it against, and null when there's no score.
    private func row(_ match: MatchFixture, team: Int64, columns: [String], scores: Bool, check: TeamMatches.Check,
                     _ context: CallContext) -> JSON {
        let home = match.home == team
        let result = scores ? match : MatchFixture(date: match.date, home: match.home, away: match.away)
        func goals(ours: Bool) -> JSON? {
            let list = result.goals.filter { $0.home == (home == ours) }
            guard !list.isEmpty else { return nil }
            return .array(list.sorted { ($0.minute, $0.addedMinute) < ($1.minute, $1.addedMinute) }.map { goal in
                var text = goal.addedMinute > 0 ? "\(goal.minute)+\(goal.addedMinute)' " : "\(goal.minute)' "
                // A goal's scorer and assister are on the side it's for, except an own goal's scorer. FM's kind says it's an
                // own goal, unless the scorer plays for the side it's for: then he may have moved since, and it's left unmarked.
                let side = goal.home ? match.homeName : match.awayName
                let ownGoal = goal.ownGoal && playersByIndex(context.read)[goal.scorer].map { Self.playsFor($0) != side } ?? true
                text += playerName(goal.scorer, side: ownGoal ? (goal.home ? match.awayName : match.homeName) : side, context)
                if ownGoal { text += " (own goal)" }
                if let assist = goal.assist { text += ", assist " + playerName(assist, side: side, context) }
                return .string(text)
            })
        }
        func cell(_ name: String) -> JSON? {
            switch name {
            case "date": return match.dateUnknown ? nil : .string(Output.iso(match.date))
            case "kick_off": return match.dateUnknown ? nil : match.kickOff.map { .string(Self.time($0)) }
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
            case "checked":
                guard match.played else { return nil }
                switch check {
                case .passed: return true
                case .noTable: return false
                case .failed, .nothingPlayed: return nil
                }
            default: return nil
            }
        }
        return .array(columns.map { cell($0) ?? .null })
    }

    static func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    /// The club a player plays for now: his loan club while he's on loan.
    static func playsFor(_ player: Player) -> String { player.loanClubFull.isEmpty ? player.clubFull : player.loanClubFull }

    /// Why he didn't play in a match he has an entry for: FM's reason where FM Starship knows it, else an injury FM keeps
    /// that covers the day. Nil when neither says.
    static func absence(_ match: PlayerMatch, _ player: Player) -> String? {
        if let absence = match.absence { return absence.rawValue }
        return injured(player, on: match.date) ? PlayerMatch.Absence.injured.rawValue : nil
    }

    /// Whether one of his injuries, as FM keeps them, covers the day.
    static func injured(_ player: Player, on day: Date) -> Bool {
        ((player.injuries ?? []) + [player.injury].compactMap { $0 }).contains { injury in
            guard injury.length > 0, let end = GameDate.calendar.date(byAdding: .day, value: injury.length, to: injury.date) else { return false }
            return injury.date <= day && day < end
        }
    }

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
