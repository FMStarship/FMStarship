import Foundation
import StarshipCore

/// How the squad compares with the rest of its league, attribute by attribute.
public struct SquadProfile {
    public struct Line {
        public let attribute: String
        public let yours: Double
        public let league: Double
        public var difference: Double { yours - league }
    }

    public let league: String
    /// Strongest first.
    public let lines: [Line]

    public var strengths: [Line] { Array(lines.prefix(5)) }
    public var weaknesses: [Line] { Array(lines.suffix(5).reversed()) }
}

/// One of FM's presets, filled with the best eleven the squad has.
public struct OptimizedTactic {
    public struct AttributeLine {
        public let attribute: String
        public let yours: Double
        public let league: Double
    }

    public let preset: TacticPreset
    public let style: TacticStyle
    public let slots: [TacticSlot]
    /// Half-stars, one per slot.
    public let stars: [Int]
    public let isYours: Bool
    /// FM's favoured attributes for the style: the XI against the league.
    public let attributes: [AttributeLine]
    /// FM's preferred roles for the style that the XI uses, and who plays them.
    public let preferredRoles: [String]
    /// FM's role complexity, averaged over both phases. Its scale runs from 7 to 10.
    public let complexity: Double
    /// Role changes from the preset, in words. Each is one FM itself uses in this style.
    public let changes: [String]
    public let newPlayers: Int
    public let score: Double
    /// "4-2-3-1 / 4-4-2". FM's full shape names go in the explanation.
    public let shapes: String

    public var averageStars: Double {
        stars.isEmpty ? 0 : Double(stars.reduce(0, +)) / Double(stars.count) / 2
    }

    /// Attribute points above the league on what this style favours.
    public var styleEdge: Double {
        attributes.isEmpty ? 0 : attributes.reduce(0) { $0 + $1.yours - $1.league } / Double(attributes.count)
    }

    /// FM's own score bands, from its tactical effectiveness settings.
    public var band: String {
        switch score {
        case 91...: return "Excellent"
        case 81...: return "Very good"
        case 67...: return "Good"
        case 51...: return "Above average"
        case 41...: return "Average"
        case 34...: return "Below average"
        default: return "Poor"
        }
    }
}

public struct TacticReport {
    public let profile: SquadProfile
    /// The user's tactic, on the same measures.
    public let yours: OptimizedTactic?
    /// The FM preset the user's tactic is closest to, and how many of its roles match.
    public let closest: (preset: TacticPreset, matching: Int)?
    /// Best first.
    public let tactics: [OptimizedTactic]
    public let leftOut: Int

    /// The best shape of each style, best first.
    public var bestOfEachStyle: [OptimizedTactic] {
        var seen = Set<String>()
        return tactics.filter { seen.insert($0.style.id).inserted }
    }
}

/// Fits the squad to FM's own tactics. The tactics and the role combinations are FM's: a preset
/// keeps its roles, and a role only changes to one FM itself uses in that place in that style,
/// and which it pairs with the neighbouring roles somewhere in its presets.
public enum TacticOptimizer {
    /// How much each measure counts towards the fit score. The weights are this app's, not FM's:
    /// FM has no such score. Role stars lead, because they are FM's own view of each player.
    private static let roleWeight = 0.65, styleWeight = 0.25, preferredWeight = 0.10
    /// How many outfield players stand for a club when comparing squads.
    private static let squadSize = 14
    /// Out for this long, a player can't be built around.
    private static let longTerm = 21
    private static let setPieces = "Set Piece Ability"

    // MARK: Squad scan

    private static func value(_ player: Player, _ attribute: String) -> Double {
        if attribute == setPieces { return Double(player.a("Corners") + player.a("Free Kicks")) / 2 }
        return Names.playerIndex[attribute] == nil ? 0 : Double(player.a(attribute))
    }

    private static func mean(_ players: [Player], _ attribute: String) -> Double {
        players.isEmpty ? 0 : players.reduce(0) { $0 + value($1, attribute) } / Double(players.count)
    }

