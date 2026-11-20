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
    /// How long a save waits for the other process to finish with the file. The plugin sets it to 0, as inside FM a save
    /// runs on FM's main thread: a missed lock is left to the poll's `saveIfPending`.
    public static var lockWait: TimeInterval = 0.5
    /// Tests point this at a temporary folder.
    static var pathOverride: URL?
    /// When this process changed ShowHidden or Reveal to a value it hasn't saved yet, by key, so `followFile` can tell
    /// whether the other window's change came later.
    static var pending: [String: Pending] = [:]
    /// Failures of saves and of follows, kept apart, so one working doesn't log the other's again.
    static var saveFailures = Failures()
    static var followFailures = Failures()
    /// How long the poll waits before trying again once the same failure has come twice.
    static var retryAfter: TimeInterval = 30
    /// A pending value and its change closer together than this can't be told apart, so it's settled the safe way.
    static let sameMoment: TimeInterval = 1

    struct Pending: Equatable {
        var value: AnyHashable
        var since: Date
    }

    /// One kind of failure at a time, by the error's domain and code, as its description can differ every time. A new kind
    /// is logged. The poll tries again every 2 seconds, and after two of its own tries fail the same way, every
    /// `retryAfter`. A save the player makes always tries, and doesn't count towards that.
    struct Failures {
        var kind: String?
        var polled = 0
        var next = Date.distantPast
        /// For follows: the modification date of the file that couldn't be read, so a newer one is tried at once.
        var at: Date?

        var allowsTry: Bool { Date() >= next }

        /// Says whether to log it.
        mutating func failed(_ kind: String, polled byPoll: Bool) -> Bool {
            let new = kind != self.kind
            self.kind = kind
            if new { polled = 0 }
            if byPoll { polled += 1 }
            next = polled >= 2 ? Date().addingTimeInterval(Settings.retryAfter) : .distantPast
            return new
        }
    }

    /// ~/Library/Application Support/FMStarship/settings.json
    public static var path: URL {
        if let pathOverride { return pathOverride }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("FMStarship").appendingPathComponent("settings.json")
    }

    /// A file that doesn't decode gives the defaults, but ShowHidden and Reveal are taken as `followFile` takes them, so
    /// the app, the plugin and the MCP server read the same file the same way.
    public static func load() {
        seenModified = modified()
        let data = try? Data(contentsOf: path)
        if let data, let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            current = saved
        } else {
            current = Settings()
            if let data, let shown = try? JSONDecoder().decode(Visibility.self, from: data) {
                current.showHidden = shown.showHidden
                current.reveal = shown.reveal
            }
        }
        baseline = current
        pending = [:]
        loaded = true
    }

    /// Does nothing before `load()`, so a failed start can't overwrite the file with defaults. Under a lock, re-reads the
    /// file and changes only the keys this process has changed, keeping every other key the file has, even ones this build
    /// doesn't know. A missing file, or one that isn't JSON, gets all of `current`. A failed save, including a file that
    /// can't be read or a lock not had in time, is logged, and `saveIfPending` tries it again. While a failed save's
    /// ShowHidden or Reveal waits and the file has changed unseen, it writes nothing and leaves it to the poll.
    public static func save() { save(wait: lockWait) }

    /// For the poll, after `followFile`: saves a change a failed save left behind, so the file and the other window don't
    /// keep a setting the player has changed. It doesn't wait for the lock, as the poll comes round again in 2 seconds, and
    /// waits `retryAfter` once the same failure has come twice.
    public static func saveIfPending() {
        guard loaded, current != baseline, saveFailures.allowsTry else { return }
        save(wait: 0, byPoll: true)
    }

    private static func save(wait: TimeInterval, byPoll: Bool = false) {
        guard loaded else { return }
        let started = Date()
        notePending()
        do {
            let now = try fields(current)
            let before = try fields(baseline ?? Settings())
            let changed = Set(now.keys).union(before.keys).filter { (now[$0] as? NSObject) != (before[$0] as? NSObject) }
            if changed.isEmpty, FileManager.default.fileExists(atPath: path.path) { return }
            let folder = path.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let lock = try FileLock(folder.appendingPathComponent("settings.lock"), wait: wait)
            defer { lock.release() }
            // Nothing the other process wrote is waiting to be followed, so this save's own write needn't be.
            let allSeen = modified() == seenModified
            // A ShowHidden or Reveal left by an earlier failed save may be older than the other window's change, which this
            // process hasn't followed yet. Nothing is written: the poll follows, then saves, within 2 seconds. A value set
            // in this call is the player's latest choice, so it doesn't hold the save back.
            if !allSeen, pending.values.contains(where: { $0.since < started }) { return }
            var output = now
            if let file = try readFile() {
                output = file
                for key in changed { output[key] = now[key] }
            }
            // An invalid object would raise rather than throw, which inside FM would close the game.
            guard JSONSerialization.isValidJSONObject(output) else { throw CocoaError(.coderInvalidValue) }
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let temporary = folder.appendingPathComponent("\(path.lastPathComponent).\(getpid()).tmp")
            do {
                try data.write(to: temporary)
            } catch {
                unlink(temporary.path)
                throw error
            }
            guard rename(temporary.path, path.path) == 0 else {
                let error = POSIXError(.init(rawValue: errno) ?? .EIO)
                unlink(temporary.path)
                throw error
            }
            if allSeen { seenModified = modified() }
            baseline = current
            pending = [:]
            saveFailures = Failures()
        } catch {
            logFailure("settings not saved", error, &saveFailures, polled: byPoll)
        }
    }

    /// Stamps ShowHidden and Reveal when they first differ from the baseline, or change again while they do.
    private static func notePending() {
        let base = baseline ?? Settings()
        func note(_ key: String, _ mine: AnyHashable, _ before: AnyHashable) {
            if mine == before {
                pending[key] = nil
            } else if pending[key]?.value != mine {
                pending[key] = Pending(value: mine, since: Date())
            }
        }
        note("ShowHidden", current.showHidden, base.showHidden)
        note("Reveal", current.reveal, base.reveal)
    }

    /// When the file has changed since this process loaded it or last looked, takes ShowHidden and Reveal from it, as the
    /// other process may have changed them, and says whether either changed here. What's taken becomes the baseline too, so
    /// it isn't this process's change to save. A missing file changes nothing. One that can't be read is read again at the
    /// next call, or after `retryAfter` once it has failed twice, unless it changes again.
    public static func followFile() -> Bool {
        guard loaded, var base = baseline, let modified = modified(), modified != seenModified else { return false }
        guard followFailures.allowsTry || modified != followFailures.at else { return false }
        let shown: Visibility
        do {
            shown = try JSONDecoder().decode(Visibility.self, from: Data(contentsOf: path))
        } catch {
            logFailure("settings not followed", error, &followFailures, polled: true)
            followFailures.at = modified
            return false
        }
        seenModified = modified
        followFailures = Failures()
        var changed = follow(\.showHidden, "ShowHidden", theirs: shown.showHidden, safe: false, modified, &base)
        changed = follow(\.reveal, "Reveal", theirs: shown.reveal, safe: Reveal.hidden.rawValue, modified, &base) || changed
        baseline = base
        return changed
    }

    /// One key from the file. With nothing pending here, or the same value both sides, the file's is taken. A value this
    /// process hasn't saved yet, which failed to save, stays when the file last changed clearly before it, and gives way
    /// when the other window changed the key clearly after it. When that can't be told, as when the file changed after it
    /// but the key reads as before (switched and back, or another key written), it's settled the safe way: Hidden
    /// attributes off, Ability Off. Says whether `current` changed.
    private static func follow<T: Hashable>(_ key: WritableKeyPath<Settings, T>, _ name: String, theirs: T, safe: T,
                                            _ modified: Date, _ base: inout Settings) -> Bool {
        let mine = current[keyPath: key], before = base[keyPath: key]
        let since = pending[name]?.since
        var value = theirs
        if mine == before || mine == theirs {
            value = theirs
        } else if let since, modified < since.addingTimeInterval(-sameMoment) {
            value = mine
        } else if let since, modified > since.addingTimeInterval(sameMoment), theirs != before {
            value = theirs
        } else {
            value = safe
        }
        base[keyPath: key] = theirs
        if value != mine { pending[name] = nil }
        current[keyPath: key] = value
        return value != mine
    }

    /// The two keys `followFile` and a `load` that can't decode the whole file take. ShowHidden is on only for a JSON true;
    /// Reveal is clamped as the picker clamps it. One that's missing, or not of its type, is the default.
    private struct Visibility: Decodable {
        var showHidden: Bool
        var reveal: Int

        private enum CodingKeys: String, CodingKey {
            case showHidden = "ShowHidden", reveal = "Reveal"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Settings()
            showHidden = (try? c.decodeIfPresent(Bool.self, forKey: .showHidden)) == true
            reveal = Reveal(setting: (try? c.decodeIfPresent(Int.self, forKey: .reveal)) ?? defaults.reveal).rawValue
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
            writeLog("settings file isn't JSON, saved over")
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
            var descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            // flock works on a file opened only for reading, such as a lock file this user can't write.
            if descriptor < 0 { descriptor = open(url.path, O_RDONLY | O_CLOEXEC) }
            self.descriptor = descriptor
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

    private static func logFailure(_ what: String, _ error: Error, _ failures: inout Failures, polled: Bool) {
        let nsError = error as NSError
        guard failures.failed("\(nsError.domain) \(nsError.code)", polled: polled) else { return }
        writeLog("\(what): \(error)")
    }

    private static func writeLog(_ message: String) {
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
