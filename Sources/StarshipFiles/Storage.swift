import Foundation
import StarshipCore

public enum SnapshotError: Error, Equatable, LocalizedError {
    case notSnapshot
    case wrongVersion(UInt32)
    case damaged

    public var errorDescription: String? {
        switch self {
        case .notSnapshot: return "This isn't an FM Starship snapshot."
        case .wrongVersion(let version): return "This snapshot was made by a different version of FM Starship (format \(version))."
        case .damaged: return "The snapshot looks damaged."
        }
    }
}

/// Saves a whole `Database` so the app can work without FM running.
///
/// The format is private to this app: a magic number and version, then one zstd frame holding a
/// table of every distinct string followed by the data as varints. Names, clubs and nations
/// repeat so often across 55,000 people that the table does most of the work.
public enum Storage {
    public static let fileExtension = "fmasnap"

    private static let magic = Array("FMSTRSNP".utf8)
    /// 2 added who is a woman and which human clubs are women's sides. A version 1 file just doesn't know.
    private static let version: UInt32 = 2

    /// `~/Library/Application Support/FMStarship/Snapshots`, created if needed.
    public static func snapshotsFolder() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("FMStarship/Snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    public static func snapshotFileName(date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "snapshot-\(formatter.string(from: date)).\(fileExtension)"
    }

    /// The saved snapshots, newest first.
    public static func snapshots() throws -> [URL] {
        let key = URLResourceKey.contentModificationDateKey
        let files = try FileManager.default.contentsOfDirectory(at: snapshotsFolder(), includingPropertiesForKeys: [key])
        let dated = files.filter { $0.pathExtension == fileExtension }.map { file in
            (file, (try? file.resourceValues(forKeys: [key]))?.contentModificationDate ?? .distantPast)
        }
        return dated.sorted { $0.1 > $1.1 }.map(\.0)
    }

    public static func saveSnapshot(_ database: Database, to url: URL) throws {
        var writer = SnapshotWriter()
        writer.write(database)

        var body: [UInt8] = []
        body.reserveCapacity(writer.table.count * 16 + writer.bytes.count)
        var tableWriter = SnapshotWriter()
        tableWriter.varint(UInt64(writer.strings.count))
        for string in writer.strings {
            let utf8 = Array(string.utf8)
            tableWriter.varint(UInt64(utf8.count))
            tableWriter.bytes += utf8
        }
        body += tableWriter.bytes
        body += writer.bytes

        var file = magic
        file.appendLE(version)
        file += try Zstd.compress(body)
        try Data(file).write(to: url, options: .atomic)
    }

    public static func loadSnapshot(from url: URL) throws -> Database {
        let file = [UInt8](try Data(contentsOf: url))
        guard file.count >= magic.count + 4, file.starts(with: magic) else { throw SnapshotError.notSnapshot }
        let found = file.readLE(UInt32.self, at: magic.count)
        guard found == 1 || found == version else { throw SnapshotError.wrongVersion(found) }
        guard let body = try? Zstd.decompress(Array(file[(magic.count + 4)...])) else { throw SnapshotError.damaged }

        let database = try body.withUnsafeBufferPointer { buffer -> Database in
            var reader = SnapshotReader(buffer, version: found)
            try reader.readTable()
            return try reader.readDatabase()
        }
        database.source = "snapshot \(url.lastPathComponent)"
        database.prepare()
        return database
    }
}

private struct SnapshotWriter {
    var bytes: [UInt8] = []
    var table: [String: UInt64] = [:]
    var strings: [String] = []

