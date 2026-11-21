import Foundation
import StarshipAnalysis
import StarshipCore

/// The user's inbox as FM holds it: each item's kind, date, sender and team, and what it's about for the kinds whose fields
/// are known. FM keeps no text for an item, only what it writes it from. Nothing in it is hidden in FM: it's the user's own
/// inbox, and no ratings are read from it.
extension Toolbox {
    private static let someone = "someone FM Starship doesn't read"

    func inbox(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let club = try context.ownClub(try args.string("club"))
        let since = try Self.date(args, "since")
        let kind = try args.string("kind")
        let limit = try args.int("limit", in: 1...200) ?? 50
        guard let source = context.read.inbox else {
            throw ToolError("FM Starship can't read FM's inbox on this build of FM.")
        }
        guard club.manager != 0 else {
            throw ToolError("FM Starship doesn't know who manages \(club.name), so it can't find their inbox.")
        }
        let db = context.db
        var problem: String?
        var items: [InboxItem] = []
        switch source.inbox(manager: club.manager, teams: db.humanTeams[club.team] ?? [:], today: db.gameDate) {
        case .failed(let why): problem = why
        case .items(let found): items = found
        }
        if problem == nil { problem = inboxProblem(items, context) }
        if let problem {
            throw ToolError("FM Starship's check of \(club.name)'s inbox failed: \(problem). So it's left out rather than guessed. "
                            + "game_status with refresh reads the save again.")
        }

        var notes: [String] = []
        guard let oldest = items.first else {
            return .object([("club", .string(club.name)), ("items", .array([])),
                            ("window", .string("FM holds no items in the user's inbox now, so it can't say what happened before today."))])
        }
        let window = "FM keeps the user's inbox from \(Output.iso(oldest.date)), \(items.count) items. Anything older, such as a "
            + "departure before then, isn't there, so it can't be said from the inbox whether it happened."
        if let since, since < oldest.date {
            notes.append("since is before \(Output.iso(oldest.date)), the oldest item FM keeps, so this can't say what happened from "
                         + "\(Output.iso(since)) to then.")
        }
        var chosen = items.filter { item in since.map { item.date >= $0 } ?? true }
        if let kind {
            let all = chosen
            chosen = chosen.filter { $0.kind.range(of: kind, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            if chosen.isEmpty {
                let kinds = Array(Set(all.map(\.kind))).sorted()
                notes.append("No item's kind contains \"\(kind)\"" + (since.map { " since \(Output.iso($0))" } ?? "")
                             + ". Kinds there: \(kinds.joined(separator: ", ")).")
            }
        }
        chosen.reverse()

        let people = self.people(context.read)
        let names = Self.indexNames(chosen, db)
        var counts: [String: Int] = [:]
        for item in chosen { counts[item.kind, default: 0] += 1 }
        let rows: [JSON] = chosen.prefix(limit).map { item in
            let squad: String = item.team.map { team in
                Names.squadName(db.humanTeams[club.team]?[team] ?? 0)
            } ?? "world news"
            return .object(dropping: [
                ("date", .string(Output.iso(item.date))),
                ("kind", .string(item.kind)),
                ("from", Self.sender(item, people)),
                ("team", .string(squad)),
                ("about", Self.about(item.subject, people, names)),
            ])
        }
        if chosen.count > limit { notes.append("Showing the newest \(limit) of \(chosen.count).") }
        notes.append("FM keeps no text for an item, only its kind and fields, so about is given only for the kinds FM Starship has "
                     + "checked: injury reports, contracts expiring soon, transfers completed and come-and-get-me pleas.")

        return .object(dropping: [
            ("club", .string(club.name)),
            ("window", .string(window)),
            ("since", since.map { .string(Output.iso($0)) }),
            ("kind", kind.map { .string($0) }),
            ("found", .int(chosen.count)),
            ("kinds", counts.isEmpty ? nil : .object(counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { ($0.key, .int($0.value)) })),
            ("items", .array(rows)),
            ("notes", .array(notes.map { .string($0) })),
        ])
    }

    /// What's wrong with the inbox against the rest of the save: an injury report whose length isn't the player's own record
    /// of that injury, the same injury on the same day. Nil when it passes.
    func inboxProblem(_ items: [InboxItem], _ context: CallContext) -> String? {
        let players = people(context.read).players
        for item in items {
            guard case .injury(let who, let injury, let on?, let days) = item.subject, let player = players[who.uid],
                  let record = player.injuries?.first(where: { $0.date == on && $0.name == injury }), record.length > 0 else { continue }
            if record.length != days {
                return "FM's injury report of \(Output.iso(item.date)) gives \(player.name) \(days) days, and his own injury record "
                    + "\(record.length)"
            }
        }
        return nil
    }

    /// The names of the people the items name only by database index, from FM Starship's read.
    private static func indexNames(_ items: [InboxItem], _ db: Database) -> [UInt32: Person] {
        var wanted = Set<UInt32>()
        for item in items { if case .contractsExpiring(let indexes) = item.subject { wanted.formUnion(indexes) } }
        guard !wanted.isEmpty else { return [:] }
        var found: [UInt32: Person] = [:]
        for person in (db.players as [Person]) + db.staff where wanted.contains(person.index) && found[person.index] == nil {
            found[person.index] = person
        }
        return found
    }

    private static func sender(_ item: InboxItem, _ people: (players: [UInt32: Player], staff: [UInt32: Staff])) -> JSON? {
        if item.fromAgent { return .object([("name", "an agent")]) }
        guard let sender = item.sender else { return nil }
        return person(sender, people, job: item.senderJob)
    }

    /// A person a news item names, with the uid the other tools take when FM Starship reads them.
    private static func person(_ person: NewsPerson, _ people: (players: [UInt32: Player], staff: [UInt32: Staff]),
                               job: String? = nil) -> JSON {
        let known: Person? = person.isPlayer ? people.players[person.uid] : people.staff[person.uid] ?? people.players[person.uid]
        let name = known?.name ?? person.name
        return .object(dropping: [
            ("uid", known.map { .int(Int($0.uid)) }),
            ("name", .string(name.isEmpty ? someone : name)),
            ("job", job.map { .string($0) }),
        ])
    }

    private static func about(_ subject: NewsSubject?, _ people: (players: [UInt32: Player], staff: [UInt32: Staff]),
                              _ names: [UInt32: Person]) -> JSON? {
        switch subject {
        case nil:
            return nil
        case .injury(let player, let injury, let on, let days)?:
            return .object(dropping: [("player", person(player, people)), ("injury", Output.text(injury)),
                                      ("injured_on", on.map { .string(Output.iso($0)) }), ("days", .int(days))])
        case .contractsExpiring(let indexes)?:
            return .object([("contracts_expiring", .array(indexes.map { index in
                guard let known = names[index] else { return .object([("name", .string(someone + " (database index \(index))"))]) }
                return .object(dropping: [("uid", .int(Int(known.uid))), ("name", .string(known.name)),
                                          ("job", (known as? Staff).flatMap { Output.text($0.job) })])
            }))])
        case .transfer(let who, let club)?:
            return .object([("person", person(who, people)), ("other_club", .string(club)),
                            ("note", "Which way the transfer went isn't read: the item names the person and the other club.")])
        case .comeAndGetMe(let player, let club)?:
            return .object([("player", person(player, people)), ("wants_to_join", .string(club))])
        }
    }
}
