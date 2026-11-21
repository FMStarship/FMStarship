import Foundation
import StarshipAnalysis
import StarshipCore
import StarshipFiles
import StarshipSearch

/// The user's matchday squad for the next match as FM's tactics hold it, and FM's scout's predicted line-up of the opponent.
/// Nothing in it is hidden in FM: its tactics screen, squad screen and opposition report show it all.
extension Toolbox {
    static let elevenColumns = ["uid", "name", "position", "role", "position_without_ball", "role_without_ball"]
    static let benchColumns = ["uid", "place", "name", "positions"]
    /// How many of a predicted eleven must play for the opponent now for a report to be taken as about them.
    static let reportPlayers = 6
    static let unread = "a player FM Starship doesn't read"

    func selection(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let club = try context.ownClub(try args.string("club"))
        guard let saved = context.db.tactics[club.team] else {
            throw ToolError("FM Starship couldn't find \(club.name)'s tactic in FM's memory. The user can open FM's Tactics screen; "
                            + "game_status with refresh then reads the save again.")
        }
        let players = playersByIndex(context.read)
        var tactic = saved
        if let source = context.read.selection {
            // The user can change the line-up without the date moving, so it's read again.
            guard let now = source.tactic(again: saved, players: players) else {
                throw ToolError("FM Starship couldn't read \(club.name)'s line-up again from FM's tactics, as FM may have let that copy "
                                + "go. game_status with refresh reads the save again.")
            }
            tactic = now
        }
        if let problem = Self.selectionProblem(tactic, club: club.name) {
            throw ToolError("FM Starship's check of \(club.name)'s line-up failed: \(problem). So it's left out rather than guessed. "
                            + "game_status with refresh reads the save again.")
        }

        var next: MatchFixture?, fixtures: [MatchFixture] = [], fixturesOff: String?
        if let source = context.read.matches, let matches = cachedMatches(context.read, team: club.team, source: source) {
            if case .failed(let why) = matches.check {
                fixturesOff = Self.failedSentence(club.name, why)
            } else {
                fixtures = matches.fixtures
                let today = context.db.gameDate
                next = fixtures.first { match in !match.played && (today.map { match.date >= $0 } ?? true) }
            }
        }

        let db = context.db, engine = context.read.engine, states = context.read.states
        let fitnessOn = db.stateIsOn(.fitness), bansOn = db.stateIsOn(.bans) && states != nil
        let stateColumns = (fitnessOn ? ["condition", "sharpness"] : []) + (bansOn ? ["suspended"] : []) + ["injury"]
        var warnings: [String] = []

        /// His state, and a warning where he can't play the next match.
        func state(_ player: Player, _ spot: String) -> [JSON] {
            states?.refresh(player)
            var cells: [JSON] = []
            if fitnessOn {
                let fitness = player.fitness(engine)
                cells += [fitness.map { Self.percent($0.condition) } ?? .null, fitness.map { Self.percent($0.sharpness) } ?? .null]
            }
            if bansOn {
                let bans = states?.bans(of: player)
                cells.append(Self.suspended(bans) ?? .null)
                for ban in bans ?? [] where ban.left > 0 {
                    let matches = ban.left == 1 ? "1 match" : "\(ban.left) matches"
                    if let next, ban.countsForClub, ban.competitionIndex == next.competitionIndex {
                        warnings.append("\(player.name) is \(spot) but is banned for the next match: \(matches) of his "
                                        + "\(next.competition) ban left.")
                    } else if ban.domestic, ban.competitionIndex == nil {
                        warnings.append("\(player.name) is \(spot) and has a ban FM Starship can't tie to a competition (\(matches) "
                                        + "left), so check in FM whether it covers the next match.")
                    }
                }
            }
            cells.append(player.injury == nil ? .null : Output.text(player.injuryText) ?? "injured")
            if Self.injuredFor(player, next) {
                let what = player.injuryText.isEmpty ? "" : " (\(player.injuryText))"
                warnings.append("\(player.name) is \(spot) but is injured\(what)" + (next == nil ? "." : " on the day of the next match."))
            }
            return cells
        }

        var unreadable = false
        let eleven: [JSON] = tactic.slots.stableSorted { $0.pitchOrder < $1.pitchOrder }.map { slot in
            let places: [JSON] = [.string(slot.label), .string(slot.roleName),
                                  .string(TacticSlot.label(position: slot.positionWithoutBall, side: slot.sideWithoutBall)),
                                  .string(slot.roleNameWithoutBall)]
            guard let index = slot.index else {
                warnings.append("Nobody is picked for the \(slot.label) place.")
                return .array([.null, .null] + places + stateColumns.map { _ in JSON.null })
            }
            guard let player = slot.player else {
                unreadable = true
                return .array([.null, .string(Self.unread + " (database index \(index))")] + places + stateColumns.map { _ in JSON.null })
            }
            return .array([.int(Int(player.uid)), .string(player.name)] + places + state(player, "in the starting eleven"))
        }
        let positions = Output.columns(["Position"], in: Columns.forPlayers(), context.visibility).first
        let bench: [JSON] = tactic.substitutes.map { place, sub in
            guard let player = sub.player else {
                unreadable = true
                return .array([.null, .int(place), .string(Self.unread + " (database index \(sub.index))"), .null]
                              + stateColumns.map { _ in JSON.null })
            }
            return .array([.int(Int(player.uid)), .int(place), .string(player.name), positions?.value(player) ?? .null]
                          + state(player, "on the bench"))
        }

        var notes = ["The line-up as saved in FM's tactics " + (context.read.selection == nil ? "when the save was read" : "now")
                     + ", which the user may still change before the match."]
        notes.append("The bench is in FM's order, place numbered from 1 with the user's gaps kept. FM names only as many substitutes "
                     + "as the competition allows, from the top, and FM Starship doesn't know each competition's number.")
        if let next { notes.append("Bans and injuries are checked for the next match, \(Output.iso(next.date)) in \(next.competition).") }
        else { notes.append("FM Starship doesn't know the next match, so it can't say which bans count for it.") }
        if !bansOn { notes.append("Suspensions can't be read on this build of FM, so bans weren't checked (game_status says why).") }
        if unreadable {
            notes.append("FM Starship doesn't read everyone FM has, such as players who are also staff, so it can't check those.")
        }
        if let same = sameAsLastMatch(tactic, club: club, fixtures: fixtures, next: next, context) { notes.append(same) }

        var pairs: [(String, JSON?)] = [("club", .string(club.name))]
        if let next { pairs.append(("next_match", Self.matchSummary(next, team: club.team))) }
        if let fixturesOff { pairs.append(("fixtures", .string("off: " + fixturesOff))) }
        pairs += [
            ("shape", .string(tactic.shape(in: FMData.library))),
            ("shape_without_ball", .string(tactic.shapeWithoutBall(in: FMData.library))),
            ("starting_eleven", .object([("columns", .array((Self.elevenColumns + stateColumns).map { .string($0) })),
                                         ("rows", .array(eleven))])),
            ("bench", .object([("columns", .array((Self.benchColumns + stateColumns).map { .string($0) })), ("rows", .array(bench))])),
            ("warnings", warnings.isEmpty ? nil : .array(warnings.map { .string($0) })),
            ("notes", .array(notes.map { .string($0) })),
        ]
        if let next { pairs.append(("opponent_prediction", prediction(next, club: club, fixtures: fixtures, context))) }
        return .object(dropping: pairs)
    }

