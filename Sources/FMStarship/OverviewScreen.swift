@preconcurrency import StarshipAnalysis
@preconcurrency import StarshipCore
import SwiftUI

/// One overview: the rows arrive at once, then who'd join fills in one row at a time, because each answer
/// is a question for the game.
@MainActor
final class OverviewState: ObservableObject {
    enum Filter: Hashable {
        case needsWork, couldImprove, developing, everyone
    }

    unowned let model: AppModel
    let job = BackgroundJob<any OverviewReport>()
    let finder = BackgroundJob<Bool>()
    @Published private(set) var hires: [String: OverviewResult] = [:]
    @Published var filter = Filter.needsWork

    private let preparing: String
    private let build: @Sendable (AnalysisSession) -> (any OverviewReport)?
    private var shownFor = -1

    init(model: AppModel, preparing: String, build: @escaping @Sendable (AnalysisSession) -> (any OverviewReport)?) {
        self.model = model
        self.preparing = preparing
        self.build = build
    }

    func appeared() {
        if shownFor != model.analysisVersion { refresh() }
    }

    func refresh() {
        guard let session = model.session else { return }
        shownFor = model.analysisVersion
        finder.cancel()
        hires = [:]
        let build = build
        job.run(preparing, work: { _, _ in build(session) }, done: { [weak self] report in self?.findHires(report) })
    }

    private func findHires(_ report: any OverviewReport) {
        // The worst places pick first, so two of them never share one name.
        let rows = report.rows.filter(\.searches).enumerated().sorted { a, b in
            a.element.standing != b.element.standing ? a.element.standing < b.element.standing : a.offset < b.offset
        }.map(\.element)
        finder.run("Asking who'd join...") { [weak self] token, status in
            var taken = Set<UInt32>()
            for (index, row) in rows.enumerated() {
                status("Looking for \(row.place): \(index + 1) of \(rows.count)")
                guard let result = report.search(row, taken: &taken, isCancelled: { token.isCancelled }) else { return nil }
                Task { @MainActor [weak self] in
                    if !token.isCancelled { self?.hires[row.id] = result }
                }
            }
            return true
        }
    }

    /// Nothing wrong here, but someone clearly better would come. Not over someone still developing.
    func couldImprove(_ row: OverviewRow) -> Bool {
        guard !row.needsWork, row.standing != .developing, case .hire = hires[row.id] else { return false }
        return true
    }

    func lookFurther(_ row: OverviewRow) {
        switch row.lookup {
        case let .staff(role, level, area):
            model.recommendedStaff.lookFor(role: role, level: level)
            if let index = StaffRoles.outfield.firstIndex(of: area) { model.recommendedStaff.options.area = index + 1 }
            model.go(to: .recommendedStaff)
        case let .signing(position):
            model.signings.options.position = position
            model.go(to: .signings)
        }
    }
}

private enum OverviewColumns {
    static let standing: CGFloat = 122
    static let action: CGFloat = 22
    static let spacing: CGFloat = 14
    /// Beside the list there has to be room for the list itself.
    static let sideBySide: CGFloat = 1020
}

