import AppKit
import StarshipAnalysis
import StarshipFiles
import StarshipSearch
import SwiftUI

/// The colours everything draws with. With no palette they are the system's semantic colours, so macOS looks
/// after dark and light mode; a palette from `Theme.all` replaces them, tables included.
struct AppColors: Equatable {
    let palette: Theme.Palette?

    init(palette: Theme.Palette? = nil) { self.palette = palette }

    /// `name` as saved in Settings: nothing saved means the default palette.
    init(themeNamed name: String) {
        self.init(palette: name == Theme.system ? nil : Theme.named(name))
    }

    private static func color(_ rgb: Theme.RGB) -> NSColor {
        NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    /// `systemYellow` can't be read on white.
    private static let systemFair = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .systemYellow
            : NSColor(srgbRed: 0.62, green: 0.47, blue: 0, alpha: 1)
    }

    var text: NSColor { palette.map { Self.color($0.text) } ?? .labelColor }
    var muted: NSColor { palette.map { Self.color($0.muted) } ?? .secondaryLabelColor }
    var good: NSColor { palette.map { Self.color($0.good) } ?? .systemGreen }
    var fair: NSColor { palette.map { Self.color($0.warning) } ?? Self.systemFair }
    var bad: NSColor { palette.map { Self.color($0.bad) } ?? .systemRed }
    /// The amber that marks everything hidden in the game.
    var hidden: NSColor { palette.map { Self.color($0.hidden) } ?? .systemOrange }
    var star: NSColor { palette.map { Self.color($0.star) } ?? .systemYellow }
    /// Someone on their way up: not a warning, and not there yet either.
    var growth: NSColor { palette.map { Self.color($0.growth) } ?? .systemTeal }

    /// Behind everything in a window.
    var ground: NSColor { palette.map { Self.color($0.back) } ?? .windowBackgroundColor }
    /// Panels and tables.
    var panel: NSColor { palette.map { Self.color($0.panel) } ?? .controlBackgroundColor }
    /// Hairlines between rows and around panels.
    var line: NSColor { palette.map { Self.color($0.line) } ?? .separatorColor }
    var hover: NSColor { palette.map { Self.color($0.altRow) } ?? .labelColor.withAlphaComponent(0.05) }
    var selection: NSColor { palette.map { Self.color($0.select) } ?? .controlAccentColor.withAlphaComponent(0.25) }
    /// Nil leaves the sidebar to macOS.
    var rail: NSColor? { palette.map { Self.color($0.header) } }
    /// Nil leaves the accent to macOS.
    var accent: NSColor? { palette.map { Self.color($0.accent) } }

    func cell(_ tone: CellTone, hidden isHidden: Bool) -> NSColor {
        switch tone {
        case .good: return good
        case .fair: return fair
        case .bad: return bad
        case .muted: return muted
        case .standard, .text: return isHidden ? hidden : text
        }
    }

    func row(_ tone: Tone?) -> NSColor {
        switch tone {
        case .good: return good
        case .fair: return fair
        case .bad: return bad
        case .muted: return muted
        case .star: return star
        case .growth: return growth
        case .text, nil: return text
        }
    }

    /// How a 1-20 attribute reads at a glance. For the three where high is bad, the ends swap.
    func attribute(_ value: Int, name: String, hidden isHidden: Bool) -> (color: Color, bold: Bool) {
        if ["Injury Proneness", "Dirtiness", "Controversy"].contains(name) {
            return (Color(nsColor: value <= 5 ? good : value >= 15 ? bad : isHidden ? hidden : text), false)
        }
        if value >= 16 { return (Color(nsColor: good), true) }
        if value <= 6 { return (Color(nsColor: muted), false) }
        return (Color(nsColor: isHidden ? hidden : text), false)
    }

    /// Standing for the "app appearance": a palette fixes it, otherwise macOS decides.
    var appearance: NSAppearance? {
        palette.flatMap { NSAppearance(named: $0.dark ? .darkAqua : .aqua) }
    }

    /// The same colours for SwiftUI.
    var ui: Swatches { Swatches(colors: self) }

    struct Swatches {
        let colors: AppColors

        var text: Color { Color(nsColor: colors.text) }
        var muted: Color { Color(nsColor: colors.muted) }
        var good: Color { Color(nsColor: colors.good) }
        var fair: Color { Color(nsColor: colors.fair) }
        var bad: Color { Color(nsColor: colors.bad) }
        var hidden: Color { Color(nsColor: colors.hidden) }
        var star: Color { Color(nsColor: colors.star) }
        var growth: Color { Color(nsColor: colors.growth) }
        var ground: Color { Color(nsColor: colors.ground) }
        var panel: Color { Color(nsColor: colors.panel) }
        var line: Color { Color(nsColor: colors.line) }
        var hover: Color { Color(nsColor: colors.hover) }
        var accent: Color { colors.accent.map { Color(nsColor: $0) } ?? .accentColor }

        func tone(_ tone: Tone?) -> Color { Color(nsColor: colors.row(tone)) }
    }
}

extension EnvironmentValues {
    private struct AppColorsKey: EnvironmentKey {
        static let defaultValue = AppColors()
    }

    var appColors: AppColors {
        get { self[AppColorsKey.self] }
        set { self[AppColorsKey.self] = newValue }
    }
}
