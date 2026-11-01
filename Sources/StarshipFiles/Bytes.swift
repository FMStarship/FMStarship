extension Array where Element == UInt8 {
    /// BitConverter.GetBytes: everything in these formats is little-endian.
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_ type: T.Type = T.self, at offset: Int) -> T {
        var value: T = 0
        Swift.withUnsafeMutableBytes(of: &value) { target in
            self.withUnsafeBytes { source in
                target.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[offset..<offset + target.count]))
            }
        }
        return T(littleEndian: value)
    }
}
