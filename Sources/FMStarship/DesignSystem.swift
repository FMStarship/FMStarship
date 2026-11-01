import AppKit
import StarshipAnalysis
import StarshipCore
import SwiftUI

/// The spacing everything sits on.
enum Metric {
    /// Around a screen's content.
    static let gutter: CGFloat = 16
    /// Between panels.
    static let gap: CGFloat = 12
    /// Inside a panel, left and right.
    static let inset: CGFloat = 14
    static let radius: CGFloat = 10
}

/// Stars are drawn, not typed, and a rating is one image so a line can't break through the middle of it.
enum StarArt {
    private struct Key: Hashable {
        let run: String
        let color: NSColor
    }

    private static let size: CGFloat = 10
    private static let gap: CGFloat = 1
    private static var drawn: [Key: NSImage] = [:]

    static func hasStars(_ text: String) -> Bool { text.contains("★") || text.contains("½") }

    /// A rating stays with the name before it.
    static func glued(_ text: String) -> String {
        text.replacingOccurrences(of: " ★", with: "\u{00A0}★").replacingOccurrences(of: " ½", with: "\u{00A0}½")
    }

    /// The words and ratings of `text`, in order.
    static func runs(_ text: String) -> [(text: String, isStars: Bool)] {
        var runs: [(text: String, isStars: Bool)] = []
        for character in glued(text) {
            let isStar = character == "★" || character == "½"
            if let last = runs.last, last.isStars == isStar {
                runs[runs.count - 1].text.append(character)
            } else {
                runs.append((String(character), isStar))
            }
        }
        return runs
    }

    /// `text` as a cell draws it. Measure this, not the typed stars, which are narrower than the images.
    static func attributed(_ text: String, attributes: [NSAttributedString.Key: Any], color: NSColor) -> NSMutableAttributedString {
        let shown = NSMutableAttributedString()
        for run in runs(text) {
            if run.isStars {
                let attachment = NSTextAttachment()
                let art = image(run.text, color: color)
                attachment.image = art
                attachment.bounds = NSRect(x: 0, y: -1, width: art.size.width, height: art.size.height)
                shown.append(NSAttributedString(attachment: attachment))
            } else {
                shown.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        return shown
    }

    static func image(_ run: String, color: NSColor) -> NSImage {
        let key = Key(run: run, color: color)
        if let known = drawn[key] { return known }
        let look = NSImage.SymbolConfiguration(pointSize: size, weight: .regular).applying(.init(paletteColors: [color]))
        let symbols = run.compactMap { mark in
            NSImage(systemSymbolName: mark == "½" ? "star.leadinghalf.filled" : "star.fill", accessibilityDescription: nil)?.withSymbolConfiguration(look)
        }
        let width = symbols.reduce(0) { $0 + $1.size.width + gap } - gap
        let height = symbols.map(\.size.height).max() ?? size
        let image = NSImage(size: NSSize(width: max(1, width), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for symbol in symbols {
                symbol.draw(at: NSPoint(x: x, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
                x += symbol.size.width + gap
            }
            return true
        }
        drawn[key] = image
        return image
    }
}

extension Text {
    /// `text` with its stars drawn.
    init(starred text: String, color: NSColor) {
        var shown = Text(verbatim: "")
        for run in StarArt.runs(text) {
            shown = shown + (run.isStars ? Text(Image(nsImage: StarArt.image(run.text, color: color))).baselineOffset(-1) : Text(verbatim: run.text))
        }
        self = shown
    }
}

/// The surface for anything grouped: a rounded panel with an optional title and something beside it.
struct Panel<Content: View, Accessory: View>: View {
    @Environment(\.appColors) private var colors
    var title: String?
    var note: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(title).font(.headline)
                        Spacer(minLength: 8)
                        accessory()
                    }
                    if let note {
                        Text(note).font(.callout).foregroundStyle(colors.ui.muted)
                    }
                }
                .padding(.horizontal, Metric.inset)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.ui.panel, in: RoundedRectangle(cornerRadius: Metric.radius))
        .clipShape(RoundedRectangle(cornerRadius: Metric.radius))
        .overlay(RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(colors.ui.line))
    }
}

extension Panel where Accessory == EmptyView {
    init(title: String? = nil, note: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, note: note, accessory: { EmptyView() }, content: content)
    }
}

/// A small tinted label for a status.
struct Pill: View {
    @Environment(\.appColors) private var colors
    let text: String
    let tone: Tone?

