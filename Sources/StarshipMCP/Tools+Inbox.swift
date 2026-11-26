import Foundation
import StarshipAnalysis
import StarshipCore
import StarshipSearch

/// The user's inbox as FM holds it: each item's kind, date, sender and team, and what it's about for the kinds whose fields
/// are known. FM keeps no text for an item, only what it writes it from. Nothing in it is hidden in FM: it's the user's own
/// inbox, and no ratings are read from it.
extension Toolbox {
    private static let someone = "someone FM Starship doesn't read"
    /// An item not addressed to one of the club's teams: FM's own news item, copied into the inbox. On the save checked,
    /// every one named the club's team or one of its players (bans, call-ups, scouting).
    static let noTeam = "not addressed to one team"

    func inbox(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let club = try context.ownClub(try args.string("club"))
        let since = try Self.date(args, "since")
        let kind = try args.string("kind")
        let important = try args.bool("important")
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
        if let important { chosen = chosen.filter { $0.isImportant == important } }
        if let kind {
            let all = chosen
            chosen = chosen.filter { $0.kind.range(of: kind, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            if chosen.isEmpty {
                let kinds = Array(Set(all.map(\.kind))).sorted()
                notes.append("No item's kind contains \"\(kind)\"" + (since.map { " since \(Output.iso($0))" } ?? "")
                             + (important.map { $0 ? " among the important ones" : " among the others" } ?? "")
                             + ". Kinds there: \(kinds.joined(separator: ", ")).")
            }
        }
        chosen.reverse()

        let people = self.people(context.read)
        let names = Self.indexNames(chosen, db)
        var counts: [String: Int] = [:]
        for item in chosen { counts[item.kind, default: 0] += 1 }
        let shown = chosen.prefix(limit)
        // FM's transfer timeline is swept for only when a transfer item is shown, as that takes a few seconds.
        let timeline = shown.contains { Self.isTransfer($0.subject) }
            ? Timeline(events: source.transferEvents(), teams: Set((db.humanTeams[club.team] ?? [:]).keys)) : nil
        let rows: [JSON] = shown.map { item in
            let squad: String = item.team.map { team in
                Names.squadName(db.humanTeams[club.team]?[team] ?? 0)
            } ?? Self.noTeam
            return .object(dropping: [
                ("date", .string(Output.iso(item.date))),
                ("kind", .string(item.kind)),
                ("from", Self.sender(item, people)),
                ("team", .string(squad)),
                ("about", Self.about(item.subject, people, names, club: club.name, date: item.date, timeline: timeline)),
            ])
        }
        if chosen.count > limit { notes.append("Showing the newest \(limit) of \(chosen.count).") }
        let revised = shown.contains { item in
            guard case .injury(let player, let injury, let on, let days)? = item.subject else { return false }
            return Self.recordDays(player, injury: injury, on: on, days: days, people.players) != nil
        }
        if revised {
            notes.append("An injury's days are the length FM's report gave. Where the player's own record of that injury holds "
                         + "another length now, that's record_days, and it's the one FM's days out goes by.")
        }
        notes.append("FM keeps no text for an item, only its kind and fields, so about is given only for the kinds FM Starship has "
                     + "checked: injury reports, contracts expiring soon, transfers completed, come-and-get-me pleas, players "
                     + "unhappy with training, fines (who, not how much), coach feedback on a player (whom, not what), contract "
                     + "add-ons activated (whose, and the clause and its sum when it's the one for goals in the season) and "
                     + "transfer offers confirmed (the person, the other club and the fee). For a transfer, direction is which "
                     + "way it went, from FM's transfer timeline, when that has it.")
        if important == true {
            notes.append("Important means these kinds: injuries, transfers, bids and offers, come-and-get-me pleas, unhappiness, "
                         + "fines, contracts and the board. Everything else, such as staff meeting advice, press, odds, coach "
                         + "feedback and bans, is left out; important false gives those.")
        }

        return .object(dropping: [
            ("club", .string(club.name)),
            ("window", .string(window)),
            ("since", since.map { .string(Output.iso($0)) }),
            ("kind", kind.map { .string($0) }),
            ("important", important.map { .bool($0) }),
            ("found", .int(chosen.count)),
            ("kinds", counts.isEmpty ? nil : .object(counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { ($0.key, .int($0.value)) })),
            ("items", .array(rows)),
            ("notes", .array(notes.map { .string($0) })),
        ])
    }

    /// What's wrong with the inbox against the rest of the save: its injury reports' lengths against the players' own
    /// records of the same injury on the same day. FM can hold another length in the record than its report gave, as for one
    /// of the two reports on the save checked on 27.1.1, so one report that agrees shows the lengths are read right; with
    /// none agreeing, a misread can't be told from that, and the check fails. Nil when it passes.
    func inboxProblem(_ items: [InboxItem], _ context: CallContext) -> String? {
        let players = people(context.read).players
        var differs: String?
        for item in items {
            guard case .injury(let who, let injury, let on?, let days) = item.subject, let player = players[who.uid],
                  let record = player.injuries?.first(where: { $0.date == on && $0.name == injury }), record.length > 0 else { continue }
            if record.length == days { return nil }
            if differs == nil {
                differs = "FM's injury report of \(Output.iso(item.date)) gives \(player.name) \(days) days, and his own injury "
                    + "record \(record.length), and no injury report agrees with its player's record"
            }
        }
        return differs
    }

    /// The length the player's own record of a reported injury holds, the same injury on the same day, where it isn't the
    /// report's.
    static func recordDays(_ player: NewsPerson, injury: String, on: Date?, days: Int, _ players: [UInt32: Player]) -> Int? {
        guard let on, let record = players[player.uid]?.injuries?.first(where: { $0.date == on && $0.name == injury }),
              record.length > 0, record.length != days else { return nil }
        return record.length
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

    /// FM's transfer timeline as read for an answer, and the user's club's teams by database index. Nil events when it
    /// couldn't be read.
    struct Timeline {
        let events: [TransferEvent]?
        let teams: Set<UInt32>
    }

    static func isTransfer(_ subject: NewsSubject?) -> Bool {
        switch subject {
        case .transfer?, .offerConfirmed?: return true
        default: return false
        }
    }

    static let timelineNote = "FM's transfer timeline keeps only the manager's notable moves, not every one"

    /// Which way a transfer went, as "to Molde FK from Pisa Sporting Club", from FM's transfer timeline: only when exactly
    /// one move in it is this person's on the item's day, between one of the user's club's teams and another club's, that
    /// club is the item's other club, and the fees agree when both have one. Nil otherwise, with why.
    static func direction(_ person: NewsPerson, on date: Date, otherClub: String?, fee: Int64?, club: String,
                          _ timeline: Timeline?) -> (direction: String?, why: String?) {
        guard let timeline, let events = timeline.events else {
            return (nil, "Which way it went isn't given: FM's transfer timeline couldn't be read.")
        }
        let teams = timeline.teams
        let matching = events.filter { event in
            let ours = (from: teams.contains(event.fromTeam), to: teams.contains(event.toTeam))
            guard event.person.uid == person.uid, event.person.isPlayer == person.isPlayer, event.date == date,
                  ours.from != ours.to else { return false }
            if let otherClub, otherClub != (ours.from ? event.to : event.from) { return false }
            if let fee, let theirs = event.fee, fee != theirs { return false }
            return true
        }
        guard matching.count == 1, let move = matching.first else {
            return (nil, "Which way it went isn't given: FM's transfer timeline has "
                    + (matching.isEmpty ? "no move" : "more than one move") + " of this person's on this day between \(club) and "
                    + "another club that agrees with the item. \(timelineNote), so most transfers aren't in it.")
        }
        return (teams.contains(move.toTeam) ? "to \(club) from \(move.from)" : "from \(club) to \(move.to)", nil)
    }

    private static func about(_ subject: NewsSubject?, _ people: (players: [UInt32: Player], staff: [UInt32: Staff]),
                              _ names: [UInt32: Person], club: String, date: Date, timeline: Timeline?) -> JSON? {
        switch subject {
        case nil:
            return nil
        case .injury(let player, let injury, let on, let days)?:
            let record = recordDays(player, injury: injury, on: on, days: days, people.players)
            return .object(dropping: [("player", person(player, people)), ("injury", Output.text(injury)),
                                      ("injured_on", on.map { .string(Output.iso($0)) }), ("days", .int(days)),
                                      ("record_days", record.map { .int($0) })])
        case .contractsExpiring(let indexes)?:
            // The item holds no date: what's given is the contract FM has for them now, while they're still at the club.
            return .object([("contracts_expiring", .array(indexes.map { index in
                guard let known = names[index] else { return .object([("name", .string(someone + " (database index \(index))"))]) }
                let here = known.clubFull == club
                return .object(dropping: [("uid", .int(Int(known.uid))), ("name", .string(known.name)),
                                          ("job", (known as? Staff).flatMap { Output.text($0.job) }),
                                          ("contract_ends_now", here ? known.contractEnd.map { .string(Output.iso($0)) } : nil),
                                          ("now_at", here ? nil : .string(known.clubFull.isEmpty ? "no club" : known.clubFull))])
            })), ("note", .string("FM's item keeps no end date. contract_ends_now is the contract FM has for them today, which may "
                  + "be a new one signed since the item."))])
        case .unhappyWithTraining(let player)?:
            return .object([("player", person(player, people))])
        case .fine(let player)?:
            return .object([("player", person(player, people)),
                            ("note", "FM's fine item holds no amount FM Starship has found, so how much isn't given.")])
        case .coachFeedback(let player)?:
            return .object([("player", person(player, people)),
                            ("note", "Whom the feedback is on; what it says isn't read.")])
        case .transfer(let who, let other)?:
            let way = direction(who, on: date, otherClub: other, fee: nil, club: club, timeline)
            return .object(dropping: [("person", person(who, people)), ("other_club", .string(other)),
                                      ("direction", way.direction.map { .string($0) }), ("note", way.why.map { .string($0) })])
        case .comeAndGetMe(let player, let club)?:
            return .object([("player", person(player, people)), ("wants_to_join", .string(club))])
        case .addOnsActivated(let addOns)?:
            var notes: [String] = []
            if addOns.contains(where: { $0.seasonGoals != nil }) {
                notes.append("FM's item names the clause by a code. FM Starship knows one, goals in the season, checked on one item: "
                             + "it came the day after the player's 10th league goal of the season, his goals in Europe didn't count, "
                             + "and whether cup goals do isn't known. amount is the sum the clause holds, as his contract does.")
            }
            for addOn in addOns where addOn.seasonGoals == nil {
                let name = person(addOn.player, people)["name"]?.string ?? someone
                notes.append("FM Starship doesn't know the code of \(name)'s clause, so which clause it is isn't given.")
            }
            return .object([("activated", .array(addOns.map { addOn in
                .object(dropping: [("player", person(addOn.player, people)),
                                   ("clause", addOn.seasonGoals.map { .string("\($0) goals in the season") }),
                                   ("amount", addOn.amount.flatMap { Output.text(Units.moneyText(Double($0))) })])
            })), ("note", .string(notes.joined(separator: " ")))])
        case .offerConfirmed(let who, let other, let fee)?:
            let way = direction(who, on: date, otherClub: other, fee: fee, club: club, timeline)
            var notes = way.why.map { [$0] } ?? []
            if other == nil { notes.append("The other club isn't given: the item doesn't name it plainly.") }
            if fee == nil { notes.append("No fee is given: the item's copies of it don't agree, or it holds none.") }
            return .object(dropping: [("person", person(who, people)), ("other_club", other.map { .string($0) }),
                                      ("fee", fee.flatMap { Output.text(Units.moneyText(Double($0))) }),
                                      ("direction", way.direction.map { .string($0) }),
                                      ("note", notes.isEmpty ? nil : .string(notes.joined(separator: " ")))])
        }
    }
}
