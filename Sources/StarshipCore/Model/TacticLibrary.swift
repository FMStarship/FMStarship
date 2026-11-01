import Foundation

/// One of FM's tactical styles, from the game's own styles.xml.
public struct TacticStyle {
    /// The folder FM keeps its tactics in: "gegenpress".
    public let id: String
    public let name: String
    public let summary: String
    public let features: [String]
    /// FM's three favoured attributes, spelled as `Names.playerAttrs` spells them where it can.
    public let favouredAttributes: [String]
    /// FM's preferred roles, as `Names.rolesIp` or `Names.rolesOop` name them.
    public let preferredRoles: [String]

    public init(id: String, name: String, summary: String, features: [String], favouredAttributes: [String], preferredRoles: [String]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.features = features
        self.favouredAttributes = favouredAttributes
        self.preferredRoles = preferredRoles
    }
}

/// One place in one of FM's preset tactics, with the roles the game allows there.
public struct PresetSlot {
    public let position: Int
    public let positionWithoutBall: Int
    public let side: TacticSlot.Side
    public let sideWithoutBall: TacticSlot.Side
    public let role: Int
    public let roleWithoutBall: Int
    public let allowedRoles: [Int]
    public let allowedRolesWithoutBall: [Int]

    public init(position: Int, positionWithoutBall: Int, side: TacticSlot.Side, sideWithoutBall: TacticSlot.Side, role: Int, roleWithoutBall: Int,
                allowedRoles: [Int], allowedRolesWithoutBall: [Int]) {
        self.position = position
        self.positionWithoutBall = positionWithoutBall
        self.side = side
        self.sideWithoutBall = sideWithoutBall
        self.role = role
        self.roleWithoutBall = roleWithoutBall
        self.allowedRoles = allowedRoles
        self.allowedRolesWithoutBall = allowedRolesWithoutBall
    }
}

/// One of the presets FM offers when you start a tactic.
public struct TacticPreset {
    public let name: String
    public let style: String
    /// As FM's file names give them: "4-2-3-1 DM AM Wide".
    public let shape: String
    public let shapeWithoutBall: String
    public let slots: [PresetSlot]

    public init(name: String, style: String, shape: String, shapeWithoutBall: String, slots: [PresetSlot]) {
        self.name = name
        self.style = style
        self.shape = shape
        self.shapeWithoutBall = shapeWithoutBall
        self.slots = slots
    }
}

/// Everything FM ships about tactics that the planner uses. Read from the game's files, so it
/// follows FM's patches.
public struct TacticLibrary {
    public let styles: [TacticStyle]
    public let presets: [TacticPreset]
    /// FM's complexity for each role, keyed as `TacticLibrary.key` spells a role name.
    public let complexity: [String: Int]
    public let complexityWithoutBall: [String: Int]
    private let shapeNames: [String: String]

    public init(styles: [TacticStyle], presets: [TacticPreset], complexity: [String: Int], complexityWithoutBall: [String: Int]) {
        self.styles = styles
        self.presets = presets
        self.complexity = complexity
        self.complexityWithoutBall = complexityWithoutBall
        var names: [String: String] = [:]
        for preset in presets {
            names[Self.shapeKey(preset.slots.map { ($0.position, $0.side) })] = preset.shape
            names[Self.shapeKey(preset.slots.map { ($0.positionWithoutBall, $0.sideWithoutBall) })] = preset.shapeWithoutBall
        }
        shapeNames = names
    }

    /// The name FM's presets give these places, in any order.
    public func shapeName(_ places: [(position: Int, side: TacticSlot.Side)]) -> String? {
        shapeNames[Self.shapeKey(places)]
    }

    private static func shapeKey(_ places: [(position: Int, side: TacticSlot.Side)]) -> String {
        places.map { TacticSlot.label(position: $0.position, side: $0.side) }.sorted().joined(separator: ",")
    }

    /// "Ball-Playing Centre-Back" as FM's tables spell it: "BALL_PLAYING_CENTRE_BACK".
    public static func key(_ role: String) -> String {
        role.uppercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
    }

    /// Two role names FM's complexity table abbreviates.
    private static let shortKeys = [
        "LINE_HOLDING_GOALKEEPER": "LINE_KEEPER",
        "WIDE_COVERING_CENTRAL_MIDFIELDER": "WIDE_COVER_CENTRAL_MIDFIELDER",
        "WIDE_COVERING_DEFENSIVE_MIDFIELDER": "WIDE_COVER_DEFENSIVE_MIDFIELDER",
    ]

    public func complexity(of slot: TacticSlot) -> (withBall: Int, withoutBall: Int)? {
        let without = Self.key(slot.roleNameWithoutBall)
        guard let with = complexity[Self.key(slot.roleName)], let out = complexityWithoutBall[Self.shortKeys[without] ?? without] else { return nil }
        return (with, out)
    }
}