    var body: some View {
        let color = tone == .text || tone == nil ? colors.ui.muted : colors.ui.tone(tone)
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

/// How someone stands against the league.
struct StandingPill: View {
    let standing: Standing

    var body: some View { Pill(text: standing.title, tone: standing.tone) }
}

/// The answer, in a sentence, at the top of a screen.
struct LeadLine: View {
    @Environment(\.appColors) private var colors
    let text: String

    var body: some View {
        Text(starred: text, color: colors.star)
            .font(.title3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

/// Small print under a panel.
struct FootNote: View {
    @Environment(\.appColors) private var colors
    let text: String

    var body: some View {
        Text(starred: text, color: colors.muted)
            .font(.callout)
            .foregroundStyle(colors.ui.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lays its items out in a row and wraps to the next line rather than squeezing them, so a control is never cut off.
struct Flow: Layout {
    var spacing: CGFloat = 14
    var lineSpacing: CGFloat = 8
    /// Below this the window is only measuring its minimum size, and everything would land on its own line.
    private static let measuring: CGFloat = 200

    private func lines(_ width: CGFloat, _ subviews: Subviews) -> [[(view: LayoutSubview, size: CGSize)]] {
        var lines: [[(view: LayoutSubview, size: CGSize)]] = [[]]
        var used: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if used > 0, used + spacing + size.width > width {
                lines.append([])
                used = 0
            }
            used += (used > 0 ? spacing : 0) + size.width
            lines[lines.count - 1].append((view, size))
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Asked how narrow it can go, it can go as narrow as anything: it wraps. Saying otherwise pushes the window wider.
        if let offered = proposal.width, offered < Self.measuring {
            return CGSize(width: offered, height: lines(.infinity, subviews).first.map { $0.map(\.size.height).max() ?? 0 } ?? 0)
        }
        let width = proposal.width ?? .infinity
        let laid = lines(width, subviews)
        let height = laid.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) } + lineSpacing * CGFloat(laid.count - 1)
        let widest = laid.map { line in line.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, line.count - 1)) }.max() ?? 0
        return CGSize(width: min(widest, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(bounds.width, subviews) {
            let height = line.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for item in line {
                item.view.place(at: CGPoint(x: x, y: y + (height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + lineSpacing
        }
    }
}

/// A wide column beside a narrow one, or the one above the other when there isn't room for both.
struct SideColumn: Layout {
    /// The narrow column's width.
    var side: CGFloat
    /// The least the wide column can be read at.
    var main: CGFloat
    var spacing = Metric.gap

    private func fits(_ width: CGFloat) -> Bool { width >= main + spacing + side }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? main + spacing + side
        guard subviews.count == 2 else { return CGSize(width: width, height: 0) }
        if fits(width) {
            let first = subviews[0].sizeThatFits(ProposedViewSize(width: width - side - spacing, height: nil))
            let second = subviews[1].sizeThatFits(ProposedViewSize(width: side, height: nil))
            return CGSize(width: width, height: max(first.height, second.height))
        }
        let across = ProposedViewSize(width: width, height: nil)
        return CGSize(width: width, height: subviews[0].sizeThatFits(across).height + spacing + subviews[1].sizeThatFits(across).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if fits(bounds.width) {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width - side - spacing, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.maxX - side, y: bounds.minY), proposal: ProposedViewSize(width: side, height: nil))
        } else {
            let across = ProposedViewSize(width: bounds.width, height: nil)
            subviews[0].place(at: bounds.origin, proposal: across)
            let below = subviews[0].sizeThatFits(across).height + spacing
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + below), proposal: across)
        }
    }
}

/// A screen's controls: the ones that shape the list on the left, what you do with it on the right.
struct ControlBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Flow { leading() }
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { trailing() }
                .fixedSize()
        }
    }
}

/// A person's name that opens their profile.
struct NameLink: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appColors) private var colors
    let name: String
    let person: Person?
    @State private var hovering = false

    var body: some View {
        if let person {
            Button { model.openProfile(person) } label: {
                Text(name).underline(hovering).multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Open \(name)'s profile")
        } else {
            Text(name).foregroundStyle(colors.ui.muted)
        }
    }
}

/// Stars or a staff score, with what a move would gain beside it.
struct ScoreText: View {
    @Environment(\.appColors) private var colors
    let score: String
    var gain: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(starred: score, color: colors.star)
                .foregroundStyle(score.contains("★") ? colors.ui.star : colors.ui.text)
                .monospacedDigit()
                .fixedSize()
            if let gain {
                Text(gain)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(colors.ui.good)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
    }
}

/// A young player's story in one bar: ability now, how far they're likely to get, and the tick is their potential.
struct RangeBar: View {
    @Environment(\.appColors) private var colors
    let now: Int
    let peak: Int
    let potential: Int
    let scale: ClosedRange<Int>

    private func share(_ value: Int, of width: CGFloat) -> CGFloat {
        let span = CGFloat(max(1, scale.upperBound - scale.lowerBound))
        return min(1, max(0, CGFloat(value - scale.lowerBound) / span)) * width
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(colors.ui.line)
                Capsule().fill(colors.ui.growth.opacity(0.4)).frame(width: share(peak, of: width))
                Capsule().fill(colors.ui.growth).frame(width: share(now, of: width))
                Rectangle().fill(colors.ui.text).frame(width: 2, height: 12).offset(x: share(potential, of: width) - 1)
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 12)
        .accessibilityLabel("Ability \(now), likely peak \(peak), potential \(potential)")
    }
}

/// Stands in for rows that are on their way.
struct SkeletonRows: View {
    @Environment(\.appColors) private var colors
    var rows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<rows, id: \.self) { row in
                RoundedRectangle(cornerRadius: 4)
                    .fill(colors.ui.line)
                    .frame(width: [320, 240, 280, 200][row % 4], height: 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metric.inset)
    }
}
