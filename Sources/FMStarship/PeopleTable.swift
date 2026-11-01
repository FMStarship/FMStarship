import AppKit
import StarshipCore
import StarshipSearch
import SwiftUI

/// The main grid. AppKit's table handles tens of thousands of rows and user-chosen columns with ease.
struct PeopleTable: NSViewRepresentable {
    typealias MenuItem = MenuEntry

    var rows: [Person]
    var rowsVersion: Int
    var columns: [Col]
    /// Goes up when widths or order change other than by dragging in this table.
    var layoutVersion = 0
    /// Goes up when answers arrive for rows already on screen.
    var cellsVersion = 0
    var reveal: Reveal
    var colors = AppColors()
    var sortColumn: String?
    var sortDescending: Bool
    var onSort: (String) -> Void = { _ in }
    var onOpen: (Person) -> Void = { _ in }
    var onSelection: ([Person]) -> Void = { _ in }
    var menuItems: ([Person]) -> [MenuItem] = { _ in [] }
    /// A cell that needs the game to answer: Days out, and Interest on rows not yet asked about.
    var onPendingCell: (Person, Col) -> Void = { _, _ in }
    var onLayout: (_ order: [String], _ widths: [String: Int]) -> Void = { _, _ in }
    var columnFilter: (Col) -> String = { _ in "" }
    var setColumnFilter: (Col, String) -> Void = { _, _ in }
    var onHideColumn: (Col) -> Void = { _ in }
    var onChooseColumns: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let (table, scroll) = GridStyle.makeTable()
        let coordinator = context.coordinator
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.onCopy = { [weak coordinator] in coordinator?.copySelection() }
        table.onReturn = { [weak coordinator] in coordinator?.openSelection() }

        let rowMenu = NSMenu()
        rowMenu.delegate = coordinator
        table.menu = rowMenu
        let header = GridHeaderView(frame: table.headerView?.frame ?? .zero)
        let headerMenu = NSMenu()
        headerMenu.delegate = coordinator
        header.menu = headerMenu
        table.headerView = header

        coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let table = coordinator.table else { return }

        if coordinator.colors != colors || !coordinator.colorsApplied {
            coordinator.colors = colors
            coordinator.colorsApplied = true
            GridStyle.apply(colors, to: table)
            coordinator.columnNames = []
        }

        let names = columns.map(\.name)
        if names != coordinator.columnNames || layoutVersion != coordinator.layoutVersion {
            coordinator.columnNames = names
            coordinator.layoutVersion = layoutVersion
            coordinator.rebuildColumns(columns)
            coordinator.show(rows, append: false)
        } else if rowsVersion != coordinator.rowsVersion {
            coordinator.show(rows, append: true)
        } else if reveal != coordinator.reveal {
            coordinator.show(rows, append: false)
        } else if cellsVersion != coordinator.cellsVersion {
            coordinator.refreshVisibleRows()
        }
        coordinator.rowsVersion = rowsVersion
        coordinator.reveal = reveal
        coordinator.cellsVersion = cellsVersion

