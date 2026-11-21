@testable import StarshipCore
import XCTest

/// Made-up fixtures, results, league tables and players' match histories, laid out as `MacLayout` says.
extension FakeGame {
    /// A vector as libc++ keeps one: begin, end and capacity, here over `words`.
    func vector(_ words: [Int64]) -> Int64 {
        let list = record("Vector", size: 24)
        guard !words.isEmpty else { return list.address }
        let items = record("Vector items", size: words.count * 8)
        for (i, word) in words.enumerated() { items.set("item \(i)", i * 8, word) }
        list.set("begin", 0, items.address)
        list.set("end", 8, items.address + Int64(words.count * 8))
        list.set("capacity", 16, items.address + Int64(words.count * 8))
        return list.address
    }

    /// A competition with its database index and FM's type of competition (0 a top league), and, for a league, the stages
    /// that hold its tables.
    func competition(_ name: String, index: UInt32, type: UInt8 = 0, tables: [Int64] = []) -> Int64 {
        let record = self.record("Competition", size: Int(MacLayout.Comp.type) + 8)
        record.set("index", Int(MacLayout.Comp.index), index)
        record.set("type", Int(MacLayout.Comp.type), type)
        record.set("name", MacLayout.competitionName, string(name))
        if !tables.isEmpty {
            let actual = self.record("Actual competition", size: Int(MacLayout.ActualComp.stages) + 24)
            // A league can have stages that aren't tables, so one comes first.
            let other = self.record("Other stage", size: 16)
            actual.set("stages", Int(MacLayout.ActualComp.stages), bytes: vectorBytes([other.address] + tables))
            record.set("actual", Int(MacLayout.Comp.actual), actual.address)
        }
        return record.address
    }

    /// The begin, end and capacity words of a vector held inside a record.
    private func vectorBytes(_ words: [Int64]) -> [UInt8] {
        let items = record("Vector items", size: max(8, words.count * 8))
        for (i, word) in words.enumerated() { items.set("item \(i)", i * 8, word) }
        let begin = words.isEmpty ? 0 : items.address, end = begin + Int64(words.count * 8)
        return [begin, end, end].flatMap { withUnsafeBytes(of: $0) { Array($0) } }
    }

    /// One club's row: overall, home and away, as (played, won, drawn, lost, for, against, points).
    typealias Record = (p: UInt8, w: UInt8, d: UInt8, l: UInt8, f: UInt16, a: UInt16, pts: UInt16)

    func tableRow(team: Int64, overall: Record, home: Record, away: Record) -> Int64 {
        typealias T = MacLayout.TableRow
        let row = record("Table row", size: T.size)
        for (name, offset, values) in [("overall", T.overall, overall), ("home", T.home, home), ("away", T.away, away)] {
            typealias R = T.Record
            row.set("\(name).for", offset + R.goalsFor, values.f)
            row.set("\(name).against", offset + R.goalsAgainst, values.a)
            row.set("\(name).points", offset + R.points, values.pts)
            row.set("\(name).played", offset + R.played, values.p)
            row.set("\(name).won", offset + R.won, values.w)
            row.set("\(name).drawn", offset + R.drawn, values.d)
            row.set("\(name).lost", offset + R.lost, values.l)
        }
        row.set("team", T.team, team)
        return row.address
    }

    /// A league stage whose table is these rows, in order, with its settings if it has them.
    func leagueStage(rows: [Int64], settings: Int64? = nil) -> Int64 {
        let stage = record("League stage", size: Int(MacLayout.LeagueStage.settings) + 8, vtable: "LEAGUE_STAGE")
        stage.set("rows", Int(MacLayout.LeagueStage.rows), bytes: vectorBytes(rows))
        if let settings { stage.set("settings", Int(MacLayout.LeagueStage.settings), settings) }
        return stage.address
    }

    /// A league stage's settings: the stage its fixtures name (none if empty), how many clubs it has, and its four counts
    /// of places.
    func leagueSettings(stage: String, clubs: UInt8, places: [UInt8]) -> Int64 {
        typealias S = MacLayout.LeagueSettings
        let settings = record("League settings", size: Int(S.places) + 8, vtable: "LEAGUE_SETTINGS")
        if !stage.isEmpty {
            let text = record("Stage name", size: Int(MacLayout.FixtureName.stageText) + 8)
            text.set("text", Int(MacLayout.FixtureName.stageText), string(stage))
            settings.set("stage", Int(S.stageName), text.address)
        }
        settings.set("clubs", Int(S.clubs), clubs)
        settings.set("places", Int(S.places), bytes: places)
        return settings.address
    }

    /// What a fixture's name points at: its competition and, if it has one, its stage.
    func fixtureName(competition: Int64, stage: String = "") -> Int64 {
        typealias N = MacLayout.FixtureName
        let name = record("Fixture name", size: Int(N.stage) + 8)
        name.set("comp", Int(N.comp), competition)
        if !stage.isEmpty {
            let text = record("Stage name", size: Int(N.stageText) + 8)
            text.set("text", Int(N.stageText), string(stage))
            name.set("stage", Int(N.stage), text.address)
        }
        return name.address
    }

