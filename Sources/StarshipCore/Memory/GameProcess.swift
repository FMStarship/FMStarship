import CStarshipProtocol
import Darwin
import Foundation
import MachO

/// The running game, seen through the agent, or directly when FM Starship runs inside FM as a plugin.
/// Same job as FM Moleman's GameProcess on Windows.
public final class GameProcess: @unchecked Sendable {
    public static let agentLibraryEnv = "DYLD_INSERT_LIBRARIES"

    public let pid: Int32
    public let pluginBase: Int64
    public let pluginSize: Int64
    public let pluginPath: String
    public let regions: [(base: Int64, size: Int64, writable: Bool)]
    /// True inside FM, where reads go straight to memory instead of through the agent.
    public let inside: Bool
    /// Inside FM, the regions of malloc's tiny, small and nano zones, sorted. See `inSmallHeap`.
    private let smallHeap: [(base: Int64, end: Int64)]

    private let lock = NSLock()
    private var idle: [AgentConnection] = []
    private var traffic = (requests: 0, bytes: 0)

    static let smallHeapTags: Set<UInt32> = [1, 2, 7, 11]
    /// Thread stacks hold none of FM's records. Inside FM they hold the reader's own copies of the class tables it
    /// sweeps for, which would read as more records, so the sweep leaves them out.
    static let stackTag: UInt32 = 30

    private init(pid: Int32, plugin: (base: Int64, size: Int64, path: String),
                 regions: [(base: Int64, size: Int64, writable: Bool)], smallHeap: [(base: Int64, end: Int64)] = [], inside: Bool) {
        self.pid = pid
        pluginBase = plugin.base
        pluginSize = plugin.size
        pluginPath = plugin.path
        self.regions = regions
        self.smallHeap = smallHeap
        self.inside = inside
    }

    /// True for an address in malloc's small zones inside FM. FM keeps its people in larger blocks, while the reader's
    /// own copies of people land in these zones as it sweeps, so a person found here is one of those copies.
    /// FM does keep other records here, such as human managers, so the sweep still covers these zones.
    public func inSmallHeap(_ address: Int64) -> Bool {
        var low = 0, high = smallHeap.count
        while low < high {
            let middle = (low + high) / 2
            if smallHeap[middle].end <= address { low = middle + 1 } else { high = middle }
        }
        return low < smallHeap.count && smallHeap[low].base <= address
    }

    private static let gameExecutable = "/fm.app/Contents/MacOS/Football Manager 27"

    public static func runningPID() -> Int32? {
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = pids.withUnsafeMutableBufferPointer {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            if path.hasSuffix(gameExecutable) { return pid }
        }
        return nil
    }

