import Foundation
import StarshipCore

/// Condition, sharpness, morale, playing time, suspensions, yellow cards toward a ban and home-grown status. None of these is
/// hidden in FM: the first five and home-grown status are on its squad screen and a player's profile, and FM warns of a
/// player one booking from a ban. FM shows them as icons and words in the game's language, so they go out as FM's numbers,
/// which the skill explains. A field whose check failed for this read is left out, and `game_status` says why.
extension Toolbox {
    /// Condition and sharpness as a percentage with one decimal, as FM keeps them: 0-10000.
    static func percent(_ value: Int) -> JSON { .double((Double(value) / 10).rounded() / 10) }

    /// The matches he's banned for with his club, as "1 Eliteserien, 1 Cupen". Nil when there are none. A ban that isn't
    /// for a competition his team plays in isn't counted, as FM's squad screen doesn't count it: `person` has it.
    static func suspended(_ bans: [Ban]?) -> JSON? {
        let bans = (bans ?? []).filter(\.countsForClub)
        guard !bans.isEmpty else { return nil }
        return .string(bans.map { "\($0.left) \($0.competition)" }.joined(separator: ", "))
    }

    /// Why a ban isn't in the squad's Suspended.
    static func uncounted(_ ban: Ban) -> String? {
        if ban.countsForClub { return nil }
        if !ban.competition.isEmpty {
            return "not counted in the squad's Suspended: \(ban.competition) isn't a competition his team plays in, so it's most "
                + "likely for his national team or a youth or reserve side"
        }
        if !ban.domestic {
            return "not counted in the squad's Suspended: it's from another association than his club's league's, so most likely "
                + "for his national team or a youth side, and FM's squad screen doesn't count it"
        }
        return "not counted in the squad's Suspended: FM Starship can't tell which competition it's for"
    }

    static func homeGrownText(_ value: HomeGrown) -> JSON { .string(value.rawValue) }

    /// A rule set by its competitions: "Eliteserien", "Eliteserien + U19 National League" where his team plays in both and
    /// the cards count together, or "Allsvenskan, Superettan and 2 more" where his team plays in none of them.
    static func bookingsName(_ booking: Booking) -> String? {
        guard !booking.competitions.isEmpty else { return nil }
        if booking.teamPlays { return booking.competitions.joined(separator: " + ") }
        return booking.competitions.joined(separator: ", ") + (booking.moreCompetitions > 0 ? " and \(booking.moreCompetitions) more" : "")
    }

    /// His yellow cards toward a ban in the competitions his team plays in, as "Eliteserien 2 (2 more: 1-match ban), Cupen 1
    /// (1 more: 1-match ban)". Nil when there are none. `person` has the others.
    static func bookingsCell(_ bookings: [Booking]?) -> JSON? {
        let parts = (bookings ?? []).filter(\.teamPlays).compactMap { booking -> String? in
            guard let name = bookingsName(booking) else { return nil }
            guard booking.plain else { return "\(name): counted another way, not given" }
            guard let next = booking.next else { return "\(name): FM's rules didn't answer" }
            return "\(name) \(next.count) (\(next.left) more: \(next.length)-match ban)"
        }
        return parts.isEmpty ? nil : .string(parts.joined(separator: ", "))
    }

    /// One rule set in full, for `person`.
    static func bookingsDetail(_ booking: Booking) -> JSON {
        var notes: [String] = []
        if booking.competitions.isEmpty {
            notes.append("a rule set FM Starship can't name (FM's rules index \(booking.rules)): no competition FM holds fixtures of plays "
                         + "under it, so it's most likely his national team's or a club's he was at before")
        } else if !booking.teamPlays {
            notes.append("not a competition his team plays in: most likely his national team's, a youth or reserve side's, or a club's he "
                         + "was at before this season")
        }
        if !booking.plain {
            notes.append("FM counts these another way, such as points or a window of matches, which FM Starship hasn't checked, so the "
                         + "numbers aren't given")
        } else if booking.next == nil {
            notes.append("FM's rules didn't answer for this one, so the numbers aren't given")
        }
        let next = booking.next
        return .object(dropping: [
            ("competitions", bookingsName(booking).map { .string($0) }),
            ("yellow_cards", next.map { .int($0.count) }),
            ("more_until_ban", next.map { .int($0.left) }),
            ("next_ban_matches", next.map { .int($0.length) }),
            ("last_ban_at", next.flatMap { $0.lastBanAt > 0 ? .int($0.lastBanAt) : nil }),
            ("note", notes.isEmpty ? nil : .string(notes.joined(separator: "; "))),
        ])
    }

