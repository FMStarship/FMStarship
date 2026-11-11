import AppKit
import StarshipAnalysis
import StarshipCore
import SwiftUI

/// SwiftUI has a `TableRow` of its own.
typealias ReportRow = StarshipAnalysis.TableRow

/// Shows an `AnalysisTable`. Every column gets the width of its longest text, a long sentence wraps rather than
/// shortens, and a table that still can't fit scrolls sideways: nothing is ever cut off.
struct AnalysisGrid: NSViewRepresentable {
    var table: AnalysisTable
    /// Goes up when `table` is replaced.
    var version: Int
    var colors = AppColors()
    /// The row and its index in `table.rows`, which sorting doesn't change.
    var onOpen: (ReportRow, Int) -> Void = { _, _ in }
    var onSelection: ([Int]) -> Void = { _ in }
    var menuItems: ([Person]) -> [MenuEntry] = { _ in [] }
    /// Shown at its full height on a page that scrolls, so the wheel goes to the page.
    var fitted = false
    /// Everything's height, heading included, once it's known.
    var onHeight: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let (grid, scroll) = GridStyle.makeTable()
        let coordinator = context.coordinator
        grid.rowHeight = Coordinator.baseRow
        grid.allowsColumnReordering = false
        grid.columnAutoresizingStyle = .noColumnAutoresizing
        grid.dataSource = coordinator
        grid.delegate = coordinator
        grid.target = coordinator
        grid.doubleAction = #selector(Coordinator.doubleClicked)
        grid.onCopy = { [weak coordinator] in coordinator?.copySelection() }
        grid.onReturn = { [weak coordinator] in coordinator?.openSelection() }
        let menu = NSMenu()
        menu.delegate = coordinator
        grid.menu = menu
        coordinator.grid = grid
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.fillWidth),
                                               name: NSView.frameDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        (scroll as? GridScrollView)?.passesScrolling = fitted
        if coordinator.colors != colors || !coordinator.colorsApplied, let grid = coordinator.grid {
            coordinator.colors = colors
            coordinator.colorsApplied = true
            GridStyle.apply(colors, to: grid)
            grid.reloadData()
        }
        if coordinator.version != version {
            coordinator.version = version
            coordinator.show(table)
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        private static let cellID = NSUserInterfaceItemIdentifier("cell")
        private static let wrappedID = NSUserInterfaceItemIdentifier("wrapped")
        static let baseRow: CGFloat = 26
        private static let rowPadding: CGFloat = 10
        private static let plain = NSFont.systemFont(ofSize: 12)
        private static let bold = NSFont.boldSystemFont(ofSize: 12)
        private static let number = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        private static let boldNumber = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        private static let pillFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        /// A status short enough for this goes in a pill. Anything longer is a sentence.
        private static let pillsUpTo: CGFloat = 200
        /// Text this wide or wider may wrap, down to the narrowest width worth reading.
        private static let wrapsAbove: CGFloat = 100
        private static let narrowestWrap: CGFloat = 84
        /// The reasons behind a status are sentences: they get room before anything else has to wrap.
        private static let narrowestReason: CGFloat = 230
        /// Names stay on one line: they're how you tell the rows apart.
        private static let keptWhole: Set<String> = ["Name", "Player", "Tactic", "Shape", "Fit", "Your pick"]
        /// Mostly numbers: lined up on the right.
        private static let numberCell = try? NSRegularExpression(pattern: "^[-+−–]?[^\\d\\s]{0,3}[\\d.,]+[%KMkm★]*$")

        var parent: AnalysisGrid?
        weak var grid: GridTableView?
        var version = -1
        var colors = AppColors()
        var colorsApplied = false
        private var table = AnalysisTable()
        /// Display order, as indexes into `table.rows`.
        private var order: [Int] = []
        private var sortColumn: Int?
        private var sortDescending = false
        private let menus = MenuBuilder()
        private var settingWidths = false
        /// Once you drag a column, the grid stops fitting the window and leaves your widths alone.
        private var widthsAreYours = false
        /// What each column's longest text takes.
        private var needed: [CGFloat] = []
        /// What it can get by on: the same, unless it wraps.
        private var narrowest: [CGFloat] = []
        private var wraps: [Bool] = []
        private var numeric: [Bool] = []
        private var pills: [Bool] = []
        private var reportedHeight: CGFloat = 0
        /// By index into `table.rows`.
        private var heights: [CGFloat] = []

        func show(_ newTable: AnalysisTable) {
            guard let grid else { return }
            let sameColumns = newTable.columns == table.columns
            // Changing columns redraws, and nothing may be drawn from the old order against the new rows.
            order = []
            grid.deselectAll(nil)
            grid.reloadData()
            table = newTable
            if !sameColumns {
                sortColumn = nil
                widthsAreYours = false
                for column in grid.tableColumns { grid.removeTableColumn(column) }
                for (index, column) in table.columns.enumerated() {
                    let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
                    tableColumn.minWidth = 24
                    tableColumn.headerToolTip = column.title
                    grid.addTableColumn(tableColumn)
                }
            }
            measure()
            if !sameColumns {
                for (index, tableColumn) in grid.tableColumns.enumerated() {
                    GridStyle.header(tableColumn, title: table.columns[index].title, alignment: numeric[index] ? .right : .left,
                                     first: index == 0, colors: colors)
                }
            }
            sortRows()
            grid.reloadData()
            fillWidth()
        }

        private func measure() {
            func width(_ text: String, _ font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
            needed = []
            narrowest = []
            wraps = []
            numeric = []
            pills = []
            let margin = GridStyle.cellMargins
            for column in table.columns.indices {
                let title = width(table.columns[column].title, GridHeaderCell.font) + GridHeaderCell.arrowRoom
                var longest = title, longestWord = title
                var numbers = 0, filled = 0, spaced = false
                var longestStatus: CGFloat = 0, hasStatus = false
                for row in table.rows where column < row.cells.count {
                    let text = row.cells[column]
                    guard !text.isEmpty else { continue }
                    filled += 1
                    if Self.numberCell?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { numbers += 1 }
                    let each = width(text, row.bold ? Self.bold : Self.plain) + (StarArt.hasStars(text) ? 6 : 0)
                    longest = max(longest, each)
                    if row.toneColumn == column {
                        hasStatus = true
                        longestStatus = max(longestStatus, each)
                    }
                    if each > Self.wrapsAbove, text.contains(" "), !Self.keptWhole.contains(table.columns[column].title) { spaced = true }
                    for word in text.split(separator: " ") { longestWord = max(longestWord, width(String(word), row.bold ? Self.bold : Self.plain)) }
                }
                let lead = column == 0 ? GridStyle.firstColumnInset : 0
                let isNumber = filled > 0 && numbers * 5 >= filled * 4
                let isPill = hasStatus && !isNumber && longestStatus <= Self.pillsUpTo
                if isPill { longest += GridCell.pillPadding * 2 }
                needed.append(longest.rounded(.up) + margin + lead)
                let isReason = table.rows.contains { $0.quietColumn == column }
                let wrapped = min(longest, max(longestWord, isReason ? Self.narrowestReason : Self.narrowestWrap))
                narrowest.append((spaced && !isPill ? wrapped : longest).rounded(.up) + margin + lead)
                wraps.append(spaced && !isPill)
                numeric.append(isNumber)
                pills.append(isPill)
            }
        }

        /// Spare room goes to the columns of words. When it's tight the sentences give way by wrapping, the longest
        /// first; if the numbers alone don't fit, the table scrolls sideways.
        @objc func fillWidth() {
            guard let grid, !widthsAreYours, let width = grid.enclosingScrollView?.contentSize.width, width > 0,
                  !needed.isEmpty, needed.count == grid.tableColumns.count else { return }
            let room = width - grid.intercellSpacing.width * CGFloat(needed.count)
            let total = needed.reduce(0, +)
            var widths = needed
            if total <= room {
                let takers = needed.indices.filter { !numeric[$0] }
                let shares = takers.isEmpty ? Array(needed.indices) : takers
                let weights = CGFloat(max(1, shares.reduce(0) { $0 + table.columns[$1].weight }))
                for index in shares { widths[index] += (room - total) * CGFloat(table.columns[index].weight) / weights }
            } else {
                func capped(_ cap: CGFloat) -> [CGFloat] {
                    needed.indices.map { wraps[$0] ? max(narrowest[$0], min(needed[$0], cap)) : needed[$0] }
                }
                var low: CGFloat = 24, high = needed.max() ?? 24
                for _ in 0..<24 {
                    let cap = (low + high) / 2
                    if capped(cap).reduce(0, +) > room { high = cap } else { low = cap }
                }
                widths = capped(low)
            }
            settingWidths = true
            for (column, each) in zip(grid.tableColumns, widths) { column.width = max(column.minWidth, each.rounded(.down)) }
            settingWidths = false
            measureHeights()
        }

        private func measureHeights() {
            guard let grid else { return }
            let widths = grid.tableColumns.map(\.width)
            let wrapping = wraps.indices.filter { wraps[$0] && $0 < widths.count }
            heights = table.rows.map { row in
                var tallest = Self.baseRow
                for column in wrapping where column < row.cells.count {
                    let lead = column == 0 ? GridStyle.firstColumnInset : 0
                    let box = NSSize(width: widths[column] - GridStyle.cellMargins - lead, height: .greatestFiniteMagnitude)
                    let text = StarArt.attributed(row.cells[column], attributes: [.font: row.bold ? Self.bold : Self.plain], color: colors.star)
                    let height = text.boundingRect(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading]).height
                    tallest = max(tallest, height.rounded(.up) + Self.rowPadding)
                }
                return tallest
            }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            grid.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<grid.numberOfRows))
            NSAnimationContext.endGrouping()
            let total = heights.reduce(GridStyle.headerHeight, +)
            guard total != reportedHeight else { return }
            reportedHeight = total
            DispatchQueue.main.async { [weak self] in self?.parent?.onHeight(total) }
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < order.count, order[row] < heights.count else { return Self.baseRow }
            return heights[order[row]]
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard !settingWidths else { return }
            widthsAreYours = true
            measureHeights()
        }

        private func sortRows() {
            guard let column = sortColumn else {
                order = Array(table.rows.indices)
                return
            }
            order = table.sortedIndices(byColumn: column, descending: sortDescending)
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let grid, let column = Int(tableColumn.identifier.rawValue) else { return }
            if sortColumn == column {
                sortDescending.toggle()
            } else {
                sortColumn = column
                sortDescending = false
            }
            sortRows()
            grid.reloadData()
            for each in grid.tableColumns { GridStyle.sort(each, ascending: each === tableColumn ? !sortDescending : nil) }
            grid.headerView?.needsDisplay = true
        }

        func numberOfRows(in tableView: NSTableView) -> Int { order.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            GridStyle.rowView(tableView, row: row, colors: colors)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Int(tableColumn.identifier.rawValue), row < order.count,
                  order[row] < table.rows.count else { return nil }
            let item = table.rows[order[row]]
            let wrapped = column < wraps.count && wraps[column]
            let label = GridStyle.label(tableView, wrapped ? Self.wrappedID : Self.cellID, first: column == 0, wraps: wrapped)
            let text = column < item.cells.count ? item.cells[column] : ""
            let isNumber = column < numeric.count && numeric[column]
            let toned = item.toneColumn.map { $0 == column } ?? true
            let isPill = column < pills.count && pills[column]
            // In a column of pills, a row with nothing to flag still gets a quiet one.
            let color = isPill ? colors.row(item.toneColumn != column || item.tone == nil || item.tone == .text ? .muted : item.tone)
                : item.quietColumn == column ? colors.muted : colors.row(toned ? item.tone : nil)
            label.toolTip = text.isEmpty ? nil : text
            label.alignment = isNumber ? .right : .left
            label.font = isPill ? Self.pillFont : isNumber ? (item.bold ? Self.boldNumber : Self.number) : (item.bold ? Self.bold : Self.plain)
            label.textColor = color
            (label.cell as? GridCell)?.pill = isPill ? color : nil
            GridStyle.show(text, in: label, starColor: toned && item.tone != nil ? color : colors.star)
            return label
        }

        private var selected: [Int] {
            guard let grid else { return [] }
            return grid.selectedRowIndexes.compactMap { $0 < order.count ? order[$0] : nil }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            let chosen = selected
            DispatchQueue.main.async { [weak self] in self?.parent?.onSelection(chosen) }
        }

        @objc func doubleClicked() {
            guard let grid, grid.clickedRow >= 0, grid.clickedRow < order.count else { return }
            let index = order[grid.clickedRow]
            parent?.onOpen(table.rows[index], index)
        }

        func openSelection() {
            if let index = selected.first { parent?.onOpen(table.rows[index], index) }
        }

        func copySelection() {
            let chosen = selected
            guard !chosen.isEmpty else { return }
            var lines = [table.columns.map(\.title).joined(separator: "\t")]
            lines += chosen.map { table.rows[$0].cells.joined(separator: "\t") }
            GridStyle.copyToPasteboard(lines.joined(separator: "\n"))
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let parent, let grid, grid.clickedRow >= 0, grid.clickedRow < order.count else {
                menu.removeAllItems()
                return
            }
            if !grid.selectedRowIndexes.contains(grid.clickedRow) {
                grid.selectRowIndexes(IndexSet(integer: grid.clickedRow), byExtendingSelection: false)
            }
            let people = selected.compactMap { table.rows[$0].person }
            if people.isEmpty {
                menu.removeAllItems()
            } else {
                menus.fill(menu, with: parent.menuItems(people))
            }
        }
    }
}
