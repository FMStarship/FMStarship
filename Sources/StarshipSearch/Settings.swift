import Darwin
import Foundation

/// One column's saved state. JSON keys keep the original's spelling, as with `Settings`.
public struct ColState: Codable, Equatable {
    public var name = ""
    public var visible = false
    public var order = -1
    public var width = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case name = "Name", visible = "Visible", order = "Order", width = "Width"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? false
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? -1
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
    }
}

/// App settings, stored as JSON with the same setting names as the Windows app.
public struct Settings: Codable, Equatable {
    public var dark = true
    public var theme = ""
    public var x = Int(Int32.min)
    public var y = 0
    public var width = 1500
    public var height = 950
    public var maximized = false
    public var sidebarWidth = 0
    public var sidebarVisible = true
    public var detailHeight = 0
    public var staffMode = false
    public var fitWindow = false
    public var showHidden = false
    public var reveal = 0
    public var interestClub = ""
    public var unitsFollowFm = true
    public var heightUnit = "cm"
    public var wagePeriod = "week"
    public var currencyName = "United Kingdom Pound"
    public var buildCache = ""
    public var windows: [String: [Int]]?
    public var playerColumns: [ColState]?
    public var staffColumns: [ColState]?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case dark = "Dark", theme = "Theme", x = "X", y = "Y", width = "Width", height = "Height"
        case maximized = "Maximized", sidebarWidth = "SidebarWidth", sidebarVisible = "SidebarVisible"
        case detailHeight = "DetailHeight", staffMode = "StaffMode", fitWindow = "FitWindow"
        case showHidden = "ShowHidden", reveal = "Reveal", interestClub = "InterestClub"
        case unitsFollowFm = "UnitsFollowFm", heightUnit = "HeightUnit", wagePeriod = "WagePeriod"
        case currencyName = "CurrencyName", buildCache = "BuildCache", windows = "Windows"
        case playerColumns = "PlayerColumns", staffColumns = "StaffColumns"
    }

    /// A key missing from the file keeps its default, as System.Text.Json does.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        dark = try value(.dark, dark)
        theme = try value(.theme, theme)
        x = try value(.x, x)
        y = try value(.y, y)
        width = try value(.width, width)
        height = try value(.height, height)
        maximized = try value(.maximized, maximized)
        sidebarWidth = try value(.sidebarWidth, sidebarWidth)
        sidebarVisible = try value(.sidebarVisible, sidebarVisible)
        detailHeight = try value(.detailHeight, detailHeight)
        staffMode = try value(.staffMode, staffMode)
        fitWindow = try value(.fitWindow, fitWindow)
        showHidden = try value(.showHidden, showHidden)
        reveal = try value(.reveal, reveal)
        interestClub = try value(.interestClub, interestClub)
        unitsFollowFm = try value(.unitsFollowFm, unitsFollowFm)
        heightUnit = try value(.heightUnit, heightUnit)
        wagePeriod = try value(.wagePeriod, wagePeriod)
        currencyName = try value(.currencyName, currencyName)
        buildCache = try value(.buildCache, buildCache)
        windows = try c.decodeIfPresent([String: [Int]].self, forKey: .windows)
        playerColumns = try c.decodeIfPresent([ColState].self, forKey: .playerColumns)
        staffColumns = try c.decodeIfPresent([ColState].self, forKey: .staffColumns)
    }

    public static var current = Settings()
    /// Internal so tests can put it back: a test that loads mustn't leave later tests able to save.
    static var loaded = false
    /// `current` as this process last loaded or saved it, or took from the file. A save writes only the keys that differ
    /// from it, so the app and the plugin inside FM, each with the file loaded once, don't write back each other's values.
    static var baseline: Settings?
    /// The file's modification date when this process last loaded it or looked at it, so `followFile` reads it only once
    /// it changes.
    static var seenModified: Date?
    /// How long a save waits for the other process to finish with the file. Inside FM a save runs on FM's main thread.
    static var lockWait: TimeInterval = 0.5
    /// Tests point this at a temporary folder.
    static var pathOverride: URL?

    /// ~/Library/Application Support/FMStarship/settings.json
    public static var path: URL {
        if let pathOverride { return pathOverride }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("FMStarship").appendingPathComponent("settings.json")
    }

    public static func load() {
        seenModified = modified()
        if let data = try? Data(contentsOf: path), let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            current = saved
        } else {
            current = Settings()
        }
        baseline = current
        loaded = true
    }

    /// Does nothing before `load()`, so a failed start can't overwrite the file with defaults. Under a lock, re-reads the
    /// file and changes only the keys this process has changed, keeping every other key the file has, even ones this build
    /// doesn't know. A missing file, or one that isn't JSON, gets all of `current`. A failed save, including a file that
    /// can't be read or a lock not had in time, is logged, and its changes are saved next time.
    public static func save() {
        guard loaded else { return }
        do {
            let now = try fields(current)
            let before = try fields(baseline ?? Settings())
            let changed = Set(now.keys).union(before.keys).filter { (now[$0] as? NSObject) != (before[$0] as? NSObject) }
            if changed.isEmpty, FileManager.default.fileExists(atPath: path.path) { return }
            let folder = path.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let lock = try FileLock(folder.appendingPathComponent("settings.lock"), wait: lockWait)
            defer { lock.release() }
            var output = now
            if let file = try readFile() {
                output = file
                for key in changed { output[key] = now[key] }
            }
            // An invalid object would raise rather than throw, which inside FM would close the game.
            guard JSONSerialization.isValidJSONObject(output) else { throw CocoaError(.coderInvalidValue) }
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let temporary = folder.appendingPathComponent("\(path.lastPathComponent).\(getpid()).tmp")
            try data.write(to: temporary)
            guard rename(temporary.path, path.path) == 0 else {
                let error = POSIXError(.init(rawValue: errno) ?? .EIO)
                unlink(temporary.path)
                throw error
            }
            baseline = current
        } catch {
            logFailure("settings not saved: \(error)")
        }
    }

    /// When the file has changed since this process loaded it or last looked, takes ShowHidden and Reveal from it, as the
    /// other process may have changed them, and says whether either changed here. What's taken becomes the baseline too, so
    /// it isn't this process's change to save. A key this process has changed but not saved yet keeps its own value. A
    /// missing file changes nothing; one that can't be read is logged once per change.
    public static func followFile() -> Bool {
        guard loaded, var base = baseline, let modified = modified(), modified != seenModified else { return false }
        seenModified = modified
        let shown: Visibility
        do {
            shown = try JSONDecoder().decode(Visibility.self, from: Data(contentsOf: path))
        } catch {
            logFailure("settings not followed: \(error)")
            return false
        }
        let defaults = Settings()
        let showHidden = shown.showHidden ?? defaults.showHidden
        let reveal = Reveal(setting: shown.reveal ?? defaults.reveal).rawValue
        var changed = false
        if current.showHidden == base.showHidden, current.showHidden != showHidden {
            current.showHidden = showHidden
            changed = true
        }
        if current.reveal == base.reveal, current.reveal != reveal {
            current.reveal = reveal
            changed = true
        }
        if current.showHidden == showHidden { base.showHidden = showHidden }
        if current.reveal == reveal { base.reveal = reveal }
        baseline = base
        return changed
    }

    /// The two keys `followFile` takes. One that's missing, or not of its type, is the default, as `load` would have it.
    private struct Visibility: Decodable {
        var showHidden: Bool?
        var reveal: Int?

        private enum CodingKeys: String, CodingKey {
            case showHidden = "ShowHidden", reveal = "Reveal"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            showHidden = try? c.decodeIfPresent(Bool.self, forKey: .showHidden)
            reveal = try? c.decodeIfPresent(Int.self, forKey: .reveal)
        }
    }

    private static func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
    }

    /// The file's keys as they are now, or nil when there's no file, or one that isn't JSON, which is logged and saved over.
    /// A file that's there but can't be read throws, so the save fails rather than writing over it.
    private static func readFile() throws -> [String: Any]? {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        guard let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            logFailure("settings file isn't JSON, saved over")
            return nil
        }
        return file
    }

    /// The top-level keys as they'd be written, for comparing and merging. A nil optional is a missing key.
    private static func fields(_ settings: Settings) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return object
    }

    /// An flock on a file of its own, held around read, merge and rename, so two processes' saves can't interleave. It
    /// tries again for up to `wait` and then gives up, rather than holding up FM's main thread for long.
    private struct FileLock {
        let descriptor: Int32

        init(_ url: URL, wait: TimeInterval) throws {
            descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            let deadline = Date().addingTimeInterval(wait)
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let error = errno
                guard error == EWOULDBLOCK || error == EINTR, Date() < deadline else {
                    close(descriptor)
                    throw POSIXError(error == EWOULDBLOCK ? .ETIMEDOUT : .init(rawValue: error) ?? .EIO)
                }
                usleep(10_000)
            }
        }

        func release() {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    private static func logFailure(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n\n"
        let log = path.deletingLastPathComponent().appendingPathComponent("errors.log")
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: log) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: log)
        }
    }
}
