import StarshipAnalysis
import StarshipCore
import SwiftUI

/// What the analysis screens have in common: their controls, the answer in a sentence, the grid and its small
/// print. When the game couldn't narrow the list the screen says so here, in one place.
struct ReportPane<Controls: View, Actions: View>: View {
    @EnvironmentObject private var model: AppModel

    var table: AnalysisTable?
    var version: Int
    var exportTitle: String
    /// Replaces the usual "open the profile" for a double-click.
    var onOpen: ((ReportRow, Int) -> Void)?
    var onSelection: (([Int]) -> Void)?
    @ViewBuilder var controls: () -> Controls
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.gap) {
            ControlBar(leading: controls) {
                actions()
                Button("Export...") { if let table { model.exportTable(table, title: exportTitle) } }
                    .disabled(table?.rows.isEmpty ?? true)
            }
            if let table {
                ReportGrid(table: table, version: version, onOpen: onOpen, onSelection: onSelection)
                if !table.status.isEmpty { FootNote(text: table.status) }
            } else {
                Panel { SkeletonRows() }
                Spacer(minLength: 0)
            }
        }
        .padding(Metric.gutter)
    }
}

extension ReportPane where Actions == EmptyView {
    init(table: AnalysisTable?, version: Int, exportTitle: String, onOpen: ((ReportRow, Int) -> Void)? = nil,
         onSelection: (([Int]) -> Void)? = nil, @ViewBuilder controls: @escaping () -> Controls) {
        self.init(table: table, version: version, exportTitle: exportTitle, onOpen: onOpen, onSelection: onSelection,
                  controls: controls, actions: { EmptyView() })
    }
}

/// The head line, the "couldn't be narrowed" warning and the grid itself.
struct ReportGrid: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appColors) private var colors

    var table: AnalysisTable
    var version: Int
    var title: String?
    /// Inside a panel that's already there.
    var bare = false
    /// At its full height, for a page that scrolls.
    var fitted = false
    var onOpen: ((ReportRow, Int) -> Void)?
    var onSelection: (([Int]) -> Void)?
    @State private var height: CGFloat?

    /// Near enough until the grid has measured its rows.
    private var estimate: CGFloat { CGFloat(table.rows.count + 1) * 26 }

    var body: some View {
        if bare {
            grid
        } else {
            VStack(alignment: .leading, spacing: Metric.gap) {
                if !table.head.isEmpty { LeadLine(text: table.head) }
                if !table.interestChecked {
                    NotNarrowedBanner(text: "Whether they would join could not be checked here, so the game has not narrowed this list. Treat it as a list of candidates, not of people who would come.")
                }
                Panel(title: title) { grid }
            }
        }
    }

    private var grid: some View {
        AnalysisGrid(table: table, version: version, colors: colors,
                     onOpen: { row, index in
                         if let onOpen {
                             onOpen(row, index)
                         } else if let person = row.person {
                             model.openProfile(person)
                         }
                     },
                     onSelection: { indexes in
                         onSelection?(indexes)
                         model.selection = indexes.compactMap { $0 < table.rows.count ? table.rows[$0].person : nil }
                     },
                     menuItems: { model.menuItems(for: $0) },
                     fitted: fitted,
                     onHeight: { height = $0 })
            .frame(height: fitted ? height ?? estimate : nil)
    }
}

/// A small box with its label in front, and Return to act on it.
struct LabeledBox: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    var width: CGFloat = 80
    var onSubmit: () -> Void = {}

    init(_ label: String, text: Binding<String>, prompt: String = "", width: CGFloat = 80, onSubmit: @escaping () -> Void = {}) {
        self.label = label
        _text = text
        self.prompt = prompt
        self.width = width
        self.onSubmit = onSubmit
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .onSubmit(onSubmit)
        }
        .fixedSize()
    }
}
