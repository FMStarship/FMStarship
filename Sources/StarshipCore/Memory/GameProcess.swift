import CStarshipProtocol
import Darwin
import Foundation

/// The running game, seen through the agent. Same job as FM Moleman's GameProcess on Windows.
public final class GameProcess: @unchecked Sendable {
    public static let agentLibraryEnv = "DYLD_INSERT_LIBRARIES"

    public let pid: Int32
    public let pluginBase: Int64
    public let pluginSize: Int64
    public let pluginPath: String
    public let regions: [(base: Int64, size: Int64, writable: Bool)]

    private let lock = NSLock()
    private var idle: [AgentConnection] = []

    public static func runningPID() -> Int32? {
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = pids.withUnsafeMutableBufferPointer {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            if path.hasSuffix("/fm.app/Contents/MacOS/Football Manager 27") { return pid }
        }
        return nil
    }

    public init() throws {
        guard let pid = GameProcess.runningPID() else { throw AgentError.notRunning }
        self.pid = pid
        let first = try AgentConnection(pid: pid)
        let hello = try first.hello()
        guard hello.version == STARSHIP_PROTOCOL_VERSION else { throw AgentError.protocolMismatch(hello.version) }

        let images = try first.images().map { image in
            (image, withUnsafeBytes(of: image.path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) })
        }
        guard let (plugin, path) = images.first(where: { $0.1.hasSuffix("/game_plugin") }) else {
            throw AgentError.notRunning
        }
        pluginPath = path
        pluginBase = Int64(plugin.base)
        pluginSize = Int64(plugin.size)
        regions = try first.regions().map { (Int64($0.base), Int64($0.size), $0.protection & 2 != 0) }
        idle = [first]
    }

    private func withConnection<T>(_ body: (AgentConnection) throws -> T) throws -> T {
        lock.lock()
        let reused = idle.popLast()
        lock.unlock()
        let connection = try reused ?? AgentConnection(pid: pid)
        defer {
            lock.lock()
            idle.append(connection)
            lock.unlock()
        }
        return try body(connection)
    }

    /// False when the address is not mapped, like ReadProcessMemory. Larger reads are split.
    public func read(_ address: Int64, into buffer: UnsafeMutableRawPointer, count: Int) -> Bool {
        guard address > 0x10000, address < 0x7fff_ffff_ffff else { return false }
        let limit = Int(STARSHIP_MAX_READ)
        return (try? withConnection { connection in
            var offset = 0
            while offset < count {
                let chunk = min(limit, count - offset)
                guard try connection.read(address: UInt64(address) + UInt64(offset), into: buffer + offset, length: chunk) else {
                    return false
                }
                offset += chunk
            }
            return true
        }) ?? false
    }

    public func read(_ address: Int64, count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        return bytes.withUnsafeMutableBytes { read(address, into: $0.baseAddress!, count: count) } ? bytes : nil
    }

    public func readPointer(_ address: Int64) -> Int64 {
        var value: Int64 = 0
        return read(address, into: &value, count: 8) ? value : 0
    }

    /// FM's strings: a 32-bit length followed by UTF-8.
    public func lengthPrefixedString(_ address: Int64) -> String {
        guard address != 0 else { return "" }
        var length: Int32 = 0
        guard read(address, into: &length, count: 4), length > 0, length < 200,
              let bytes = read(address + 4, count: Int(length)) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func nameEntry(_ address: Int64) -> String {
        address == 0 ? "" : lengthPrefixedString(readPointer(address))
    }

    /// Fixed-size pieces of every readable region, overlapping so that a record that straddles
    /// two pieces is still seen whole in one of them.
    public func pieces(size: Int, overlap: Int, writableOnly: Bool = false) -> [(address: Int64, count: Int)] {
        var result: [(Int64, Int)] = []
        for region in regions where !writableOnly || region.writable {
            var offset: Int64 = 0
            while offset < region.size {
                let count = Int(min(Int64(size), region.size - offset))
                result.append((region.base + offset, count))
                offset += Int64(count == size ? count - overlap : count)
            }
        }
        return result
    }
}
