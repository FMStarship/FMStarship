import AppKit
import StarshipCore
import StarshipSearch
import SwiftUI

/// The normal table with everything around it. Players, Staff, Open squad and Shortlists all use it, so they
/// all get the same filters, columns and menus.
struct PeopleList: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appColors) private var colors
    let isStaff: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.gap) {
            FilterStrip(isStaff: isStaff)
            Panel {
                if isStaff {
                    table(rows: model.staff, columns: model.staffColumns, sort: model.staffSort)
                } else {
                    table(rows: model.players, columns: model.playerColumns, sort: model.playerSort)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                FootNote(text: model.status)
                if model.searching { ProgressView().controlSize(.small) }
                Text("\(model.rowsShown.formatted()) shown")
                    .font(.callout)
                    .foregroundStyle(colors.ui.muted)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
    }

    private func table(rows: [Person], columns: [Col], sort: AppModel.SortState) -> some View {
        PeopleTable(rows: rows, rowsVersion: model.rowsVersion, columns: columns,
                    layoutVersion: model.columnsVersion, cellsVersion: model.cellsVersion,
                    reveal: model.shownReveal, colors: colors,
                    sortColumn: sort.column, sortDescending: sort.descending,
                    onSort: { model.sort(by: $0) },
                    onOpen: { model.openProfile($0) },
                    onSelection: { model.selection = $0 },
                    menuItems: { model.menuItems(for: $0) },
                    onPendingCell: { model.cellNeedsCheck($0, $1) },
                    onLayout: { model.columnsLaidOut(staff: isStaff, order: $0, widths: $1) },
                    columnFilter: { model.columnFilter($0, staff: isStaff) },
                    setColumnFilter: { model.setColumnFilter($0, $1, staff: isStaff) },
                    onHideColumn: { model.hideColumn($0, staff: isStaff) },
                    onChooseColumns: { model.editingColumns = true })
    }
}

/// What's narrowing the list, and when the game couldn't be asked, saying so.
private struct FilterStrip: View {
    @EnvironmentObject private var model: AppModel
    let isStaff: Bool

    var body: some View {
        let summary = model.filterSummary
        // Only what's applying: a filter on a column that's gone waits until the column is back.
        let shown = isStaff ? model.staffColumns : model.playerColumns
        let columnFilters = (isStaff ? model.staffColumnFilters : model.playerColumnFilters)
            .filter { filter in shown.contains { $0.name == filter.key } }
            .sorted { $0.key < $1.key }
        VStack(alignment: .leading, spacing: 8) {
            if let reason = model.interestUnavailable {
                NotNarrowedBanner(text: "\"Would join\" is ticked, but this list could not be narrowed by the game. \(reason)")
            }
            if model.unanswered > 0 {
                NotNarrowedBanner(text: "The game gave no answer for \(model.unanswered.formatted()) of these, so they are left out rather than guessed.")
            }
            if !summary.isEmpty || !columnFilters.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Flow(spacing: 6, lineSpacing: 4) {
                        if !summary.isEmpty {
                            Text(summary).help(summary)
                        }
                        ForEach(columnFilters, id: \.key) { name, text in
                            Pill(text: "\(name): \(text)", tone: .muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !columnFilters.isEmpty {
                        Button("Clear column filters") { model.clearColumnFilters() }.buttonStyle(.link).fixedSize()
                    }
                    if !summary.isEmpty, model.screen != .openSquad {
                        Button("Reset filters") { model.resetFilters() }.buttonStyle(.link).fixedSize()
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// The honest line above a list the game couldn't narrow.
struct NotNarrowedBanner: View {
    @Environment(\.appColors) private var colors
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(colors.ui.fair)
            Text(text)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(colors.ui.fair.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The toolbar's search field. An AppKit one, because it can be given the keyboard focus for Cmd-F on macOS 14.
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    /// Goes up to ask for the keyboard.
    var focus: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search by name"
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focus != focus {
            context.coordinator.focus = focus
            field.window?.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ToolbarSearchField
        var focus: Int

        init(_ parent: ToolbarSearchField) {
            self.parent = parent
            focus = parent.focus
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
    }
}
