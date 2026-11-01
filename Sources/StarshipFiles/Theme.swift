/// The colour themes as data. All WinForms painting stays behind; a SwiftUI layer builds its
/// colours from these.
public enum Theme {
    public static let defaultName = "Starship"
    /// The saved name for following macOS instead of a palette.
    public static let system = "System"

    public struct RGB: Hashable, Sendable {
        /// 0xRRGGBB
        public let hex: UInt32
        public init(_ hex: UInt32) { self.hex = hex }

        public var red: Double { Double((hex >> 16) & 255) / 255 }
        public var green: Double { Double((hex >> 8) & 255) / 255 }
        public var blue: Double { Double(hex & 255) / 255 }
        public var css: String { "#" + String(hex, radix: 16, uppercase: true).leftPadded(to: 6) }

        /// System.Drawing.Color.GetBrightness, which is HSL lightness.
        var brightness: Double { (max(red, green, blue) + min(red, green, blue)) / 2 }

        /// Between red and yellow.
        var isWarm: Bool { red >= green && green > blue }
    }

    public struct Palette: Hashable, Sendable {
        public let name: String
        public let dark: Bool
        public let back, panel, field, altRow, line, text, muted: RGB
        public let select, pressed, header, good, fair, bad, hidden: RGB

        public var accent: RGB {
            switch name {
            case "Starship": return RGB(0x3D6CF0)
            case "Graphite": return RGB(0xD6303A)
            case "Black & Gold": return RGB(0xD4AF37)
            case "Red Devil": return RGB(0xC8102E)
            default: return good
            }
        }

        public var onAccent: RGB {
            if name == "Starship" || name == "Graphite" || name == "Red Devil" { return RGB(0xFFFFFF) }
            return accent.brightness > 0.5 ? RGB(0x141000) : RGB(0xFFFFFF)
        }

        public var star: RGB { dark ? RGB(0xE8B830) : RGB(0xB08000) }

        /// Something to watch. `fair` is an amber on some palettes and a softer green on others, where `hidden` is the amber.
        public var warning: RGB { fair.isWarm ? fair : hidden }

        /// Someone on their way up, in text and bars. The accent itself is too dark to read as text on Starship.
        public var growth: RGB { name == "Starship" ? RGB(0x8BABFF) : accent }
    }

    public static let natural = RGB(0x2ECC71)
    public static let accomplished = RGB(0xF4D03F)
    public static let competent = RGB(0xE67E22)
    public static let unconvincing = RGB(0xE74C3C)

