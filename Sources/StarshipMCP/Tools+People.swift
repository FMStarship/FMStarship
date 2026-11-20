import Foundation
import StarshipAnalysis
import StarshipCore
import StarshipFiles
import StarshipSearch

extension Toolbox {
    static let squadColumns = ["Name", "Age", "Nation", "Position", "CA", "PA", "Value", "Wage", "Contract end", "Appearances",
                               "Goals", "Assists", "Average rating", "Yellow cards", "Red cards", "Form (last 5 ratings)", "Injury",
                               "Days out", "Transfer status", "Loan status", "On loan at"]
    static let staffColumns = ["Name", "Job", "Age", "Squad", "CA", "PA", "Wage", "Contract end"]
    static let playerListColumns = ["Name", "Age", "Position", "Club", "On loan at", "Nation", "CA", "PA", "Value", "Wage", "Contract end",
                                    "Appearances"]
    static let staffListColumns = ["Name", "Job", "Age", "Club", "Nation", "CA", "PA", "Wage", "Contract end"]

    /// A club by the name it goes by in FM, any club, or the user's own.
    private func clubName(_ named: String?, _ context: CallContext) throws -> (name: String, squads: OpenSquad) {
        let own = try? context.ownClub(nil)
        let session = context.session(for: own ?? ChosenClub())
        let catalogue = OpenSquad(session: session)
        guard let named else {
            guard let own else { throw ToolError("No club in this save is run by a human manager, so name a club.") }
            return (own.name, catalogue)
        }
        guard let found = catalogue.club(matching: named) else {
            let near = catalogue.clubs.filter { $0.localizedCaseInsensitiveContains(named) }.prefix(8)
            throw ToolError("No club is called \(named)." + (near.isEmpty ? "" : " Did you mean: \(near.joined(separator: ", "))?"))
        }
        return (found, catalogue)
    }