    /// What's wrong with a line-up read from memory: a player twice, or one who doesn't play for the club. Nil when it passes.
    static func selectionProblem(_ tactic: Tactic, club: String) -> String? {
        if let twice = twice(tactic) { return "\(twice.player?.name ?? unread) is in it twice" }
        for player in tactic.slots.compactMap(\.player) + tactic.bench.compactMap({ $0?.player }) where playsFor(player) != club {
            return "\(player.name), who plays for \(playsFor(player)), is in it"
        }
        return nil
    }

    /// The first player a line-up names twice.
    static func twice(_ tactic: Tactic) -> (index: UInt32, player: Player?)? {
        var seen = Set<UInt32>()
        let named = tactic.slots.map { ($0.index, $0.player) } + tactic.bench.compactMap { $0.map { ($0.index, $0.player) } }
        for case let (index?, player) in named where !seen.insert(index).inserted { return (index, player) }
        return nil
    }

    /// Whether he's injured on the day of the next match, as FM keeps his injuries: an injury of a length FM Starship didn't
    /// read is taken as still running. With no next match, whether he's injured now.
    static func injuredFor(_ player: Player, _ next: MatchFixture?) -> Bool {
        if let injury = player.injury, injury.length <= 0 { return true }
        guard let next else { return player.injury != nil }
        return injured(player, on: next.date)
    }