    public static let all: [Palette] = [
        make("Starship", true, 0x0F1115, 0x171A20, 0x171A20, 0x1E222A, 0x262B35, 0xE8EBF1, 0x9AA3B2, 0x223258, 0x2B3F6E, 0x14171D, 0x3ECF8E, 0xF2C14E, 0xF2828A, 0xF2A65A),
        make("Dark", true, 0x151B22, 0x1B222B, 0x0E1217, 0x1F2731, 0x263140, 0xE8ECF1, 0x9AA5B4, 0x1E405C, 0x133424, 0x121820, 0x4ADE9A, 0x8FD9B6, 0xFF8A73, 0xF2B544),
        make("Light", false, 0xF0F2F5, 0xFFFFFF, 0xFFFFFF, 0xF5F7FA, 0xCDD2D8, 0x1A1A1A, 0x666666, 0xCCE4F7, 0xBAD6F0, 0xE9ECEF, 0x0B6B2E, 0x288246, 0xB3261E, 0xA35A00),
        make("Midnight", true, 0x0B1020, 0x111831, 0x070B16, 0x161F3D, 0x223055, 0xE6EAF7, 0x8E9AC0, 0x26407A, 0x1B2D5A, 0x0A0F1E, 0x6EE7B7, 0xA7F3D0, 0xFCA5A5, 0xFBBF24),
        make("Charcoal", true, 0x1E1E1E, 0x252526, 0x161616, 0x2B2B2C, 0x3C3C3C, 0xE0E0E0, 0x9E9E9E, 0x3A4A5C, 0x2D3E2D, 0x1A1A1A, 0x7FD88F, 0xB4E0BC, 0xF48771, 0xE5C07B),
        make("Classic Grey", false, 0xD4D0C8, 0xF4F2EE, 0xFFFFFF, 0xEAE7E0, 0xA9A49A, 0x101010, 0x4F4F4F, 0x9DB9E8, 0xB8C9E8, 0xC8C4BB, 0x006400, 0x2E7D32, 0xB00020, 0x8A4B00),
        make("Royal Purple", true, 0x1A1030, 0x22163D, 0x120A22, 0x2A1C4A, 0x3B2A63, 0xF1EBFF, 0xA99BC9, 0x4B2E8A, 0x3A1F6B, 0x150C27, 0xFFD166, 0xFFE29A, 0xFF6B9A, 0xFF9F1C),
        make("Pitch", true, 0x0F2418, 0x143020, 0x0A1A11, 0x183A27, 0x245236, 0xE7F5EC, 0x93B9A1, 0x22603E, 0x1C4E33, 0x0C1D13, 0xFFFFFF, 0xC8F7DC, 0xFF8A80, 0xFFD54F),
        make("Solarized Dark", true, 0x002B36, 0x073642, 0x00212B, 0x0A3F4C, 0x1B4F5B, 0xEEE8D5, 0x93A1A1, 0x1A5D6E, 0x2A4F2A, 0x00232C, 0x859900, 0xB5C14E, 0xDC322F, 0xB58900),
        make("Solarized Light", false, 0xFDF6E3, 0xFFFBEF, 0xFFFFFF, 0xF5EED8, 0xD8CFB4, 0x073642, 0x657B83, 0xEEE1B8, 0xE6D7A8, 0xEEE8D5, 0x5F7A00, 0x859900, 0xDC322F, 0xB58900),
        make("Nord", true, 0x2E3440, 0x3B4252, 0x272C36, 0x434C5E, 0x4C566A, 0xECEFF4, 0xA3ABBA, 0x5E81AC, 0x4C6A4C, 0x272C36, 0xA3BE8C, 0xC5D9B4, 0xBF616A, 0xEBCB8B),
        make("Dracula", true, 0x282A36, 0x2F3242, 0x1E1F29, 0x353848, 0x44475A, 0xF8F8F2, 0xB0B4D0, 0x44475A, 0x3B4A3B, 0x21222C, 0x50FA7B, 0xA4FBBB, 0xFF5555, 0xFFB86C),
        make("Monokai", true, 0x272822, 0x2F302A, 0x1E1F1A, 0x35362F, 0x49483E, 0xF8F8F2, 0xA59F85, 0x49483E, 0x3E4A2A, 0x1F201B, 0xA6E22E, 0xCDEE8A, 0xF92672, 0xE6DB74),
        make("High Contrast", true, 0x000000, 0x000000, 0x000000, 0x0D0D0D, 0xFFFFFF, 0xFFFFFF, 0xFFFF00, 0x1A6BFF, 0x006400, 0x000000, 0x00FF00, 0x7CFF7C, 0xFF4040, 0xFFFF00),
        make("Sepia", false, 0xF1E7D0, 0xFAF3E3, 0xFFFBF2, 0xF3EAD6, 0xD2C2A0, 0x3B2F20, 0x7A6A55, 0xE2CFA6, 0xD9C397, 0xE8DCC0, 0x4E6B1F, 0x6B8A35, 0xA4331E, 0x9A5B12),
        make("Ocean", true, 0x0B1E26, 0x102A35, 0x071419, 0x133340, 0x1F4756, 0xE3F4F8, 0x8FB3BF, 0x15607A, 0x135245, 0x081820, 0x4FD1C5, 0x9AE6DE, 0xFF8C7A, 0xF6C26B),
        make("Red Devil", true, 0x1A0D0D, 0x231212, 0x120808, 0x2B1616, 0x4A2020, 0xF5E9E9, 0xC09A9A, 0x7A1E1E, 0x5A1414, 0x150A0A, 0xFFD700, 0xFFE680, 0xFF5A5A, 0xFFA94D),
        make("Sky", false, 0xEAF4FB, 0xFFFFFF, 0xFFFFFF, 0xF2F8FD, 0xBFD7EA, 0x0F2A3F, 0x557089, 0xBFE0F7, 0xA9D3F2, 0xDCEBF7, 0x0B7A3B, 0x2E9A5A, 0xC0392B, 0xB9770E),
        make("Graphite", true, 0x141414, 0x1C1C1C, 0x0F0F0F, 0x181818, 0x2E2E2E, 0xECECEC, 0xA9A9A9, 0x3A2224, 0x4A2A2D, 0x181818, 0x8FE0B8, 0xF2C27B, 0xFF7A6B, 0x8FB8E8),
        make("Black & Gold", true, 0x0B0B0B, 0x141414, 0x070707, 0x111111, 0x2B2619, 0xF2EEE4, 0xB3AB9B, 0x2B2414, 0x3D3420, 0x101010, 0xD4AF37, 0xE8C860, 0xFF7A6B, 0x8FB8E8),
    ]

    /// The saved-setting lookup: resolves names of retired themes, then falls back to the default.
    public static func named(_ name: String?) -> Palette {
        var wanted = name ?? ""
        if wanted.isEmpty { wanted = defaultName }
        switch wanted {
        case "Genie Classic": wanted = "Classic Grey"
        case "FM Purple": wanted = "Royal Purple"
        default: break
        }
        return all.first { $0.name == wanted } ?? all.first { $0.name == defaultName }!
    }

    private static func make(
        _ name: String, _ dark: Bool,
        _ back: UInt32, _ panel: UInt32, _ field: UInt32, _ altRow: UInt32, _ line: UInt32,
        _ text: UInt32, _ muted: UInt32, _ select: UInt32, _ pressed: UInt32, _ header: UInt32,
        _ good: UInt32, _ fair: UInt32, _ bad: UInt32, _ hidden: UInt32
    ) -> Palette {
        Palette(
            name: name, dark: dark,
            back: RGB(back), panel: RGB(panel), field: RGB(field), altRow: RGB(altRow), line: RGB(line),
            text: RGB(text), muted: RGB(muted), select: RGB(select), pressed: RGB(pressed),
            header: RGB(header), good: RGB(good), fair: RGB(fair), bad: RGB(bad), hidden: RGB(hidden)
        )
    }
}

private extension String {
    func leftPadded(to width: Int) -> String { String(repeating: "0", count: max(0, width - count)) + self }
}
