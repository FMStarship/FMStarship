import Foundation
import StarshipCore

public enum FMDataError: Error {
    case notAContainer
    case missing(String)
    case badTactic(String)
    case badConstants
}

/// One of the .fmf archives FM keeps its own data in. Same layout as a shortlist, but not encrypted:
/// a 26-byte header, the files, a 9-byte trailer, then a zstd table of contents.
struct FMContainer {
    private static let headerSize = 26
    private static let trailerSize = 9

    private let bytes: [UInt8]
    /// File sizes and offsets by path: "simatch/tactics/styles.xml".
    private(set) var files: [String: (offset: Int, size: Int)] = [:]

    init(_ bytes: [UInt8]) throws {
        self.bytes = bytes
        guard bytes.count > Self.headerSize + Self.trailerSize else { throw FMDataError.notAContainer }
        let end = Int(truncatingIfNeeded: bytes.readLE(UInt64.self, at: 9) &+ 9)
        guard end > Self.headerSize, end + Self.trailerSize < bytes.count, bytes[end + 2..<end + 6].elementsEqual(Array("fmf.".utf8)) else {
            throw FMDataError.notAContainer
        }
        var reader = ShortlistFile.TocReader(bytes: try Zstd.decompress(Array(bytes[(end + Self.trailerSize)...])))
        try walk(&reader, path: "", depth: 0)
    }

    private mutating func walk(_ reader: inout ShortlistFile.TocReader, path: String, depth: Int) throws {
        guard depth < 64 else { throw FMDataError.notAContainer }
        let folder = path + (try reader.string()) + "/"
        for _ in 0..<(try reader.u32()) {
            let name = try reader.string(), ext = try reader.string()
            let offset = try reader.u64(), size = try reader.u64()
            _ = (try reader.u64(), try reader.u64(), try reader.u64())
            files[folder + name + ext] = (Int(truncatingIfNeeded: offset), Int(truncatingIfNeeded: size))
        }
        for _ in 0..<(try reader.u32()) { try walk(&reader, path: folder, depth: depth + 1) }
    }

    func read(_ path: String) throws -> [UInt8] {
        guard let file = files[path] else { throw FMDataError.missing(path) }
        let start = Self.headerSize + file.offset
        guard start >= 0, file.size >= 0, start + file.size <= bytes.count else { throw FMDataError.notAContainer }
        let body = Array(bytes[start..<start + file.size])
        return Zstd.hasMagic(body) ? try Zstd.decompress(body) : body
    }
}

/// FM's binary JSON. A value's tag has its type in the low four bits. The high four hold a small
/// number plus one, or zero when the number follows in full.
enum FMConstants {
    indirect enum Value {
        case number(Double)
        case text(String)
        case list([Value])
        case table([String: Value])

        subscript(key: String) -> Value? {
            if case let .table(entries) = self { return entries[key] }
            return nil
        }

        /// A table of whole numbers.
        var numbers: [String: Int] {
            guard case let .table(entries) = self else { return [:] }
            return entries.compactMapValues { value in
                if case let .number(number) = value { return Int(number) }
                return nil
            }
        }
    }

    static func parse(_ bytes: [UInt8]) throws -> Value {
        var offset = 0
        return try value(bytes, &offset)
    }

