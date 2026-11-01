import Foundation

public struct ShortlistEntry {
    public let url: URL
    public let shortlist: Shortlist
    public let modified: Date
}

/// Finding the user's shortlists, and the add-to and new-shortlist flows on top of the file format.
///
/// On the Mac FM keeps its user files under the Steam Cloud folder in Application Support, with
/// staff lists in a folder of their own:
/// `~/Library/Application Support/Sports Interactive/Football Manager 27/cloud/shortlists` and
/// `.../cloud/staff shortlists`.
extension ShortlistFile {
    public static let gameFolderName = "Football Manager 27"

    /// The folders that may hold FM's data, best first: wherever the last save went, FM's own
    /// Application Support folder, then the Documents folder the Windows game uses.
    public static func gameRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let support = home.appendingPathComponent("Library/Application Support/Sports Interactive/\(gameFolderName)")
        var roots = lastSaveRoots(in: support.appendingPathComponent("Preferences"))
        roots.append(support)
        roots.append(home.appendingPathComponent("Documents/Sports Interactive/\(gameFolderName)"))

        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func lastSaveRoots(in preferences: URL) -> [URL] {
        guard let files = FileManager.default.enumerator(at: preferences, includingPropertiesForKeys: nil) else { return [] }
        let value = try? NSRegularExpression(pattern: "value=\"([^\"]+)\"")
        var roots: [URL] = []
        for case let file as URL in files where file.lastPathComponent == "last_saved_game.xml" {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let match = value?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text)
            else { continue }
            // <root>/games/<save>.fm
            let root = URL(fileURLWithPath: String(text[range])).deletingLastPathComponent().deletingLastPathComponent()
            if root.path != "/" { roots.append(root) }
        }
        return roots
    }

    /// Where a shortlist of this kind goes. With `create` the folder is made if FM hasn't yet,
    /// but only in a root that really has FM's `games` folder.
    public static func folder(create: Bool = false, isStaff: Bool = false, roots: [URL]? = nil) -> URL? {
        let roots = roots ?? gameRoots()
        let manager = FileManager.default
        if let existing = existingFolders(isStaff: isStaff, roots: roots).first { return existing }
        guard create else { return nil }

        for root in roots where manager.isDirectory(root.appendingPathComponent("games")) {
            let cloud = root.appendingPathComponent("cloud")
            let base = manager.isDirectory(cloud) ? cloud : root
            let folder = base.appendingPathComponent(folderNames(isStaff: isStaff)[0], isDirectory: true)
            if (try? manager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil { return folder }
        }
        return nil
    }

    /// Staff lists fall back to the player folder, which is where the Windows app put them.
    private static func folderNames(isStaff: Bool) -> [String] {
        isStaff ? ["staff shortlists", "shortlists"] : ["shortlists"]
    }

    private static func existingFolders(isStaff: Bool, roots: [URL]) -> [URL] {
        let manager = FileManager.default
        var folders: [URL] = []
        for name in folderNames(isStaff: isStaff) {
            for root in roots {
                for base in [root.appendingPathComponent("cloud"), root] {
                    let folder = base.appendingPathComponent(name, isDirectory: true)
                    if manager.isDirectory(folder) { folders.append(folder) }
                }
            }
        }
        return folders
    }

    /// Every readable shortlist of this kind, newest first. Files that won't parse are skipped.
    public static func list(isStaff: Bool, roots: [URL]? = nil) -> [ShortlistEntry] {
        var entries: [ShortlistEntry] = []
        for folder in existingFolders(isStaff: isStaff, roots: roots ?? gameRoots()) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension.lowercased() == fileExtension {
                guard let shortlist = try? read(file), shortlist.isStaff == isStaff else { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                entries.append(ShortlistEntry(url: file, shortlist: shortlist, modified: modified ?? .distantPast))
            }
        }
        return entries.sorted { $0.modified > $1.modified }
    }

    /// Adds people to an existing shortlist, keeping the previous version as `<file>.bak`.
    @discardableResult
    public static func add(_ uids: some Sequence<UInt32>, to url: URL) throws -> (shortlist: Shortlist, added: Int) {
        var shortlist = try read(url)
        var seen = Set(shortlist.uids)
        let new = uids.filter { seen.insert($0).inserted }
        shortlist.uids += new

        try Data(contentsOf: url).write(to: backupURL(for: url), options: .atomic)
        try write(to: url, name: shortlist.name, isStaff: shortlist.isStaff, uids: shortlist.uids)
        return (shortlist, new.count)
    }

    public static func backupURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + backupSuffix)
    }

    /// Makes a new shortlist in `folder`. If the name is taken this throws `.alreadyExists` with
    /// the file's URL, so the caller can offer `add(_:to:)` instead.
    @discardableResult
    public static func create(name: String, isStaff: Bool, uids: some Sequence<UInt32>, in folder: URL) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = sanitizedFileName(trimmed)
        guard !fileName.isEmpty else { throw ShortlistError.emptyName }

        let url = folder.appendingPathComponent("\(fileName).\(fileExtension)")
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ShortlistError.alreadyExists(url) }
        try write(to: url, name: trimmed, isStaff: isStaff, uids: uids)
        return url
    }

    /// Path.GetInvalidFileNameChars on Windows. It's kept on the Mac because Steam Cloud carries
    /// these files to Windows machines.
    public static func sanitizedFileName(_ name: String) -> String {
        String(name.unicodeScalars.filter { $0.value >= 32 && !"\"<>|:*?\\/".unicodeScalars.contains($0) }.map(Character.init))
    }
}

private extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
