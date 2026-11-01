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
    private static var loaded = false
    private static var lastSaved: Data?

    /// ~/Library/Application Support/FMStarship/settings.json
    public static var path: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("FMStarship").appendingPathComponent("settings.json")
    }

    public static func load() {
        if let data = try? Data(contentsOf: path), let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            current = saved
        } else {
            current = Settings()
        }
        loaded = true
    }

    /// Does nothing before `load()`, so a failed start can't overwrite the file with defaults.
    public static func save() {
        guard loaded else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(current)
            if data == lastSaved { return }
            let folder = path.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let temporary = path.appendingPathExtension("tmp")
            try data.write(to: temporary)
            guard rename(temporary.path, path.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            lastSaved = data
        } catch {
            logFailure(error)
        }
    }

    private static func logFailure(_ error: Error) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) settings not saved: \(error)\n\n"
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