    /// The squad's columns for these, each only while it can be given. The caller has brought each row's state up to date.
    static func stateFields(_ db: Database, _ engine: GameRulesEngine?, _ states: PlayerStateSource?,
                            _ bookings: BookingSource?) -> [Output.Field] {
        final class Known {
            var fitness: [UInt32: Fitness?] = [:]
        }
        let known = Known()
        func fitness(_ person: Person) -> Fitness? {
            if let found = known.fitness[person.uid] { return found }
            let found = (person as? Player)?.fitness(engine)
            known.fitness[person.uid] = .some(found)
            return found
        }
        var fields: [Output.Field] = []
        if db.stateIsOn(.fitness) {
            fields += [Output.Field(name: "Condition") { fitness($0).map { percent($0.condition) } },
                       Output.Field(name: "Sharpness") { fitness($0).map { percent($0.sharpness) } }]
        }
        if db.stateIsOn(.morale) { fields.append(Output.Field(name: "Morale") { ($0 as? Player)?.morale.map { .int($0) } }) }
        if db.stateIsOn(.playingTime) {
            fields.append(Output.Field(name: "Playing time") { ($0 as? Player)?.playingTime.map { .int($0) } })
        }
        if db.stateIsOn(.bans) {
            fields.append(Output.Field(name: "Suspended") { person in (person as? Player).flatMap { suspended(states?.bans(of: $0)) } })
        }
        if let bookings, bookings.off == nil {
            fields.append(Output.Field(name: "Bookings") { person in (person as? Player).flatMap { bookingsCell(bookings.bookings(of: $0)) } })
        }
        if let engine {
            fields.append(Output.Field(name: "Home-grown") { person in
                (person as? Player).flatMap { engine.homeGrown(player: $0) }.map(homeGrownText)
            })
        }
        return fields
    }

    /// One player's, for `person`, with each suspension and each rule set's bookings in full.
    static func stateGroup(_ player: Player, _ db: Database, _ engine: GameRulesEngine?, _ states: PlayerStateSource?,
                           _ bookings: BookingSource?) -> JSON? {
        var pairs: [(String, JSON?)] = []
        if db.stateIsOn(.fitness) {
            if let fitness = player.fitness(engine) {
                pairs += [("Condition", percent(fitness.condition)), ("Sharpness", percent(fitness.sharpness))]
            } else if player.fitnessNeedsCatchUp, engine == nil, let updated = player.fitnessUpdated {
                pairs.append(("Condition and sharpness", .string("not known: FM last brought them up to date on \(Output.iso(updated)), "
                                                                 + "and FM's rules, whose getters give them on other days, are off")))
            }
        }
        if db.stateIsOn(.morale) { pairs.append(("Morale", player.morale.map { .int($0) })) }
        if db.stateIsOn(.playingTime) { pairs.append(("Playing time", player.playingTime.map { .int($0) })) }
        if let engine { pairs.append(("Home-grown", engine.homeGrown(player: player).map(homeGrownText))) }
        if db.stateIsOn(.bans), let bans = states?.bans(of: player) {
            pairs.append(("Suspensions", .array(bans.map { ban in
                .object(dropping: [
                    ("matches_left", .int(ban.left)), ("matches", .int(ban.matches)), ("served", .int(ban.served)),
                    ("competition", Output.text(ban.competition)), ("association", Output.text(ban.associationName)),
                    ("reason", ban.reason.map { .string($0.rawValue) }), ("opponent", Output.text(ban.opponent)),
                    ("issued", .string(Output.iso(ban.issued))), ("note", uncounted(ban).map { .string($0) }),
                ])
            })))
        }
        if let bookings, bookings.off == nil, let found = bookings.bookings(of: player) {
            pairs.append(("Bookings", .array(found.map(bookingsDetail))))
        }
        let kept = pairs.compactMap { name, value in value.map { (name, $0) } }
        return kept.isEmpty ? nil : .object(kept)
    }

    /// Whether each is on, for `game_status`, and why not.
    static func stateStatus(_ db: Database, _ engine: GameRulesEngine?, _ bookings: BookingSource?) -> JSON {
        func status(_ field: PlayerStateField) -> String { db.stateOff[field].map { "off: \($0)" } ?? "on" }
        var fitness = status(.fitness)
        if db.stateIsOn(.fitness), engine == nil {
            fitness = "on for players FM has brought up to date today. For the others it's left out, since FM's rules, whose getters "
                + "give them, are off"
        }
        let homeGrown = engine == nil ? "off: it comes from FM's own rules, which are off on this build" : "on"
        return .object([("condition", .string(fitness)), ("sharpness", .string(fitness)), ("morale", .string(status(.morale))),
                        ("playing_time", .string(status(.playingTime))), ("suspensions", .string(status(.bans))),
                        ("bookings", .string(bookings?.status ?? "off: it can't be read from this save")),
                        ("home_grown", .string(homeGrown))])
    }
}
