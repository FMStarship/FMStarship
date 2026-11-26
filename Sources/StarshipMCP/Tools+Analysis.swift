import Foundation
import StarshipAnalysis
import StarshipCore
import StarshipSearch

/// FM Starship's own analysis, from the same calls as its screens, so what they leave out with Hidden attributes or
/// Ability off is left out here too.
extension Toolbox {
    /// The overview columns about who'd be hired, which ask the game place by place and aren't in this version.
    private static let hireColumns: Set<String> = ["Best who'd join", "Their rating", "Gain", "About them"]

    /// The club's players who could cover a place: its own and those on loan to it, not those it has loaned out, and not
    /// anyone out for three weeks or more, as the squad overview counts them.
    static func fitSquad(_ session: AnalysisSession) -> [Player] {
        let club = session.club.name
        return session.db.players.filter { player in
            (player.clubFull == club && player.loanClub.isEmpty || player.loanClubFull == club)
                && (player.injury == nil || (session.checks.injuryKnown(player) ?? player.injuryDays) < 21)
        }
    }

    /// The overview's footnote, without what it says about the hires column, which isn't sent.
    static func withoutHires(_ footnote: String) -> String {
        footnote.replacingOccurrences(of: " Each pick fits your budget on the wage they earn now.", with: "")
            .replacingOccurrences(of: "Each pick fits your budget on the wage they earn now.", with: "")
    }

    private static func rulesOff(_ what: String) -> ToolError {
        ToolError("\(what) needs FM's rules, which are off on this build of FM because FM Starship hasn't been checked on it.")
    }

    /// How keen each player is, in FM's words, from the answers the finder already got from FM. Nothing new is asked.
    private static func keenness(_ session: AnalysisSession) -> [Output.Field] {
        [Output.Field(name: "Transfer interest") { person in
            (person as? Player).flatMap { session.checks.known($0) }.map { .string($0.transferInterest.text) }
        },
         Output.Field(name: "Loan interest") { person in
            (person as? Player).flatMap { player in session.checks.known(player).map { .string(loanText(player, $0)) } }
        }]
    }

    /// FM isn't asked about a loan when the player's club won't loan him: that's the club's decision, not his.
    static func loanText(_ player: Player, _ answer: JoinAnswer) -> String {
        player.loanUnavailable ? "Not available for loan" : answer.loanInterest.text
    }

    func clubOverview(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let club = try context.ownClub(try args.string("club"))
        let session = context.session(for: club)
        let dashboard = ClubDashboard(session: session)
        var pairs: [(String, JSON)] = [("club", .string(dashboard.club))]
        if !dashboard.line.isEmpty { pairs.append(("line", .string(Output.prose(dashboard.line)))) }
        pairs.append(("facts", .object(dashboard.facts.map { ($0.label, Output.text($0.value) ?? .null) })))
        pairs.append(("players_needing_action_now", .int(dashboard.actions)))
        pairs.append(("issues", .array(dashboard.issues.map { issue in
            .object(dropping: [("uid", issue.person.map { .int(Int($0.uid)) }), ("name", .string(issue.name)),
                               ("issue", Output.text(issue.issue)), ("detail", Output.text(issue.detail))])
        })))
        if dashboard.showsAbility {
            pairs.append(("prospects", .array(dashboard.prospects.map { prospect in
                .object(dropping: [("uid", .int(Int(prospect.player.uid))), ("name", .string(prospect.player.name)),
                                   ("age", prospect.player.age >= 0 ? .int(prospect.player.age) : nil),
                                   ("now_to_likely_peak", Output.text(prospect.path)),
                                   ("verdict", prospect.verdict.map { .string($0.title) }), ("odds", prospect.odds.flatMap(Output.text))])
            })))
        } else {
            pairs.append(("prospects", "Not listed: prospects are picked on PA, which is off."))
        }
        return .object(pairs)
    }