        for column in table.tableColumns {
            GridStyle.sort(column, ascending: column.identifier.rawValue == sortColumn ? !sortDescending : nil)
        }
        table.headerView?.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        private static let cellID = NSUserInterfaceItemIdentifier("cell")
        private static let textFont = NSFont.systemFont(ofSize: 12)
        private static let boldFont = NSFont.boldSystemFont(ofSize: 12)
        private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        private static let boldNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)

        var parent: PeopleTable?
        weak var table: GridTableView?
        var columnNames: [String] = []
        var columnsByName: [String: Col] = [:]
        var rowsVersion = -1
        var layoutVersion = -1
        var cellsVersion = 0
        var reveal: Reveal = .exact
        var colors = AppColors()
        var colorsApplied = false
        private var rows: [Person] = []
        private var rebuilding = false
        private let menus = MenuBuilder()
        private var filterPopover: NSPopover?
        /// Widths are fitted once for each set of rows the table is given, then left to you.
        private var fittedFor: ObjectIdentifier?
        /// How many rows, spread through the list, stand for the whole of it.
        private static let fitSample = 3000
        private static let widestFit: CGFloat = 340
        private static let spareWidth: CGFloat = 16

        // MARK: Columns

        func rebuildColumns(_ columns: [Col]) {
            guard let table else { return }
            rebuilding = true
            defer { rebuilding = false }
            columnsByName = Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            for column in table.tableColumns { table.removeTableColumn(column) }
            for (index, col) in columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.name))
                column.width = CGFloat(max(col.width, 28))
                column.minWidth = 24
                column.headerToolTip = col.toolTip
                GridStyle.header(column, title: col.header, alignment: col.numeric ? .right : .left, first: index == 0, colors: colors,
                                 titleColor: col.hidden ? colors.hidden : nil)
                table.addTableColumn(column)
            }
            fittedFor = nil
        }

        private func layoutChanged() {
            guard !rebuilding else { return }
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(reportLayout), object: nil)
            perform(#selector(reportLayout), with: nil, afterDelay: 0.4)
        }

        @objc private func reportLayout() {
            guard let table else { return }
            let order = table.tableColumns.map(\.identifier.rawValue)
            var widths: [String: Int] = [:]
            for column in table.tableColumns { widths[column.identifier.rawValue] = Int(column.width) }
            columnNames = order
            parent?.onLayout(order, widths)
        }

        func tableViewColumnDidResize(_ notification: Notification) { layoutChanged() }
        func tableViewColumnDidMove(_ notification: Notification) { layoutChanged() }

        // MARK: Rows

        /// Rows arrive in growing lists during an interest check, so a list that only got longer keeps its
        /// scroll position and selection without a reload. Otherwise the selection follows the people in it.
        func show(_ newRows: [Person], append: Bool) {
            guard let table else { return }
            let extended = append && !rows.isEmpty && newRows.count >= rows.count
                && newRows[rows.count - 1] === rows[rows.count - 1]
            if extended {
                rows = newRows
                table.noteNumberOfRowsChanged()
                return
            }
            let selected = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? ObjectIdentifier(rows[$0]) : nil })
            rows = newRows
            fitOnce()
            table.reloadData()
            guard !selected.isEmpty else { return }
            var indexes = IndexSet()
            for (index, person) in rows.enumerated() where selected.contains(ObjectIdentifier(person)) { indexes.insert(index) }
            table.selectRowIndexes(indexes, byExtendingSelection: false)
        }

        /// A column saved too narrow would cut off what's in it, and one far too wide pushes others off the screen,
        /// so each one is fitted to its longest text in a sample of the rows, with a little to spare.
        private func fitOnce() {
            guard let table, let parent, let first = rows.first, fittedFor != ObjectIdentifier(first) else { return }
            fittedFor = ObjectIdentifier(first)
            let step = max(1, rows.count / Self.fitSample)
            let sample = stride(from: 0, to: rows.count, by: step).map { rows[$0] }
            rebuilding = true
            defer { rebuilding = false }
            for (index, column) in table.tableColumns.enumerated() {
                guard let col = columnsByName[column.identifier.rawValue] else { continue }
                var width = (col.header as NSString).size(withAttributes: [.font: GridHeaderCell.font]).width + GridHeaderCell.arrowRoom
                // Measuring text is slow and counting it isn't, so only the longest get measured.
                var longest = 0
                for person in sample {
                    let cell = col.cell(person, reveal: parent.reveal)
                    guard cell.text.utf16.count >= longest else { continue }
                    longest = cell.text.utf16.count
                    let font = col.numeric ? Self.numberFont : Self.textFont
                    width = max(width, (cell.text as NSString).size(withAttributes: [.font: cell.bold ? Self.boldFont : font]).width)
                }
                let lead = index == 0 ? GridStyle.firstColumnInset : 0
                let fitted = min(width.rounded(.up) + GridStyle.cellMargins + lead, Self.widestFit)
                column.width = min(max(column.width, fitted), fitted + Self.spareWidth)
            }
        }

        func refreshVisibleRows() {
            guard let table, !rows.isEmpty else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            table.reloadData(forRowIndexes: IndexSet(integersIn: visible.lowerBound..<visible.upperBound),
                             columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            GridStyle.rowView(tableView, row: row, colors: colors)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let parent, let tableColumn, row < rows.count, let col = columnsByName[tableColumn.identifier.rawValue] else { return nil }
            let label = GridStyle.label(tableView, Self.cellID, first: tableView.column(withIdentifier: tableColumn.identifier) == 0)
            let person = rows[row]
            let cell = col.cell(person, reveal: parent.reveal)
            label.toolTip = cell.text.isEmpty ? nil : cell.text
            label.alignment = col.numeric ? .right : .left
            label.font = col.numeric ? (cell.bold ? Self.boldNumberFont : Self.numberFont)
                                     : (cell.bold ? Self.boldFont : Self.textFont)
            label.textColor = colors.cell(cell.tone, hidden: col.hidden)
            GridStyle.show(cell.text, in: label, starColor: colors.star)
            if cell.pending || (col.name == "Interest" && cell.text.isEmpty) { parent.onPendingCell(person, col) }
            return label
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            parent?.onSort(tableColumn.identifier.rawValue)
        }

        private var selectedPeople: [Person] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            let chosen = selectedPeople
            // This can fire from inside a SwiftUI update, which must not publish changes.
            DispatchQueue.main.async { [weak self] in self?.parent?.onSelection(chosen) }
        }

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
            parent?.onOpen(rows[table.clickedRow])
        }

        func openSelection() {
            if let person = selectedPeople.first { parent?.onOpen(person) }
        }

        func copySelection() {
            guard let table, let parent, !selectedPeople.isEmpty else { return }
            let columns = table.tableColumns.compactMap { columnsByName[$0.identifier.rawValue] }
            var lines = [columns.map(\.header).joined(separator: "\t")]
            for person in selectedPeople {
                lines.append(columns.map { $0.cell(person, reveal: parent.reveal).text }.joined(separator: "\t"))
            }
            GridStyle.copyToPasteboard(lines.joined(separator: "\n"))
        }

        // MARK: Menus

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let table else { return }
            if menu === table.headerView?.menu {
                fillHeaderMenu(menu)
                return
            }
            guard let parent, table.clickedRow >= 0, table.clickedRow < rows.count else {
                menu.removeAllItems()
                return
            }
            if !table.selectedRowIndexes.contains(table.clickedRow) {
                table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
            }
            menus.fill(menu, with: parent.menuItems(selectedPeople))
        }

        private func fillHeaderMenu(_ menu: NSMenu) {
            guard let table, let parent else { return }
            let index = (table.headerView as? GridHeaderView)?.menuColumn ?? -1
            guard index >= 0, index < table.tableColumns.count,
                  let col = columnsByName[table.tableColumns[index].identifier.rawValue] else {
                menus.fill(menu, with: [MenuEntry("Columns...", action: parent.onChooseColumns)])
                return
            }
            var entries = [MenuEntry("Filter \"\(col.name)\"...") { [weak self] in self?.showFilter(col, at: index) }]
            if !parent.columnFilter(col).isEmpty {
                entries.append(MenuEntry("Clear this filter") { [weak self] in self?.parent?.setColumnFilter(col, "") })
            }
            entries += [
                .separator,
                MenuEntry("Size this column to fit") { [weak self] in self?.fit(index) },
                MenuEntry("Size all columns to fit window") { [weak self] in self?.fitToWindow() },
                MenuEntry("Size all columns to contents") { [weak self] in self?.fitAllToContents() },
                .separator,
                MenuEntry("Hide \"\(col.name)\"") { [weak self] in self?.parent?.onHideColumn(col) },
                MenuEntry("Columns...", action: parent.onChooseColumns),
            ]
            menus.fill(menu, with: entries)
        }

        private func showFilter(_ col: Col, at index: Int) {
            guard let table, let header = table.headerView, let parent else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: ColumnFilterEditor(
                column: col, text: parent.columnFilter(col),
                apply: { [weak self] in self?.parent?.setColumnFilter(col, $0) },
                close: { [weak popover] in popover?.close() }))
            filterPopover = popover
            popover.show(relativeTo: header.headerRect(ofColumn: index), of: header, preferredEdge: .maxY)
        }

        private func contentWidth(_ col: Col) -> CGFloat {
            guard let table, let parent else { return CGFloat(col.width) }
            var width = (col.header as NSString).size(withAttributes: [.font: GridHeaderCell.font]).width + GridHeaderCell.arrowRoom
            let visible = table.rows(in: table.visibleRect)
            let start = min(visible.location, rows.count)
            for person in rows[start..<min(start + 200, rows.count)] {
                let text = col.cell(person, reveal: parent.reveal).text as NSString
                width = max(width, text.size(withAttributes: [.font: Self.textFont]).width + 12)
            }
            return min(width.rounded(.up), 420)
        }

        private func fit(_ index: Int) {
            guard let table, index < table.tableColumns.count else { return }
            let column = table.tableColumns[index]
            if let col = columnsByName[column.identifier.rawValue] { column.width = contentWidth(col) }
        }

        private func fitAllToContents() {
            guard let table else { return }
            for index in table.tableColumns.indices { fit(index) }
        }

        private func fitToWindow() {
            guard let table, let width = table.enclosingScrollView?.contentSize.width else { return }
            let spacing = table.intercellSpacing.width * CGFloat(table.tableColumns.count)
            let total = table.tableColumns.reduce(0) { $0 + $1.width }
            guard total > 0 else { return }
            let scale = max(1, width - spacing) / total
            for column in table.tableColumns { column.width = max(column.minWidth, (column.width * scale).rounded(.down)) }
        }
    }
}

/// The popover from a column header's "Filter" item.
struct ColumnFilterEditor: View {
    let column: Col
    @State var text: String
    let apply: (String) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Filter \(column.name)").font(.headline)
            TextField(column.numeric ? "e.g. 15, 10-20 or <=5" : "Contains...", text: $text)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text) { apply(text) }
                .onSubmit(close)
            if column.numeric {
                Text("A number means at least. Also \"10-20\", \"<=5\", \"<5\", \"=5\".")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Clear") {
                    text = ""
                    close()
                }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 250)
    }
}
