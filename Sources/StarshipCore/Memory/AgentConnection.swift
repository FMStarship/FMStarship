import CStarshipProtocol
import Darwin
import Foundation

public enum AgentError: Error, CustomStringConvertible {
    case notRunning
    case connectionLost
    case protocolMismatch(UInt32)

    public var description: String {
        switch self {
        case .notRunning: return "Football Manager isn't running with FM Starship's agent."
        case .connectionLost: return "Lost the connection to Football Manager."
        case .protocolMismatch(let version): return "The agent inside FM is version \(version). Restart FM from FM Starship."
        }
    }
}

/// One socket to the agent. Not thread-safe: GameProcess keeps a pool of these.
final class AgentConnection {
    private let fd: Int32

    init(pid: Int32) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentError.notRunning }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = AgentConnection.socketPath(pid: pid)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            _ = path.withCString { strlcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, capacity) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw AgentError.notRunning
        }
    }

    deinit { close(fd) }

    static func socketPath(pid: Int32) -> String { "/tmp/fmstarship-\(getuid())-\(pid).sock" }

    private func sendAll(_ data: UnsafeRawPointer, _ size: Int) -> Bool {
        var sent = 0
        while sent < size {
            let n = send(fd, data + sent, size - sent, 0)
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    private func receiveAll(_ data: UnsafeMutableRawPointer, _ size: Int) -> Bool {
        var got = 0
        while got < size {
            let n = recv(fd, data + got, size - got, 0)
            if n <= 0 { return false }
            got += n
        }
        return true
    }

    private func call(op: Int32, address: UInt64 = 0, length: UInt32 = 0) throws -> starship_response {
        var request = starship_request(op: UInt32(op), length: length, address: address)
        guard sendAll(&request, MemoryLayout<starship_request>.size) else { throw AgentError.connectionLost }
        var response = starship_response()
        guard receiveAll(&response, MemoryLayout<starship_response>.size) else { throw AgentError.connectionLost }
        return response
    }

    func read(address: UInt64, into buffer: UnsafeMutableRawPointer, length: Int) throws -> Bool {
        let response = try call(op: Int32(STARSHIP_OP_READ), address: address, length: UInt32(length))
        guard Int(response.status) == STARSHIP_OK else { return false }
        guard Int(response.length) == length, receiveAll(buffer, length) else { throw AgentError.connectionLost }
        return true
    }

    private func table<Row>(op: Int32, of: Row.Type) throws -> [Row] {
        let response = try call(op: op)
        guard Int(response.status) == STARSHIP_OK else { return [] }
        let count = Int(response.length) / MemoryLayout<Row>.stride
        return try [Row](unsafeUninitializedCapacity: count) { rows, initialized in
            guard receiveAll(rows.baseAddress!, Int(response.length)) else { throw AgentError.connectionLost }
            initialized = count
        }
    }

    func hello() throws -> starship_hello {
        let rows = try table(op: Int32(STARSHIP_OP_HELLO), of: starship_hello.self)
        guard let first = rows.first else { throw AgentError.connectionLost }
        return first
    }

    func regions() throws -> [starship_region] { try table(op: Int32(STARSHIP_OP_REGIONS), of: starship_region.self) }
    func images() throws -> [starship_image] { try table(op: Int32(STARSHIP_OP_IMAGES), of: starship_image.self) }
}
