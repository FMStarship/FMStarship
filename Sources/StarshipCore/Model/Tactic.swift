import Foundation

/// One of the eleven places in a tactic, as FM's tactics screen shows it. FM27 gives every place a
/// position and role with the ball and another pair without it.
public struct TacticSlot {
    public enum Side {
        case left, centre, right
    }

    public var player: Player?
    /// `Names.positions` indexes.
    public let position: Int
    public let positionWithoutBall: Int
    public let side: Side
    public let sideWithoutBall: Side
    /// `Names.rolesIp` and `Names.rolesOop` indexes.
    public let role: Int
    public let roleWithoutBall: Int

    public init(player: Player?, position: Int, positionWithoutBall: Int, side: Side, sideWithoutBall: Side, role: Int, roleWithoutBall: Int) {
        self.player = player
        self.position = position
        self.positionWithoutBall = positionWithoutBall
        self.side = side
        self.sideWithoutBall = sideWithoutBall
        self.role = role
        self.roleWithoutBall = roleWithoutBall
    }

    public var roleName: String { Names.rolesIp[role] ?? "Role \(role)" }
    public var roleNameWithoutBall: String { Names.rolesOop[roleWithoutBall] ?? "Role \(roleWithoutBall)" }

    /// "DC (R)" where a line has two or three of the same position.
    public var label: String { Self.label(position: position, side: side) }

    static func label(position: Int, side: Side) -> String {
        let name = Names.positions[position]
        switch side {
        case .left: return "\(name) (L)"
        case .right: return "\(name) (R)"
        case .centre: return name
        }
    }

    /// Goalkeeper first, up to the strikers, and right to left within a line as FM lists it.
    public var pitchOrder: Int {
        let name = Names.positions[position]
        let across = name.hasSuffix("R") ? 0 : name.hasSuffix("L") ? 4 : side == .right ? 1 : side == .left ? 3 : 2
        return Tactic.line(position) * 10 + across
    }
}

public struct Tactic {
    public var slots: [TacticSlot]
    /// What the game itself calls this shape, when its rules are running.
    public var fmShape: String?
    public var fmShapeWithoutBall: String?

    public init(slots: [TacticSlot]) {
        self.slots = slots
    }

    /// Which line of the team a position stands in: goalkeeper, defence, screen, midfield, attacking midfield, attack.
    public static func line(_ position: Int) -> Int {
        switch Names.positions[position] {
        case "GK": return 0
        case "SW", "DL", "DC", "DR", "WBL", "WBR": return 1
        case "DM": return 2
        case "ML", "MC", "MR": return 3
        case "AML", "AMC", "AMR": return 4
        default: return 5
        }
    }

    /// FM's name for this shape: from the game, or from a preset that uses it. Failing both, a count of its lines.
    public func shape(in library: TacticLibrary?) -> String {
        fmShape ?? library?.shapeName(slots.map { ($0.position, $0.side) }) ?? Self.count(slots.map(\.position))
    }

    public func shapeWithoutBall(in library: TacticLibrary?) -> String {
        fmShapeWithoutBall ?? library?.shapeName(slots.map { ($0.positionWithoutBall, $0.sideWithoutBall) }) ?? Self.count(slots.map(\.positionWithoutBall))
    }

    /// The outfield lines from the back: "4-2-3-1". Nobody up front still counts as a line: "4-6-0".
    private static func count(_ positions: [Int]) -> String {
        var lines = [Int](repeating: 0, count: 6)
        for position in positions { lines[line(position)] += 1 }
        return (lines[1...4].filter { $0 > 0 } + [lines[5]]).map(String.init).joined(separator: "-")
    }
}
