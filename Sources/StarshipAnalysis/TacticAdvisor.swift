import Foundation
import StarshipCore

/// FM's own role ratings for one club's players, and what they say about where people should play.
public final class RoleBook {
    /// A player's stars in one place of a tactic, in half-stars.
    public struct Rating {
        public let withBall: Int
        public let withoutBall: Int
        /// What the formula picks by: finer than stars.
        public let score: Int
        public var combined: Int { RoleBook.combined(withBall, withoutBall) }
    }

    private struct Key: Hashable {
        let player: UInt32
        let position: Int
    }

    private let engine: PositionalRoleEngine
    private let team: Int64
    private var tables: [Key: [RoleRow]] = [:]

    /// Nil without the live game.
    public init?(_ session: AnalysisSession) {
        guard let engine = GameRules.engine as? PositionalRoleEngine, session.club.team != 0 else { return nil }
        self.engine = engine
        team = session.club.team
    }

    private func rows(_ player: Player, _ position: Int) -> [RoleRow] {
        let key = Key(player: player.uid, position: position)
        if let known = tables[key] { return known }
        let rows = engine.roleRows(player: player, position: position, team: team) ?? []
        tables[key] = rows
        return rows
    }

    private static func halfStars(_ row: RoleRow) -> Int { (row.minHalfStars + row.maxHalfStars + 1) / 2 }

    /// FM's tactics screen shows the two phases' average, rounded up.
    static func combined(_ withBall: Int, _ withoutBall: Int) -> Int { (withBall + withoutBall + 1) / 2 }

    /// "★★★½".
    public static func stars(_ half: Int) -> String {
        guard half > 0 else { return "-" }
        return String(repeating: "★", count: half / 2) + (half % 2 == 1 ? "½" : "")
    }

    func best(_ player: Player, _ position: Int, withoutBall: Bool) -> RoleRow? {
        rows(player, position).filter { $0.outOfPossession == withoutBall }.max { $0.rating < $1.rating }
    }

    func rate(_ player: Player, in slot: TacticSlot) -> Rating? {
        guard let with = rows(player, slot.position).first(where: { !$0.outOfPossession && $0.role == slot.roleName }),
              let without = rows(player, slot.positionWithoutBall).first(where: { $0.outOfPossession && $0.role == slot.roleNameWithoutBall })
        else { return nil }
        return Rating(withBall: Self.halfStars(with), withoutBall: Self.halfStars(without), score: with.rating + without.rating)
    }

    /// The best role pair for a player at a position, whatever a tactic says.
    func bestRoles(_ player: Player, position: Int, withoutBall: Int) -> (with: RoleRow, without: RoleRow, stars: Int)? {
        guard let with = best(player, position, withoutBall: false), let without = best(player, withoutBall, withoutBall: true) else { return nil }
        return (with, without, Self.combined(Self.halfStars(with), Self.halfStars(without)))
    }

    /// Who to turn to when this place's starter is out.
    func cover(for slot: TacticSlot, squad: [Player], excluding starters: Set<UInt32>) -> (player: Player, stars: Int)? {
        var best: (player: Player, rating: Rating)?
        for player in squad where !starters.contains(player.uid) {
            guard let rating = rate(player, in: slot), rating.score > (best?.rating.score ?? 0) else { continue }
            best = (player, rating)
        }
        return best.map { ($0.player, $0.rating.combined) }
    }

    /// A real second eleven: everyone off the first one goes where they do most good, once. Cover as `cover`
    /// reports it can name one versatile player for half the team.
    func secondEleven(_ slots: [TacticSlot], squad: [Player], excluding starters: Set<UInt32>) -> [(player: Player, stars: Int)?] {
        let bench = squad.filter { !starters.contains($0.uid) }
        let scores = bench.map { player in slots.map { rate(player, in: $0)?.score ?? 0 } }
        var picks = TacticOptimizer.assign(scores, places: slots.count)?.map { $0 >= 0 ? Optional($0) : nil }
        if picks == nil {
            // Not enough players for a whole eleven: the likeliest stand-ins go first.
            var used = Set<Int>()
            picks = slots.indices.map { place in
                let best = bench.indices.filter { !used.contains($0) }.max { scores[$0][place] < scores[$1][place] }
                if let best { used.insert(best) }
                return best
            }
        }
        return zip(slots, picks ?? []).map { slot, pick in
            guard let pick, let rating = rate(bench[pick], in: slot) else { return nil }
            return (bench[pick], rating.combined)
        }
    }

    /// Positions below this aren't offered as somewhere a player is better.
    private static let goodEnough: UInt8 = 15
    /// Only a true natural position is worth a mention when it's no better.
    private static let natural: UInt8 = 18

    /// Where a player would do best, for a table cell and as a sentence.
    public struct Advice {
        public let short: String
        public let sentence: String
    }

    func advice(_ player: Player, in slot: TacticSlot) -> Advice? {
        guard let here = rate(player, in: slot) else { return nil }
        let place = Names.positions[slot.position]
        let now = "\(player.name) works at \(place) as \(slot.roleName) \(Self.stars(here.combined))"
        var better: (position: Int, role: String, stars: Int)?
        var level: (position: Int, role: String, stars: Int)?
        for position in 0..<15 where position != slot.position && player.pos[position] >= Self.goodEnough {
            guard let roles = bestRoles(player, position: position, withoutBall: position) else { continue }
            if roles.stars > better?.stars ?? here.combined {
                better = (position, roles.with.role, roles.stars)
            } else if roles.stars == here.combined, level == nil, player.pos[position] >= Self.natural {
                level = (position, roles.with.role, roles.stars)
            }
        }
        if let better {
            let target = "\(Names.positions[better.position]) as \(better.role) \(Self.stars(better.stars))"
            return Advice(short: "\(Names.positions[better.position]): \(better.role) \(Self.stars(better.stars))",
                          sentence: "\(now), but the best position is \(target).")
        }
        if let role = best(player, slot.position, withoutBall: false), Self.halfStars(role) > here.withBall {
            let stars = Self.stars(Self.halfStars(role))
            return Advice(short: "Here: \(role.role) \(stars)", sentence: "\(now), but \(role.role) suits better here, \(stars) with the ball.")
        }
        if let role = best(player, slot.positionWithoutBall, withoutBall: true), Self.halfStars(role) > here.withoutBall {
            let stars = Self.stars(Self.halfStars(role))
            return Advice(short: "Without ball: \(role.role) \(stars)", sentence: "\(now), but \(role.role) suits better without the ball, \(stars).")
        }
        if let level {
            let role = "\(level.role) \(Self.stars(level.stars))"
            return Advice(short: "Here, or \(Names.positions[level.position]): \(role)",
                          sentence: "\(now), the best fit, and is just as good at \(Names.positions[level.position]) as \(role).")
        }
        return Advice(short: "Here", sentence: "\(now), the best fit.")
    }
}
