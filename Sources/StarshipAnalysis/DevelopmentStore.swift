import Foundation
import StarshipCore

/// A snapshot of the squad at every load, kept between sessions so that "My club" can show who is
/// improving. The JSON has the shape of the original's, so its files can be read here unchanged.
public struct DevelopmentStore {
    public static let keep = 200

    public struct Row: Codable, Equatable {
        public var name: String
        public var ca: Int
        public var pa: Int
        public var attr: [UInt8]

        public init(name: String = "", ca: Int = 0, pa: Int = 0, attr: [UInt8] = []) {
            self.name = name
            self.ca = ca
            self.pa = pa
            self.attr = attr
        }

        private enum CodingKeys: String, CodingKey {
            case name = "Name", ca = "CA", pa = "PA", attr = "Attr"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            ca = try c.decodeIfPresent(Int.self, forKey: .ca) ?? 0
            pa = try c.decodeIfPresent(Int.self, forKey: .pa) ?? 0
            attr = [UInt8](try c.decodeIfPresent(Data.self, forKey: .attr) ?? Data())
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(ca, forKey: .ca)
            try c.encode(pa, forKey: .pa)
            try c.encode(Data(attr), forKey: .attr)
        }
    }

    public struct Snap: Codable {
        public var gameDate: Date
        public var players: [UInt32: Row]

        public init(gameDate: Date, players: [UInt32: Row] = [:]) {
            self.gameDate = gameDate
            self.players = players
        }

        private enum CodingKeys: String, CodingKey {
            case gameDate = "GameDate", players = "Players"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let text = try c.decode(String.self, forKey: .gameDate)
            guard let date = DevelopmentStore.dateFormatter.date(from: String(text.prefix(19))) else {
                throw DecodingError.dataCorruptedError(forKey: .gameDate, in: c, debugDescription: text)
            }
            gameDate = date
            let rows = try c.decodeIfPresent([String: Row].self, forKey: .players) ?? [:]
            players = Dictionary(rows.compactMap { key, row in UInt32(key).map { ($0, row) } }, uniquingKeysWith: { $1 })
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(DevelopmentStore.dateFormatter.string(from: gameDate), forKey: .gameDate)
            try c.encode(Dictionary(uniqueKeysWithValues: players.map { (String($0.key), $0.value) }), forKey: .players)
        }
    }

    fileprivate static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = GameDate.calendar.timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("FMStarship", isDirectory: true)
    }

    public var directory: URL

    public init(directory: URL = DevelopmentStore.defaultDirectory) {
        self.directory = directory
    }

    /// One file per club, with a folder per game version; FM 26 saves sit at the top level.
    public func path(db: Database?, club: String) -> URL {
        let invalid = CharacterSet(charactersIn: "\"<>|:*?\\/").union(.controlCharacters)
        let file = String(String.UnicodeScalarView(club.unicodeScalars.map { invalid.contains($0) ? "_" : $0 })) + ".json"
        let root = directory.appendingPathComponent("development", isDirectory: true)
        let build = db?.build ?? ""
        let version = build.range(of: "Football Manager [0-9][0-9]", options: .regularExpression).map { String(build[$0]) } ?? ""
        if version.isEmpty || version == "Football Manager 26" { return root.appendingPathComponent(file) }
        return root.appendingPathComponent(version, isDirectory: true).appendingPathComponent(file)
    }

    public func load(db: Database?, club: String) -> [Snap] {
        guard let data = try? Data(contentsOf: path(db: db, club: club)) else { return [] }
        return (try? JSONDecoder().decode([Snap].self, from: data)) ?? []
    }

    /// One snapshot per game day: saving again on the same day replaces it. Failures are ignored.
    public func save(db: Database, club: String) {
        guard !club.isEmpty, let gameDate = db.gameDate else { return }
        let day = gameDate.startOfGameDay
        var snaps = load(db: db, club: club)
        snaps.removeAll { $0.gameDate.startOfGameDay == day }

        var snap = Snap(gameDate: day)
        for p in db.players where p.clubFull == club && p.block != 0 && p.ca > 0 {
            let attr = (0..<min(54, Names.playerAttrs.count)).map { UInt8(p.attribute(at: $0)) }
            snap.players[p.uid] = Row(name: p.name, ca: p.ca, pa: p.pa, attr: attr)
        }
        if snap.players.isEmpty { return }
        snaps.append(snap)
        snaps = Array(snaps.stableSorted { $0.gameDate < $1.gameDate }.suffix(DevelopmentStore.keep))

        let url = path(db: db, club: club)
        let temporary = url.appendingPathExtension("tmp")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snaps), (try? data.write(to: temporary)) != nil else { return }
        _ = rename(temporary.path, url.path)
    }
}