    /// A club's best outfield players. Keepers would drag down every outfield attribute.
    private static func best(_ players: [Player], _ count: Int) -> [Player] {
        Array(players.filter { $0.pos[0] < 15 }.stableSorted { $0.ca > $1.ca }.prefix(count))
    }

    /// The first teams of the rest of the user's league.
    static func rivals(_ session: AnalysisSession, squad: [Player]) -> [[Player]] {
        guard let first = squad.first, !first.league.isEmpty else { return [] }
        // A league's name isn't enough: several countries' divisions can share one.
        let players = session.db.players.filter {
            $0.league == first.league && $0.clubNation == first.clubNation && $0.clubFull != session.club.name
                && session.canSign($0) && $0.loanClub.isEmpty && ($0.squad == "First team" || $0.squad.isEmpty)
        }
        return Array(Dictionary(grouping: players, by: \.clubFull).values)
    }

    private static func leagueMean(_ groups: [[Player]], _ attribute: String) -> Double {
        groups.isEmpty ? 0 : groups.reduce(0) { $0 + mean($1, attribute) } / Double(groups.count)
    }

    /// Who the rest of the league has at each position. An XI is measured against these, place by
    /// place: Positioning is a defender's attribute, so a back five would look strong on it against
    /// any mixed group, whoever played there.
    private static func baseline(_ rivals: [[Player]]) -> [[Player]] {
        let regulars = rivals.flatMap { best($0, squadSize) }
        return (0..<15).map { position in
            let here = regulars.filter { $0.pos[position] >= 15 }
            return here.isEmpty ? regulars : here
        }
    }

    static func profile(squad: [Player], rivals: [[Player]]) -> SquadProfile {
        let ours = best(squad, squadSize)
        let theirs = rivals.map { best($0, squadSize) }
        let lines = (Names.technical + Names.mental + Names.physical).filter { Names.playerIndex[$0] != nil }.map { attribute in
            SquadProfile.Line(attribute: attribute, yours: mean(ours, attribute), league: leagueMean(theirs, attribute))
        }
        return SquadProfile(league: squad.first?.league ?? "", lines: lines.stableSorted { $0.difference > $1.difference })
    }

    // MARK: Role combinations

    /// Which pairs of neighbouring roles FM itself puts together, and which roles it uses in each place.
    struct Combinations {
        private(set) var pairs = Set<String>()
        private(set) var variants: [String: [(role: Int, roleWithoutBall: Int)]] = [:]

        init(_ presets: [TacticPreset]) {
            for preset in presets {
                for (index, slot) in preset.slots.enumerated() {
                    let key = Self.place(preset.style, slot.position, slot.side)
                    if variants[key]?.contains(where: { $0.role == slot.role && $0.roleWithoutBall == slot.roleWithoutBall }) != true {
                        variants[key, default: []].append((slot.role, slot.roleWithoutBall))
                    }
                    for other in preset.slots[(index + 1)...] where Self.neighbours(slot.position, slot.side, other.position, other.side) {
                        pairs.insert(Self.pair(slot.position, slot.role, other.position, other.role, phase: 0))
                        pairs.insert(Self.pair(slot.positionWithoutBall, slot.roleWithoutBall, other.positionWithoutBall, other.roleWithoutBall, phase: 1))
                    }
                }
            }
        }

        private static func place(_ style: String, _ position: Int, _ side: TacticSlot.Side) -> String { "\(style)|\(position)|\(side)" }

        private static func pair(_ a: Int, _ roleA: Int, _ b: Int, _ roleB: Int, phase: Int) -> String {
            let first = "\(a):\(roleA)", second = "\(b):\(roleB)"
            return "\(phase)|" + (first < second ? first + "|" + second : second + "|" + first)
        }

        /// The players who have to work together: down a flank, or next to each other through the middle.
        static func neighbours(_ a: Int, _ sideA: TacticSlot.Side, _ b: Int, _ sideB: TacticSlot.Side) -> Bool {
            let (x, y) = (across(a, sideA), across(b, sideB))
            if (x == 0 && y == 0) || (x == 4 && y == 4) { return true }
            return (1...3).contains(x) && (1...3).contains(y) && abs(Tactic.line(a) - Tactic.line(b)) <= 1
        }

