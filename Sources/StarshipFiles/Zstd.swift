import CZstd

enum ZstdError: Error {
    case failed(String)
    case truncated
}

enum Zstd {
    static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    static func hasMagic(_ bytes: [UInt8]) -> Bool { bytes.starts(with: magic) }

    /// Decodes every frame in `input`, as the ZstdSharp stream with end-of-stream checking did.
    static func decompress(_ input: [UInt8]) throws -> [UInt8] {
        guard !input.isEmpty else { return [] }
        guard let stream = ZSTD_createDStream() else { throw ZstdError.failed("out of memory") }
        defer { ZSTD_freeDStream(stream) }
        ZSTD_initDStream(stream)

        var output: [UInt8] = []
        // The size is only a hint and a damaged header can claim anything, so it's capped.
        let declared = ZSTD_getFrameContentSize(input, input.count)
        if declared < UInt64.max - 1 { output.reserveCapacity(Int(min(declared, 1 << 28))) }

        let chunkSize = ZSTD_DStreamOutSize()
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var remainder = 0

        try input.withUnsafeBytes { source in
            var inBuffer = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
            var filled = 0
            repeat {
                filled = try chunk.withUnsafeMutableBytes { target in
                    var outBuffer = ZSTD_outBuffer(dst: target.baseAddress, size: target.count, pos: 0)
                    remainder = ZSTD_decompressStream(stream, &outBuffer, &inBuffer)
                    if ZSTD_isError(remainder) != 0 {
                        throw ZstdError.failed(String(cString: ZSTD_getErrorName(remainder)))
                    }
                    return outBuffer.pos
                }
                output.append(contentsOf: chunk[..<filled])
            } while inBuffer.pos < inBuffer.size || (remainder != 0 && filled == chunkSize)
        }
        guard remainder == 0 else { throw ZstdError.truncated }
        return output
    }

    /// One frame with a checksum, so decompressing also proves the data arrived intact.
    static func compress(_ input: [UInt8], level: Int32 = 3) throws -> [UInt8] {
        guard let context = ZSTD_createCCtx() else { throw ZstdError.failed("out of memory") }
        defer { ZSTD_freeCCtx(context) }
        ZSTD_CCtx_setParameter(context, ZSTD_c_compressionLevel, level)
        ZSTD_CCtx_setParameter(context, ZSTD_c_checksumFlag, 1)

        var output = [UInt8](repeating: 0, count: ZSTD_compressBound(input.count))
        let written = ZSTD_compress2(context, &output, output.count, input, input.count)
        if ZSTD_isError(written) != 0 { throw ZstdError.failed(String(cString: ZSTD_getErrorName(written))) }
        output.removeLast(output.count - written)
        return output
    }

    /// A valid frame that holds `data` uncompressed in raw blocks. FM reads these as happily as
    /// its own compressed ones, so writing shortlists needs no compressor.
    static func stored(_ data: [UInt8]) -> [UInt8] {
        var frame = magic
        let length = data.count
        // Frame header: single segment, with the content size in 1, 2 or 4 bytes.
        if length < 256 {
            frame.append(32)
            frame.append(UInt8(length))
        } else if length < 0x10100 {
            frame.append(96)
            frame.appendLE(UInt16(length - 256))
        } else {
            frame.append(160)
            frame.appendLE(Int32(length))
        }

        var offset = 0
        repeat {
            let size = min(0x20000, length - offset)
            let isLast: UInt32 = offset + size >= length ? 1 : 0
            let blockHeader = isLast | UInt32(size) << 3
            frame.append(UInt8(truncatingIfNeeded: blockHeader))
            frame.append(UInt8(truncatingIfNeeded: blockHeader >> 8))
            frame.append(UInt8(truncatingIfNeeded: blockHeader >> 16))
            frame.append(contentsOf: data[offset..<offset + size])
            offset += 0x20000
        } while offset < length
        return frame
    }
}