    static func matchSummary(_ match: MatchFixture, team: Int64) -> JSON {
        let home = match.home == team
        return .object(dropping: [
            ("date", .string(Output.iso(match.date))), ("kick_off", match.kickOff.map { .string(time($0)) }),
            ("competition", Output.text(match.competition)), ("stage", Output.text(match.stage)),
            ("venue", .string(home ? "home" : "away")), ("opponent", Output.text(home ? match.awayName : match.homeName)),
        ])
    }

    /// A sentence when the players picked are exactly the last match's matchday squad, as FM's record of their form gives it:
    /// the user may not have picked for this match yet.
    private func sameAsLastMatch(_ tactic: Tactic, club: ChosenClub, fixtures: [MatchFixture], next: MatchFixture?,
                                 _ context: CallContext) -> String? {
        guard let engine = context.read.engine,
              let last = fixtures.last(where: { match in match.played && (next.map { match.date <= $0.date } ?? true) }) else { return nil }
        let picked = Set(tactic.slots.compactMap(\.index) + tactic.bench.compactMap { $0?.index })
        let histories = Histories(engine)
        let squad = context.db.players.filter { Self.playsFor($0) == club.name }.filter { player in
            histories.of(player)?.matches.contains { match in
                match.team == club.team && match.date == last.date && (match.played || match.absence == .unusedSubstitute)
            } ?? false
        }
        guard squad.count > 11, Set(squad.map(\.index)) == picked else { return nil }
        let opponent = last.home == club.team ? last.awayName : last.homeName
        return "These are the same players as the matchday squad of the last match, \(Output.iso(last.date)) v \(opponent), so the "
            + "user may not have picked for the next one yet."
    }

    /// FM's scout's predicted line-up of the next opponent, from FM's newest opposition report on them, made after the last
    /// match with them and by the day of this one. Nil when FM has none.
    private func prediction(_ next: MatchFixture, club: ChosenClub, fixtures: [MatchFixture], _ context: CallContext) -> JSON? {
        let opponentTeam = next.home == club.team ? next.away : next.home
        let opponent = next.home == club.team ? next.awayName : next.homeName
        guard !opponent.isEmpty, let reports = scoutReports(context.read) else { return nil }
        let lastMet = fixtures.last { $0.played && ($0.home == opponentTeam || $0.away == opponentTeam) && $0.date < next.date }
        guard let report = reports.first(where: { report in
            report.date <= next.date && (lastMet.map { report.date > $0.date } ?? true)
                && report.tactic.slots.filter { $0.player.map { Self.playsFor($0) == opponent } ?? false }.count >= Self.reportPlayers
                && Self.twice(report.tactic) == nil
        }) else { return nil }
        let eleven: [JSON] = report.tactic.slots.stableSorted { $0.pitchOrder < $1.pitchOrder }.map { slot in
            .array([slot.player.map { .int(Int($0.uid)) } ?? .null,
                    slot.player.map { .string($0.name) } ?? (slot.index == nil ? .null : .string(Self.unread)),
                    .string(slot.label), .string(slot.roleName),
                    .string(TacticSlot.label(position: slot.positionWithoutBall, side: slot.sideWithoutBall)),
                    .string(slot.roleNameWithoutBall)])
        }
        let subs: [JSON] = report.tactic.substitutes.map { place, sub in
            .array([sub.player.map { .int(Int($0.uid)) } ?? .null, .int(place), .string(sub.player?.name ?? Self.unread)])
        }
        return .object([
            ("opponent", .string(opponent)), ("report_date", .string(Output.iso(report.date))),
            ("note", .string("FM's scout's predicted line-up for \(opponent), from FM's opposition report of \(Output.iso(report.date)): "
                             + "a prediction, not the line-up they'll pick.")),
            ("shape", .string(report.tactic.shape(in: FMData.library))),
            ("shape_without_ball", .string(report.tactic.shapeWithoutBall(in: FMData.library))),
            ("starting_eleven", .object([("columns", .array(Self.elevenColumns.map { .string($0) })), ("rows", .array(eleven))])),
            ("substitutes", .object([("columns", ["uid", "place", "name"]), ("rows", .array(subs))])),
        ])
    }
}