    func squadOverview(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let club = try context.ownClub(try args.string("club"))
        guard context.read.engine != nil else { throw Self.rulesOff("The squad overview") }
        guard context.db.tactics[club.team] != nil else {
            throw ToolError("FM Starship couldn't find \(club.name)'s tactic in FM's memory. The user can try opening the tactic they "
                + "play in FM's Tactics screen; then ask again with game_status refresh: true, which says whether it's found.")
        }
        let noRatings = ToolError("The squad overview needs FM's role ratings, which FM didn't give for \(club.name). Ask again in a moment.")
        let session = context.session(for: club)
        guard let report = SquadOverview(session: session) else { throw noRatings }
        guard report.places.contains(where: { $0.slot.player != nil }) else {
            throw ToolError("\(club.name)'s tactic in FM has nobody picked for it. The user can pick a team in FM's Tactics screen; "
                + "then ask again with game_status refresh: true.")
        }
        // Without FM's role ratings every place comes back unrated, or with "no real cover" from a bench FM didn't rate,
        // and neither is something FM said.
        guard report.places.contains(where: { $0.slot.player != nil && $0.stars > 0 }) else { throw noRatings }
        if report.places.allSatisfy({ $0.cover == "Nobody" }), Self.fitSquad(session).count > 11 { throw noRatings }
        return .object([("club", .string(club.name)), ("headline", .string(Output.prose(report.headline)))]
                       + Output.table(report.table(hires: [:]), dropping: Self.hireColumns, withHead: false)
                       + [("footnote", .string(Self.withoutHires(Output.prose(report.footnote))))])
    }

    func staffOverview(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let club = try context.ownClub(try args.string("club"))
        let report = StaffOverview(session: context.session(for: club))
        var pairs: [(String, JSON)] = [("club", .string(club.name)), ("headline", .string(Output.prose(report.headline)))]
        pairs += Output.table(report.table(hires: [:]), dropping: Self.hireColumns, withHead: false)
        pairs.append(("training", .array(report.areas.map { area in
            .object(dropping: [("area", .string(area.name)), ("stars", area.stars > 0 ? .double(area.stars) : nil),
                               ("coach", Output.text(area.coach)), ("rank", Output.text(area.rank)), ("standing", .string(area.standing.title))])
        })))
        if !report.places.isEmpty {
            pairs.append(("places", .array(report.places.map { ["job": .string($0.name), "filled": .int($0.filled), "allowed": .int($0.allowed)] })))
        }
        if let note = report.coachNote { pairs.append(("coach_note", .string(Output.prose(note)))) }
        pairs.append(("footnote", .string(Output.prose(report.footnote))))
        return .object(pairs)
    }

    func compare(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let uids = try args.array("uids") ?? []
        guard (2...4).contains(uids.count) else { throw ToolError("compare takes two to four uids.") }
        let numbers = try uids.map { item -> Int in
            guard let uid = item.int else { throw ToolError("Each uid must be a whole number.") }
            return uid
        }
        // A player/manager is a player and a member of staff under one uid, so with no kind given he's on the side the
        // others are all on: with staff, as staff.
        var kind = try args.choice("kind", ["player", "staff"])
        if kind == nil {
            let all = self.people(context.read)
            if !numbers.allSatisfy({ all.players[UInt32(clamping: $0)] != nil }), numbers.allSatisfy({ all.staff[UInt32(clamping: $0)] != nil }) {
                kind = "staff"
            }
        }
        let people = try numbers.map { try context.person($0, kind: kind) }
        guard people.allSatisfy({ $0 is Player }) || people.allSatisfy({ $0 is Staff }) else {
            throw ToolError("compare takes players or staff, not both.")
        }
        // A club that's named must be one; with none named, the user's, if the save has one.
        let named = try args.string("club")
        let club = try named.map { try context.ownClub($0) } ?? (try? context.ownClub(nil))
        let report = CompareReport(people: people, session: context.session(for: club ?? ChosenClub()))
        let rows: [JSON] = report.rows().flatMap { row -> [JSON] in
            // Whether someone would join the club they're already at means nothing.
            if row.label == "Interest", !row.isSection, let club {
                let cells: [JSON] = zip(people, row.cells).map { person, cell in
                    person.clubFull == club.name ? .null : Output.text(cell) ?? .null
                }
                return cells.allSatisfy { $0 == .null } ? [] : [.array(["Interest"] + cells)]
            }
            // "3 (2)" as two numbers, as in the lists.
            if row.label == "Appearances", !row.isSection {
                return [.array(["Starts"] + people.map { Output.starts($0) ?? .null }),
                        .array(["Sub appearances"] + people.map { person in (person as? Player)?.season.map { .int($0.subs) } ?? .null })]
            }
            return [.array([.string(row.label)] + row.cells.map { Output.text($0) ?? .null })]
        }
        return ["people": .array(people.map { ["uid": .int(Int($0.uid)), "name": .string($0.name)] }),
                "note": "A row with only a label starts a section.", "rows": .array(rows)]
    }

