import Foundation

/// Where cards go on a drawing of the pitch, kept apart from the drawing so every shape FM ships can be checked.
public enum PitchPlan {
    public struct Card {
        /// Where it belongs, as a share of the pitch.
        public let spot: CGPoint
        public let width: CGFloat
        public let height: CGFloat

        public init(spot: CGPoint, width: CGFloat, height: CGFloat) {
            self.spot = spot
            self.width = width
            self.height = height
        }
    }

    public static let gap: CGFloat = 3

    /// Spread wide enough that a full line of cards doesn't overlap: a trio leaves more room around its middle, and a
    /// pair with nobody out wide can sit further apart.
    public static func spot(_ slot: TacticSlot, among slots: [TacticSlot]) -> CGPoint {
        let name = Names.positions[slot.position]
        let trio = slots.contains { $0.position == slot.position && $0.side == .centre }
        let flanked = slots.contains { other in
            let place = Names.positions[other.position]
            return Tactic.line(other.position) == Tactic.line(slot.position) && (place.hasSuffix("L") || place.hasSuffix("R"))
        }
        let inner: CGFloat = trio ? 0.26 : flanked ? 0.38 : 0.32
        let across: CGFloat = name.hasSuffix("L") ? 0.14 : name.hasSuffix("R") ? 0.86
            : slot.side == .left ? inner : slot.side == .right ? 1 - inner : 0.5
        var down: CGFloat
        switch Tactic.line(slot.position) {
        case 0: down = 0.92
        case 1: down = 0.76
        case 2: down = 0.59
        case 3: down = 0.43
        case 4: down = 0.25
        default: down = 0.08
        }
        if name.hasPrefix("WB") { down = 0.62 }
        return CGPoint(x: across, y: down)
    }

    /// Each card's centre, as near its spot as it can get. Cards on one line push each other apart and stay on the pitch.
    /// A line too wide for that splits in two, the wide cards holding the line and the ones inside them stepping forward.
    public static func centres(_ cards: [Card], in size: CGSize) -> [CGPoint] {
        var centres = cards.map { CGPoint(x: $0.spot.x * size.width, y: $0.spot.y * size.height) }
        // Wing-backs sit a little off the midfield line but still share its width.
        for line in Dictionary(grouping: cards.indices, by: { (cards[$0].spot.y * 10).rounded() }).values {
            let ordered = line.sorted { cards[$0].spot.x < cards[$1].spot.x }
            let needed = ordered.reduce(0) { $0 + cards[$1].width + gap } - gap
            guard needed > size.width else {
                spread(ordered, cards, in: size.width, into: &centres)
                continue
            }
            let lift = (ordered.map { cards[$0].height }.max() ?? 0) + gap
            let wide = ordered.indices.filter { min($0, ordered.count - 1 - $0) % 2 == 0 }.map { ordered[$0] }
            let inside = ordered.filter { !wide.contains($0) }
            spread(wide, cards, in: size.width, into: &centres)
            spread(inside, cards, in: size.width, into: &centres)
            for index in inside { centres[index].y -= lift }
        }
        // Two split lines can still land on each other, so working forward from the goal, a card moves up clear of any behind it.
        var settled: [Int] = []
        for index in cards.indices.sorted(by: { centres[$0].y > centres[$1].y }) {
            while let blocker = settled.first(where: { overlap(index, $0, cards, centres) }) {
                centres[index].y = centres[blocker].y - (cards[index].height + cards[blocker].height) / 2 - gap
            }
            settled.append(index)
        }
        return centres
    }

    private static func spread(_ row: [Int], _ cards: [Card], in width: CGFloat, into centres: inout [CGPoint]) {
        var edge: CGFloat = 0
        for index in row {
            centres[index].x = max(centres[index].x, edge + cards[index].width / 2)
            edge = centres[index].x + cards[index].width / 2 + gap
        }
        edge = width
        for index in row.reversed() {
            centres[index].x = min(centres[index].x, edge - cards[index].width / 2)
            edge = centres[index].x - cards[index].width / 2 - gap
        }
    }

    private static func overlap(_ a: Int, _ b: Int, _ cards: [Card], _ centres: [CGPoint]) -> Bool {
        abs(centres[a].x - centres[b].x) < (cards[a].width + cards[b].width) / 2
            && abs(centres[a].y - centres[b].y) < (cards[a].height + cards[b].height) / 2
    }
}