    private static func value(_ bytes: [UInt8], _ offset: inout Int) throws -> Value {
        guard offset < bytes.count else { throw FMDataError.badConstants }
        let tag = bytes[offset]
        offset += 1
        let small = Int(tag >> 4)

        func count() throws -> Int {
            if small > 0 { return small - 1 }
            guard offset + 4 <= bytes.count else { throw FMDataError.badConstants }
            defer { offset += 4 }
            return Int(bytes.readLE(UInt32.self, at: offset))
        }

        switch tag & 15 {
        case 0xa:
            var entries: [String: Value] = [:]
            for _ in 0..<(try count()) {
                guard offset < bytes.count else { throw FMDataError.badConstants }
                let length = Int(bytes[offset])
                offset += 1
                guard offset + length <= bytes.count else { throw FMDataError.badConstants }
                let key = String(decoding: bytes[offset..<offset + length], as: UTF8.self)
                offset += length
                entries[key] = try value(bytes, &offset)
            }
            return .table(entries)
        case 0x9:
            var items: [Value] = []
            for _ in 0..<(try count()) { items.append(try value(bytes, &offset)) }
            return .list(items)
        case 0x2:
            if small > 0 { return .number(Double(small - 1)) }
            guard offset + 4 <= bytes.count else { throw FMDataError.badConstants }
            defer { offset += 4 }
            return .number(Double(bytes.readLE(Int32.self, at: offset)))
        case 0x7:
            if small > 0 { return .number(Double(small - 1)) }
            guard offset + 8 <= bytes.count else { throw FMDataError.badConstants }
            defer { offset += 8 }
            return .number(Double(bitPattern: bytes.readLE(UInt64.self, at: offset)))
        case 0x3, 0x4, 0x5, 0x6, 0x8:
            let length = try count()
            guard offset + length <= bytes.count else { throw FMDataError.badConstants }
            defer { offset += length }
            return .text(String(decoding: bytes[offset..<offset + length], as: UTF8.self))
        case 0, 1:
            return .number(Double(small))
        default:
            throw FMDataError.badConstants
        }
    }
}

/// FM's tactic data, straight from the game's files.
public enum FMData {
    private static let archive = "Contents/PlugIns/game_plugin.bundle/Contents/Resources/shared/data/simatch.fmf"
    private static let folder = "simatch/tactics/"

    /// Read once. Nil when the game can't be found or its files have changed shape.
    public static let library: TacticLibrary? = GameLauncher.gameApp.flatMap {
        try? tacticLibrary(archive: $0.appendingPathComponent(archive))
    }

    public static func tacticLibrary(archive: URL) throws -> TacticLibrary {
        let container = try FMContainer([UInt8](Data(contentsOf: archive)))
        let styles = try readStyles(Data(container.read(folder + "styles.xml")))
        var presets: [TacticPreset] = []
        for path in container.files.keys.sorted() where path.hasPrefix(folder) && path.hasSuffix(".tac") {
            presets.append(try readPreset(try container.read(path), path: path))
        }
        guard !presets.isEmpty else { throw FMDataError.missing(folder) }

        let constants = try FMConstants.parse(try container.read("simatch/constants/generated_tactical_complexity_constants.jsb"))
        let player = constants["root"]?["Player"]
        return TacticLibrary(styles: styles, presets: presets, complexity: player?["IP Role"]?.numbers ?? [:],
                             complexityWithoutBall: player?["OOP Role"]?.numbers ?? [:])
    }

    // MARK: Tactics

    /// A .tac file: a header, then eleven pairs of records, with the ball and without it, each pair
    /// followed by its slot number.
    static func readPreset(_ file: [UInt8], path: String) throws -> TacticPreset {
        let tag: [UInt8] = [0x44, 0x00, 0x02]
        guard file.count > 24, let first = file[20...].firstRange(of: tag)?.lowerBound else { throw FMDataError.badTactic(path) }
        let nameLength = Int(file.readLE(UInt32.self, at: 0x10))
        guard 0x14 + nameLength < file.count else { throw FMDataError.badTactic(path) }
        let name = String(decoding: file[0x14..<0x14 + nameLength], as: UTF8.self)

        struct Record {
            let word: UInt32
            let allowed: [UInt64]
            let role: UInt64
        }

        var at = first
        func record() throws -> Record {
            guard at + 14 <= file.count, file[at..<at + 3].elementsEqual(tag) else { throw FMDataError.badTactic(path) }
            let word = file.readLE(UInt32.self, at: at + 3)
            let count = Int(file.readLE(UInt32.self, at: at + 10))
            let items = at + 14
            let end = items + count * 24
            guard count < 64, end + 12 <= file.count else { throw FMDataError.badTactic(path) }
            let allowed = (0..<count).map { file.readLE(UInt64.self, at: items + $0 * 24) }
            at = end + 12
            return Record(word: word, allowed: allowed, role: file.readLE(UInt64.self, at: end + 4))
        }

        func position(_ word: UInt32) -> Int? {
            let bits = word & 0x7fff
            return bits.nonzeroBitCount == 1 ? Names.posToGame.firstIndex(of: bits.trailingZeroBitCount) : nil
        }

        // Three bits of a role word aren't the role.
        func roles(_ word: UInt64) -> Int? {
            let bits = word & ~0xe0_0000
            return bits.nonzeroBitCount == 1 ? bits.trailingZeroBitCount : nil
        }

        var slots: [PresetSlot] = []
        for _ in 0..<11 {
            let with = try record(), without = try record()
            at += 1
            guard let inPosition = position(with.word), let outPosition = position(without.word),
                  let role = roles(with.role), let roleOut = roles(without.role) else { throw FMDataError.badTactic(path) }
            let side = { (word: UInt32) -> TacticSlot.Side in word & 0x10_0000 != 0 ? .left : word & 0x20_0000 != 0 ? .right : .centre }
            slots.append(PresetSlot(position: inPosition, positionWithoutBall: outPosition, side: side(with.word), sideWithoutBall: side(without.word),
                                    role: role, roleWithoutBall: roleOut,
                                    allowedRoles: with.allowed.compactMap(roles).filter { Names.rolesIp[$0] != nil },
                                    allowedRolesWithoutBall: without.allowed.compactMap(roles).filter { Names.rolesOop[$0] != nil }))
        }

        let shapes = shapes(path)
        return TacticPreset(name: name, style: shapes.style, shape: shapes.with, shapeWithoutBall: shapes.without, slots: slots)
    }

