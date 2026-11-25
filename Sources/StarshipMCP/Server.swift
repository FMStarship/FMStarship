import Foundation

/// What a tool gives back: one block of text for the agent, and whether it's an answer or why there isn't one.
public struct ToolResult: Equatable {
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public static func answer(_ value: JSON) -> ToolResult { ToolResult(text: value.text) }
    public static func problem(_ sentence: String) -> ToolResult { ToolResult(text: sentence, isError: true) }
}

/// The tools a server offers. `call` is nil for a name it doesn't know.
public protocol ToolProvider: AnyObject {
    var definitions: [JSON] { get }
    func call(_ name: String, arguments: JSON) -> ToolResult?
}

/// The Model Context Protocol over stdio, one JSON-RPC message per line, in both of its eras: the stateless one of
/// 2026-07-28, where every request names its version in `_meta`, and the older one that opens with `initialize`.
/// https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning
public final class MCPServer {
    public static let modernVersions = ["2026-07-28"]
    public static let handshakeVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let capabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"

    /// For the agent, before it calls anything. The skill says the rest.
    public static let instructions = """
        FM Starship reads the user's Football Manager 27 save while FM runs with FM Starship. Read only. Start with game_status. \
        Lists give one row per person with its uid; ask for one person in full with person. Attributes are FM's 1-20. When \
        Hidden attributes is off, CA, PA, hidden attributes and personality numbers aren't sent: don't guess them or ask for them.
        """

    private let tools: ToolProvider
    private let version: String

    public init(tools: ToolProvider, version: String) {
        self.tools = tools
        self.version = version
    }

    private var serverInfo: JSON { ["name": "fmstarship-mcp", "title": "FM Starship", "version": .string(version)] }

    private enum Failure: Error {
        case rpc(code: Int, message: String, data: JSON?)
    }

    /// One line in, and the line to answer with, or nil for a notification, which gets no answer.
    public func handle(_ line: String) -> String? {
        guard let message = try? JSON.parse(line) else {
            return Self.error(id: .null, code: -32700, message: "Parse error").text
        }
        // MCP took JSON-RPC batches out in 2025-06-18, and none of the versions here needs one.
        if message.array != nil {
            return Self.error(id: .null, code: -32600, message: "Invalid request: batches aren't supported").text
        }
        guard message.isObject, message["jsonrpc"]?.string == "2.0", let method = message["method"]?.string else {
            // A response from the client, or something else that isn't a request: nothing to answer, unless it has an id.
            if let id = message["id"], message["result"] == nil, message["error"] == nil {
                return Self.error(id: id, code: -32600, message: "Invalid request").text
            }
            return nil
        }
        guard let id = message["id"], id != .null else { return nil }
        let params = message["params"] ?? [:]
        do {
            return Self.reply(id: id, result: try answer(method, params: params)).text
        } catch Failure.rpc(let code, let text, let data) {
            return Self.error(id: id, code: code, message: text, data: data).text
        } catch {
            return Self.error(id: id, code: -32603, message: "Internal error").text
        }
    }

    private func answer(_ method: String, params: JSON) throws -> JSON {
        let meta = params["_meta"]
        // A request that names its version in `_meta` is a modern one, served on its own, whatever came before it.
        if let requested = meta?[Self.versionKey] {
            guard let version = requested.string else {
                throw Failure.rpc(code: -32602, message: "Invalid params: \(Self.versionKey) must be text", data: nil)
            }
            guard Self.modernVersions.contains(version) else {
                throw Failure.rpc(code: -32022, message: "Unsupported protocol version",
                                  data: ["supported": .array((Self.modernVersions + Self.handshakeVersions).map { .string($0) }),
                                         "requested": requested])
            }
            guard meta?[Self.capabilitiesKey] != nil else {
                throw Failure.rpc(code: -32602, message: "Invalid params: _meta needs \(Self.capabilitiesKey)", data: nil)
            }
            return modern(try result(method, params: params), cacheable: ["server/discover", "tools/list"].contains(method))
        }
        if method == "server/discover" {
            throw Failure.rpc(code: -32602, message: "Invalid params: _meta needs \(Self.versionKey)", data: nil)
        }
        return try result(method, params: params)
    }

    /// A 2026-07-28 result. Discover and the tool list must say how long they may be kept: they're answered for this user
    /// only, and the tools can change with an update, so they're private and not kept.
    private func modern(_ result: JSON, cacheable: Bool) -> JSON {
        guard case .object(var pairs) = result else { return result }
        pairs.removeAll { ["resultType", "_meta", "ttlMs", "cacheScope"].contains($0.0) }
        let caching: [(String, JSON)] = cacheable ? [("ttlMs", 0), ("cacheScope", "private")] : []
        return .object([("resultType", "complete")] + pairs + caching + [("_meta", [Self.serverInfoKey: serverInfo])])
    }

    private func result(_ method: String, params: JSON) throws -> JSON {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? ""
            let version = Self.handshakeVersions.contains(asked) ? asked : Self.handshakeVersions[0]
            return ["protocolVersion": .string(version), "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": serverInfo, "instructions": .string(Self.instructions)]
        case "server/discover":
            return ["supportedVersions": .array((Self.modernVersions + Self.handshakeVersions).map { .string($0) }),
                    "capabilities": ["tools": [:]], "instructions": .string(Self.instructions)]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": .array(tools.definitions)]
        case "tools/call":
            guard let name = params["name"]?.string else {
                throw Failure.rpc(code: -32602, message: "Invalid params: tools/call needs a name", data: nil)
            }
            let arguments = params["arguments"] ?? [:]
            guard arguments.isObject else {
                throw Failure.rpc(code: -32602, message: "Invalid params: arguments must be an object", data: nil)
            }
            guard let result = tools.call(name, arguments: arguments) else {
                throw Failure.rpc(code: -32602, message: "Unknown tool: \(name)", data: nil)
            }
            return ["content": [["type": "text", "text": .string(result.text)]], "isError": .bool(result.isError)]
        default:
            throw Failure.rpc(code: -32601, message: "Method not found: \(method)", data: nil)
        }
    }

    private static func reply(id: JSON, result: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: JSON, code: Int, message: String, data: JSON? = nil) -> JSON {
        var error: [(String, JSON)] = [("code", .int(code)), ("message", .string(message))]
        if let data { error.append(("data", data)) }
        return ["jsonrpc": "2.0", "id": id, "error": .object(error)]
    }
}
