import StarshipCore
import StarshipFiles
import SwiftUI

/// Where a player can play. A click picks the position whose roles are listed.
struct PitchView: View {
    let player: Player
    @Binding var selected: Int

    private static let spots: [(name: String, column: Int, row: Int)] = [
        ("ST", 2, 0), ("AML", 0, 1), ("AMC", 2, 1), ("AMR", 4, 1), ("ML", 0, 2), ("MC", 2, 2), ("MR", 4, 2),
        ("WBL", 0, 3), ("DM", 2, 3), ("WBR", 4, 3), ("DL", 0, 4), ("DC", 2, 4), ("DR", 4, 4), ("SW", 2, 5), ("GK", 2, 6),
    ]

    private static let levels: [(name: String, color: Theme.RGB)] = [
        ("Natural", Theme.natural), ("Accomplished", Theme.accomplished), ("Competent", Theme.competent), ("Unconvincing", Theme.unconvincing),
    ]

    private static func color(_ rgb: Theme.RGB) -> Color { Color(red: rgb.red, green: rgb.green, blue: rgb.blue) }

    private func color(rating: Int) -> Color? {
        if rating >= 18 { return Self.color(Theme.natural) }
        if rating >= 15 { return Self.color(Theme.accomplished) }
        if rating >= 10 { return Self.color(Theme.competent) }
        if rating >= 5 { return Self.color(Theme.unconvincing) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack(alignment: .topLeading) {
                    PitchBackground(size: size)
                    ForEach(Self.spots, id: \.name) { spot in
                        if let index = Names.positions.firstIndex(of: spot.name) {
                            let rating = Int(player.pos[index])
                            if let color = color(rating: rating) {
                                dot(spot.name, index: index, color: color)
                                    .position(x: size.width * (0.12 + CGFloat(spot.column) * 0.19),
                                              y: size.height * (0.07 + CGFloat(spot.row) * 0.143))
                            }
                        }
                    }
                }
            }
            .aspectRatio(0.8, contentMode: .fit)

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 3) {
                ForEach(Self.levels, id: \.name) { level in
                    HStack(spacing: 5) {
                        Circle().fill(Self.color(level.color)).frame(width: 9, height: 9)
                        Text(level.name).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func dot(_ name: String, index: Int, color: Color) -> some View {
        Button {
            selected = index
        } label: {
            Text(name)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.black.opacity(0.8))
                .frame(width: 30, height: 30)
                .background(color, in: Circle())
                .overlay(Circle().strokeBorder(.primary, lineWidth: selected == index ? 2.5 : 0))
        }
        .buttonStyle(.plain)
        .help("\(name): rated \(player.pos[index]) of 20")
    }
}

/// Cards on a pitch, placed by `PitchPlan`, so a long surname can't run into its neighbour.
struct PitchLayout: Layout {
    /// Where a card belongs, as a share of the pitch.
    struct Spot: LayoutValueKey {
        static let defaultValue = CGPoint(x: 0.5, y: 0.5)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cards = subviews.map { view -> PitchPlan.Card in
            let size = view.sizeThatFits(.unspecified)
            return PitchPlan.Card(spot: view[Spot.self], width: size.width, height: size.height)
        }
        for (view, centre) in zip(subviews, PitchPlan.centres(cards, in: bounds.size)) {
            view.place(at: CGPoint(x: bounds.minX + centre.x, y: bounds.minY + centre.y), anchor: .center, proposal: .unspecified)
        }
    }
}

/// The pitch itself, drawn to fit: line work on the panel, because colour here has jobs to do.
struct PitchBackground: View {
    @Environment(\.appColors) private var colors
    let size: CGSize

    var body: some View {
        Canvas { context, size in
            let line = GraphicsContext.Shading.color(colors.ui.line)
            let box = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            context.stroke(Path(roundedRect: box, cornerRadius: 6), with: line, lineWidth: 1)
            var halfway = Path()
            halfway.move(to: CGPoint(x: box.minX, y: box.midY))
            halfway.addLine(to: CGPoint(x: box.maxX, y: box.midY))
            context.stroke(halfway, with: line, lineWidth: 1)
            let radius = box.width * 0.14
            context.stroke(Path(ellipseIn: CGRect(x: box.midX - radius, y: box.midY - radius, width: radius * 2, height: radius * 2)),
                           with: line, lineWidth: 1)
            let area = CGSize(width: box.width * 0.6, height: box.height * 0.13)
            context.stroke(Path(CGRect(x: box.midX - area.width / 2, y: box.minY, width: area.width, height: area.height)), with: line, lineWidth: 1)
            context.stroke(Path(CGRect(x: box.midX - area.width / 2, y: box.maxY - area.height, width: area.width, height: area.height)), with: line, lineWidth: 1)
        }
        .frame(width: size.width, height: size.height)
    }
}
