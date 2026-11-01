@preconcurrency import StarshipAnalysis
@preconcurrency import StarshipCore
import SwiftUI

@MainActor
final class DashboardState: ObservableObject {
    unowned let model: AppModel
    let job = BackgroundJob<ClubDashboard>()
    private var shownFor = -1

    init(model: AppModel) { self.model = model }

    func appeared() {
        if shownFor != model.analysisVersion { refresh() }
        model.squadOverview.appeared()
        model.staffOverview.appeared()
    }

    func refresh() {
        guard let session = model.session else { return }
        shownFor = model.analysisVersion
        job.run("Going through \(session.club.name)...") { _, _ in ClubDashboard(session: session) }
    }
}

/// Where the app lands after Load Save: what needs a decision, who's coming through, and what wants doing now.
struct DashboardScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appColors) private var colors
    @ObservedObject private var state: DashboardState
    @ObservedObject private var job: BackgroundJob<ClubDashboard>
    @ObservedObject private var squadJob: BackgroundJob<any OverviewReport>
    @ObservedObject private var staffJob: BackgroundJob<any OverviewReport>

    /// Most places to show before pointing at the overview, so one list can't push the other off the screen.
    private static let teamRows = 6
    private static let staffRows = 5

    init(state: DashboardState, squad: OverviewState, staff: OverviewState) {
        self.state = state
        job = state.job
        squadJob = squad.job
        staffJob = staff.job
    }

    var body: some View {
        ScrollView {
            if let dashboard = job.output {
                VStack(alignment: .leading, spacing: 16) {
                    header(dashboard)
                    LeadLine(text: ClubDashboard.headline(team: squadJob.output?.rows, emptyPlaces: staffJob.output?.emptyPlaces ?? 0, actions: dashboard.actions))
                    SideColumn(side: 340, main: 620) {
                        decisions
                        side(dashboard)
                    }
                }
                .padding(Metric.gutter)
            } else {
                Panel { SkeletonRows(rows: 12) }.padding(Metric.gutter)
            }
        }
        .onAppear { state.appeared() }
        .onChange(of: model.analysisVersion) {
            state.refresh()
            model.squadOverview.refresh()
            model.staffOverview.refresh()
        }
    }

    private func header(_ dashboard: ClubDashboard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dashboard.club).font(.title.weight(.semibold))
                Text(dashboard.line).foregroundStyle(colors.ui.muted)
            }
            Flow(spacing: 24) {
                ForEach(dashboard.facts) { fact in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(fact.label).font(.callout).foregroundStyle(colors.ui.muted)
                        Text(fact.value).font(.headline).monospacedDigit()
                    }
                }
            }
        }
    }

    private var decisions: some View {
        VStack(spacing: Metric.gap) {
            OverviewPreview(state: model.squadOverview, title: "Your team", screen: .squadOverview, limit: Self.teamRows, placeWidth: 58,
                            allClear: "Nothing in the team needs work.", unavailable: "Needs the live game. Start FM from here and press Load Save.")
            OverviewPreview(state: model.staffOverview, title: "Your backroom", screen: .staffOverview, limit: Self.staffRows, placeWidth: 132,
                            allClear: "Nothing in the backroom needs work.", unavailable: "")
        }
    }

    private func side(_ dashboard: ClubDashboard) -> some View {
        VStack(spacing: Metric.gap) {
            if dashboard.showsAbility { talent(dashboard) }
            health(dashboard)
        }
    }

    private func talent(_ dashboard: ClubDashboard) -> some View {
        Panel(title: "Young talent", note: "Ability now, then likely peak. The tick is PA.") {
            Button("All of them") { model.openTalent() }.buttonStyle(.link).font(.callout)
        } content: {
            VStack(spacing: 0) {
                if dashboard.prospects.isEmpty {
                    FootNote(text: "Nobody at the club is 23 or younger.").padding(Metric.inset)
                }
                ForEach(dashboard.prospects) { prospect in
                    ProspectRow(prospect: prospect, scale: dashboard.scale)
                }
            }
        }
    }

    private func health(_ dashboard: ClubDashboard) -> some View {
        Panel(title: "Health check") {
            Button("All of it") { model.openHealthCheck() }.buttonStyle(.link).font(.callout)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if dashboard.issues.isEmpty {
                    FootNote(text: "Nobody needs action.").padding(.horizontal, Metric.inset).padding(.bottom, 12)
                }
                ForEach(dashboard.issues) { issue in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            NameLink(name: issue.name, person: issue.person)
                            Spacer(minLength: 4)
                            Pill(text: issue.issue, tone: issue.tone)
                        }
                        Text(issue.detail).font(.callout).foregroundStyle(colors.ui.muted)
                    }
                    .padding(.horizontal, Metric.inset)
                    .padding(.vertical, 8)
                    .overlay(alignment: .top) { colors.ui.line.frame(height: 1) }
                }
            }
        }
    }
}

