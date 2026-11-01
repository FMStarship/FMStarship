import AppKit
import StarshipCore
import StarshipFiles
import UniformTypeIdentifiers

/// FM's shortlist files. These are the only files the app writes outside its own folder, and only when asked.
extension AppModel {
    private static var shortlistType: UTType { UTType(filenameExtension: ShortlistFile.fileExtension) ?? .data }

    /// "Add ... to shortlist": `PersonMenu.FillShortlists`.
    func shortlistEntries(_ people: [Person], isStaff: Bool) -> [MenuEntry] {
        let lists = ShortlistFile.list(isStaff: isStaff)
        var entries = lists.map { entry -> MenuEntry in
            let have = people.filter { entry.shortlist.uids.contains($0.uid) }.count
            let note = have == people.count ? " - already in it" : have > 0 ? " - \(have) already in it" : ""
            return MenuEntry("\(entry.shortlist.name)  (\(entry.shortlist.uids.count))\(note)", enabled: have < people.count) { [weak self] in
                self?.addToShortlist(people, at: entry.url)
            }
        }
        if lists.isEmpty {
            let hasFolder = ShortlistFile.folder(isStaff: isStaff) != nil
            entries.append(MenuEntry(hasFolder ? "(no \(isStaff ? "staff" : "player") shortlists yet)" : "(FM's shortlists folder not found)", enabled: false))
        }
        entries.append(.separator)
        entries.append(MenuEntry("New shortlist...") { [weak self] in self?.newShortlist(people, isStaff: isStaff) })
        return entries
    }

    /// Keeps the previous version as `.bak`.
    func addToShortlist(_ people: [Person], at url: URL) {
        do {
            let (shortlist, added) = try ShortlistFile.add(people.map(\.uid), to: url)
            status = "Added \(added) to shortlist \"\(shortlist.name)\" (now \(shortlist.uids.count)). In FM: Shortlist > Load it."
            shortlistsChanged()
            refreshOpenShortlist(url, uids: shortlist.uids)
        } catch {
            Dialogs.inform("FM shortlist", "Couldn't add to the shortlist: \(error.localizedDescription)")
        }
    }

    func newShortlist(_ people: [Person], isStaff: Bool) {
        guard let folder = ShortlistFile.folder(isStaff: isStaff) else {
            saveAsShortlist(people, isStaff: isStaff, name: isStaff ? "FM Starship staff" : "FM Starship players")
            return
        }
        Dialogs.ask("New FM shortlist", "Name for the shortlist:", initial: isStaff ? "Staff targets" : "Targets") { [weak self] name in
            guard let self else { return }
            do {
                try ShortlistFile.create(name: name, isStaff: isStaff, uids: people.map(\.uid), in: folder)
                self.status = "Made shortlist \"\(name)\" with \(people.count). In FM: Shortlist > Load it."
                self.shortlistsChanged()
            } catch ShortlistError.alreadyExists(let url) {
                let file = url.deletingPathExtension().lastPathComponent
                Dialogs.confirm("FM shortlist", "There's already a shortlist file called \"\(file)\". Add to it instead?") { [weak self] in
                    self?.addToShortlist(people, at: url)
                }
            } catch {
                Dialogs.inform("FM shortlist", "Couldn't make the shortlist: \(error.localizedDescription)")
            }
        }
    }

    /// `ShortlistFile.SaveDialog`: the save panel, starting in FM's folder.
    func saveAsShortlist(_ people: [Person], isStaff: Bool, name: String) {
        guard !people.isEmpty else {
            Dialogs.inform("FM shortlist", "There's nobody to save - select some rows first.")
            return
        }
        let folder = ShortlistFile.folder(create: true, isStaff: isStaff)
        let what = "\(people.count) \(isStaff ? "staff" : "players")"
        let panel = NSSavePanel()
        panel.title = "Save \(what) as an FM shortlist"
        panel.allowedContentTypes = [Self.shortlistType]
        panel.nameFieldStringValue = ShortlistFile.sanitizedFileName(name)
        panel.directoryURL = folder
        Dialogs.present(panel) { [weak self] url in
            let saved = url.deletingPathExtension().lastPathComponent
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try Data(contentsOf: url).write(to: ShortlistFile.backupURL(for: url), options: .atomic)
                }
                try ShortlistFile.write(to: url, name: saved, isStaff: isStaff, uids: people.map(\.uid))
            } catch {
                Dialogs.inform("FM shortlist", "Couldn't save the shortlist: \(error.localizedDescription)")
                return
            }
            let inFolder = folder?.standardizedFileURL.path == url.deletingLastPathComponent().standardizedFileURL.path
            let elsewhere = inFolder ? "" : "FM looks for shortlists in:\n\(folder?.path ?? "your FM folder/shortlists")\n\n"
            let how = isStaff ? "Load it from the Staff Shortlist tab (not Shortlists)." : "FM leaves out players who are already at your club."
            Dialogs.inform("FM shortlist", "Saved \"\(saved)\" (\(what)).\n\n\(elsewhere)In FM, use Shortlist > Load. \(how)")
            self?.status = "Saved FM shortlist \"\(saved)\" - \(what)."
            self?.shortlistsChanged()
        }
    }

    /// "Save as FM shortlist" from the File menu: the selected rows, or all of them.
    func saveListAsShortlist() {
        let isStaff = listIsStaff
        let rows: [Person] = isStaff ? staff : players
        let people = selection.count > 1 ? selection : rows
        let name = isStaff ? "FM Starship staff" : "FM Starship players"
        guard people.count > 500 else {
            saveAsShortlist(people, isStaff: isStaff, name: name)
            return
        }
        Dialogs.confirm("FM shortlist", "Save all \(people.count.formatted()) rows to one shortlist? (Select rows first to save just those.)") { [weak self] in
            self?.saveAsShortlist(people, isStaff: isStaff, name: name)
        }
    }

    /// Any .fmf file, not just the ones in FM's folders.
    func chooseShortlistFile() {
        let panel = NSOpenPanel()
        panel.title = "Open an FM shortlist"
        panel.allowedContentTypes = [Self.shortlistType]
        panel.directoryURL = ShortlistFile.folder()
        Dialogs.present(panel) { [weak self] url in self?.openShortlistFile(url) }
    }

    func openShortlistFile(_ url: URL) {
        do {
            let shortlist = try ShortlistFile.read(url)
            showShortlist(OpenShortlist(url: url, name: shortlist.name, isStaff: shortlist.isStaff, uids: shortlist.uids))
            go(to: .shortlists)
        } catch {
            Dialogs.inform("Open shortlist", "Couldn't open it: \(error.localizedDescription)")
        }
    }
}