        /// 0 is the right touchline, 4 the left.
        private static func across(_ position: Int, _ side: TacticSlot.Side) -> Int {
            let name = Names.positions[position]
            return name.hasSuffix("R") ? 0 : name.hasSuffix("L") ? 4 : side == .right ? 1 : side == .left ? 3 : 2
        }

        func variants(style: String, position: Int, side: TacticSlot.Side) -> [(role: Int, roleWithoutBall: Int)] {
            variants[Self.place(style, position, side)] ?? []
        }

        /// Whether FM has this role next to all of these neighbours in some preset.
        func fits(_ slot: TacticSlot, with others: [TacticSlot]) -> Bool {
            others.allSatisfy { other in
                guard Self.neighbours(slot.position, slot.side, other.position, other.side) else { return true }
                return pairs.contains(Self.pair(slot.position, slot.role, other.position, other.role, phase: 0))
                    && pairs.contains(Self.pair(slot.positionWithoutBall, slot.roleWithoutBall, other.positionWithoutBall, other.roleWithoutBall, phase: 1))
            }
        }
    }

    // MARK: Filling a tactic

    /// The best way to give each place a different player. `scores[player][place]`; nil when there
    /// aren't enough players. One player at a time, over every set of places filled so far.
    static func assign(_ scores: [[Int]], places: Int) -> [Int]? {
        let full = 1 << places
        var best = [Int](repeating: -1, count: full)
        best[0] = 0
        var taken: [[Int8]] = []
        for score in scores {
            var next = best
            var choice = [Int8](repeating: -1, count: full)
            for mask in 0..<full where best[mask] >= 0 {
                for place in 0..<places where mask & (1 << place) == 0 {
                    let total = best[mask] + score[place]
                    if total > next[mask | 1 << place] {
                        next[mask | 1 << place] = total
                        choice[mask | 1 << place] = Int8(place)
                    }
                }
            }
            best = next
            taken.append(choice)
        }
        guard best[full - 1] >= 0 else { return nil }
        var chosen = [Int](repeating: -1, count: places)
        var mask = full - 1
        for index in scores.indices.reversed() where taken[index][mask] >= 0 {
            let place = Int(taken[index][mask])
            chosen[place] = index
            mask ^= 1 << place
        }
        return chosen
    }

    private static func slot(_ preset: PresetSlot, player: Player?) -> TacticSlot {
        TacticSlot(player: player, position: preset.position, positionWithoutBall: preset.positionWithoutBall, side: preset.side,
                   sideWithoutBall: preset.sideWithoutBall, role: preset.role, roleWithoutBall: preset.roleWithoutBall)
    }

    private static func fill(_ preset: TacticPreset, players: [Player], book: RoleBook) -> [TacticSlot]? {
        let scores = players.map { player in
            preset.slots.map { book.rate(player, in: slot($0, player: player))?.score ?? 0 }
        }
        guard let chosen = assign(scores, places: preset.slots.count) else { return nil }
        return zip(preset.slots, chosen).map { slot($0, player: players[$1]) }
    }

