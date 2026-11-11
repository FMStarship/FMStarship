import Foundation

/// The order FM sorts its own Position column in, which the engine's position columns sort in too.
public enum PositionOrder {
    /// FM's order, as its Squad screen sorts by Position: the goalkeeper first, then each line from the right to the
    /// left, a wing-back after the defender on its side. The sweeper goes with the centre-backs. A player rated best at
    /// two positions goes by the earlier one here.
    public static let order: [[String]] = [
        ["GK"], ["DR"], ["WBR"], ["DC", "SW"], ["DL"], ["WBL"], ["DM"],
        ["MR"], ["MC"], ["ML"], ["AMR"], ["AMC"], ["AML"], ["ST"],
    ]

    /// The squad planner's lines in words, by the first of their positions in the order.
    private static let words = [
        "goalkeeper": "GK", "right-back": "DR", "centre-back": "DC", "left-back": "DL", "defensive midfield": "DM",
        "right wing": "MR", "central midfield": "MC", "left wing": "ML", "attacking midfield": "AMC", "striker": "ST",
    ]

    private static let places: [String: Int] = {
        var places: [String: Int] = [:]
        for (index, line) in order.enumerated() { for name in line { places[name] = index } }
        return places
    }()

    /// Where a player stands: by the position they're rated best at, of their 15 in `Names.positions` order. Nil for
    /// a player rated nowhere.
    public static func rank(of player: Player) -> Int? {
        guard let best = player.pos.max(), best > 0 else { return nil }
        return player.pos.indices.filter { player.pos[$0] == best && $0 < Names.positions.count }
            .compactMap { rank(Names.positions[$0], across: nil) }.min()
    }

    /// Where a position's text stands, by the first position it names: FM's short forms, such as D (C), M/AM (RC) or
    /// AMR, the engine's places in a tactic, such as DC (R) or ST (L), and the planner's lines, such as Right-back. A
    /// role or anything else after it is left out, and where it covers more than one place, the earliest decides. Nil
    /// for text that names no position, which sorts as text.
    public static func rank(_ text: String) -> Int? {
        let first = text.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return ranks(first).min()
    }

    /// Where each place one position's text names stands: D/WB (RL) names four.
    static func ranks(_ item: String) -> [Int] {
        places(item).compactMap { rank($0.name, across: $0.across) }
    }

    /// Every place one position's text names, and where across it, if it says.
    static func places(_ item: String) -> [(name: String, across: Character?)] {
        let item = item.trimmingCharacters(in: .whitespaces)
        if let name = words[item.lowercased()] { return [(name, nil)] }
        // The positions, such as M/AM, end where a side, a space or a role's punctuation starts, never in a word.
        let token = item.prefix { ("A"..."Z").contains($0) || $0 == "/" }
        let rest = item.dropFirst(token.count)
        if token.isEmpty || token.hasSuffix("/") || rest.first?.isLetter == true { return [] }
        // The sides in brackets: of a line, as FM writes D (RLC), or across a place, as a tactic's DC (R).
        var sides: [Character] = []
        let after = rest.drop { $0 == " " }
        if after.first == "(", let close = after.firstIndex(of: ")") {
            let inside = after[after.index(after: after.startIndex)..<close]
            if !inside.isEmpty, inside.allSatisfy({ "RLC".contains($0) }) { sides = Array(inside) }
        }
        var found: [(name: String, across: Character?)] = []
        for part in token.split(separator: "/").map(String.init) {
            if places[part] != nil {
                // A place of its own, such as DC or ST: what's in brackets is across it.
                found += sides.isEmpty ? [(part, nil)] : sides.map { (part, $0) }
            } else {
                // A line in FM's short form: D, WB, M or AM, with its sides, or all of them.
                let named = (sides.isEmpty ? Array("RCL") : sides).map { part + String($0) }.filter { places[$0] != nil }
                if named.isEmpty { return [] }
                found += named.map { ($0, nil) }
            }
        }
        return found
    }

    /// One place, and where across it, as a tactic's pair of centre-backs, DC (R) and DC (L): the same way round as
    /// the order goes across a line.
    static func rank(_ name: String, across side: Character?) -> Int? {
        guard let place = places[name] else { return nil }
        let rightFirst = (places["DR"] ?? 0) <= (places["DL"] ?? 0)
        let offset: Int
        switch side {
        case "R": offset = rightFirst ? 0 : 2
        case "L": offset = rightFirst ? 2 : 0
        default: offset = 1
        }
        return place * 3 + offset
    }
}
