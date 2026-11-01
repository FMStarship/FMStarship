import CommonCrypto
import Foundation

public struct Shortlist: Equatable {
    public var name: String
    public var isStaff: Bool
    public var uids: [UInt32]

    public init(name: String, isStaff: Bool, uids: [UInt32]) {
        self.name = name
        self.isStaff = isStaff
        self.uids = uids
    }
}

public enum ShortlistError: Error, Equatable, LocalizedError {
    case notFMFile
    case damaged
    case notShortlist
    case emptyName
    case alreadyExists(URL)
    case pictureFailed

    public var errorDescription: String? {
        switch self {
        case .notFMFile: return "This isn't an FM shortlist file."
        case .damaged: return "The shortlist looks damaged."
        case .notShortlist: return "This FM file isn't a player or staff shortlist."
        case .emptyName: return "A shortlist needs a name."
        case .alreadyExists(let url): return "There's already a shortlist file called \"\(url.deletingPathExtension().lastPathComponent)\"."
        case .pictureFailed: return "Couldn't draw the shortlist's picture."
        }
    }
}

/// FM's .fmf container: a 26-byte header, the AES-CTR encrypted files, a 9-byte trailer, then a
/// zstd-framed table of contents that lays the files out as folders.
public enum ShortlistFile {
    public static let fileExtension = "fmf"
    public static let backupSuffix = ".bak"

    /// Every encrypted file starts with this: the key length and IV length, as int32s.
    private static let mark: [UInt8] = [16, 0, 0, 0, 16, 0, 0, 0]
    private static let headerSize = 26
    private static let cipherHeaderSize = mark.count + 16 + 16
    /// Stamped on the details file; it's 0001-01-01 in Unix seconds.
    private static let nullTime = UInt64(bitPattern: -0xE7791F700)

    // MARK: Reading

    public static func read(_ url: URL) throws -> Shortlist {
        try parse([UInt8](Data(contentsOf: url)))
    }

    public static func parse(_ file: [UInt8]) throws -> Shortlist {
        guard file.count > 96, [Array("afe.".utf8), Array("fmf.".utf8)].contains(Array(file[2..<6])),
              file[26..<34].elementsEqual(mark)
        else { throw ShortlistError.notFMFile }

        let bodyEnd = Int64(truncatingIfNeeded: file.readLE(UInt64.self, at: 9) &+ 9)
        guard bodyEnd >= 66, bodyEnd <= file.count - 9 else { throw ShortlistError.damaged }
        let end = Int(bodyEnd)

        // Older files have no readable table of contents, just the list right after the header.
        guard let toc = try? Zstd.decompress(Array(file[(end + 9)...])) else {
            return try parseList(ctr(key: file[34..<50], iv: file[50..<66], file[66..<end]))
        }

        var reader = TocReader(bytes: toc)
        var found: (offset: UInt64, size: UInt64)?
        try reader.walkFolder(depth: 0, found: &found)
        guard let entry = found else { throw ShortlistError.notShortlist }

        let start = headerSize + Int(Int32(truncatingIfNeeded: entry.offset))
        let size = Int(Int32(truncatingIfNeeded: entry.size))
        guard start >= headerSize, size >= cipherHeaderSize, start + size <= end,
              file[start..<start + mark.count].elementsEqual(mark)
        else { throw ShortlistError.damaged }

        var plain = ctr(key: file[start + 8..<start + 24], iv: file[start + 24..<start + 40],
                        file[start + 40..<start + size])
        if Zstd.hasMagic(plain) {
            guard let inflated = try? Zstd.decompress(plain) else { throw ShortlistError.damaged }
            plain = inflated
        }
        return try parseList(plain)
    }

