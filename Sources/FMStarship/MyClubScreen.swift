@preconcurrency import StarshipAnalysis
@preconcurrency import StarshipCore
import SwiftUI

@MainActor
final class MyClubState: ObservableObject {
    struct Output {
        let table: AnalysisTable
        let since: [String]
    }

    unowned let model: AppModel
    let job = BackgroundJob<Output>()
    private var shownFor = -1

    @Published var tab = ClubReport.Tab.health {
        didSet { if tab != oldValue { refresh() } }
    }
    @Published var since = 0 {
        didSet { if since != oldValue { refresh() } }
    }

    init(model: AppModel) { self.model = model }

    func appeared() {
        if shownFor != model.analysisVersion { refresh() }
    }

    func refresh() {
        guard let session = model.session else { return }
        shownFor = model.analysisVersion
        let tab = tab, since = since
        job.run("Going through \(session.club.name)...") { token, _ in
            // Each run gets its own report: a cancelled one can't be stopped, only ignored.
            let report = ClubReport(session: session)
            let table = report.table(tab, since: since)
            return token.isCancelled ? nil : Output(table: table, since: tab == .development ? report.sinceChoices : [])
        }
    }
}

struct MyClubScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var state: MyClubState
    @ObservedObject private var job: BackgroundJob<MyClubState.Output>

    init(state: MyClubState) {
        self.state = state
        job = state.job
    }

    var body: some View {
        ReportPane(table: job.output?.table, version: job.version, exportTitle: "My club - \(state.tab.title)") { controls }
            .overlay(alignment: .bottom) { JobOverlay(job: job) }
            .onAppear { state.appeared() }
            .onChange(of: model.analysisVersion) { state.refresh() }
    }

    @ViewBuilder
    private var controls: some View {
        Picker("Tab", selection: $state.tab) {
            ForEach(ClubReport.Tab.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()

        if state.tab == .development, let choices = job.output?.since, !choices.isEmpty {
            Picker(ClubReport.sinceLabel, selection: $state.since) {
                ForEach(Array(choices.enumerated()), id: \.offset) { index, date in
                    Text(date).tag(index)
                }
            }
            .fixedSize()
        }
    }
}