/// What every overview shares: a sentence, the places group by group, and a map of the club beside them.
struct OverviewScreen<Map: View>: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appColors) private var colors
    @ObservedObject private var state: OverviewState
    @ObservedObject private var job: BackgroundJob<any OverviewReport>
    @ObservedObject private var finder: BackgroundJob<Bool>
    private let unavailable: String
    private let placeWidth: CGFloat
    private let mapWidth: CGFloat
    private let map: (any OverviewReport) -> Map

    init(state: OverviewState, unavailable: String, placeWidth: CGFloat, mapWidth: CGFloat,
         @ViewBuilder map: @escaping (any OverviewReport) -> Map) {
        self.state = state
        job = state.job
        finder = state.finder
        self.unavailable = unavailable
        self.placeWidth = placeWidth
        self.mapWidth = mapWidth
        self.map = map
    }

    var body: some View {
        Group {
            if let report = job.output {
                VStack(alignment: .leading, spacing: Metric.gap) {
                    header(report)
                    GeometryReader { geometry in
                        if geometry.size.width >= OverviewColumns.sideBySide {
                            HStack(alignment: .top, spacing: Metric.gap) {
                                Panel { list(report, map: false) }
                                ScrollView { map(report) }
                                    .frame(width: mapWidth)
                            }
                        } else {
                            Panel { list(report, map: true) }
                        }
                    }
                    FootNote(text: report.footnote)
                }
            } else if job.running {
                VStack {
                    Panel { SkeletonRows(rows: 12) }
                    Spacer(minLength: 0)
                }
            } else {
                ContentUnavailableView(unavailable, systemImage: "sportscourt", description: Text("Press Load Save with Football Manager running."))
            }
        }
        .padding(Metric.gutter)
        .overlay(alignment: .bottom) { JobOverlay(job: job) }
        .onAppear { state.appeared() }
        .onChange(of: model.analysisVersion) { state.refresh() }
    }

    private func header(_ report: any OverviewReport) -> some View {
        let work = report.rows.filter(\.needsWork).count
        let better = report.rows.filter(state.couldImprove).count
        let developing = report.rows.filter { $0.standing == .developing }.count
        return VStack(alignment: .leading, spacing: Metric.gap) {
            ControlBar {
                Picker("Show", selection: $state.filter) {
                    Text("Needs work (\(work))").tag(OverviewState.Filter.needsWork)
                    Text("Could improve (\(better))").tag(OverviewState.Filter.couldImprove)
                    if developing > 0 {
                        Text("Developing (\(developing))").tag(OverviewState.Filter.developing)
                    }
                    Text("Everything (\(report.rows.count))").tag(OverviewState.Filter.everyone)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if finder.running {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(finder.progress).font(.callout).foregroundStyle(colors.ui.muted).monospacedDigit()
                        Button("Stop") { finder.cancel() }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
            } trailing: {
                Button("Export...") { model.exportTable(report.table(hires: state.hires), title: report.exportTitle) }
            }
            LeadLine(text: report.headline)
        }
    }

    @ViewBuilder
    private func list(_ report: any OverviewReport, map showsMap: Bool) -> some View {
        let shown = report.rows.filter { row in
            switch state.filter {
            case .needsWork: return row.needsWork
            case .couldImprove: return state.couldImprove(row)
            case .developing: return row.standing == .developing
            case .everyone: return true
            }
        }
        VStack(spacing: 0) {
            OverviewHeading(placeTitle: report.placeTitle, nowTitle: report.nowTitle, placeWidth: placeWidth)
            if shown.isEmpty, !showsMap {
                if finder.running {
                    Spacer(minLength: 0)
                } else {
                    ContentUnavailableView(emptyTitle, systemImage: "checkmark.circle",
                                           description: Text("Choose Everything to see the rest of the club."))
                }
            } else {
                ScrollView {
                    // Not lazy: rows grow as answers arrive, and a lazy stack holds them to their old height and cuts the text off.
                    VStack(spacing: 0) {
                        ForEach(report.groups, id: \.self) { group in
                            let rows = shown.filter { $0.group == group }
                            if !rows.isEmpty {
                                Section {
                                    ForEach(rows) { row in
                                        OverviewRowView(row: row, result: state.hires[row.id], waiting: finder.running, placeWidth: placeWidth) {
                                            state.lookFurther(row)
                                        }
                                    }
                                } header: {
                                    groupHeader(group)
                                }
                            }
                        }
                        if showsMap { map(report).padding(Metric.gap) }
                    }
                }
            }
        }
    }

    private var emptyTitle: String {
        switch state.filter {
        case .needsWork: return "Nothing needs work"
        case .couldImprove: return "Nobody clearly better would join"
        case .developing, .everyone: return "Nobody is developing here"
        }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(colors.ui.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metric.inset)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .background(colors.ui.panel)
    }
}

/// The headings over a list of places, in step with `OverviewRowView`.
struct OverviewHeading: View {
    @Environment(\.appColors) private var colors
    let placeTitle: String
    let nowTitle: String
    let placeWidth: CGFloat

    var body: some View {
        HStack(spacing: OverviewColumns.spacing) {
            Text(placeTitle).frame(width: placeWidth, alignment: .leading)
            Text(nowTitle).frame(maxWidth: .infinity, alignment: .leading)
            Text("Best who'd join").frame(maxWidth: .infinity, alignment: .leading)
            Text("Against the league").frame(width: OverviewColumns.standing, alignment: .leading)
            Color.clear.frame(width: OverviewColumns.action, height: 1)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(colors.ui.muted)
        .padding(.horizontal, Metric.inset)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { colors.ui.line.frame(height: 1) }
    }
}

/// One place. `compact` keeps it to who and why, for the dashboard; the overview shows everything known about it.
struct OverviewRowView: View {
    @Environment(\.appColors) private var colors
    let row: OverviewRow
    let result: OverviewResult?
    let waiting: Bool
    let placeWidth: CGFloat
    var compact = false
    let onLook: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: OverviewColumns.spacing) {
            Text(row.place)
                .fontWeight(.medium)
                .frame(width: placeWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                who(row.person, name: row.name, score: row.score, gain: nil)
                if compact {
                    if let warning = row.warning {
                        note(warning, colors.fair)
                    } else {
                        note(row.detail, colors.muted)
                    }
                } else {
                    note(row.detail, colors.muted)
                    if let warning = row.warning { note(warning, colors.fair) }
                    if let outlook = row.outlook { note(outlook, colors.growth) }
                    if let talent = row.talent { note(talent, colors.row(row.talentTone)) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                if let advice = row.advice, !compact { note(advice, colors.growth) }
                hire
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StandingPill(standing: row.standing)
                .frame(width: OverviewColumns.standing, alignment: .leading)
            Button(action: onLook) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(colors.ui.muted)
            .frame(width: OverviewColumns.action)
            .help("See more options for \(row.place)")
            .accessibilityLabel("See more options for \(row.place)")
        }
        .padding(.horizontal, Metric.inset)
        .padding(.vertical, 8)
        .background(hovering ? colors.ui.hover : .clear)
        .overlay(alignment: .bottom) { colors.ui.line.frame(height: 1) }
        .onHover { hovering = $0 }
    }

    private func note(_ text: String, _ color: NSColor) -> some View {
        Text(starred: text, color: color).font(.callout).foregroundStyle(Color(nsColor: color))
    }

    @ViewBuilder
    private var hire: some View {
        switch result {
        case let .hire(hire):
            VStack(alignment: .leading, spacing: 2) {
                who(hire.person, name: hire.name, score: hire.score, gain: hire.gain)
                note(hire.detail, colors.muted)
            }
        case let .nobody(reason):
            note(reason, colors.muted)
        case nil:
            note(row.searches && waiting ? "Checking..." : row.searches ? "" : "Nothing to gain", colors.muted)
        }
    }

    private func who(_ person: Person?, name: String, score: String, gain: String?) -> some View {
        Flow(spacing: 6, lineSpacing: 2) {
            NameLink(name: name, person: person)
            if !score.isEmpty || gain != nil { ScoreText(score: score, gain: gain) }
        }
    }
}

struct StandingDot: View {
    @Environment(\.appColors) private var colors
    let standing: Standing

    var body: some View {
        let color = standing == .good ? colors.ui.muted : colors.ui.tone(standing.tone)
        Group {
            if standing == .missing {
                Circle().strokeBorder(color, lineWidth: 1.5)
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

// MARK: Staff

struct StaffOverviewScreen: View {
    let state: OverviewState

    var body: some View {
        OverviewScreen(state: state, unavailable: "The staff overview needs a loaded save", placeWidth: 132, mapWidth: 300) { report in
            if let overview = report as? StaffOverview { StaffMap(overview: overview) }
        }
    }
}

/// What can't be read from one row: how the coaches cover training, and what the board allows.
private struct StaffMap: View {
    @Environment(\.appColors) private var colors
    let overview: StaffOverview

    var body: some View {
        VStack(spacing: Metric.gap) {
            Panel(title: "Training cover") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(overview.areas) { area in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            StandingDot(standing: area.standing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(area.name)
                                Text(area.coach.isEmpty ? "No coach" : area.coach).font(.callout).foregroundStyle(colors.ui.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .trailing, spacing: 1) {
                                ScoreText(score: area.starsText)
                                Text(area.rank).font(.callout).foregroundStyle(colors.ui.muted).monospacedDigit()
                            }
                            .fixedSize()
                        }
                        .padding(.horizontal, Metric.inset)
                        .padding(.vertical, 6)
                        .overlay(alignment: .top) { colors.ui.line.frame(height: 1) }
                    }
                    if let note = overview.coachNote {
                        FootNote(text: note).padding(Metric.inset).overlay(alignment: .top) { colors.ui.line.frame(height: 1) }
                    }
                }
            }
            if !overview.places.isEmpty {
                Panel(title: "Places the board allows") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(overview.places) { place in
                            HStack(alignment: .firstTextBaseline) {
                                Text(place.name).frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(place.filled) of \(place.allowed)")
                                    .monospacedDigit()
                                    .foregroundStyle(place.filled < place.allowed ? colors.ui.fair : colors.ui.muted)
                                    .fixedSize()
                            }
                            .padding(.horizontal, Metric.inset)
                            .padding(.vertical, 5)
                            .overlay(alignment: .top) { colors.ui.line.frame(height: 1) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: Squad

struct SquadOverviewScreen: View {
    let state: OverviewState

    var body: some View {
        OverviewScreen(state: state, unavailable: "The squad overview needs the live game", placeWidth: 58, mapWidth: 404) { report in
            if let overview = report as? SquadOverview {
                Panel(title: "Your eleven", note: "Coloured by how each place stands against the league. Click a name for the profile.") {
                    DepthBoard(places: overview.places).padding(.horizontal, 10).padding(.bottom, 10)
                }
            }
        }
    }
}

/// The eleven on a pitch, coloured by how they stand against the league.
private struct DepthBoard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appColors) private var colors
    let places: [SquadOverview.Place]

    var body: some View {
        GeometryReader { geometry in
            let slots = places.map(\.slot)
            ZStack {
                PitchBackground(size: geometry.size)
                PitchLayout {
                    ForEach(places) { place in
                        card(place).layoutValue(key: PitchLayout.Spot.self, value: PitchPlan.spot(place.slot, among: slots))
                    }
                }
            }
        }
        .aspectRatio(0.78, contentMode: .fit)
    }

    private func card(_ place: SquadOverview.Place) -> some View {
        PitchCard(position: Names.positions[place.slot.position], stars: place.stars, name: place.slot.player.map(TacticBoard.surname) ?? "Nobody",
                  standing: place.standing) {
            if let player = place.slot.player { model.openProfile(player) }
        }
        .help("\(place.slot.label): \(place.standing.title). Cover: \(place.cover)")
    }
}

/// One place on a pitch: where, how well, and who.
struct PitchCard: View {
    @Environment(\.appColors) private var colors
    let position: String
    let stars: Int
    let name: String
    var standing: Standing?
    var marked = false
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    if let standing { StandingDot(standing: standing) }
                    Text(position).font(.subheadline.weight(.semibold)).foregroundStyle(colors.ui.muted)
                    Text(starred: RoleBook.stars(stars), color: colors.star).font(.subheadline)
                }
                Text(name).font(.callout.weight(.semibold))
            }
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(colors.ui.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(marked ? colors.ui.accent : colors.ui.line))
        }
        .buttonStyle(.plain)
    }
}
