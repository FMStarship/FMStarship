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
    static let playerListColumns = ["Name", "Age", "Position", "Club", "Nation", "CA", "PA", "Value", "Wage", "Contract end"]
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
        var names = Self.squadColumns
        if shown == nil, let at = names.firstIndex(of: "Position") { names.insert("Squad", at: at + 1) }
        let columns = Output.columns(names, in: Columns.forPlayers(), context.visibility)
        return .object([("club", .string(club)), ("squad", .string(shown ?? "all")),
                        ("squads", .array(squads.map { .string($0) })), ("players", .int(players.count)),
                        ("wages", .string(Units.wageSuffix))]
                       + Output.rows(players, columns, context.visibility))
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
                       + Output.rows(people, columns, context.visibility, extra: [("Best coaching", { Self.bestCoaching($0) })]))
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
        if let player = person as? Player {
            pairs.append(("kind", "player"))
            if player.injury != nil { _ = RulesState.shared.injuryCheck(player) }
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
            let values = columns.filter { $0.group == group }.compactMap { col in
                Output.value(col, person, visibility).map { (col.name, $0) }
            }
            if !values.isEmpty { pairs.append((group, .object(values))) }
        }
        if let player = person as? Player {
            let traits = player.traits.components(separatedBy: "; ").filter { !$0.isEmpty }
            if !traits.isEmpty { pairs.append(("Traits", .array(traits.map { .string($0) }))) }
        }
        if let session, let join = wouldJoin(person, session) { pairs.append(("Would join your club", join)) }
        return .object(pairs)
    }

    /// FM's own answer, asked for this one person. Nothing when FM's rules are off or they're already at the club.
    private func wouldJoin(_ person: Person, _ session: AnalysisSession) -> JSON? {
        guard person.clubFull != session.club.name else { return nil }
        if let player = person as? Player, let answer = session.checks.check(player) {
            return ["club": .string(session.club.name), "transfer": .string(answer.transferInterest.text),
                    "loan": .string(answer.loanInterest.text)]
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
                                       ("people", .int(people.count))]
        let missing = entry.shortlist.uids.count - people.count
        if missing > 0 { pairs.append(("not_in_this_save", .int(missing))) }
        return .object(pairs + Output.rows(people, columns, context.visibility))
    }
}