    /// True when this code is running inside FM itself, as the plugin.
    public static var runsInsideGame: Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 && String(cString: buffer).hasSuffix(gameExecutable)
    }

    public convenience init() throws {
        guard let pid = GameProcess.runningPID() else { throw AgentError.notRunning }
        let first = try AgentConnection(pid: pid)
        let hello = try first.hello()
        guard hello.version == STARSHIP_PROTOCOL_VERSION else { throw AgentError.protocolMismatch(hello.version) }

        let images = try first.images().map { image in
            (image, withUnsafeBytes(of: image.path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) })
        }
        guard let (plugin, path) = images.first(where: { $0.1.hasSuffix("/game_plugin") }) else {
            throw AgentError.notRunning
        }
        let regions = try first.regions().map { (base: Int64($0.base), size: Int64($0.size), writable: $0.protection & 2 != 0) }
        self.init(pid: pid, plugin: (Int64(plugin.base), Int64(plugin.size), path), regions: regions, inside: false)
        idle = [first]
    }

    /// The game from inside it, for FM Starship running as a plugin. Built the same way as the agent's answers.
    public static func insideGame() throws -> GameProcess {
        guard let game = inside(imageEndingWith: "/game_plugin") else { throw AgentError.notRunning }
        return game
    }

    /// Tests stand in another loaded image for FM's.
    static func inside(imageEndingWith suffix: String) -> GameProcess? {
        guard let plugin = localImage(endingWith: suffix) else { return nil }
        let (regions, smallHeap) = localRegions()
        return GameProcess(pid: getpid(), plugin: plugin, regions: regions, smallHeap: smallHeap, inside: true)
    }

    private static func localImage(endingWith suffix: String) -> (base: Int64, size: Int64, path: String)? {
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i), let header = _dyld_get_image_header(i) else { continue }
            let path = String(cString: name)
            guard path.hasSuffix(suffix) else { continue }
            let base = UnsafeRawPointer(header)
            let slide = Int64(_dyld_get_image_vmaddr_slide(i))
            var end = Int64(Int(bitPattern: base))
            var cursor = base + MemoryLayout<mach_header_64>.size
            for _ in 0..<base.load(as: mach_header_64.self).ncmds {
                let command = cursor.load(as: load_command.self)
                if command.cmd == UInt32(LC_SEGMENT_64) {
                    let segment = cursor.load(as: segment_command_64.self)
                    let segmentName = withUnsafeBytes(of: segment.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    if segmentName != "__LINKEDIT", segmentName != "__PAGEZERO" {
                        end = max(end, Int64(segment.vmaddr) + slide + Int64(segment.vmsize))
                    }
                }
                cursor += Int(command.cmdsize)
            }
            let start = Int64(Int(bitPattern: base))
            return (start, end - start, path)
        }
        return nil
    }

    /// Readable regions holding real data, apart from thread stacks, and which of them belong to malloc's small zones.
    private static func localRegions() -> (regions: [(base: Int64, size: Int64, writable: Bool)], smallHeap: [(base: Int64, end: Int64)]) {
        var rows: [(base: Int64, size: Int64, writable: Bool)] = []
        var smallHeap: [(base: Int64, end: Int64)] = []
        var address: mach_vm_address_t = 0
        while true {
            var size: mach_vm_size_t = 0
            var depth: natural_t = 0
            var info = vm_region_submap_info_data_64_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                    mach_vm_region_recurse(mach_task_self_, &address, &size, &depth, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { break }
            let touched = info.pages_resident + info.pages_swapped_out + info.pages_dirtied > 0
            if info.is_submap == 0, info.protection & VM_PROT_READ != 0, touched, info.user_tag != stackTag {
                rows.append((Int64(address), Int64(size), info.protection & VM_PROT_WRITE != 0))
                if smallHeapTags.contains(info.user_tag) { smallHeap.append((Int64(address), Int64(address + size))) }
            }
            address += size
        }
        return (rows, smallHeap)
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
        if inside {
            // Like the agent: a bad address comes back as an error rather than a crash.
            var got: mach_vm_size_t = 0
            let result = mach_vm_read_overwrite(mach_task_self_, mach_vm_address_t(address), mach_vm_size_t(count),
                                                mach_vm_address_t(UInt(bitPattern: buffer)), &got)
            return result == KERN_SUCCESS && got == mach_vm_size_t(count)
        }
        let limit = Int(STARSHIP_MAX_READ)
        var requests = 0, bytes = 0
        let done = (try? withConnection { connection in
            var offset = 0
            while offset < count {
                let chunk = min(limit, count - offset)
                requests += 1
                guard try connection.read(address: UInt64(address) + UInt64(offset), into: buffer + offset, length: chunk) else {
                    return false
                }
                bytes += chunk
                offset += chunk
            }
            return true
        }) ?? false
        lock.lock()
        traffic.requests += requests
        traffic.bytes += bytes
        lock.unlock()
        return done
    }

    /// Reads asked of the agent so far, and the bytes they brought back, for timing a read. Swift's own atomics need
    /// macOS 15, so these are kept under the pool's lock, which costs nothing next to a round trip. Zero inside FM.
    public var agentTraffic: (requests: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return traffic
    }

    public func read(_ address: Int64, count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        return bytes.withUnsafeMutableBytes { read(address, into: $0.baseAddress!, count: count) } ? bytes : nil
    }

    /// The bytes at an address, for one look. Inside FM they're read into a fresh allocation of their own, as the agent
    /// does, not a malloc buffer that could land in a region still to be swept and be found again as more people.
    public func withBytes<T>(_ address: Int64, count: Int, _ body: (UnsafeRawBufferPointer) -> T) -> T? {
        guard inside else {
            guard let bytes = read(address, count: count) else { return nil }
            return bytes.withUnsafeBytes(body)
        }
        guard count > 0 else { return nil }
        var buffer: mach_vm_address_t = 0
        guard mach_vm_allocate(mach_task_self_, &buffer, mach_vm_size_t(count), VM_FLAGS_ANYWHERE) == KERN_SUCCESS else { return nil }
        defer { mach_vm_deallocate(mach_task_self_, buffer, mach_vm_size_t(count)) }
        let pointer = UnsafeMutableRawPointer(bitPattern: UInt(buffer))!
        guard read(address, into: pointer, count: count) else { return nil }
        return body(UnsafeRawBufferPointer(start: pointer, count: count))
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
