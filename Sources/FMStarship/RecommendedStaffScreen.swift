@preconcurrency import StarshipAnalysis
@preconcurrency import StarshipCore
import SwiftUI

@MainActor
final class RecommendedStaffState: ObservableObject {
    struct Output {
        let table: AnalysisTable
        let recommender: StaffRecommender
        let maxWage: String
    }

    unowned let model: AppModel
    let job = BackgroundJob<Output>()
    private var shownFor = -1
    private weak var startedFor: AnalysisSession?

    /// The boxes wait for Return; everything else searches at once.
    @Published var options = StaffSearchOptions() {
        didSet {
            if oldValue.role != options.role || oldValue.level != options.level || oldValue.area != options.area
                || oldValue.keen != options.keen || oldValue.onlyJoin != options.onlyJoin { find() }
        }
    }
    @Published private(set) var recommender: StaffRecommender?

    init(model: AppModel) { self.model = model }

    func appeared() {
        if shownFor != model.analysisVersion { find() }
    }

    func find() {
        guard let session = model.session else { return }
        // Reading the board's limits can mean asking the game, so it happens off the main thread too.
        let first = startedFor !== session
        startedFor = session
        shownFor = model.analysisVersion
        let reuse = first ? nil : recommender
        let chosen = options
        job.run("Finding staff...", work: { token, status in
            let recommender = reuse ?? StaffRecommender(session: session)
            var options = chosen
            // The max-wage box starts at the wage room.
            if first { options.maxWage = recommender.startingMaxWage }
            guard let table = recommender.find(options, isCancelled: { token.isCancelled }, status: status) else { return nil }
            return Output(table: table, recommender: recommender, maxWage: options.maxWage)
        }, done: { [weak self] output in
            self?.recommender = output.recommender
            if first { self?.options.maxWage = output.maxWage }
        })
    }

    /// Staff review sends someone here to look for a replacement.
    func lookFor(role: StaffRole, level: Int) {
        if let recommender {
            options = recommender.select(role: role, level: level, in: options)
        } else {
            options.role = role
        }
    }

    func saveShortlist() {
        guard let output = job.output else { return }
        model.saveAsShortlist(output.table.people, isStaff: true, name: output.recommender.shortlistName(options.role))
    }
}

struct RecommendedStaffScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var state: RecommendedStaffState
    @ObservedObject private var job: BackgroundJob<RecommendedStaffState.Output>

    init(state: RecommendedStaffState) {
        self.state = state
        job = state.job
    }

    private var tabs: [(title: String, role: StaffRole)] {
        state.recommender?.tabs ?? StaffRoles.base.map { ($0.name, $0) }
    }

    var body: some View {
        ReportPane(table: job.output?.table, version: job.version, exportTitle: "Recommended staff - \(state.options.role.name)") {
            controls
        } actions: {
            Button(StaffRecommender.reviewButton) { model.go(to: .staffReview) }
            Button(StaffRecommender.saveButton) { state.saveShortlist() }
                .disabled(job.output?.table.people.isEmpty ?? true)
        }
        .overlay(alignment: .bottom) { JobOverlay(job: job) }
        .onAppear { state.appeared() }
        .onChange(of: model.analysisVersion) { state.find() }
    }

    private var units: MoneyUnits? { model.session?.display.units }

    @ViewBuilder
    private var controls: some View {
        Picker("Job", selection: $state.options.role) {
            ForEach(tabs, id: \.role) { tab in
                Text(tab.title).tag(tab.role)
            }
        }
        .fixedSize()
        if let recommender = state.recommender {
            Picker(StaffRecommender.levelLabel, selection: $state.options.level) {
                ForEach(Array(recommender.levelNames.enumerated()), id: \.offset) { index, name in
                    Text(name).tag(index)
                }
            }
            .fixedSize()
            .disabled(!recommender.levelEnabled(state.options.role))

            if recommender.showsArea(state.options.role) {
                Picker(StaffRecommender.areaLabel, selection: $state.options.area) {
                    ForEach(Array(StaffRecommender.areaChoices.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index)
                    }
                }
                .fixedSize()
            }
        }
        LabeledBox(StaffRecommender.maxWageLabel, text: $state.options.maxWage,
                   prompt: units.map { "\($0.symbol)K \($0.wageSuffix)" } ?? "", width: 80) { state.find() }
        LabeledBox(StaffRecommender.maxAgeLabel, text: $state.options.maxAge, width: 44) { state.find() }
        Picker(StaffRecommender.keenLabel, selection: $state.options.keen) {
            ForEach(Array(StaffRecommender.keenChoices.enumerated()), id: \.offset) { index, name in
                Text(name).tag(index)
            }
        }
        .fixedSize()
        .disabled(state.recommender?.keenEnabled != true)

        Toggle(state.recommender?.onlyJoinTitle ?? "Only staff who'd join", isOn: $state.options.onlyJoin)
            .fixedSize()
            .disabled(state.recommender?.onlyJoinEnabled != true)
        if let note = missingNote {
            Text(note).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// What the game couldn't tell us. The columns stay, empty, and this says why.
    private var missingNote: String? {
        guard let output = job.output else { return nil }
        var missing: [String] = []
        if output.recommender.limits == nil { missing.append("the board's staff limits") }
        let wantsJob = output.table.columns.firstIndex { $0.title == "Wants job" } ?? -1
        let rows = output.table.rows
        if !rows.isEmpty, wantsJob >= 0, rows.allSatisfy({ wantsJob < $0.cells.count && $0.cells[wantsJob].isEmpty }) {
            missing.append("how keen they are on the job and the job they prefer")
        }
        guard !missing.isEmpty else { return nil }
        return "Not available on this version: " + missing.joined(separator: ", ") + "."
    }
}