/// One young player: their name and odds, then the bar and where it runs from and to.
private struct ProspectRow: View {
    @Environment(\.appColors) private var colors
    let prospect: ClubDashboard.Prospect
    let scale: ClosedRange<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                NameLink(name: prospect.player.name, person: prospect.player)
                Spacer(minLength: 4)
                Text(prospect.path).foregroundStyle(colors.ui.muted).monospacedDigit().fixedSize()
            }
            RangeBar(now: prospect.now, peak: prospect.peak, potential: prospect.potential, scale: scale)
            Text(detail).font(.callout).foregroundStyle(tone)
        }
        .padding(.horizontal, Metric.inset)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { colors.ui.line.frame(height: 1) }
    }

    private var detail: String {
        var parts = ["Age \(prospect.player.age)"]
        if let verdict = prospect.verdict { parts.append(verdict.title) }
        if let odds = prospect.odds { parts.append(odds) }
        return parts.joined(separator: " · ")
    }

    private var tone: Color {
        prospect.verdict.map { colors.ui.tone($0.tone == .text ? .muted : $0.tone) } ?? colors.ui.muted
    }
}

/// An overview's worst places, with a way through to the rest.
private struct OverviewPreview: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appColors) private var colors
    @ObservedObject private var state: OverviewState
    @ObservedObject private var job: BackgroundJob<any OverviewReport>
    @ObservedObject private var finder: BackgroundJob<Bool>
    private let title: String
    private let screen: Screen
    private let limit: Int
    private let placeWidth: CGFloat
    private let allClear: String
    private let unavailable: String

    init(state: OverviewState, title: String, screen: Screen, limit: Int, placeWidth: CGFloat, allClear: String, unavailable: String) {
        self.state = state
        job = state.job
        finder = state.finder
        self.title = title
        self.screen = screen
        self.limit = limit
        self.placeWidth = placeWidth
        self.allClear = allClear
        self.unavailable = unavailable
    }

    private var rows: [OverviewRow] {
        (job.output?.rows.filter(\.needsWork) ?? []).enumerated().sorted { a, b in
            a.element.standing != b.element.standing ? a.element.standing < b.element.standing : a.offset < b.offset
        }.map(\.element)
    }

    var body: some View {
        Panel(title: title) {
            Button(rows.count > limit ? "All \(rows.count) in \(screen.title)" : screen.title) { model.go(to: screen) }.buttonStyle(.link).font(.callout)
        } content: {
            if job.output == nil {
                if job.running { SkeletonRows(rows: 4) } else { FootNote(text: unavailable).padding(.horizontal, Metric.inset).padding(.bottom, 12) }
            } else if rows.isEmpty {
                FootNote(text: allClear).padding(.horizontal, Metric.inset).padding(.bottom, 12)
            } else {
                VStack(spacing: 0) {
                    OverviewHeading(placeTitle: job.output?.placeTitle ?? "", nowTitle: job.output?.nowTitle ?? "", placeWidth: placeWidth)
                    ForEach(rows.prefix(limit)) { row in
                        OverviewRowView(row: row, result: state.hires[row.id], waiting: finder.running, placeWidth: placeWidth, compact: true) {
                            state.lookFurther(row)
                        }
                    }
                }
            }
        }
    }
}
