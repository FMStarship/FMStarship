import Foundation
import StarshipCore

/// Condition, sharpness, morale, playing time, suspensions and home-grown status. None of these is hidden in FM: they're
/// all on its squad screen and a player's profile. FM shows them as icons and words in the game's language, so they go
/// out as FM's numbers, which the skill explains. A field whose check failed for this read is left out, and
/// `game_status` says why.
extension Toolbox {
    /// Condition and sharpness as a percentage with one decimal, as FM keeps them: 0-10000.
    static func percent(_ value: Int) -> JSON { .double((Double(value) / 10).rounded() / 10) }

    /// The suspensions he still has to serve, as "1 Eliteserien, 1 Cupen". Nil when there are none.
    static func suspended(_ player: Player) -> JSON? {
        guard let bans = player.bans, !bans.isEmpty else { return nil }
        return .string(bans.map { ban in
            if !ban.competition.isEmpty { return "\(ban.left) \(ban.competition)" }
            return "\(ban.left) (" + (ban.associationName.isEmpty ? "" : "\(ban.associationName), ") + "competition not known)"
        }.joined(separator: ", "))
    }

    static func homeGrownText(_ value: HomeGrown) -> JSON { .string(value.rawValue) }

    /// The squad's columns for these, each only while it can be given.
    static func stateFields(_ db: Database, _ engine: GameRulesEngine?) -> [Output.Field] {
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
        if db.stateIsOn(.bans) { fields.append(Output.Field(name: "Suspended") { ($0 as? Player).flatMap(suspended) }) }
        if let engine {
            fields.append(Output.Field(name: "Home-grown") { person in
                (person as? Player).flatMap { engine.homeGrown(player: $0) }.map(homeGrownText)
            })
        }
        return fields
    }

    /// One player's, for `person`, with each suspension in full.
    static func stateGroup(_ player: Player, _ db: Database, _ engine: GameRulesEngine?) -> JSON? {
        var pairs: [(String, JSON?)] = []
        if db.stateIsOn(.fitness) {
            if let fitness = player.fitness(engine) {
                pairs += [("Condition", percent(fitness.condition)), ("Sharpness", percent(fitness.sharpness))]
            } else if player.fitnessNeedsCatchUp, engine == nil, let updated = player.fitnessUpdated {
                pairs.append(("Condition and sharpness", .string("not known: FM last brought them up to date on \(Output.iso(updated)), "
                                                                 + "and FM's rules, which catch them up to today, are off")))
            }
        }
        if db.stateIsOn(.morale) { pairs.append(("Morale", player.morale.map { .int($0) })) }
        if db.stateIsOn(.playingTime) { pairs.append(("Playing time", player.playingTime.map { .int($0) })) }
        if let engine { pairs.append(("Home-grown", engine.homeGrown(player: player).map(homeGrownText))) }
        if db.stateIsOn(.bans), let bans = player.bans {
            pairs.append(("Suspensions", .array(bans.map { ban in
                .object(dropping: [
                    ("matches_left", .int(ban.left)), ("matches", .int(ban.matches)), ("served", .int(ban.served)),
                    ("competition", Output.text(ban.competition)), ("association", Output.text(ban.associationName)),
                    ("reason", ban.reason.map { .string($0.rawValue) }), ("opponent", Output.text(ban.opponent)),
                    ("issued", .string(Output.iso(ban.issued))),
                ])
            })))
        }
        let kept = pairs.compactMap { name, value in value.map { (name, $0) } }
        return kept.isEmpty ? nil : .object(kept)
    }

    /// Whether each is on, for `game_status`, and why not.
    static func stateStatus(_ db: Database, _ engine: GameRulesEngine?) -> JSON {
        func status(_ field: PlayerStateField) -> String { db.stateOff[field].map { "off: \($0)" } ?? "on" }
        var fitness = status(.fitness)
        if db.stateIsOn(.fitness), engine == nil {
            fitness = "on for players FM has brought up to date today. For the others it's left out, since FM's rules, which catch "
                + "them up, are off"
        }
        let homeGrown = engine == nil ? "off: it comes from FM's own rules, which are off on this build" : "on"
        return .object([("condition", .string(fitness)), ("sharpness", .string(fitness)), ("morale", .string(status(.morale))),
                        ("playing_time", .string(status(.playingTime))), ("suspensions", .string(status(.bans))),
                        ("home_grown", .string(homeGrown))])
    }
}
