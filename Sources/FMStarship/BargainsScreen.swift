@preconcurrency import StarshipAnalysis
@preconcurrency import StarshipCore
import SwiftUI

@MainActor
final class BargainsState: ObservableObject {
    unowned let model: AppModel
    let job = BackgroundJob<Output>()
    private var shownFor = -1
    private weak var startedFor: AnalysisSession?

    struct Output {
        let table: AnalysisTable
        let startingMaxFee: String
    }

    /// The boxes wait for Return; the pickers search at once.
    @Published var options = BargainOptions() {
        didSet {
            if oldValue.kind != options.kind || oldValue.position != options.position || oldValue.onlyJoin != options.onlyJoin { find() }
        }
    }
    @Published private(set) var onlyJoinEnabled = true

    init(model: AppModel) { self.model = model }

    func appeared() {
        if shownFor != model.analysisVersion { find() }
    }

    func find() {
        guard let session = model.session else { return }
        let first = startedFor !== session
        startedFor = session
        shownFor = model.analysisVersion
        onlyJoinEnabled = session.checks.canCheckInterest
        let chosen = options
        job.run("Finding bargains...", work: { token, status in
            let finder = BargainFinder(session: session)
            var options = chosen
            // The max-fee box starts at the transfer budget.
            if first { options.maxFee = finder.startingMaxFee }
            guard let table = finder.find(options, isCancelled: { token.isCancelled }, status: status) else { return nil }
            return Output(table: table, startingMaxFee: options.maxFee)
        }, done: { [weak self] output in
            if first { self?.options.maxFee = output.startingMaxFee }
        })
    }

    func saveShortlist() {
        guard let session = model.session, let table = job.output?.table else { return }
        model.saveAsShortlist(table.people, isStaff: false, name: BargainFinder(session: session).shortlistName(options))
    }
}

struct BargainsScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var state: BargainsState
    @ObservedObject private var job: BackgroundJob<BargainsState.Output>

    init(state: BargainsState) {
        self.state = state
        job = state.job
    }

    var body: some View {
        ReportPane(table: job.output?.table, version: job.version, exportTitle: "Bargains") {
            controls
        } actions: {
            Button(BargainFinder.saveButton) { state.saveShortlist() }
                .disabled(job.output?.table.people.isEmpty ?? true)
        }
        .overlay(alignment: .bottom) { JobOverlay(job: job) }
        .onAppear { state.appeared() }
        .onChange(of: model.analysisVersion) { state.find() }
    }

    @ViewBuilder
    private var controls: some View {
        Picker("Kind", selection: $state.options.kind) {
            ForEach(BargainOptions.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        PositionPicker(label: BargainFinder.positionLabel, choices: BargainFinder.positionChoices, selection: $state.options.position)
        LabeledBox(BargainFinder.minCALabel, text: $state.options.minCA, width: 50) { state.find() }
        LabeledBox(BargainFinder.maxAgeLabel, text: $state.options.maxAge, width: 50) { state.find() }
        LabeledBox(BargainFinder.maxFeeLabel, text: $state.options.maxFee,
                   prompt: (model.session?.display.units.symbol ?? "") + "M", width: 70) { state.find() }
        Toggle(BargainFinder.onlyJoinLabel, isOn: $state.options.onlyJoin)
            .fixedSize()
            .disabled(!state.onlyJoinEnabled)
            .help(state.onlyJoinEnabled ? "Asks the game who would come" : "Needs the live game and your club")
    }
}