    func recommendSignings(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let club = try context.ownClub(try args.string("club"))
        var options = RecommendOptions()
        switch try args.choice("mode", ["best", "young", "budget"]) {
        case "young": options.mode = .young
        case "budget": options.mode = .budget
        default: options.mode = .best
        }
        if let position = try args.choice("position", Names.positions) { options.position = Names.positions.firstIndex(of: position) ?? -1 }
        if let fee = try args.number("max_fee") { options.maxFee = String(fee / 1_000_000) }
        switch try args.choice("show", ["all", "free_agents", "no_free_agents"]) {
        case "free_agents": options.show = .freeAgentsOnly
        case "no_free_agents": options.show = .noFreeAgents
        default: options.show = .all
        }
        options.includeLoans = try args.bool("include_loans") ?? false
        options.upgradesOnly = try args.bool("upgrades_only") ?? true
        let limit = try args.int("limit", in: 1...10) ?? 10
        let session = context.session(for: club)
        guard let table = SigningRecommender(session: session).find(options) else {
            throw ToolError("The search was stopped.")
        }
        return .object([("club", .string(club.name))] + Output.table(table, limit: limit, extra: Self.keenness(session)))
    }

    /// The jobs Recommended staff looks for, once each: a job the app has a tab for at each team level is one name here.
    static let staffRoleNames: [String] = StaffRoles.all.map(\.name).reduce(into: []) { names, name in
        if !names.contains(name) { names.append(name) }
    }
    /// The app's "For your" box, and its "Wants the job" box, in order.
    static let staffLevels = ["first_team", "reserves", "youth"]
    static let staffKeenness = ["open_to_it", "keen", "favourite", "anyone"]
    /// How far down a job's ranking FM is asked who'd join: each one asked is several of FM's rules, and the server answers
    /// one call at a time. The app's staff overview stops at 480.
    static let staffDeepest = 600