    /// ".../gegenpress/4--4-2-3-1 DM AM Wide _ 4-4-2 2DM - gegenpress.tac".
    private static func shapes(_ path: String) -> (style: String, with: String, without: String) {
        let parts = path.split(separator: "/")
        let style = parts.count >= 2 ? String(parts[parts.count - 2]) : ""
        var name = String(parts.last ?? "")
        if let start = name.range(of: "--") { name = String(name[start.upperBound...]) }
        if let tail = name.range(of: " - ", options: .backwards) { name = String(name[..<tail.lowerBound]) }
        let both = name.components(separatedBy: " _ ")
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
        return (style, trim(both.first ?? ""), trim(both.count > 1 ? both[1] : ""))
    }

    // MARK: Styles

    /// FM's preferred roles use old names for a few roles that FM27 has renamed. Roles with no one
    /// clear successor are left out rather than guessed at.
    private static let renamedRoles = [
        "BALL_PLAYING_DEFENDER": "Ball-Playing Centre-Back",
        "SHADOW_STRIKER": "Second Striker",
        "FALSE_NUMBER_NINE": "False Nine",
        "TARGET_MAN": "Target Forward",
    ]

    static func readStyles(_ data: Data) throws -> [TacticStyle] {
        let document = try XMLDocument(data: data, options: [.nodePreserveAll])
        let known = (Names.rolesIp + Names.rolesOop).compactMap { $0 }
        let byKey = Dictionary(known.map { (TacticLibrary.key($0), $0) }, uniquingKeysWith: { first, _ in first })

        return (document.rootElement()?.elements(forName: "record") ?? []).compactMap { style in
            guard let id = style.attribute(forName: "folder")?.stringValue, !id.isEmpty else { return nil }
            let text = { (key: String) -> String in
                style.elements(forName: "translation").first { $0.attribute(forName: "id")?.stringValue == key }.flatMap(Self.translation) ?? ""
            }
            let list = { (key: String) -> XMLElement? in
                style.elements(forName: "list").first { $0.attribute(forName: "id")?.stringValue == key }
            }
            let values = { (key: String) -> [String] in
                list(key)?.elements(forName: "translation").compactMap(Self.translation) ?? []
            }
            let roles = (list("preferred_roles")?.children ?? []).compactMap { node -> String? in
                guard node.kind == .comment, let comment = node.stringValue?.trimmingCharacters(in: .whitespaces),
                      comment.hasPrefix("TPRF_") else { return nil }
                let key = String(comment.dropFirst(5))
                return renamedRoles[key] ?? byKey[key]
            }
            return TacticStyle(id: id, name: text("text"), summary: text("hint"), features: values("features_of_play"),
                               favouredAttributes: values("favoured_attributes"), preferredRoles: roles)
        }
    }

    /// Translated text carries a note to FM's translators on the end.
    private static func translation(_ element: XMLElement) -> String? {
        element.attribute(forName: "value")?.stringValue?.components(separatedBy: "[COMMENT").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