    mutating func varint(_ value: UInt64) {
        var rest = value
        while rest >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: rest) | 0x80)
            rest >>= 7
        }
        bytes.append(UInt8(rest))
    }

    /// Zigzag, so that the -1 ages and rare negatives stay small.
    mutating func int(_ value: Int64) { varint(UInt64(bitPattern: (value << 1) ^ (value >> 63))) }
    mutating func int(_ value: Int) { int(Int64(value)) }
    mutating func double(_ value: Double) { bytes.appendLE(value.bitPattern) }
    mutating func date(_ value: Date) { double(value.timeIntervalSinceReferenceDate) }

    mutating func string(_ value: String) {
        if let index = table[value] { return varint(index) }
        let index = UInt64(strings.count)
        table[value] = index
        strings.append(value)
        varint(index)
    }

    mutating func blob(_ value: [UInt8]) {
        varint(UInt64(value.count))
        bytes += value
    }

    mutating func optional<T>(_ value: T?, _ write: (inout SnapshotWriter, T) -> Void) {
        bytes.append(value == nil ? 0 : 1)
        if let value { write(&self, value) }
    }

    mutating func write(_ database: Database) {
        string(database.build)
        string(database.fingerprint)
        date(database.readAt)
        optional(database.gameDate) { $0.date($1) }
        int(database.unnamed)
        string(database.checks)
        string(database.source)

        varint(UInt64(database.currencies.count))
        for currency in database.currencies {
            string(currency.name)
            string(currency.symbol)
            double(currency.rate)
        }
        varint(UInt64(database.humanClubs.count))
        for club in database.humanClubs {
            int(club.team)
            string(club.name)
            int(club.manager)
        }
        varint(UInt64(database.budgets.count))
        for (team, budget) in database.budgets {
            int(team)
            int(budget.transfer)
            int(budget.wageRoom)
        }
        bytes.append(database.knowsSides ? 1 : 0)
        varint(UInt64(database.womensTeams.count))
        for team in database.womensTeams.sorted() { int(team) }

        varint(UInt64(database.players.count))
        for player in database.players { write(player) }
        varint(UInt64(database.staff.count))
        for staff in database.staff { write(staff) }
    }

    private mutating func write(person p: Person) {
        varint(UInt64(p.uid))
        int(p.block)
        varint(UInt64(p.index))
        string(p.firstName)
        string(p.secondName)
        string(p.commonName)
        string(p.fullName)
        string(p.nation)
        int(p.birthYear)
        int(p.birthDay)
        string(p.club)
        string(p.clubFull)
        string(p.league)
        string(p.clubNation)
        string(p.region)
        string(p.area)
        int(p.areaRecord)
        bytes.append(p.flags)
        blob(p.pers)
        string(p.personality)
        string(p.media)
        int(p.age)
        int(p.wage)
        string(p.squad)
        string(p.loanClub)
        string(p.loanClubFull)
        bytes.append(p.statusFlags)
        int(p.listedYear)
        int(p.listedDay)
        varint(UInt64(p.teamIndex))
        int(p.clubObject)
        int(p.loanClubObject)
        int(p.endYear)
        int(p.endDay)
        int(p.loanEndYear)
        int(p.loanEndDay)
        bytes.append(p.isAtOwnBTeam ? 1 : 0)
        int(p.releaseClause)
        int(p.releaseForeign)
        int(p.releaseDomestic)
        bytes.append(p.isWoman ? 1 : 0)
    }

    private mutating func write(_ p: Player) {
        write(person: p)
        int(p.value)
        int(p.ca)
        int(p.pa)
        blob(p.pos)
        blob(p.raw)
        varint(p.traitBits)
        int(p.height)
        optional(p.injuries) { writer, injuries in
            writer.varint(UInt64(injuries.count))
            for injury in injuries { writer.write(injury) }
        }
        optional(p.injury) { $0.write($1) }
        string(p.injuryText)
        int(p.injuryDays)
        blob(p.topRoles)
        optional(p.season) { $0.write($1) }
        string(p.form)
    }

    private mutating func write(_ p: Staff) {
        write(person: p)
        int(p.ca)
        int(p.pa)
        blob(p.attr)
        string(p.job)
        int(p.secondJob)
        int(p.repCurrent)
        int(p.repHome)
        int(p.repWorld)
        varint(UInt64(p.stars.count))
        for star in p.stars { double(star) }
    }

    private mutating func write(_ injury: Injury) {
        int(injury.record)
        string(injury.name)
        date(injury.date)
        int(injury.length)
    }

    private mutating func write(_ s: SeasonStats) {
        int(s.apps)
        int(s.starts)
        int(s.subs)
        int(s.minutes)
        int(s.goals)
        int(s.assists)
        double(s.rating)
        int(s.playerOfTheMatch)
        int(s.yellow)
        int(s.red)
        int(s.cleanSheets)
        int(s.conceded)
        double(s.xG)
        double(s.xA)
        int(s.passPercent)
        int(s.shotsOnTargetPercent)
        int(s.tacklePercent)
        int(s.tackles)
        int(s.dribbles)
        int(s.fouls)
        int(s.fouled)
    }
}

