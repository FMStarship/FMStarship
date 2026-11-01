import AppKit

/// Both grids in the app share this: rows that light up under the mouse, Return to open, Cmd-C to copy.
final class GridTableView: NSTableView {
    var onCopy: (() -> Void)?
    var onReturn: (() -> Void)?
    private(set) var hoveredRow = -1
    private var tracking: NSTrackingArea?

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func keyDown(with event: NSEvent) {
        // Return and the keypad's Enter.
        if event.keyCode == 36 || event.keyCode == 76, let onReturn {
            onReturn()
        } else {
            super.keyDown(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hover(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(-1)
    }

    private func hover(_ row: Int) {
        guard row != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = row
        for index in [previous, row] where index >= 0 && index < numberOfRows {
            rowView(atRow: index, makeIfNecessary: false)?.needsDisplay = true
        }
    }
}

/// With a table shown in full there's nothing to scroll here, so the wheel goes to the page around it.
final class GridScrollView: NSScrollView {
    var passesScrolling = false

    override func scrollWheel(with event: NSEvent) {
        if passesScrolling, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Remembers which heading a right-click landed on, for the menu that follows.
final class GridHeaderView: NSTableHeaderView {
    var colors = AppColors()
    private(set) var menuColumn = -1

    override func menu(for event: NSEvent) -> NSMenu? {
        menuColumn = column(at: convert(event.locationInWindow, from: nil))
        return super.menu(for: event)
    }

    /// Past the last column too.
    override func draw(_ dirtyRect: NSRect) {
        colors.panel.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
        colors.line.setFill()
        NSRect(x: dirtyRect.minX, y: bounds.maxY - 1, width: dirtyRect.width, height: 1).fill()
    }
}

/// A quiet heading: small, muted, on the panel's own colour, with the sort direction beside the title.
final class GridHeaderCell: NSTableHeaderCell {
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// Room a heading keeps for its sort arrow.
    static let arrowRoom: CGFloat = 12

    var colors = AppColors()
    var titleColor: NSColor?
    /// Where the first column starts, to line up with the panel's title.
    var inset: CGFloat = 0
    /// Nil when this isn't the sorted column.
    var ascending: Bool?

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        colors.panel.setFill()
        cellFrame.fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let color = titleColor ?? colors.muted
        let title = NSAttributedString(string: stringValue, attributes: [.font: Self.font, .foregroundColor: ascending == nil ? color : colors.text])
        let size = title.size()
        let box = cellFrame.insetBy(dx: 4, dy: 0)
        let right = alignment == .right
        let x = right ? box.maxX - size.width : box.minX + inset
        title.draw(in: NSRect(x: x, y: box.midY - size.height / 2, width: min(size.width, box.width - inset), height: size.height))
        guard let ascending, let arrow = NSImage(systemSymbolName: ascending ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold).applying(.init(hierarchicalColor: colors.text))) else { return }
        let arrowX = right ? x - arrow.size.width - 3 : x + size.width + 3
        arrow.draw(in: NSRect(x: arrowX, y: box.midY - arrow.size.height / 2, width: arrow.size.width, height: arrow.size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// Hairlines rather than stripes, a tint under the mouse, and the palette's selection.
final class ThemedRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("row")

    var colors = AppColors()
    var index = 0

    override func drawBackground(in dirtyRect: NSRect) {
        if (superview as? GridTableView)?.hoveredRow == index {
            colors.hover.setFill()
            bounds.fill()
        }
        colors.line.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        colors.selection.setFill()
        bounds.fill()
    }
}

/// Text in the middle of its row, however tall the row. `inset` lines the first column up with the panel's title.
final class GridCell: NSTextFieldCell {
    static let pillPadding: CGFloat = 8
    private static let pillHeight: CGFloat = 18

    var inset: CGFloat = 0
    /// Puts the text in a small tinted pill of this colour.
    var pill: NSColor?

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        if let pill, !stringValue.isEmpty {
            let text = drawingRect(forBounds: cellFrame)
            let box = NSRect(x: text.minX - Self.pillPadding, y: text.midY - Self.pillHeight / 2,
                             width: min(attributedStringValue.size().width + 4 + Self.pillPadding * 2, cellFrame.width), height: Self.pillHeight)
            pill.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: box, xRadius: Self.pillHeight / 2, yRadius: Self.pillHeight / 2).fill()
        }
        super.draw(withFrame: cellFrame, in: controlView)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var box = super.drawingRect(forBounds: rect)
        let lead = inset + (pill == nil ? 0 : Self.pillPadding)
        box.origin.x += lead
        box.size.width -= lead
        let height = cellSize(forBounds: NSRect(x: 0, y: 0, width: box.width, height: .greatestFiniteMagnitude)).height
        if height < box.height {
            box.origin.y += ((box.height - height) / 2).rounded(.down)
            box.size.height = height
        }
        return box
    }
}

enum GridStyle {
    /// Where a table's first column starts, level with its panel's title.
    static let firstColumnInset: CGFloat = 10
    static let headerHeight: CGFloat = 28
    /// What a cell loses to its own margins: the cell's two, the gap to the next column.
    static let cellMargins: CGFloat = 6

    static func makeTable() -> (table: GridTableView, scroll: NSScrollView) {
        let table = GridTableView()
        table.style = .plain
        table.allowsMultipleSelection = true
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.cornerView = nil
        let header = GridHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: headerHeight))
        table.headerView = header

        let scroll = GridScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return (table, scroll)
    }

    static func apply(_ colors: AppColors, to table: NSTableView) {
        table.backgroundColor = colors.panel
        (table.headerView as? GridHeaderView)?.colors = colors
        table.headerView?.needsDisplay = true
    }

    static func rowView(_ table: NSTableView, row: Int, colors: AppColors) -> NSTableRowView {
        let view = table.makeView(withIdentifier: ThemedRowView.identifier, owner: nil) as? ThemedRowView ?? ThemedRowView()
        view.identifier = ThemedRowView.identifier
        view.colors = colors
        view.index = row
        return view
    }

    static func header(_ column: NSTableColumn, title: String, alignment: NSTextAlignment, first: Bool, colors: AppColors, titleColor: NSColor? = nil) {
        let cell = GridHeaderCell(textCell: title)
        cell.alignment = alignment
        cell.colors = colors
        cell.titleColor = titleColor
        cell.inset = first ? firstColumnInset : 0
        column.headerCell = cell
    }

    static func sort(_ column: NSTableColumn, ascending: Bool?) {
        (column.headerCell as? GridHeaderCell)?.ascending = ascending
    }

    static func label(_ table: NSTableView, _ identifier: NSUserInterfaceItemIdentifier, first: Bool, wraps: Bool = false) -> NSTextField {
        let label = table.makeView(withIdentifier: identifier, owner: nil) as? NSTextField ?? makeLabel(identifier)
        if let cell = label.cell as? GridCell {
            cell.inset = first ? firstColumnInset : 0
            cell.pill = nil
            cell.wraps = wraps
            cell.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        }
        label.maximumNumberOfLines = wraps ? 0 : 1
        return label
    }

    /// Puts `text` in a cell with its stars drawn. The cell's font, colour and alignment must be set first.
    static func show(_ text: String, in label: NSTextField, starColor: NSColor) {
        guard StarArt.hasStars(text) else {
            label.stringValue = text
            return
        }
        let style = NSMutableParagraphStyle()
        style.alignment = label.alignment
        style.lineBreakMode = label.cell?.lineBreakMode ?? .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: label.font ?? .systemFont(ofSize: 12), .foregroundColor: label.textColor ?? .labelColor,
                                                         .paragraphStyle: style]
        let shown = StarArt.attributed(text, attributes: attributes, color: starColor)
        shown.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: shown.length))
        label.attributedStringValue = shown
    }

    private static func makeLabel(_ identifier: NSUserInterfaceItemIdentifier) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        let cell = GridCell(textCell: "")
        cell.isEditable = false
        cell.isSelectable = false
        label.cell = cell
        label.identifier = identifier
        label.drawsBackground = false
        label.isBezeled = false
        return label
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
