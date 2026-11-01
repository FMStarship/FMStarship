@preconcurrency import StarshipAnalysis
@preconcurrency import StarshipCore
import SwiftUI

@MainActor
final class StaffReviewState: ObservableObject {
    unowned let model: AppModel
    let job = BackgroundJob<StaffReview>()
    private var shownFor = -1

    init(model: AppModel) { self.model = model }

    func appeared() {
        if shownFor != model.analysisVersion { refresh() }
    }

    func refresh() {
        guard let session = model.session else { return }
        shownFor = model.analysisVersion
        job.run("Comparing your staff with the league...") { _, _ in
            let recommender = StaffRecommender(session: session)
            return StaffReview(session: session, limits: recommender.limits, levelNames: recommender.levelNames)
        }
    }

    /// Double-click: look for a replacement, or someone for an empty place.
    func lookForReplacement(_ index: Int) {
        guard let entries = job.output?.entries, index < entries.count else { return }
        model.recommendedStaff.lookFor(role: entries[index].role, level: entries[index].level)
        model.go(to: .recommendedStaff)
    }
}

struct StaffReviewScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var state: StaffReviewState
    @ObservedObject private var job: BackgroundJob<StaffReview>

    init(state: StaffReviewState) {
        self.state = state
        job = state.job
    }

    var body: some View {
        ReportPane(table: job.output?.table, version: job.version, exportTitle: "Staff review",
                   onOpen: { _, index in state.lookForReplacement(index) }) { EmptyView() }
            .overlay(alignment: .bottom) { JobOverlay(job: job) }
            .onAppear { state.appeared() }
            .onChange(of: model.analysisVersion) { state.refresh() }
    }
}