/// The exact mirror of `SnapshotWriter`. Every read is bounds-checked, so a damaged body fails
/// with an error instead of trapping.
private struct SnapshotReader {
    private let buffer: UnsafeBufferPointer<UInt8>
    private let version: UInt32
    private var offset = 0
    private var strings: [String] = []

    init(_ buffer: UnsafeBufferPointer<UInt8>, version: UInt32) {
        self.buffer = buffer
        self.version = version
    }

    private mutating func byte() throws -> UInt8 {
        guard offset < buffer.count else { throw SnapshotError.damaged }
        defer { offset += 1 }
        return buffer[offset]
    }

    private mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let next = try byte()
            value |= UInt64(next & 0x7F) << shift
            if next < 0x80 { return value }
            shift += 7
            guard shift < 64 else { throw SnapshotError.damaged }
        }
    }

    /// A count of things that take at least a byte each can't exceed what's left of the file.
    private mutating func count() throws -> Int {
        let value = try varint()
        guard value <= UInt64(buffer.count - offset) else { throw SnapshotError.damaged }
        return Int(value)
    }

    private mutating func int64() throws -> Int64 {
        let raw = try varint()
        return Int64(bitPattern: raw >> 1) ^ -Int64(bitPattern: raw & 1)
    }

    private mutating func int() throws -> Int { Int(try int64()) }
    private mutating func uint32() throws -> UInt32 { UInt32(truncatingIfNeeded: try varint()) }

    private mutating func double() throws -> Double {
        guard offset + 8 <= buffer.count else { throw SnapshotError.damaged }
        let bits = UnsafeRawBufferPointer(buffer).loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        offset += 8
        return Double(bitPattern: UInt64(littleEndian: bits))
    }

    private mutating func date() throws -> Date { Date(timeIntervalSinceReferenceDate: try double()) }

    private mutating func string() throws -> String {
        let index = try varint()
        guard index < UInt64(strings.count) else { throw SnapshotError.damaged }
        return strings[Int(index)]
    }

    private mutating func blob() throws -> [UInt8] {
        let length = try count()
        defer { offset += length }
        return Array(buffer[offset..<offset + length])
    }

    private mutating func optional<T>(_ read: (inout SnapshotReader) throws -> T) throws -> T? {
        try byte() == 0 ? nil : try read(&self)
    }

    mutating func readTable() throws {
        let total = try count()
        strings.reserveCapacity(total)
        for _ in 0..<total {
            let length = try count()
            strings.append(String(decoding: buffer[offset..<offset + length], as: UTF8.self))
            offset += length
        }
    }

    mutating func readDatabase() throws -> Database {
        let database = Database()
        database.build = try string()
        database.fingerprint = try string()
        database.readAt = try date()
        database.gameDate = try optional { try $0.date() }
        database.unnamed = try int()
        database.checks = try string()
        database.source = try string()

        for _ in 0..<(try count()) {
            let name = try string(), symbol = try string(), rate = try double()
            database.currencies.append(Currency(name: name, symbol: symbol, rate: rate))
        }
        for _ in 0..<(try count()) {
            let team = try int64(), name = try string(), manager = try int64()
            database.humanClubs.append((team: team, name: name, manager: manager))
        }
        for _ in 0..<(try count()) {
            let team = try int64(), transfer = try int64(), wageRoom = try int()
            database.budgets[team] = (transfer: transfer, wageRoom: wageRoom)
        }
        if version >= 2 {
            database.knowsSides = try byte() != 0
            for _ in 0..<(try count()) { database.womensTeams.insert(try int64()) }
        }

        let players = try count()
        database.players.reserveCapacity(players)
        for _ in 0..<players { database.players.append(try readPlayer()) }
        let staff = try count()
        database.staff.reserveCapacity(staff)
        for _ in 0..<staff { database.staff.append(try readStaff()) }
        return database
    }

    private mutating func readPerson(into p: Person) throws {
        p.uid = try uint32()
        p.block = try int64()
        p.index = try uint32()
        p.firstName = try string()
        p.secondName = try string()
        p.commonName = try string()
        p.fullName = try string()
        p.nation = try string()
        p.birthYear = try int()
        p.birthDay = try int()
        p.club = try string()
        p.clubFull = try string()
        p.league = try string()
        p.clubNation = try string()
        p.region = try string()
        p.area = try string()
        p.areaRecord = try int64()
        p.flags = try byte()
        p.pers = try blob()
        p.personality = try string()
        p.media = try string()
        p.age = try int()
        p.wage = try int()
        p.squad = try string()
        p.loanClub = try string()
        p.loanClubFull = try string()
        p.statusFlags = try byte()
        p.listedYear = try int()
        p.listedDay = try int()
        p.teamIndex = try uint32()
        p.clubObject = try int64()
        p.loanClubObject = try int64()
        p.endYear = try int()
        p.endDay = try int()
        p.loanEndYear = try int()
        p.loanEndDay = try int()
        p.isAtOwnBTeam = try byte() != 0
        p.releaseClause = try int64()
        p.releaseForeign = try int64()
        p.releaseDomestic = try int64()
        if version >= 2 { p.isWoman = try byte() != 0 }
    }

    private mutating func readPlayer() throws -> Player {
        let p = Player()
        try readPerson(into: p)
        p.value = try int64()
        p.ca = try int()
        p.pa = try int()
        p.pos = try blob()
        p.raw = try blob()
        p.traitBits = try varint()
        p.height = try int()
        p.injuries = try optional { reader in
            let total = try reader.count()
            var injuries: [Injury] = []
            injuries.reserveCapacity(total)
            for _ in 0..<total { injuries.append(try reader.readInjury()) }
            return injuries
        }
        p.injury = try optional { try $0.readInjury() }
        p.injuryText = try string()
        p.injuryDays = try int()
        p.topRoles = try blob()
        p.season = try optional { try $0.readSeason() }
        p.form = try string()
        return p
    }

    private mutating func readStaff() throws -> Staff {
        let p = Staff()
        try readPerson(into: p)
        p.ca = try int()
        p.pa = try int()
        p.attr = try blob()
        p.job = try string()
        p.secondJob = try int()
        p.repCurrent = try int()
        p.repHome = try int()
        p.repWorld = try int()
        let total = try count()
        p.stars = []
        p.stars.reserveCapacity(total)
        for _ in 0..<total { p.stars.append(try double()) }
        return p
    }

    private mutating func readInjury() throws -> Injury {
        let record = try int64(), name = try string(), date = try date(), length = try int()
        let injury = Injury()
        injury.record = record
        injury.name = name
        injury.date = date
        injury.length = length
        return injury
    }

    private mutating func readSeason() throws -> SeasonStats {
        var s = SeasonStats()
        s.apps = try int()
        s.starts = try int()
        s.subs = try int()
        s.minutes = try int()
        s.goals = try int()
        s.assists = try int()
        s.rating = try double()
        s.playerOfTheMatch = try int()
        s.yellow = try int()
        s.red = try int()
        s.cleanSheets = try int()
        s.conceded = try int()
        s.xG = try double()
        s.xA = try double()
        s.passPercent = try int()
        s.shotsOnTargetPercent = try int()
        s.tacklePercent = try int()
        s.tackles = try int()
        s.dribbles = try int()
        s.fouls = try int()
        s.fouled = try int()
        return s
    }
}