    struct MatchValues {
        var home: Int64
        var away: Int64
        var name: Int64
        var season: UInt16 = 2029
        var round: UInt8 = 0
        var day: UInt16
        var year: UInt16 = 2029
        /// The kick-off code, in quarter hours after 05:45: 37 is 15:00.
        var kickOff: UInt16 = 37
        /// Nil for a fixture not played yet.
        var score: (home: UInt8, away: UInt8)?
        var aggregate: (home: UInt8, away: UInt8)?
        var attendance: UInt32 = 0
        /// 0xffffffff for a half-made copy.
        var matchNumber: UInt32 = 1
        /// Scorer, assister, home side, kind, minute, added minutes.
        var goals: [(scorer: UInt32, assist: UInt32?, home: Bool, kind: UInt8, minute: UInt8, added: UInt8)] = []
    }

    /// A fixture, or with a score a result, which is a fixture with more after it.
    @discardableResult
    func match(_ values: MatchValues) -> FakeRecord {
        typealias F = MacLayout.Fixture
        typealias R = MacLayout.FixtureResult
        let result = values.score != nil
        let record = self.record(result ? "Result" : "Fixture", size: result ? R.size : F.size, vtable: result ? "FIXTURE_RESULT" : "FIXTURE")
        record.set("home", F.home, values.home)
        record.set("away", F.away, values.away)
        record.set("name", F.name, values.name)
        record.set("season", F.season, values.season)
        record.set("round", F.round, values.round)
        record.set("date", F.date, values.day | values.kickOff << 9)
        record.set("year", F.year, values.year)
        guard let score = values.score else { return record }
        record.set("matchNumber", R.matchNumber, values.matchNumber)
        record.set("attendance", R.attendance, values.attendance)
        // The bytes beside the score are 0xff in every match seen.
        record.set("homeGoals", R.homeGoals, bytes: [score.home, 0xff, 0xff, values.aggregate?.home ?? 0xff])
        record.set("awayGoals", R.awayGoals, bytes: [score.away, 0xff, 0xff, values.aggregate?.away ?? 0xff])
        if !values.goals.isEmpty {
            typealias G = MacLayout.Goal
            let list = self.record("Goals", size: values.goals.count * G.size)
            for (i, goal) in values.goals.enumerated() {
                let o = i * G.size
                list.set("scorer \(i)", o + G.scorer, goal.scorer)
                list.set("assist \(i)", o + G.assist, goal.assist ?? .max)
                list.set("side \(i)", o + G.side, bytes: [goal.home ? 0 : 1, goal.kind, goal.minute, goal.added])
            }
            let vector = self.record("Goal vector", size: 24)
            vector.set("begin", 0, list.address)
            vector.set("end", 8, list.address + Int64(list.size))
            record.set("goals", R.goals, vector.address)
        }
        return record
    }

    struct PlayedValues {
        var minutes: UInt8 = 90
        var rating: UInt8 = 70
        var goals: UInt8 = 0
        var assists: UInt8 = 0
        var yellow: UInt8 = 0
        var red: UInt8 = 0
        /// xG × 100, or for a goalkeeper the xG he faced.
        var xG: UInt16 = 0
        /// 0 for a goalkeeper.
        var position: UInt8 = 12
        var shots: UInt8 = 0
        var shotsOnTarget: UInt8 = 0
        var fouls: UInt8 = 0
    }

    /// One match in a player's history. Nil `played` for a substitute who didn't come on.
    struct HistoryEntry {
        var opponent: Int64
        var day: UInt16
        var year: UInt16 = 2029
        var competition: UInt32
        var played: PlayedValues?
        /// Why he didn't play, when `played` is nil.
        var reason: UInt8 = 12
    }

    /// The record a player's `injuries` points at, holding his matches for each team and his bans, from `ban`.
    func history(_ groups: [(team: Int64, entries: [HistoryEntry])], bans: [Int64] = []) -> Int64 {
        typealias G = MacLayout.FormGroup
        typealias E = MacLayout.FormEntry
        typealias M = MacLayout.MatchRecord
        let groupAddresses: [Int64] = groups.map { group in
            let record = self.record("Form group", size: G.entries + 8 * G.kept)
            record.set("team", G.team, group.team)
            record.set("count", G.count, UInt8(group.entries.count))
            for (i, values) in group.entries.enumerated() {
                let entry = self.record("Form entry", size: E.size)
                entry.set("opponent", E.opponent, values.opponent)
                entry.set("day", E.day, values.day)
                entry.set("year", E.year, values.year)
                entry.set("competition", E.competition, values.competition)
                if values.played == nil { entry.set("reason", E.reason, values.reason) }
                if let played = values.played {
                    let stats = self.record("Match record", size: M.size)
                    stats.set("xG", M.xG, played.xG)
                    stats.set("position", M.position, played.position)
                    stats.set("goals", M.goals, played.goals)
                    stats.set("assists", M.assists, played.assists)
                    stats.set("red", M.red, played.red)
                    stats.set("minutes", M.minutes, played.minutes)
                    stats.set("rating", M.rating, played.rating)
                    stats.set("yellow", M.yellow, played.yellow)
                    stats.set("shots", M.shots, played.shots)
                    stats.set("shotsOnTarget", M.shotsOnTarget, played.shotsOnTarget)
                    stats.set("fouls", M.fouls, played.fouls)
                    entry.set("record", E.record, stats.address)
                }
                record.set("entry \(i)", G.entries + 8 * i, entry.address)
            }
            return record.address
        }
        let holder = record("Injuries and matches", size: MacLayout.History.matches + 8)
        holder.set("matches", MacLayout.History.matches, vector(groupAddresses))
        if !bans.isEmpty { holder.set("bans", MacLayout.History.bans, bytes: vectorBytes(bans)) }
        return holder.address
    }
}
