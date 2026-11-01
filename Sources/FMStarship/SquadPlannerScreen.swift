@preconcurrency import StarshipAnalysis
@preconcurrency import StarshipCore
import StarshipFiles
import SwiftUI

@MainActor
final class PlannerState: ObservableObject {
    struct Output {
        let lines: [SquadPlanner.Line]
        let squad: AnalysisTable
        /// The line behind each row of `squad`.
        let rows: [SquadPlanner.Line]
        /// A sentence about each row's player, when the tactic could be read.
        let notes: [String]
        let plan: SquadPlanner.Plan
        /// Nil without the live game.
        let report: TacticReport?
        /// Nil without the live game.
        let best: BestEleven?
    }

    enum Tab: String, CaseIterable {
        case team = "Squad and signings"
        case best = "Best eleven"
        case tactics = "Optimized tactic and roles"
    }

    unowned let model: AppModel
    let job = BackgroundJob<Output>()
    private var shownFor = -1
    private weak var startedFor: AnalysisSession?

    @Published var budget = ""
    @Published var wageRoom = ""
    @Published var includeLoans = false {
        didSet { if includeLoans != oldValue { find() } }
    }
    /// The row picked in the first-team grid, for "Just this position".
    @Published var selectedLine: Int?
    @Published var hint = ""
    @Published var tab = Tab.team
    /// The row picked in the tactics grid.
    @Published var selectedTactic = 0
    /// Goes up when a search you asked for has an answer, so the screen can take you to it.
    @Published private(set) var picksFound = 0
    /// Every shape of every style, not just each style's best.
    @Published var allShapes = false {
        didSet { selectedTactic = 0 }
    }

    init(model: AppModel) { self.model = model }

    func appeared() {
        if shownFor != model.analysisVersion { find() }
    }

    /// A new load is analysed from scratch and starts from the save's own budget.
    func find(onlySelected: Bool = false, showingPicks: Bool = false) {
        guard let session = model.session else { return }
        hint = ""
        let fresh = shownFor != model.analysisVersion
        shownFor = model.analysisVersion
        let known = fresh ? nil : job.output?.lines
        let knownRows = fresh ? nil : job.output?.rows
        let knownReport = fresh ? nil : job.output?.report
        let knownBest = fresh ? nil : job.output?.best
        let position = onlySelected ? selectedLine.flatMap { index in knownRows.flatMap { index < $0.count ? $0[index] : nil } } : nil
        if onlySelected, position == nil {
            hint = SquadPlanner.noPositionChosen
            return
        }
        if startedFor !== session {
            startedFor = session
            let start = SquadPlanner.startingBudget(session)
            budget = start.budget
            wageRoom = start.wageRoom
            selectedLine = nil
            selectedTactic = 0
        }
        let budget = budget, wageRoom = wageRoom, includeLoans = includeLoans
        job.run("Going through your first team...", work: { token, status in
            let lines = known ?? SquadPlanner.analyse(session)
            let squad = SquadPlanner.squadView(lines, session: session)
            let report = knownReport ?? TacticOptimizer.report(session, status: status)
            let best = knownBest ?? BestEleven(session: session)
            guard let plan = SquadPlanner.plan(session, lines: lines, only: position, budget: budget, wageRoom: wageRoom,
                                               includeLoans: includeLoans, isCancelled: { token.isCancelled }, status: status) else { return nil }
            return Output(lines: lines, squad: squad.table, rows: squad.rows, notes: squad.notes, plan: plan, report: report, best: best)
        }, done: { [weak self] _ in
            if showingPicks { self?.picksFound += 1 }
        })
    }

    func saveShortlist() {
        guard let plan = job.output?.plan else { return }
        model.saveAsShortlist(plan.shortlist, isStaff: false, name: SquadPlanner.shortlistName)
    }
}

struct SquadPlannerScreen: View {
    private static let picks = "picks"
    /// A page's scroller runs in the gutter, clear of the last column, with the page still lined up with the controls above it.
    private static let scrollerRoom: CGFloat = 12

    @EnvironmentObject private var model: AppModel
    @Environment(\.appColors) private var colors
    @ObservedObject private var state: PlannerState
    @ObservedObject private var job: BackgroundJob<PlannerState.Output>