    func recommendStaff(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let club = try context.ownClub(try args.string("club"))
        guard let name = try args.choice("role", Self.staffRoleNames) else {
            throw ToolError("recommend_staff needs a role, one of: \(Self.staffRoleNames.joined(separator: ", ")).")
        }
        let chosen = try args.choice("level", Self.staffLevels).flatMap { Self.staffLevels.firstIndex(of: $0) }
        let session = context.session(for: club)
        let recommender = StaffRecommender(session: session)
        let level = chosen ?? 0
        if level > 0, let limits = recommender.limits, limits.teamFor(level) < 0 {
            throw ToolError("\(club.name) has no \(level == 1 ? "reserve" : "youth") team in FM.")
        }
        // A job that repeats at each team level is its own tab there; any other takes the level from the "For your" box.
        let tabs = recommender.tabs.map(\.role).filter { $0.name == name }
        guard let role = tabs.first(where: { $0.level == level }) ?? tabs.first(where: { $0.level < 0 }) else {
            throw ToolError(level == 0 ? "The first team's \(name.lowercased()) is the user. Give level reserves or youth."
                                       : "\(club.name) has no \(name.lowercased()) place at that team level.")
        }
        var options = StaffSearchOptions(role: role, level: role.level >= 0 ? role.level : level)
        let wageMax = try args.number("wage_max")
        // The app's screen opens with the box at the wage room.
        options.maxWage = wageMax.map { String($0 / 1000) } ?? recommender.startingMaxWage
        options.maxAge = try args.int("age_max").map(String.init) ?? ""
        if let keen = try args.choice("wants_job", Self.staffKeenness) { options.keen = Self.staffKeenness.firstIndex(of: keen) ?? 0 }
        options.onlyJoin = try args.bool("only_join") ?? true
        let limit = try args.int("limit", in: 1...25) ?? 10
        let checks = session.checks
        let failedBefore = checks.failures
        guard var table = recommender.find(options, wanted: limit, deepest: Self.staffDeepest) else {
            throw ToolError("The search was stopped.")
        }
        // People FM couldn't answer for in this call; it remembers only the answers it gave.
        let failed = max(checks.failures - failedBefore, 0)

        let team = recommender.levelNames[options.level]
        // As the screen writes the level: "first team", otherwise the team's own name.
        let teamText = options.level == 0 ? "first team" : team
        // What FM is asked about the job itself, and how to say it.
        let question = StaffRecommender.jobQuestion(role: role, level: options.level).flatMap { checks.canCheckStaffJob(level: $0.level) ? $0 : nil }
        let jobText = "the job of \(name.lowercased())"
        // Whether Would join at this level is about the team named here: for Molde, FM's reserves level is its U19, not Molde 2.
        let fits = recommender.wouldJoinFits(role: role, level: options.level)
        // FM answering without weighing up the job, as it does for a whole club in some game modes.
        let notWeighed = question.map { checks.staffJobNotWeighed(job: $0.job, level: $0.level) } ?? false
        // The teams FM's staff search asked about, which Would join names.
        let levelTeams = (0..<3).map { checks.levelTeamName(level: $0) }
        var levelsAsked = "the first team, reserves and youth"
        if let reserves = levelTeams[1], let youth = levelTeams[2] {
            levelsAsked = checks.reservesAreYouth ? "the first team and the \(youth), FM's reserves and youth levels being the same team"
                : "the first team, the \(reserves) and the \(youth)"
        }
        let asked = question.map { q in
            " FM's staff search answers Would join about the club and the team, for the job FM itself would weigh each one up for, "
                + "which may not be this one. Takes job is the same rule of FM's asked about \(jobText) at "
                + (q.level == 0 ? "the first team" : "the \(teamText)") + ": No is FM turning them down for this job, as it does when "
                + "someone in a bigger job, such as a director of football, is offered a smaller one."
        } ?? ""
        let noJobAnswer = " FM couldn't be asked whether they'd take this job itself, so Takes job is empty: Would join is FM's answer "
            + "about the club and the team, not the job, and people in a bigger job, such as a director of football, may refuse a "
            + "smaller one in talks."
        var interest: String
        if !recommender.onlyJoinEnabled {
            let why = context.read.engine == nil ? "FM's rules are off on this build of FM"
                : "FM only answers that for a club the user manages, and FM Starship found no manager at \(club.name)"
            interest = "FM couldn't be asked who'd join: \(why). This list isn't narrowed to people who'd come, and Would join is empty."
        } else if options.onlyJoin {
            if !fits && !table.jobChecked && (question == nil || notWeighed) {
                interest = "This list isn't narrowed to people who'd come, and Takes job is empty: FM's staff search has no level for "
                    + "\(club.name)'s \(teamText), and FM " + (notWeighed ? "answers without weighing up the job there"
                                                                     : "couldn't be asked about the job there")
                    + ". Don't present it as people who'd come."
                if failed > 0 {
                    interest += " FM didn't answer who'd join for \(failed) of the people it was asked about, whose Would join is empty."
                }
            } else if !table.interestChecked {
                let asked = failed > 0 ? "any of the \(failed) people it was asked about" : "anyone it was asked about"
                interest = "FM gave no answer about who'd join for \(asked), so this list isn't narrowed to people who'd come, and Would join "
                    + "is empty. Don't present it as people who'd come. If asking again gives the same, FM can't answer it for "
                    + "\(club.name) on this build of FM."
            } else {
                let joins = fits ? "would join \(club.name)'s \(teamText)" + (table.jobChecked ? " and take \(jobText)" : "")
                    : "would take \(jobText) at \(club.name)'s \(teamText), among those it says would join the first team"
                interest = table.rows.isEmpty
                    ? failed == 0 && !table.stoppedAtDeepest ? "Nobody FM says \(joins) passes these settings."
                        : "None of those FM answered for \(joins)."
                    : "Everyone listed is someone FM says \(joins)."
                if failed > 0 {
                    interest += " FM didn't answer for \(failed) of the people it was asked about, so they're left out; asking again may "
                        + "get their answers."
                }
                interest += table.jobChecked ? asked : noJobAnswer
            }
        } else {
            // The screen only fills Would join for people FM was asked about, so the rows sent out are asked about here.
            let shown = table.rows.prefix(limit).compactMap { $0.person as? Staff }
            checks.checkAllStaff(shown)
            if let column = table.columns.firstIndex(where: { $0.title == "Would join" }) {
                for index in table.rows.indices.prefix(limit) {
                    guard let person = table.rows[index].person as? Staff, column < table.rows[index].cells.count else { continue }
                    table.rows[index].cells[column] = checks.staffText(person)
                }
            }
            // Only those FM says would join at this level, or the first team where FM's level is another team, are asked about
            // the job: the question skips FM's own job pick, which can turn someone down whatever the job, so a yes for anyone
            // else wouldn't be FM's.
            let joining = shown.filter { person in
                checks.staffKnown(person).map { $0.wouldJoin(level: fits ? options.level : 0) } == true
            }
            var jobAsked = question != nil
            if let question {
                checks.checkStaffJob(joining, job: question.job, level: question.level)
                jobAsked = !joining.contains { checks.staffJobKnown($0, job: question.job, level: question.level) == .notAsked }
                if jobAsked, let column = table.columns.firstIndex(where: { $0.title == "Takes job" }) {
                    let askedUIDs = Set(joining.map(\.uid))
                    for index in table.rows.indices.prefix(limit) {
                        guard let person = table.rows[index].person as? Staff, column < table.rows[index].cells.count else { continue }
                        table.rows[index].cells[column] = askedUIDs.contains(person.uid)
                            ? checks.staffJobText(person, job: question.job, level: question.level) : ""
                    }
                }
            }
            let unanswered = shown.filter { checks.staffKnown($0) == nil }.count
            interest = "Not narrowed to who'd join. Would join is FM's answer for each one listed, naming the teams it was asked about: "
                + levelsAsked
                + (unanswered == 0 ? "." : "; FM didn't answer for \(unanswered) of them, whose Would join is empty.")
            if let question, jobAsked {
                let noJob = joining.filter { checks.staffJobKnown($0, job: question.job, level: question.level) == nil }.count
                interest += asked + " Takes job is only asked for those FM says would join " + (fits ? "your \(teamText)" : "your first team")
                    + ", and left empty for the rest: "
                    + "the question skips the first step of FM's rule, which can turn someone down whatever the job, so a Yes for "
                    + "them wouldn't be FM's." + (noJob == 0 ? "" : " FM didn't answer about the job for \(noJob) of those it was "
                    + "asked about, whose Takes job is empty.")
            } else {
                interest += noJobAnswer
            }
        }
        if table.stoppedAtDeepest {
            interest += " FM was asked about the best \(Self.staffDeepest) for the job who pass these settings and no further, so there may "
                + "be more further down: a lower wage_max or an age_max reaches others."
        }
        table.status = table.status.replacingOccurrences(of: "'Anyone' for wanting the job", with: "wants_job anyone")
            .replacingOccurrences(of: "untick 'Only staff who'd join'", with: "only_join false")

        var pairs: [(String, JSON)] = [("club", .string(club.name)), ("role", .string(name)), ("team", .string(team))]
        pairs += Output.table(table, limit: limit)
        if let note = recommender.levelNote(role: role, level: options.level, listedByJob: options.onlyJoin && table.jobChecked) {
            interest += " " + note
        }
        pairs.append(("interest", .string(interest)))
        if wageMax == nil, !options.maxWage.isEmpty {
            pairs.append(("wage_max", .string("Left out, so up to the club's wage room, \(recommender.startingMaxWageText), "
                + "as the app's screen starts. Give wage_max to look further.")))
        }
        // As the screen's note: what this build of FM couldn't tell.
        var missing: [String] = []
        if recommender.limits == nil { missing.append("the board's staff limits") }
        if recommender.onlyJoinEnabled, !recommender.jobCheckEnabled(role: role, level: options.level) {
            missing.append("whether they'd take this job")
        }
        if StaffRoles.preferenceIndex(role.name) >= 0, !table.rows.isEmpty,
           let column = table.columns.firstIndex(where: { $0.title == "Wants job" }),
           table.rows.allSatisfy({ column >= $0.cells.count || $0.cells[column].isEmpty }) {
            missing.append("how keen they are on the job and the job they prefer" + (args.has("wants_job") ? ", so wants_job wasn't used" : ""))
        }
        if !missing.isEmpty { pairs.append(("not_available", .string("Not available on this version: " + missing.joined(separator: ", ") + "."))) }
        if let note = recommender.wantsJobNote(role) { pairs.append(("wants_job_note", .string(note))) }
        return .object(pairs)
    }