    /// Swaps a role where FM's own presets for this style use another in the same place that this
    /// player is clearly better in, and that still sits with the neighbours in FM's presets.
    private static func refine(_ slots: [TacticSlot], preset: TacticPreset, book: RoleBook, combinations: Combinations) -> (slots: [TacticSlot], changes: [String]) {
        var slots = slots
        var changes: [String] = []
        for index in slots.indices {
            guard let player = slots[index].player, let here = book.rate(player, in: slots[index]) else { continue }
            let allowed = preset.slots[index]
            var best: (slot: TacticSlot, rating: RoleBook.Rating)?
            for variant in combinations.variants(style: preset.style, position: allowed.position, side: allowed.side) {
                guard allowed.allowedRoles.contains(variant.role), allowed.allowedRolesWithoutBall.contains(variant.roleWithoutBall) else { continue }
                let candidate = TacticSlot(player: player, position: allowed.position, positionWithoutBall: allowed.positionWithoutBall,
                                           side: allowed.side, sideWithoutBall: allowed.sideWithoutBall,
                                           role: variant.role, roleWithoutBall: variant.roleWithoutBall)
                guard let rating = book.rate(player, in: candidate), rating.combined > (best?.rating.combined ?? here.combined) else { continue }
                var others = slots
                others.remove(at: index)
                if combinations.fits(candidate, with: others) { best = (candidate, rating) }
            }
            if let best {
                let was = slots[index]
                let name = was.roleName == best.slot.roleName ? "\(was.roleNameWithoutBall) to \(best.slot.roleNameWithoutBall) without the ball"
                                                              : "\(was.roleName) to \(best.slot.roleName)"
                changes.append("\(was.label): \(name), for \(player.name) \(RoleBook.stars(here.combined)) to \(RoleBook.stars(best.rating.combined))")
                slots[index] = best.slot
            }
        }
        return (slots, changes)
    }

    private static func evaluate(_ preset: TacticPreset, style: TacticStyle, tactic: Tactic, changes: [String], isYours: Bool,
                                 book: RoleBook, library: TacticLibrary, baseline: [[Player]], current: Set<UInt32>) -> OptimizedTactic {
        let slots = tactic.slots
        let ordered = slots.stableSorted { $0.pitchOrder < $1.pitchOrder }
        let ratings = ordered.map { slot in slot.player.flatMap { book.rate($0, in: slot) } }
        let stars = ratings.map { $0?.combined ?? 0 }
        let eleven = ordered.compactMap(\.player)
        let outfield = ordered.filter { $0.position != 0 && $0.player != nil }

        let attributes = style.favouredAttributes.map { attribute in
            OptimizedTactic.AttributeLine(attribute: attribute, yours: mean(outfield.compactMap(\.player), attribute),
                                          league: outfield.isEmpty ? 0 : outfield.reduce(0) { $0 + mean(baseline[$1.position], attribute) } / Double(outfield.count))
        }
        // How well this XI fills each role FM wants in the style. A role it doesn't use scores nothing.
        let filled = style.preferredRoles.map { role -> (role: String, slot: TacticSlot?, stars: Int) in
            let best = zip(ordered, stars).filter { $0.0.roleName == role || $0.0.roleNameWithoutBall == role }.max { $0.1 < $1.1 }
            return (role, best?.0, best?.1 ?? 0)
        }
        let preferred = filled.compactMap { entry -> String? in
            entry.slot.map { "\(entry.role) (\($0.player?.name ?? "nobody") \(RoleBook.stars(entry.stars)))" }
        }
        let complexities = ordered.compactMap { library.complexity(of: $0) }
        let complexity = complexities.isEmpty ? 0 : complexities.reduce(0.0) { $0 + Double($1.withBall + $1.withoutBall) / 2 } / Double(complexities.count)

        let average = stars.isEmpty ? 0 : Double(stars.reduce(0, +)) / Double(stars.count) / 2
        let edge = attributes.isEmpty ? 0 : attributes.reduce(0) { $0 + $1.yours - $1.league } / Double(attributes.count)
        let roleScore = average / 5 * 100
        // Level with the league is 50; two attribute points clear of it is the top of the scale.
        let styleScore = min(100, max(0, 50 + edge * 25))
        let preferredScore = filled.isEmpty ? roleScore : Double(filled.reduce(0) { $0 + $1.stars }) / Double(filled.count) / 10 * 100
        let score = roleScore * roleWeight + styleScore * styleWeight + preferredScore * preferredWeight

        return OptimizedTactic(preset: preset, style: style, slots: ordered, stars: stars, isYours: isYours, attributes: attributes,
                               preferredRoles: preferred, complexity: complexity, changes: changes,
                               newPlayers: eleven.filter { !current.contains($0.uid) }.count, score: score, shapes: shapes(tactic, library: library))
    }