    init(state: PlannerState) {
        self.state = state
        job = state.job
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.gap) {
            ControlBar {
                controls
            } trailing: {
                if state.tab == .team {
                    Button(SquadPlanner.saveButton) { state.saveShortlist() }
                        .disabled(job.output?.plan.canSaveShortlist != true)
                    Button("Export...") { if let output = job.output { model.exportTable(output.plan.table, title: SquadPlanner.shortlistName) } }
                        .disabled(job.output?.plan.table.rows.isEmpty ?? true)
                } else if state.tab == .best {
                    Button("Export...") { if let best = job.output?.best { model.exportTable(best.table, title: best.title) } }
                        .disabled(job.output?.best == nil)
                }
            }
            if let output = job.output {
                switch state.tab {
                case .team: team(output)
                case .best: bestEleven(output)
                case .tactics: tactics(output)
                }
            } else {
                Panel { SkeletonRows(rows: 11) }
                Spacer(minLength: 0)
            }
        }
        .padding(Metric.gutter)
        .overlay(alignment: .bottom) { JobOverlay(job: job) }
        .onAppear { state.appeared() }
        .onChange(of: model.analysisVersion) { state.find() }
    }

    private func team(_ output: PlannerState.Output) -> some View {
        ScrollViewReader { page in
            ScrollView {
                VStack(alignment: .leading, spacing: Metric.gap) {
                    LeadLine(text: state.hint.isEmpty ? output.plan.table.status : state.hint)
                    ReportGrid(table: output.squad, version: job.version, title: SquadPlanner.squadTitle, fitted: true,
                               onSelection: { state.selectedLine = $0.first })
                        .help(SquadPlanner.haveWantTip)
                    if !output.notes.isEmpty {
                        note(output)
                    }
                    ReportGrid(table: output.plan.table, version: job.version, title: SquadPlanner.picksTitle, fitted: true)
                        .id(Self.picks)
                    FootNote(text: "Double-click anyone for the full profile.")
                }
                .padding(.trailing, Self.scrollerRoom)
            }
            .padding(.trailing, -Self.scrollerRoom)
            .onChange(of: state.picksFound) {
                withAnimation(.easeOut(duration: 0.2)) { page.scrollTo(Self.picks, anchor: .top) }
            }
        }
    }

    @ViewBuilder
    private func bestEleven(_ output: PlannerState.Output) -> some View {
        if let best = output.best {
            ScrollView {
                VStack(alignment: .leading, spacing: Metric.gap) {
                    LeadLine(text: best.headline)
                    SideColumn(side: 340, main: 620) {
                        ReportGrid(table: best.table, version: job.version, title: best.title, fitted: true)
                        VStack(spacing: Metric.gap) {
                            Panel {
                                // Under the table on a small window, the panel is far wider than a pitch should be.
                                TacticBoard(slots: best.places.map(\.slot), stars: best.places.map(\.stars), marked: best.places.map(\.isChange))
                                    .frame(maxWidth: 320)
                                    .padding(10)
                                    .frame(maxWidth: .infinity)
                            }
                            if !best.notes.isEmpty {
                                Panel(title: "Worth knowing") {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(Array(best.notes.enumerated()), id: \.offset) { _, line in
                                            Text(starred: line, color: colors.star).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                        }
                                    }
                                    .padding(.horizontal, Metric.inset)
                                    .padding(.bottom, 12)
                                }
                            }
                        }
                    }
                    FootNote(text: best.footnote)
                }
                .padding(.trailing, Self.scrollerRoom)
            }
            .padding(.trailing, -Self.scrollerRoom)
        } else {
            ContentUnavailableView("The best eleven needs the live game", systemImage: "sportscourt",
                                   description: Text("Press Load Save with Football Manager running."))
        }
    }

    @ViewBuilder
    private func tactics(_ output: PlannerState.Output) -> some View {
        if let report = output.report {
            let listed = state.allShapes ? report.tactics : report.bestOfEachStyle
            let choices = (report.yours.map { [$0] } ?? []) + listed
            let shown = choices[min(state.selectedTactic, max(0, choices.count - 1))]
            let strengths = TacticOptimizer.strengths(report.profile)
            ScrollView {
                VStack(alignment: .leading, spacing: Metric.gap) {
                    VStack(alignment: .leading, spacing: 2) {
                        LeadLine(text: "Your squad against \(report.profile.league)")
                        Text("Stronger: \(strengths.strong)")
                        Text("Weaker: \(strengths.weak)").foregroundStyle(colors.ui.muted)
                    }
                    HStack(alignment: .top, spacing: Metric.gap) {
                        VStack(spacing: Metric.gap) {
                            Panel(title: state.allShapes ? "All of FM's tactics" : "FM's tactics, best shape of each style") {
                                Toggle("Show every shape", isOn: $state.allShapes).font(.callout).fixedSize()
                            } content: {
                                // Ninety shapes would push everything else off the page.
                                ReportGrid(table: TacticOptimizer.ranking(report, shown: listed), version: job.version * 2 + (state.allShapes ? 1 : 0), bare: true, fitted: !state.allShapes, onSelection: { rows in
                                    if let first = rows.first { state.selectedTactic = first }
                                })
                                .frame(height: state.allShapes ? 340 : nil)
                            }
                            ReportGrid(table: TacticOptimizer.detail(shown), version: job.version * 1000 + state.selectedTactic * 2 + (state.allShapes ? 1 : 0), fitted: true)
                        }
                        .frame(minWidth: 480, maxWidth: .infinity)
                        VStack(spacing: Metric.gap) {
                            Panel {
                                TacticBoard(slots: shown.slots, stars: shown.stars).padding(10)
                            }
                            Panel(title: "Why this fits") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(TacticOptimizer.explanation(shown, report: report).enumerated()), id: \.offset) { _, line in
                                        Text(starred: line, color: colors.star).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                    }
                                }
                                .padding(.horizontal, Metric.inset)
                                .padding(.bottom, 12)
                            }
                        }
                        .frame(width: 340)
                    }
                    FootNote(text: "Tactics, roles and stars are FM's. Fit is this app's blend: 65% role stars, 25% style attributes against the league, 10% how well your players fill FM's preferred roles. Anyone out for 3+ weeks is left out\(report.leftOut > 0 ? " (\(report.leftOut))" : "").")
                }
                .padding(.trailing, Self.scrollerRoom)
            }
            .padding(.trailing, -Self.scrollerRoom)
        } else {
            ContentUnavailableView("The optimized tactic needs the live game", systemImage: "sportscourt",
                                   description: Text("Press Load Save with Football Manager running."))
        }
    }

    private func note(_ output: PlannerState.Output) -> some View {
        let row = state.selectedLine.flatMap { $0 < output.notes.count ? output.notes[$0] : nil }
        return Text(starred: row ?? "Click a player to see where they'd do best.", color: colors.star)
            .font(.callout)
            .foregroundStyle(row == nil ? colors.ui.muted : colors.ui.text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var controls: some View {
        Picker("", selection: $state.tab) {
            ForEach(PlannerState.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        if state.tab == .team {
            // The money stays together when the bar wraps.
            HStack(spacing: 14) {
                LabeledBox(SquadPlanner.budgetLabel, text: $state.budget, prompt: "e.g. 40M", width: 90) { state.find() }
                LabeledBox(SquadPlanner.wageLabel, text: $state.wageRoom, prompt: "e.g. 75K", width: 110) { state.find() }
            }
            Toggle(SquadPlanner.loansLabel, isOn: $state.includeLoans).fixedSize()
            Button(SquadPlanner.findButton) { state.find(showingPicks: true) }
                .keyboardShortcut(.defaultAction)
            Button(SquadPlanner.positionButton) { state.find(onlySelected: true, showingPicks: true) }
        }
    }
}

/// A tactic on a pitch, one card per player, like FM's tactics screen.
struct TacticBoard: View {
    @EnvironmentObject private var model: AppModel
    let slots: [TacticSlot]
    let stars: [Int]
    /// The places to pick out, one per slot.
    var marked: [Bool] = []

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PitchBackground(size: geometry.size)
                PitchLayout {
                    ForEach(Array(zip(slots, stars).enumerated()), id: \.offset) { index, entry in
                        card(entry.0, stars: entry.1, marked: index < marked.count && marked[index])
                            .layoutValue(key: PitchLayout.Spot.self, value: PitchPlan.spot(entry.0, among: slots))
                    }
                }
            }
        }
        .aspectRatio(0.78, contentMode: .fit)
    }

    /// The name a shirt would carry.
    static func surname(_ player: Player) -> String {
        player.name.split(separator: " ").last.map(String.init) ?? player.name
    }

    private func card(_ slot: TacticSlot, stars: Int, marked: Bool) -> some View {
        PitchCard(position: Names.positions[slot.position], stars: stars, name: slot.player.map(Self.surname) ?? "-", marked: marked) {
            if let player = slot.player { model.openProfile(player) }
        }
        .help("\(slot.label): \(slot.roleName) with the ball, \(slot.roleNameWithoutBall) without it")
    }
}
