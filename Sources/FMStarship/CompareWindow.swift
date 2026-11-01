@preconcurrency import StarshipAnalysis
@preconcurrency import StarshipCore
import SwiftUI

/// Two or three people side by side, with the best in each row highlighted.
struct CompareWindow: View {
    @EnvironmentObject private var model: AppModel
    let refs: [PersonRef]

    private var people: [Person] { refs.compactMap { model.person($0) } }

    var body: some View {
        if let session = model.session, people.count >= 2 {
            CompareContent(report: CompareReport(people: people, session: session))
                .id(refs)
                .navigationTitle(people.map(\.name).joined(separator: " vs "))
        } else {
            ContentUnavailableView("Nothing to compare", systemImage: "rectangle.split.3x1",
                                   description: Text("Press Load Save, then Cmd-click two or three rows and choose Compare."))
                .frame(minWidth: 500, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        }
    }
}

private struct CompareContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appColors) private var colors
    let report: CompareReport

    @State private var rows: [CompareReport.Row] = []
    @State private var roleRows: [CompareReport.Row] = []
    @State private var status = ""
    @State private var position = 0
    @State private var working = true

    private var labelWidth: CGFloat { 210 }

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.gap) {
            Panel {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(Array((rows + roleRows).enumerated()), id: \.offset) { _, row in
                                rowView(row)
                            }
                        } header: {
                            header
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                if working { ProgressView().controlSize(.small) }
                FootNote(text: working ? "Comparing..." : status)
            }
        }
        .padding(Metric.gutter)
        .frame(minWidth: 620, minHeight: 500)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if report.offersRoles {
                    Picker(CompareReport.rolePositionLabel, selection: $position) {
                        ForEach(Array(Names.positions.enumerated()), id: \.offset) { index, name in
                            Text(name).tag(index)
                        }
                    }
                    .help(CompareReport.rolePositionLabel)
                }
                Button(CompareReport.saveButton) {
                    model.saveAsShortlist(report.people, isStaff: report.people.first is Staff, name: CompareReport.shortlistName)
                }
            }
        }
        .task(id: model.analysisVersion) { await load() }
        .task(id: position) { await loadRoles() }
        .onAppear { position = report.startingRolePosition }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("").frame(width: labelWidth, alignment: .leading)
            ForEach(Array(report.people.enumerated()), id: \.offset) { _, person in
                Text(person.name)
                    .font(.headline)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.openProfile(person) }
                    .help("Double-click for the full profile")
            }
        }
        .padding(.horizontal, Metric.inset)
        .padding(.vertical, 10)
        .background(colors.ui.panel)
        .overlay(alignment: .bottom) { colors.ui.line.frame(height: 1) }
    }

    @ViewBuilder
    private func rowView(_ row: CompareReport.Row) -> some View {
        if row.isSection {
            Text(row.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(colors.ui.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metric.inset)
                .padding(.top, 12)
                .padding(.bottom, 4)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.label)
                    .foregroundStyle(row.hidden ? colors.ui.hidden : colors.ui.text)
                    .frame(width: labelWidth, alignment: .leading)
                ForEach(Array(row.cells.enumerated()), id: \.offset) { index, text in
                    let best = index < row.best.count && row.best[index]
                    Text(starred: text, color: best ? colors.good : colors.star)
                        .monospacedDigit()
                        .fontWeight(best ? .semibold : .regular)
                        .foregroundStyle(best ? colors.ui.good : colors.ui.text)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, Metric.inset)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) { colors.ui.line.frame(height: 1) }
        }
    }

    private func load() async {
        working = true
        let report = report
        rows = await offMain { report.rows() }
        if !report.offersRoles { status = CompareReport.staffStatus }
        working = false
    }

    private func loadRoles() async {
        guard report.offersRoles else { return }
        let report = report, position = position
        let answer = await offMain { report.roleRows(position: position) }
        roleRows = answer.rows
        // The engine is there but had no answer: say what that means here.
        status = answer.rows.isEmpty && GameRules.engine != nil ? "Green = the best in that row. Role stars: not available on this version." : answer.status
        if !model.seasonStatsAvailable { status += " Season stats: not available on this version." }
    }
}
