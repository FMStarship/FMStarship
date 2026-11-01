/// The sanity checks that identify a player or staff record from its bytes alone.
public enum ShapeCheck {
    public static func player(_ b: UnsafeRawBufferPointer, _ o: Int) -> Bool {
        for i in 8..<23 where !(1...20).contains(b[o + i]) { return false }
        for i in 23..<77 where !(1...100).contains(b[o + i]) { return false }
        let ca = b.loadUnaligned(fromByteOffset: o + 0x11c, as: UInt16.self)
        let pa = b.loadUnaligned(fromByteOffset: o + 0x11e, as: UInt16.self)
        return pa >= ca && pa >= 1 && pa <= 200
    }

    public static func staff(_ b: UnsafeRawBufferPointer, _ o: Int) -> Bool {
        for i in 16..<43 where i != 29 && b[o + i] > 20 { return false }
        if b[o + 29] > 100 { return false }
        for i in 43..<68 where b[o + i] > 100 { return false }
        let index = b.loadUnaligned(fromByteOffset: o + 0x108, as: UInt32.self)
        let ca = b.loadUnaligned(fromByteOffset: o + 218, as: UInt16.self)
        let pa = b.loadUnaligned(fromByteOffset: o + 220, as: UInt16.self)
        return index > 0 && index < 10_000_000 && pa >= ca && pa >= 1 && pa <= 200
    }
}
