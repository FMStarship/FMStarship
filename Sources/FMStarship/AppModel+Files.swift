import AppKit
@preconcurrency import StarshipAnalysis
@preconcurrency import StarshipCore
import StarshipFiles
import StarshipSearch
import UniformTypeIdentifiers

/// Snapshots and export. All the writing happens off the main thread.
extension AppModel {
    private static var snapshotType: UTType { UTType(filenameExtension: Storage.fileExtension) ?? .data }

    // MARK: Snapshots

    func saveSnapshot() {
        guard let database else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.snapshotType]
        panel.nameFieldStringValue = Storage.snapshotFileName()
        panel.directoryURL = try? Storage.snapshotsFolder()
        Dialogs.present(panel) { [weak self] url in
            self?.fileJob.run("Saving snapshot...", work: { _, _ in
                do {
                    try Storage.saveSnapshot(database, to: url)
                    return "Snapshot saved: \(url.path)"
                } catch {
                    return "Couldn't save the snapshot: \(error.localizedDescription)"
                }
            }, done: { [weak self] in self?.status = $0 })
        }
    }

    func openSnapshot() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.snapshotType]
        panel.directoryURL = try? Storage.snapshotsFolder()
        Dialogs.present(panel) { [weak self] url in self?.openSnapshot(at: url) }
    }

    func openSnapshot(at url: URL) {
        snapshotJob.run("Opening snapshot...", work: { [weak self] _, _ in
            do {
                return NewData(try Storage.loadSnapshot(from: url))
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in self?.alert = "Could not open the snapshot: \(message)" }
                return nil
            }
        }, done: { [weak self] data in
            // A snapshot has no game behind it, so everything that needs the game stays honestly off.
            GameRules.engine = nil
            self?.install(data)
        })
    }

    // MARK: Export

    /// The "Export" button: the list on screen.
    func exportList() {
        guard let database else { return }
        let isStaff = listIsStaff
        let shown = isStaff ? staffColumns : playerColumns
        let all = isStaff ? allStaffColumns : allPlayerColumns
        let showHidden = showHidden
        let showAbility = showsAbility
        let reveal = shownReveal
        let rows: [Person] = isStaff ? staff : players
        choose(baseName: Export.defaultFileName(isStaff: isStaff), offerEveryColumn: true) { [weak self] url, everyColumn in
            let columns = everyColumn ? all : shown
            let title = Export.title(rowCount: rows.count, isStaff: isStaff, build: database.build, gameDate: database.gameDate)
            self?.write(rows.count, to: url) {
                Self.exportFile(ExportFormat(pathExtension: url.pathExtension), columns: columns, rows: rows,
                                showHidden: showHidden, showAbility: showAbility, reveal: reveal, title: title)
            }
        }
    }

    /// The file `exportList` writes. Whatever columns it's given, those Hidden attributes and Ability don't allow are left out.
    nonisolated static func exportFile(_ format: ExportFormat, columns: [Col], rows: [Person], showHidden: Bool, showAbility: Bool,
                                       reveal: Reveal, title: String) -> Data {
        let columns = columns.filter { Columns.allowed($0, showHidden: showHidden, showAbility: showAbility) }
        return Export.file(format, columns: columns.map(exportColumn),
                           rows: rows.map { person in columns.map { exportCell($0, person, reveal: reveal) } }, title: title)
    }

    /// The analysis screens: what the grid shows.
    func exportTable(_ table: AnalysisTable, title: String) {
        let columns = table.columns.map { ExportColumn(name: $0.title) }
        let cells = table.rows.map { row in
            table.columns.indices.map { ExportCell(.string($0 < row.cells.count ? row.cells[$0] : "")) }
        }
        let base = ShortlistFile.sanitizedFileName(title)
        choose(baseName: base, offerEveryColumn: false) { [weak self] url, _ in
            self?.write(cells.count, to: url) {
                Export.file(ExportFormat(pathExtension: url.pathExtension), columns: columns, rows: cells, title: "FM Starship - \(title)")
            }
        }
    }

    private func choose(baseName: String, offerEveryColumn: Bool, then: @escaping (URL, Bool) -> Void) {
        let panel = NSSavePanel()
        let options = ExportOptionsView(panel: panel, baseName: baseName, offerEveryColumn: offerEveryColumn)
        panel.accessoryView = options
        Dialogs.present(panel) { then($0, options.everyColumn) }
    }

    private func write(_ rowCount: Int, to url: URL, make: @escaping @Sendable () -> Data) {
        fileJob.run("Exporting \(rowCount.formatted()) rows...", work: { _, _ in
            do {
                try make().write(to: url, options: .atomic)
                return "\(rowCount.formatted()) rows exported to \(url.path)"
            } catch {
                return "Couldn't export: \(error.localizedDescription)"
            }
        }, done: { [weak self] message in
            self?.status = message
            guard message.contains(" exported to "), url.pathExtension.lowercased().hasPrefix("htm") else { return }
            Dialogs.confirm("Export", "Open the web page now?") { NSWorkspace.shared.open(url) }
        })
    }

    nonisolated static func exportColumn(_ col: Col) -> ExportColumn {
        ExportColumn(name: col.name, group: col.group, numeric: col.numeric, hidden: col.hidden, ability: col.ability, shortName: col.shortName)
    }

    nonisolated static func exportCell(_ col: Col, _ person: Person, reveal: Reveal) -> ExportCell {
        let value = col.get(person)
        if col.ability, reveal == .stars, case .int(let number) = value { return ExportCell(.string(Columns.abilityStars(number))) }
        let exported: ExportValue
        switch value {
        case .empty: exported = .none
        case .text(let text): exported = .string(text)
        case .int(let number): exported = .int(number)
        case .double(let number): exported = .double(number)
        case .date(let date): exported = .date(date)
        }
        return ExportCell(exported, text: col.format.map { $0(value) })
    }
}

/// The save panel's format and "every column?" controls.
private final class ExportOptionsView: NSView {
    private weak var panel: NSSavePanel?
    private let baseName: String
    private let formats = ExportFormat.allCases
    private let formatPopUp = NSPopUpButton()
    private let everyColumnBox = NSButton(checkboxWithTitle: "Export every column (otherwise only the columns shown)", target: nil, action: nil)

    var everyColumn: Bool { everyColumnBox.state == .on }

    init(panel: NSSavePanel, baseName: String, offerEveryColumn: Bool) {
        self.panel = panel
        self.baseName = baseName
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: offerEveryColumn ? 62 : 36))

        let label = NSTextField(labelWithString: "Format:")
        formatPopUp.addItems(withTitles: formats.map(\.title))
        formatPopUp.target = self
        formatPopUp.action = #selector(formatChanged)
        let row = NSStackView(views: [label, formatPopUp])
        let stack = NSStackView(views: offerEveryColumn ? [row, everyColumnBox] : [row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = bounds.insetBy(dx: 8, dy: 4)
        stack.autoresizingMask = [.width, .height]
        addSubview(stack)
        panel.nameFieldStringValue = baseName + "." + formats[0].fileExtension
        apply(formats[0])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func formatChanged() { apply(formats[formatPopUp.indexOfSelectedItem]) }

    private func apply(_ format: ExportFormat) {
        guard let panel else { return }
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        let current = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = (current.isEmpty ? baseName : current) + "." + format.fileExtension
    }
}
