import Foundation

/// Finds C++ vtables in game_plugin by class name, using Itanium RTTI. The Mac counterpart of
/// FM Moleman's MSVC RTTI walk. Addresses are offsets from the start of the image.
public final class Rtti {
    public let image: [UInt8]
    public let base: Int64

    public init(_ game: GameProcess) {
        base = game.pluginBase
        var bytes = [UInt8](repeating: 0, count: Int(game.pluginSize))
        let chunk = 1 << 20
        DispatchQueue.concurrentPerform(iterations: (bytes.count + chunk - 1) / chunk) { i in
            let offset = i * chunk
            let count = min(chunk, Int(game.pluginSize) - offset)
            let target = bytes.withUnsafeMutableBytes { $0.baseAddress! + offset }
            _ = game.read(game.pluginBase + Int64(offset), into: target, count: count)
        }
        image = bytes
    }

    public func word(_ offset: Int) -> Int64 {
        guard offset >= 0, offset + 8 <= image.count else { return 0 }
        return image.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int64.self) }
    }

    public func find(_ needle: [UInt8], from start: Int = 0) -> Int? {
        image.withUnsafeBytes { hay -> Int? in
            needle.withUnsafeBytes { pat -> Int? in
                guard start < hay.count, let found = memmem(hay.baseAddress! + start, hay.count - start, pat.baseAddress!, pat.count) else { return nil }
                return UnsafeRawPointer(found) - hay.baseAddress!
            }
        }
    }

    /// Every aligned location in the image that holds this absolute address.
    public func pointers(to target: Int64) -> [Int] {
        image.withUnsafeBytes { raw -> [Int] in
            let words = raw.bindMemory(to: Int64.self)
            var hits: [Int] = []
            for i in 0..<words.count where words[i] == target { hits.append(i * 8) }
            return hits
        }
    }

    /// The class of the object whose vtable is at this address, spelled as RTTI spells it.
    public func className(vtable: Int64) -> String? {
        let offset = vtable &- base
        guard offset >= 8, offset < image.count else { return nil }
        let info = word(Int(offset) - 8) &- base
        guard info > 0, info < image.count - 16 else { return nil }
        let name = (word(Int(info) + 8) & Int64.max) &- base
        guard name > 0, name < image.count else { return nil }
        let start = Int(name)
        guard let end = image[start..<min(start + 256, image.count)].firstIndex(of: 0), end > start,
              image[start..<end].allSatisfy({ (33...126).contains($0) }) else { return nil }
        return String(decoding: image[start..<end], as: UTF8.self)
    }

    /// Class names as RTTI spells them: "N2db4TEAME", "N7simatch..." or "18GAME_ACTUAL_PLAYER".
    public static func mangled(_ name: String) -> [String] {
        ["N2db\(name.count)\(name)E", "N7simatch\(name.count)\(name)E", "\(name.count)\(name)"]
    }

    public struct VTable {
        public let offsetToTop: Int64
        public let addressPoint: Int
    }

    public func vtables(_ name: String) -> [VTable] {
        var result: [VTable] = []
        for spelling in Rtti.mangled(name) {
            var from = 0
            while let at = find(Array(spelling.utf8) + [0], from: from) {
                from = at + 1
                // The mangled name must start the string, or "4TEAM" would match inside "N2db4TEAM".
                if at > 0, let previous = Optional(image[at - 1]),
                   (48...57).contains(previous) || (65...90).contains(previous) || (97...122).contains(previous) || previous == 95 {
                    continue
                }
                // Apple arm64 sets the top bit on the name pointer of non-unique (hidden) type_info.
                let nameAddress = base + Int64(at)
                let nonUnique = Int64(bitPattern: UInt64(bitPattern: nameAddress) | (1 << 63))
                for nameSlot in pointers(to: nameAddress) + pointers(to: nonUnique) {
                    let typeInfo = nameSlot - 8
                    for slot in pointers(to: base + Int64(typeInfo)) {
                        let top = word(slot - 8)
                        guard top <= 0, top > -0x10000 else { continue }
                        result.append(VTable(offsetToTop: top, addressPoint: slot + 8))
                    }
                }
            }
        }
        return result.sorted { $0.offsetToTop > $1.offsetToTop }
    }
}
