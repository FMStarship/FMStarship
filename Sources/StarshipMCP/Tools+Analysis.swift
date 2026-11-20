import Foundation
import StarshipAnalysis
import StarshipCore
import StarshipSearch

/// FM Starship's own analysis, from the same calls as its screens, so what they leave out with Hidden attributes or
/// Ability off is left out here too.
extension Toolbox {
    /// The overview columns about who'd be hired, which ask the game place by place and aren't in this version.
    private static let hireColumns: Set<String> = ["Best who'd join", "Their rating", "Gain", "About them"]

    private static func rulesOff(_ what: String) -> ToolError {
        ToolError("\(what) needs FM's rules, which are off on this build of FM because FM Starship hasn't been checked on it.")
    }

    func clubOverview(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let club = try context.ownClub(try args.string("club"))
        let session = context.session(for: club)
        let dashboard = ClubDashboard(session: session)
        var pairs: [(String, JSON)] = [("club", .string(dashboard.club))]
        if let line = Output.text(dashboard.line) { pairs.append(("line", line)) }
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
        guard let report = SquadOverview(session: context.session(for: club)) else {
            throw ToolError("The squad overview needs \(club.name)'s tactic, which FM Starship couldn't find in this save.")
        }
        return .object([("club", .string(club.name)), ("headline", .string(Output.isoDates(report.headline)))]
                       + Output.table(report.table(hires: [:]), dropping: Self.hireColumns, withHead: false)
                       + [("footnote", .string(Output.isoDates(report.footnote)))])
    }

    func staffOverview(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let club = try context.ownClub(try args.string("club"))
        let report = StaffOverview(session: context.session(for: club))
        var pairs: [(String, JSON)] = [("club", .string(club.name)), ("headline", .string(Output.isoDates(report.headline)))]
        pairs += Output.table(report.table(hires: [:]), dropping: Self.hireColumns, withHead: false)
        pairs.append(("training", .array(report.areas.map { area in
            .object(dropping: [("area", .string(area.name)), ("stars", area.stars > 0 ? .double(area.stars) : nil),
                               ("coach", Output.text(area.coach)), ("rank", Output.text(area.rank)), ("standing", .string(area.standing.title))])
        })))
        if !report.places.isEmpty {
            pairs.append(("places", .array(report.places.map { ["job": .string($0.name), "filled": .int($0.filled), "allowed": .int($0.allowed)] })))
        }
        if let note = report.coachNote { pairs.append(("coach_note", .string(note))) }
        pairs.append(("footnote", .string(report.footnote)))
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
        let rows: [JSON] = report.rows().map { row in
            .array([.string(row.label)] + row.cells.map { Output.text($0) ?? .null })
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
        guard let table = SigningRecommender(session: context.session(for: club)).find(options) else {
            throw ToolError("The search was stopped.")
        }
        return .object([("club", .string(club.name))] + Output.table(table))
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
        guard let table = BargainFinder(session: context.session(for: club)).find(options) else {
            throw ToolError("The search was stopped.")
        }
        return .object([("club", .string(club.name))] + Output.table(table))
    }
}
