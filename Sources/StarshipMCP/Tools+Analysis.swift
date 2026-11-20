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
        let people = try uids.map { item -> Person in
            guard let uid = item.int else { throw ToolError("Each uid must be a whole number.") }
            return try context.person(uid)
        }
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