    func findBargains(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let club = try context.ownClub(try args.string("club"))
        var options = BargainOptions()
        switch try args.choice("kind", ["contracts_ending", "free_agents", "release_clauses", "transfer_listed", "wonderkids"]) {
        case "free_agents": options.kind = .free
        case "release_clauses": options.kind = .clause
        case "transfer_listed": options.kind = .listed
        case "wonderkids": options.kind = .wonderkid
        default: options.kind = .ending
        }
        if let position = try args.choice("position", Names.positions) { options.position = Names.positions.firstIndex(of: position) ?? -1 }
        if args.has("min_ca"), !context.visibility.showsAbility {
            throw ToolError(Visibility.abilitySentence("CA", showHidden: context.visibility.showHidden))
        }
        options.minCA = try args.int("min_ca").map(String.init) ?? ""
        options.maxAge = try args.int("max_age").map(String.init) ?? ""
        if let fee = try args.number("max_fee") { options.maxFee = String(fee / 1_000_000) }
        options.onlyJoin = try args.bool("only_join") ?? true
        let limit = try args.int("limit", in: 1...25) ?? 25
        let session = context.session(for: club)
        guard let table = BargainFinder(session: session).find(options) else {
            throw ToolError("The search was stopped.")
        }
        return .object([("club", .string(club.name))] + Output.table(table, limit: limit, extra: Self.keenness(session)))
    }
}
