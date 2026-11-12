import Foundation

/// One build of FM: its version, and GameAssembly's UUID, which is new each time FM's game code is built. The plugin's
/// names live in GameAssembly, so this is what says whether the plugin was checked on it. The rules keep their own check,
/// on game_plugin's fingerprint, because a patch can change one and not the other.
public struct FMBuild: Hashable, Sendable, CustomStringConvertible {
    public let version: String
    public let gameAssembly: String

    public init(version: String, gameAssembly: String) {
        self.version = version
        self.gameAssembly = gameAssembly.uppercased()
    }

    public var description: String { "\(version) \(gameAssembly)" }

    /// The build of an installed fm.app, read from its files: the version from Info.plist, and the UUID of
    /// GameAssembly's arm64 slice. Nil if either can't be read.
    public static func installed(app: URL) -> FMBuild? {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty,
              let uuid = MachO.arm64UUID(ofFile: contents.appendingPathComponent("Frameworks/GameAssembly.dylib")) else { return nil }
        return FMBuild(version: version, gameAssembly: uuid)
    }
}

/// The builds of FM the plugin has been checked on. It stays out of any other, until an update of FM Starship lists it.
/// Patch day adds each new build here once the plugin has run on it, as `ops/roles/patch-day.md` says.
public enum CheckedBuilds {
    public static let list: [FMBuild] = [
        FMBuild(version: "27.0.0.2493426", gameAssembly: "18C040AA-177A-3278-8CBD-E5289254D4FA"),
        FMBuild(version: "27.0.1.2494769", gameAssembly: "94BE5439-0807-3A78-8C32-E1F12FE5E7BB"),
        FMBuild(version: "27.0.1.2503222", gameAssembly: "61843D56-DEEF-3A03-A86C-3C92DA3E2455"),
    ]

    public static func contains(_ build: FMBuild, in list: [FMBuild] = list) -> Bool { list.contains(build) }
}

/// Whether the plugin starts inside FM, decided before it touches anything of FM's.
public enum PluginGate: Equatable, Sendable {
    /// A checked build: it starts.
    case run
    /// A build nobody has checked, with the developer tools built in: it starts, because that's how a build gets checked.
    case runUnchecked
    /// A build nobody has checked, or one that couldn't be read: it adds nothing to FM.
    case off

    public static func decide(_ build: FMBuild?, developer: Bool, checked: [FMBuild] = CheckedBuilds.list) -> PluginGate {
        if let build, CheckedBuilds.contains(build, in: checked) { return .run }
        return developer ? .runUnchecked : .off
    }
}

/// Reads a Mach-O file's UUID without loading it, and without reading more than its headers.
public enum MachO {
    static let arm64: UInt32 = 0x0100_000c

    /// The UUID of the arm64 code in a file, whether it's a universal file or a single architecture. Nil if there's none.
    public static func arm64UUID(ofFile url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return arm64UUID { offset, count in
            guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
            return try? handle.read(upToCount: count)
        }
    }

    /// The same, from whatever `read` gives for an offset and a length. Every length is checked, so a short or broken file
    /// gives nil, never a trap.
    static func arm64UUID(read: (UInt64, Int) -> Data?) -> String? {
        guard let head = read(0, 4096).map({ [UInt8]($0) }), let magic = head.word(0, bigEndian: true) else { return nil }
        var slice: UInt64 = 0
        if magic == 0xcafe_babe || magic == 0xcafe_babf {
            let wide = magic == 0xcafe_babf
            let entry = wide ? 32 : 20
            guard let count = head.word(4, bigEndian: true), count <= 64 else { return nil }
            var found: UInt64?
            for index in 0..<Int(count) {
                let at = 8 + index * entry
                guard let cpu = head.word(at, bigEndian: true) else { return nil }
                guard cpu == arm64 else { continue }
                found = wide ? head.wide(at + 8) : head.word(at + 8, bigEndian: true).map(UInt64.init)
                break
            }
            // Past a terabyte isn't a real file, and the sums below can't overflow.
            guard let found, found < 1 << 40 else { return nil }
            slice = found
        }
        guard let header = read(slice, 32).map({ [UInt8]($0) }), header.word(0, bigEndian: false) == 0xfeed_facf,
              header.word(4, bigEndian: false) == arm64, let count = header.word(16, bigEndian: false),
              let size = header.word(20, bigEndian: false), size <= 4 << 20,
              let commands = read(slice + 32, Int(size)).map({ [UInt8]($0) }), commands.count == Int(size) else { return nil }
        var offset = 0
        for _ in 0..<count {
            guard let command = commands.word(offset, bigEndian: false), let length = commands.word(offset + 4, bigEndian: false),
                  length >= 8, offset + Int(length) <= commands.count else { return nil }
            // LC_UUID: the command, its size, then 16 bytes.
            if command == 0x1b, length >= 24 {
                let b = Array(commands[(offset + 8)..<(offset + 24)])
                return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                                   b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])).uuidString
            }
            offset += Int(length)
        }
        return nil
    }
}

private extension [UInt8] {
    func word(_ at: Int, bigEndian: Bool) -> UInt32? {
        guard at >= 0, at + 4 <= count else { return nil }
        let bytes = self[at..<(at + 4)].map(UInt32.init)
        return bigEndian ? bytes.reduce(0) { $0 << 8 | $1 } : bytes.reversed().reduce(0) { $0 << 8 | $1 }
    }

    /// A big-endian 64-bit value, as a universal file's 64-bit table has them.
    func wide(_ at: Int) -> UInt64? {
        guard let high = word(at, bigEndian: true), let low = word(at + 4, bigEndian: true) else { return nil }
        return UInt64(high) << 32 | UInt64(low)
    }
}