    func squad(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let (club, catalogue) = try clubName(try args.string("club"), context)
        let squads = catalogue.squads(for: club).filter { $0 != OpenSquad.allSquads }
        var wanted = try args.string("squad")
        if wanted == nil { wanted = squads.contains("First team") ? "First team" : "all" }
        var shown: String?
        if let wanted, wanted.caseInsensitiveCompare("all") != .orderedSame {
            guard let match = squads.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw ToolError("\(club) has no squad called \(wanted). Its squads: \(squads.joined(separator: ", ")), or all.")
            }
            shown = match
        }
        var filter = PlayerFilter(showHidden: context.visibility.showHidden, showAbility: context.visibility.showsAbility)
        filter.openSquad(club: club, squad: shown)
        let players = filter.criteria().filter(context.db.players).stableSorted(by: Self.positionOrder)
        for player in players where player.injury != nil { _ = RulesState.shared.injuryCheck(player) }
        // FM can play a match without the date moving, so each row's state and season stats are read again.
        players.forEach { context.read.states?.refresh($0) }
        players.forEach { Self.refreshSeason($0, context.read.engine) }
        var names = Self.squadColumns
        if shown == nil, let at = names.firstIndex(of: "Position") { names.insert("Squad", at: at + 1) }
        let columns = Output.columns(names, in: Columns.forPlayers(), context.visibility)
        let engine = context.read.engine
        var pairs: [(String, JSON)] = [("club", .string(club)), ("squad", .string(shown ?? "all")),
                                       ("squads", .array(squads.map { .string($0) })), ("players", .int(players.count)),
                                       ("wages", .string(Units.wageSuffix))]
        if engine != nil { pairs.append(("season_stats", .string(Self.seasonNote))) }
        let histories = engine.map(Histories.init)
        return .object(pairs + Output.rows(players, columns + Self.competitionFields(engine, histories)
                                           + Self.lastMatch(histories, competitions: engine == nil ? [:] : competitionNames(context.read))
                                           + Self.stateFields(context.db, engine, context.read.states)))
    }

    static let seasonNote = "Starts, Sub appearances, Goals, Assists, Average rating and the cards are FM's club total for this season: "
        + "league, cup and continental matches together, at the club he plays for now (his loan club while on loan). League stats, "
        + "Cup stats and Continental stats give each apart; empty means he hasn't played in it. League stats starts with the "
        + "league they're in, from his league matches FM keeps: a reserve or B-team player's are the reserve league's, a loanee's "
        + "his loan club's; no name means FM keeps none of them. That was checked on a Norwegian "
        + "save with its league, its cup and the Champions League; other cups and continental competitions are expected in the "
        + "same split but weren't checked. Friendlies and internationals aren't in either."

    /// FM's own split of the club total, as it keeps a player's season: the league, the cup and the continental competitions.
    static let competitions = [("League", RulesEngine.league), ("Cup", RulesEngine.cup), ("Continental", RulesEngine.continental)]

    /// FM can play a match without the date moving, so a row's season stats and form are asked for again when it's answered,
    /// as its split by competition is, and the two agree. As the read does, a player with no appearances has none.
    static func refreshSeason(_ player: Player, _ engine: GameRulesEngine?) {
        guard let engine, let total = engine.seasonStats(player: player, season: RulesEngine.clubTotal) else { return }
        player.season = total.apps > 0 ? total : nil
        player.form = total.apps > 0 ? engine.form(player: player) ?? "" : ""
    }

    /// His season in each of FM's competitions apart, in a few words, so a cup goal isn't read as a league one. Empty where he
    /// hasn't played in it, and "not available" where FM's stats didn't answer, which mustn't read as no matches. None when
    /// FM's rules are off, since season stats come with them.
    static func competitionFields(_ engine: GameRulesEngine?, _ histories: Histories?) -> [Output.Field] {
        guard let engine else { return [] }
        // "League" alone is the club's league elsewhere in these answers.
        return competitions.map { name, scope in
            Output.Field(name: name + " stats") { person in
                guard let player = person as? Player else { return nil }
                guard let stats = engine.seasonStats(player: player, season: scope) else { return .string(notAvailable) }
                guard let line = seasonLine(stats)?.string else { return nil }
                guard scope == RulesEngine.league, let league = leagueName(player, histories?.of(player), apps: stats.apps) else {
                    return .string(line)
                }
                return .string(league + ": " + line)
            }
        }
    }

    /// Each player's record of his form, read once for an answer.
    final class Histories {
        private let engine: GameRulesEngine
        private var found: [UInt32: MatchHistory?] = [:]

        init(_ engine: GameRulesEngine) {
            self.engine = engine
        }

        func of(_ player: Player) -> MatchHistory? {
            if let known = found[player.uid] { return known }
            let history = engine.matchHistory(player: player)
            found[player.uid] = .some(history)
            return history
        }
    }

    /// Youth teams by type (U23, U21, U19, U18). On Molde's save their league's matches were in none of FM's season stats.
    static let youthTeams: Set<Int> = [9, 10, 11, 12]

    /// The league his league stats are for: the leagues of his newest league matches FM keeps at the club he plays for now, no
    /// more of them than FM counts this season, so an old season's aren't named. A reserve or B-team player's are the reserve
    /// league's, a loanee's his loan club's; two when he's played in two. Youth teams' leagues aren't in FM's count. The count
    /// stops at the oldest match of a team whose list is full, since that team's older matches are gone and may be newer than
    /// what follows. Nil when FM keeps none of them.
    static func leagueName(_ player: Player, _ history: MatchHistory?, apps: Int) -> String? {
        guard let history, apps > 0 else { return nil }
        let club = player.loanClubFull.isEmpty ? player.clubFull : player.loanClubFull
        let atClub = history.matches.filter { $0.teamName == club }
        let cutoff = Set(atClub.map(\.team)).compactMap { history.fullFrom[$0] }.max()
        let league = atClub.filter { $0.played && !$0.competitionName.isEmpty && !youthTeams.contains($0.teamType ?? -1) }
        var names: [String] = []
        for match in league.prefix(apps) {
            if let cutoff, match.date < cutoff { break }
            if !names.contains(match.competitionName) { names.append(match.competitionName) }
        }
        return names.isEmpty ? nil : names.joined(separator: " and ")
    }

    static let notAvailable = "not available"

    /// "6 (2) apps, 540 min, 3 goals, 1 assist, 7.25 rating", FM's way of writing starts and sub appearances.
    static func seasonLine(_ stats: SeasonStats) -> JSON? {
        guard stats.apps > 0 else { return nil }
        func count(_ number: Int, _ word: String) -> String { "\(number) \(word)\(number == 1 ? "" : "s")" }
        return .string("\(stats.starts) (\(stats.subs)) apps, \(stats.minutes) min, \(count(stats.goals, "goal")), "
                       + "\(count(stats.assists, "assist")), " + String(format: "%.2f", stats.rating) + " rating")
    }

    /// The same split in full, for `person`: the competitions he's played in, and "not available" for any FM's stats didn't
    /// answer for.
    static func seasonByCompetition(_ player: Player, _ engine: GameRulesEngine?, history: MatchHistory?) -> JSON? {
        guard let engine else { return nil }
        let split: [(String, JSON)] = competitions.compactMap { name, scope in
            guard let s = engine.seasonStats(player: player, season: scope) else { return (name, .string(notAvailable)) }
            guard s.apps > 0 else { return nil }
            let league = scope == RulesEngine.league ? leagueName(player, history, apps: s.apps).map { [("Competition", JSON.string($0))] } ?? [] : []
            return (name, .object(league + [("Starts", .int(s.starts)), ("Sub appearances", .int(s.subs)), ("Minutes", .int(s.minutes)),
                                   ("Goals", .int(s.goals)), ("Assists", .int(s.assists)),
                                   ("Average rating", .double((s.rating * 100).rounded() / 100)), ("Yellow cards", .int(s.yellow)),
                                   ("Red cards", .int(s.red)), ("Player of the Match", .int(s.playerOfTheMatch))]))
        }
        return split.isEmpty ? nil : .object(split)
    }

    /// Each player's latest match in FM's record of his form: when, which competition and opponent, his minutes and his
    /// rating, both empty when he didn't play (on the bench, left out or suspended). `competitions` names the competitions by database index.
    /// None when FM's rules are off, since the record comes with them.
    static func lastMatch(_ histories: Histories?, competitions: [UInt32: String]) -> [Output.Field] {
        guard let histories else { return [] }
        func match(_ person: Person) -> PlayerMatch? { (person as? Player).flatMap { histories.of($0)?.matches.first } }
        return [Output.Field(name: "Last match") { match($0).map { .string(Output.iso($0.date)) } },
                Output.Field(name: "Last match competition") { match($0).flatMap { competitionName($0, competitions) } },
                Output.Field(name: "Last match opponent") { match($0).flatMap { Output.text($0.opponentName) } },
                Output.Field(name: "Last match minutes") { match($0).flatMap { $0.played ? .int($0.minutes) : nil } },
                Output.Field(name: "Last match rating") { match($0)?.rating.map { .double($0) } }]
    }

    /// FM's order of positions, as its squad screen lists them.
    static func positionOrder(_ a: Player, _ b: Player) -> Bool {
        (PositionOrder.rank(of: a) ?? Int.max) < (PositionOrder.rank(of: b) ?? Int.max)
    }

    func staff(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let (club, _) = try clubName(try args.string("club"), context)
        var filter = StaffFilter(showHidden: context.visibility.showHidden, showAbility: context.visibility.showsAbility)
        filter.openClub(club)
        let people = filter.criteria().filter(context.db.staff).stableSorted { $0.job < $1.job }
        let columns = Output.columns(Self.staffColumns, in: Columns.forStaff(), context.visibility)
        return .object([("club", .string(club)), ("staff", .int(people.count)), ("wages", .string(Units.wageSuffix))]
                       + Output.rows(people, columns + [Output.Field(name: "Best coaching", value: Self.bestCoaching)]))
    }

    /// A coach's two best areas in FM's stars, from the same stars as the staff list's columns.
    static func bestCoaching(_ person: Person) -> JSON? {
        guard let staff = person as? Staff else { return nil }
        let rated = (0..<Names.areas.count).compactMap { area in Columns.starText(staff, area).map { (area, $0) } }
            .filter { $0.1 > 0 }.stableSorted { $0.1 > $1.1 }.prefix(2)
        guard !rated.isEmpty else { return nil }
        return .string(rated.map { "\(Names.areas[$0.0]) \(JSON.double($0.1).text)★" }.joined(separator: ", "))
    }

    // MARK: One person

    func person(_ args: Arguments, _ context: CallContext) throws -> JSON {
        guard let uid = try args.int("uid") else { throw ToolError("person needs a uid.") }
        let person = try context.person(uid)
        let visibility = context.visibility
        let own = try? context.ownClub(nil)
        let session = own.map { context.session(for: $0) }

        var pairs: [(String, JSON)] = [("uid", .int(Int(person.uid))), ("name", .string(person.name))]
        let catalogue: [Col]
        let groups: [String]
        let recent = try args.int("matches", in: 0...40) ?? 10
        if let player = person as? Player {
            pairs.append(("kind", "player"))
            if player.injury != nil { _ = RulesState.shared.injuryCheck(player) }
            Self.refreshSeason(player, context.read.engine)
            catalogue = Columns.forPlayers()
            groups = ["General", "Contract", "Ability", "Season stats", "Technical", "Mental", "Physical", "Goalkeeping", "Hidden",
                      "Positions", "Personality"]
        } else {
            pairs.append(("kind", "staff"))
            catalogue = Columns.forStaff()
            groups = ["General", "Contract", "Ability", "Coaching stars", "Attributes", "Hidden", "Personality"]
        }
        // The list columns that need the game asked first, and what the profile says in its own words.
        var leftOut: Set<String> = ["Name", "Unique ID", "Interest", "Traits"]
        if person.clubFull == person.club { leftOut.insert("Club (full)") }
        let columns = catalogue.filter { visibility.allows($0) && !leftOut.contains($0.name) }
        for group in groups {
            let values = columns.filter { $0.group == group }.flatMap { col -> [(String, JSON)] in
                if col.name == "Appearances" { return Output.starts(person).map { [("Starts", $0)] } ?? [] }
                let value = Output.value(col, person, visibility).map { [(col.name, $0)] } ?? []
                if col.name == "League", let nation = Output.clubNation.value(person) { return value + [(Output.clubNation.name, nation)] }
                return value
            }
            if !values.isEmpty { pairs.append((group, .object(values))) }
        }
        if let player = person as? Player {
            let history = context.read.engine?.matchHistory(player: player)
            if let split = Self.seasonByCompetition(player, context.read.engine, history: history) {
                let at = pairs.firstIndex { $0.0 == "Season stats" }.map { $0 + 1 } ?? pairs.count
                pairs.insert(("Season stats by competition", split), at: at)
            }
            context.read.states?.refresh(player)
            if let state = Self.stateGroup(player, context.db, context.read.engine, context.read.states) {
                pairs.append(("Fitness and morale", state))
            }
            if let history, let matches = recentMatches(history, limit: recent, context) { pairs.append(("Recent matches", matches)) }
            let traits = player.traits.components(separatedBy: "; ").filter { !$0.isEmpty }
            if !traits.isEmpty { pairs.append(("Traits", .array(traits.map { .string($0) }))) }
        }
        if let session, let join = wouldJoin(person, session) { pairs.append(("Would join your club", join)) }
        return .object(pairs)
    }

    /// A match's competition by FM's name: from the fixtures in memory, else his team's own league.
    static func competitionName(_ match: PlayerMatch, _ names: [UInt32: String]) -> JSON? {
        Output.text(names[match.competitionIndex] ?? match.competitionName)
    }

    static let recentMatchColumns = ["date", "team", "competition", "opponent", "minutes", "rating", "goals", "assists", "yellow", "red"]

    /// His latest matches in FM's record of his form, for any team, newest first: which competition and opponent a goal or a
    /// rating came from.
    private func recentMatches(_ history: MatchHistory, limit: Int, _ context: CallContext) -> JSON? {
        guard limit > 0, !history.matches.isEmpty else { return nil }
        let names = competitionNames(context.read)
        let rows: [JSON] = history.matches.prefix(limit).map { match in
            let head: [JSON] = [.string(Output.iso(match.date)), Output.text(match.teamName) ?? .null,
                                Self.competitionName(match, names) ?? .null, Output.text(match.opponentName) ?? .null]
            guard match.played else { return .array(head + Array(repeating: JSON.null, count: 6)) }
            return .array(head + [.int(match.minutes), match.rating.map { .double($0) } ?? .null, .int(match.goals),
                                  .int(match.assists), .int(match.yellow), .int(match.red)])
        }
        let note = "Newest first, for every team he played for, friendlies, youth and international matches too. team is the "
            + "club's name, so a reserve or youth team shows as its club, and it's empty for a national team. FM keeps his last "
            + "\(MatchHistory.kept) matches for each team. Empty minutes and rating: he was on the bench and didn't come on. "
            + "An empty competition is one FM Starship couldn't name."
        return .object([("columns", .array(Self.recentMatchColumns.map { .string($0) })), ("rows", .array(rows)), ("note", .string(note))])
    }

    /// FM's own answer, asked for this one person. Nothing when FM's rules are off or they're already at the club.
    private func wouldJoin(_ person: Person, _ session: AnalysisSession) -> JSON? {
        guard person.clubFull != session.club.name else { return nil }
        if let player = person as? Player, let answer = session.checks.check(player) {
            return ["club": .string(session.club.name), "transfer": .string(answer.transferInterest.text),
                    "loan": .string(Self.loanText(player, answer))]
        }
        if let staff = person as? Staff, let answer = session.checks.staffCheck(staff) {
            return ["club": .string(session.club.name), "first_team": .bool(answer.firstTeam), "reserves": .bool(answer.reserves),
                    "youth": .bool(answer.youth)]
        }
        return nil
    }

    // MARK: Shortlists

    func shortlist(_ args: Arguments, _ context: CallContext) throws -> JSON {
        guard let name = try args.string("name") else { throw ToolError("shortlist needs a name.") }
        let kind = try args.choice("kind", ["players", "staff"])
        let limit = try args.int("limit", in: 1...100) ?? 25
        let roots = shortlistRoots()
        var entries: [ShortlistEntry] = []
        if kind != "staff" { entries += ShortlistFile.list(isStaff: false, roots: roots) }
        if kind != "players" { entries += ShortlistFile.list(isStaff: true, roots: roots) }
        let matching = entries.filter { $0.shortlist.name.caseInsensitiveCompare(name) == .orderedSame }
        guard let entry = matching.max(by: { $0.modified < $1.modified }) else {
            let names = entries.map(\.shortlist.name)
            throw ToolError("No shortlist is called \(name)." + (names.isEmpty ? " There are none in FM's folder." : " There are: \(names.joined(separator: ", "))."))
        }
        let everyone = people(context.read)
        let found = entry.shortlist.uids.compactMap { everyone[$0] }
        let staff = entry.shortlist.isStaff
        let people: [Person] = staff ? found.filter { $0 is Staff } : found.filter { $0 is Player }
        let catalogue = staff ? Columns.forStaff() : Columns.forPlayers()
        let columns = Output.columns(staff ? Self.staffListColumns : Self.playerListColumns, in: catalogue, context.visibility)
        var pairs: [(String, JSON)] = [("name", .string(entry.shortlist.name)), ("kind", .string(staff ? "staff" : "players")),
                                       ("people", .int(people.count)), ("shown", .int(min(limit, people.count)))]
        let missing = entry.shortlist.uids.count - people.count
        if missing > 0 { pairs.append(("not_in_this_save", .int(missing))) }
        return .object(pairs + Output.rows(Array(people.prefix(limit)), columns))
    }
}
