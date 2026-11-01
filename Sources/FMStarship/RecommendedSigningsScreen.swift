@preconcurrency import StarshipAnalysis
@preconcurrency import StarshipCore
import SwiftUI

@MainActor
final class SigningsState: ObservableObject {
    unowned let model: AppModel
    let job = Report()
    private var shownFor = -1

    /// Anything but the typed fee searches at once; the fee waits for Return.
    @Published var options = RecommendOptions() {
        didSet { if oldValue.maxFee == options.maxFee { find() } }
    }

    init(model: AppModel) { self.model = model }

    func appeared() {
        if shownFor != model.analysisVersion { find() }
    }

    func find() {
        guard let session = model.session else { return }
        shownFor = model.analysisVersion
        let options = options
        job.run("Finding players who'd join you...") { token, status in
            SigningRecommender(session: session).find(options, isCancelled: { token.isCancelled }, status: status)
        }
    }

    func saveShortlist() {
        guard let session = model.session, let table = job.output else { return }
        model.saveAsShortlist(table.people, isStaff: false, name: SigningRecommender(session: session).shortlistName(options))
    }
}

struct RecommendedSigningsScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var state: SigningsState
    @ObservedObject private var job: Report

    init(state: SigningsState) {
        self.state = state
        job = state.job
    }

    var body: some View {
        ReportPane(table: job.output, version: job.version, exportTitle: "Recommended signings") {
            controls
        } actions: {
            Button(SigningRecommender.saveButton) { state.saveShortlist() }
                .disabled(job.output?.people.isEmpty ?? true)
        }
        .overlay(alignment: .bottom) { JobOverlay(job: job) }
        .onAppear { state.appeared() }
        .onChange(of: model.analysisVersion) { state.find() }
    }

    @ViewBuilder
    private var controls: some View {
        Picker("Looking for", selection: $state.options.mode) {
            ForEach(RecommendOptions.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        PositionPicker(label: SigningRecommender.positionLabel, choices: SigningRecommender.positionChoices,
                       selection: $state.options.position)
        LabeledBox(SigningRecommender.maxFeeLabel, text: $state.options.maxFee,
                   prompt: (model.session?.display.units.symbol ?? "") + "M", width: 70) { state.find() }
        Picker(SigningRecommender.showLabel, selection: $state.options.show) {
            ForEach(RecommendOptions.Show.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .fixedSize()
        Toggle(SigningRecommender.loansLabel, isOn: $state.options.includeLoans).fixedSize()
        Toggle(SigningRecommender.upgradesLabel, isOn: $state.options.upgradesOnly).fixedSize()
    }
}

/// `choices` has "Any" first, which stands for -1.
struct PositionPicker: View {
    let label: String
    let choices: [String]
    @Binding var selection: Int

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(Array(choices.enumerated()), id: \.offset) { index, name in
                Text(name).tag(index - 1)
            }
        }
        .fixedSize()
    }
}