    /// Nil without the live game or FM's files.
    public static func report(_ session: AnalysisSession, status: (String) -> Void = { _ in }) -> TacticReport? {
        guard let library = session.library, let book = RoleBook(session) else { return nil }
        status("Scanning your squad...")
        let squad = SquadPlanner.analysedSquad(session)
        let fit = squad.filter { $0.injury == nil || session.checks.daysOut($0) < longTerm }
        let others = rivals(session, squad: squad)
        let league = baseline(others)
        let profile = profile(squad: squad, rivals: others)
        let combinations = Combinations(library.presets)
        let tactic = session.db.tactics[session.club.team]
        let current = Set(tactic?.slots.compactMap { $0.player?.uid } ?? [])
        let styles = Dictionary(library.styles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        status("Trying your squad in FM's \(library.presets.count) tactics...")
        var results: [OptimizedTactic] = []
        for preset in library.presets {
            guard let style = styles[preset.style], let slots = fill(preset, players: fit, book: book) else { continue }
            let refined = refine(slots, preset: preset, book: book, combinations: combinations)
            results.append(evaluate(preset, style: style, tactic: Tactic(slots: refined.slots), changes: refined.changes, isYours: false,
                                    book: book, library: library, baseline: league, current: current))
        }

        var closest: (preset: TacticPreset, matching: Int)?
        var yours: OptimizedTactic?
        if let tactic {
            for preset in library.presets {
                let matching = tactic.slots.filter { slot in
                    preset.slots.contains { $0.position == slot.position && $0.side == slot.side && $0.role == slot.role }
                }.count
                if matching > closest?.matching ?? -1 { closest = (preset, matching) }
            }
            if let closest, let style = styles[closest.preset.style] {
                yours = evaluate(closest.preset, style: style, tactic: tactic, changes: [], isYours: true,
                                 book: book, library: library, baseline: league, current: current)
            }
        }
        return TacticReport(profile: profile, yours: yours, closest: closest,
                            tactics: results.stableSorted { $0.score > $1.score }, leftOut: squad.count - fit.count)
    }

    // MARK: Tables

    public static let rankingColumns = [
        TableColumn("Tactic", 19), TableColumn("Shape", 14), TableColumn("Fit", 15), TableColumn("Role stars", 8),
        TableColumn("Style", 7), TableColumn("Complexity", 8), TableColumn("New in XI", 7), TableColumn("Role edits", 7),
    ]

    public static let detailColumns = [
        TableColumn("Position", 8, order: .place), TableColumn("With the ball", 22), TableColumn("Without the ball", 24),
        TableColumn("Player", 20), TableColumn("Stars", 7),
    ]

    private static func signed(_ value: Double) -> String {
        (value >= 0 ? "+" : "") + NetFormat.fixed(value, min: 1, max: 1)
    }

    private static func shapes(_ tactic: Tactic, library: TacticLibrary) -> String {
        let short = { (name: String) in String(name.split(separator: " ").first ?? "") }
        return "\(short(tactic.shape(in: library))) / \(short(tactic.shapeWithoutBall(in: library)))"
    }

    private static func row(_ tactic: OptimizedTactic, name: String, bold: Bool, yours: OptimizedTactic?) -> TableRow {
        TableRow(cells: [
            name, tactic.shapes,
            "\(Int(tactic.score.rounded())) \(tactic.band)",
            NetFormat.fixed(tactic.averageStars, min: 2, max: 2) + "★",
            signed(tactic.styleEdge),
            NetFormat.fixed(tactic.complexity, min: 2, max: 2),
            tactic.isYours ? "" : "\(tactic.newPlayers)",
            tactic.isYours ? "" : "\(tactic.changes.count)",
        ], tone: tactic.isYours ? nil : tactic.score > (yours?.score ?? .infinity) + 1 ? .good : nil, toneColumn: 2, bold: bold)
    }

    /// What the grid lists: the user's tactic first, then `shown`.
    public static func ranking(_ report: TacticReport, shown: [OptimizedTactic]) -> AnalysisTable {
        var table = AnalysisTable(columns: rankingColumns)
        if let yours = report.yours { table.rows.append(row(yours, name: "Your tactic", bold: true, yours: yours)) }
        for tactic in shown { table.rows.append(row(tactic, name: tactic.style.name, bold: false, yours: report.yours)) }
        return table
    }

    public static func detail(_ tactic: OptimizedTactic) -> AnalysisTable {
        var table = AnalysisTable(columns: detailColumns)
        for (slot, stars) in zip(tactic.slots, tactic.stars) {
            let without = slot.position == slot.positionWithoutBall ? slot.roleNameWithoutBall
                                                                    : "\(Names.positions[slot.positionWithoutBall]): \(slot.roleNameWithoutBall)"
            table.rows.append(TableRow(cells: [slot.label, slot.roleName, without, slot.player?.name ?? "nobody picked", RoleBook.stars(stars)], person: slot.player))
        }
        return table
    }

    /// "Stronger than Eliteserien: Passing +1.4, ...".
    public static func strengths(_ profile: SquadProfile) -> (strong: String, weak: String) {
        let text = { (lines: [SquadProfile.Line]) in lines.map { "\($0.attribute) \(signed($0.difference))" }.joined(separator: ", ") }
        return (text(profile.strengths), text(profile.weaknesses))
    }

    /// Why a tactic scores what it scores, in sentences, with FM's data first.
    public static func explanation(_ tactic: OptimizedTactic, report: TacticReport) -> [String] {
        var lines: [String] = []
        if tactic.isYours {
            if let closest = report.closest {
                lines.append("Closest to FM's \(closest.preset.name): \(closest.matching) of 11 roles match.")
            }
        } else {
            let shape = "\(tactic.preset.shape) with the ball, \(tactic.preset.shapeWithoutBall) without it"
            lines.append(tactic.changes.isEmpty ? "FM's own \(tactic.style.name) preset, \(shape), with its roles unchanged."
                                                : "FM's own \(tactic.style.name) preset, \(shape), with \(tactic.changes.count) role change\(tactic.changes.count == 1 ? "" : "s").")
        }
        lines.append(tactic.style.summary)
        if !tactic.style.features.isEmpty { lines.append("How it plays: " + tactic.style.features.joined(separator: ", ") + ".") }
        if !tactic.attributes.isEmpty {
            let parts = tactic.attributes.map {
                "\($0.attribute) \(NetFormat.fixed($0.yours, min: 1, max: 1)) (league \(NetFormat.fixed($0.league, min: 1, max: 1)))"
            }
            lines.append("FM says this style favours: " + parts.joined(separator: ", ") + ". League figures are rivals' players in the same positions.")
        }
        if !tactic.style.preferredRoles.isEmpty {
            lines.append("FM's preferred roles for this style: \(tactic.preferredRoles.count) of \(tactic.style.preferredRoles.count) in this XI"
                + (tactic.preferredRoles.isEmpty ? "." : ": " + tactic.preferredRoles.joined(separator: ", ") + "."))
        }
        if let yours = report.yours, !tactic.isYours {
            let change = tactic.complexity - yours.complexity
            lines.append("Role complexity \(NetFormat.fixed(tactic.complexity, min: 2, max: 2)) on FM's scale, \(abs(change) < 0.05 ? "the same as" : change > 0 ? "harder than" : "easier than") your tactic's \(NetFormat.fixed(yours.complexity, min: 2, max: 2)).")
        }
        if let lowest = zip(tactic.slots, tactic.stars).min(by: { $0.1 < $1.1 }), let player = lowest.0.player {
            lines.append("Weakest place: \(lowest.0.label), \(player.name) \(RoleBook.stars(lowest.1)) as \(lowest.0.roleName).")
        }
        lines += tactic.changes.map { "Changed from FM's preset: \($0)." }
        return lines
    }
}