    private static func parseList(_ data: [UInt8]) throws -> Shortlist {
        guard data.count >= 6 else { throw ShortlistError.notShortlist }
        let kind = Array(data[2..<6])
        let isStaff = kind == Array("fss.".utf8)
        guard isStaff || kind == Array("fls.".utf8) else { throw ShortlistError.notShortlist }

        guard data.count >= 17 else { throw ShortlistError.damaged }
        let nameLength = Int(data.readLE(Int32.self, at: 13))
        guard nameLength >= 0, 17 + nameLength + 4 <= data.count else { throw ShortlistError.damaged }
        let name = String(decoding: data[17..<17 + nameLength], as: UTF8.self)

        let countOffset = 17 + nameLength
        let count = Int(data.readLE(Int32.self, at: countOffset))
        let first = countOffset + 4
        guard count >= 0, first + 4 * count <= data.count else { throw ShortlistError.damaged }
        let uids = (0..<count).map { data.readLE(UInt32.self, at: first + 4 * $0) }
        return Shortlist(name: name, isStaff: isStaff, uids: uids)
    }

    struct TocReader {
        let bytes: [UInt8]
        var offset = 0

        mutating func u32() throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw ShortlistError.damaged }
            defer { offset += 4 }
            return bytes.readLE(at: offset)
        }

        mutating func u64() throws -> UInt64 {
            guard offset + 8 <= bytes.count else { throw ShortlistError.damaged }
            defer { offset += 8 }
            return bytes.readLE(at: offset)
        }

        mutating func string() throws -> String {
            let length = Int(try u32())
            guard length <= bytes.count - offset else { throw ShortlistError.damaged }
            defer { offset += length }
            return String(decoding: bytes[offset..<offset + length], as: UTF8.self)
        }

        /// Finds the first .slf or .ssf file. The depth limit is only there for corrupt tables.
        mutating func walkFolder(depth: Int, found: inout (offset: UInt64, size: UInt64)?) throws {
            guard depth < 64 else { throw ShortlistError.damaged }
            _ = try string()
            for _ in 0..<(try u32()) {
                _ = try string()
                let ext = try string()
                let offset = try u64(), size = try u64()
                _ = (try u64(), try u64(), try u64())
                if ext == ".slf" || ext == ".ssf", found == nil { found = (offset, size) }
            }
            for _ in 0..<(try u32()) { try walkFolder(depth: depth + 1, found: &found) }
        }
    }

    // MARK: Writing

    /// Replaces the file atomically, so a failed save can't cost the user a shortlist.
    public static func write(to url: URL, name: String, isStaff: Bool, uids: some Sequence<UInt32>) throws {
        try Data(encode(name: name, isStaff: isStaff, uids: uids)).write(to: url, options: .atomic)
    }

    public static func encode(name: String, isStaff: Bool, uids: some Sequence<UInt32>, date: Date = Date()) throws -> [UInt8] {
        var seen = Set<UInt32>()
        let unique = uids.filter { seen.insert($0).inserted }
        let now = UInt64(date.timeIntervalSince1970)
        let nameBytes = Array(name.utf8)

        let files: [ContainedFile] = [
            ContainedFile(name: nameBytes, ext: isStaff ? ".ssf" : ".slf",
                          data: listData(nameBytes, isStaff: isStaff, uids: unique), time: now),
            ContainedFile(name: Array("shortlists".utf8), ext: ".jpg",
                          data: try picture(count: unique.count, isStaff: isStaff), time: now),
            ContainedFile(name: Array("details".utf8), ext: ".aom", data: detailsData(nameBytes), time: nullTime),
        ]

        var body: [UInt8] = []
        var entries: [(offset: UInt64, size: UInt64)] = []
        for file in files {
            let start = body.count
            let key = randomBytes(16), iv = randomBytes(16)
            body += mark
            body += key
            body += iv
            body += ctr(key: key[...], iv: iv[...], file.data[...])
            entries.append((UInt64(start), UInt64(body.count - start)))
        }

        var toc: [UInt8] = []
        func addFile(_ index: Int) {
            let file = files[index]
            toc.appendString(file.name)
            toc.appendString(Array(file.ext.utf8))
            for value in [entries[index].offset, entries[index].size, UInt64(file.data.count), file.time, file.time] {
                toc.appendLE(value)
            }
        }
        toc.appendString(nameBytes)
        toc.appendLE(Int32(2))
        addFile(0)
        addFile(1)
        toc.appendLE(Int32(1))
        toc.appendString(Array("_data".utf8))
        toc.appendLE(Int32(1))
        addFile(2)
        toc.appendLE(Int32(0))

        var header = [UInt8](repeating: 0, count: headerSize)
        header[0] = 2
        header[1] = 1
        header.replaceSubrange(2..<6, with: Array("afe.".utf8))
        header[6] = 8
        header.replaceSubrange(9..<17, with: leBytes(Int64(headerSize + body.count) - 9))
        header.replaceSubrange(17..<25, with: leBytes(Int64(17)))

        let trailer: [UInt8] = [0x02, 0x01, 0x66, 0x6D, 0x66, 0x2E, 0x08, 0x00, 0x00]
        return header + body + trailer + Zstd.stored(toc)
    }

    private struct ContainedFile {
        let name: [UInt8]
        let ext: String
        let data: [UInt8]
        let time: UInt64
    }

    private static func listData(_ name: [UInt8], isStaff: Bool, uids: [UInt32]) -> [UInt8] {
        var list: [UInt8] = [3, 1]
        list += Array((isStaff ? "fss." : "fls.").utf8)
        list += [2, 0, 1]
        list.appendLE(Int32.random(in: 0x100000..<0x7FFF_FFFF))
        list.appendString(name)
        list.appendLE(Int32(uids.count))
        for uid in uids { list.appendLE(uid) }
        list.append(0)
        return list
    }

    /// The handler name really is the player one for staff lists as well.
    private static func detailsData(_ name: [UInt8]) -> [UInt8] {
        var details: [UInt8] = [3, 1]
        details += Array("moa.".utf8)
        details += [4, 0]
        details.appendString(Array("PLAYER_SHORTLIST_TYPE_HANDLER".utf8))
        details.appendString(name)
        details += [UInt8](repeating: 0, count: 10)
        details += [UInt8](repeating: 255, count: 16)
        details.appendString(Array("FM Starship".utf8))
        details += [2, 0, 1, 0, 2]
        details += [UInt8](repeating: 0, count: 4)
        details += [1, 0, 16, 1, 3]
        details += [UInt8](repeating: 0, count: 8)
        return details
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: .min ... .max) }
    }

    private static func leBytes(_ value: Int64) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendLE(value)
        return bytes
    }

    // MARK: Cipher

    /// AES-128 in counter mode, with the whole IV as one big-endian counter.
    private static func ctr(key: ArraySlice<UInt8>, iv: ArraySlice<UInt8>, _ input: ArraySlice<UInt8>) -> [UInt8] {
        var cryptor: CCCryptorRef?
        let status = Array(key).withUnsafeBytes {
            CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            $0.baseAddress, $0.count, nil, &cryptor)
        }
        precondition(status == kCCSuccess, "AES setup can't fail with a 16-byte key")
        defer { CCCryptorRelease(cryptor) }

        var counter = Array(iv)
        var keystream = [UInt8](repeating: 0, count: 16)
        var output = Array(input)
        var moved = 0
        for blockStart in stride(from: 0, to: output.count, by: 16) {
            CCCryptorUpdate(cryptor, counter, 16, &keystream, 16, &moved)
            for i in 0..<min(16, output.count - blockStart) { output[blockStart + i] ^= keystream[i] }
            for i in (0..<16).reversed() {
                counter[i] &+= 1
                if counter[i] != 0 { break }
            }
        }
        return output
    }
}

private extension Array where Element == UInt8 {
    /// The container's length-prefixed string.
    mutating func appendString(_ bytes: [UInt8]) {
        appendLE(Int32(bytes.count))
        append(contentsOf: bytes)
    }
}
