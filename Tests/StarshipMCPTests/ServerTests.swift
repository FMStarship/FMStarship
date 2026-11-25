@testable import StarshipMCP
import XCTest

/// The protocol, both eras, without a game: JSON-RPC over lines, as an agent's app sends it.
final class ServerTests: XCTestCase {
    private final class Echo: ToolProvider {
        var definitions: [JSON] { [["name": "echo", "inputSchema": ["type": "object"]]] }
        func call(_ name: String, arguments: JSON) -> ToolResult? {
            name == "echo" ? .answer(["said": arguments["text"] ?? .null]) : nil
        }
    }

    private let server = MCPServer(tools: Echo(), version: "1.2.3")
    private let modern: JSON = ["io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": [:]]

    private func send(_ message: JSON, file: StaticString = #filePath, line: UInt = #line) throws -> JSON {
        let answer = try XCTUnwrap(server.handle(message.text), "no answer", file: file, line: line)
        XCTAssertFalse(answer.contains("\n"), "an answer must be one line", file: file, line: line)
        return try JSON.parse(answer)
    }

    func testInitializeAgreesOnTheClientsVersionOrOffersTheNewestHandshake() throws {
        for (asked, agreed) in [("2025-06-18", "2025-06-18"), ("2024-11-05", "2024-11-05"), ("2025-11-25", "2025-11-25"),
                                ("2026-07-28", "2025-11-25"), ("1999-01-01", "2025-11-25")] {
            let reply = try send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                  "params": ["protocolVersion": .string(asked), "capabilities": [:], "clientInfo": ["name": "test", "version": "0"]]])
            XCTAssertEqual(reply["id"], 1)
            XCTAssertEqual(reply["result"]?["protocolVersion"]?.string, agreed)
            XCTAssertEqual(reply["result"]?["serverInfo"]?["name"]?.string, "fmstarship-mcp")
            XCTAssertEqual(reply["result"]?["serverInfo"]?["version"]?.string, "1.2.3")
            XCTAssertNotNil(reply["result"]?["capabilities"]?["tools"])
            XCTAssertNotNil(reply["result"]?["instructions"]?.string)
        }
    }

    func testNotificationsGetNoAnswer() {
        XCTAssertNil(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(server.handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":4}}"#))
        // A response from the client to something isn't answered either.
        XCTAssertNil(server.handle(#"{"jsonrpc":"2.0","id":9,"result":{}}"#))
    }

    func testDiscoverServesTheModernEra() throws {
        let reply = try send(["jsonrpc": "2.0", "id": "d-1", "method": "server/discover", "params": ["_meta": modern]])
        XCTAssertEqual(reply["id"], "d-1")
        let result = try XCTUnwrap(reply["result"])
        XCTAssertEqual(result["resultType"], "complete")
        XCTAssertEqual(result["supportedVersions"]?.array?.first, "2026-07-28")
        XCTAssertTrue(result["supportedVersions"]?.array?.contains("2025-11-25") ?? false)
        XCTAssertNotNil(result["capabilities"]?["tools"])
        XCTAssertEqual(result["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"]?.string, "fmstarship-mcp")
        // The 2026-07-28 schema requires both: the answers are this user's, so they're private and not kept.
        XCTAssertEqual(result["ttlMs"], 0)
        XCTAssertEqual(result["cacheScope"], "private")

        let list = try send(["jsonrpc": "2.0", "id": "l-1", "method": "tools/list", "params": ["_meta": modern]])
        XCTAssertEqual(list["result"]?["ttlMs"], 0)
        XCTAssertEqual(list["result"]?["cacheScope"], "private")
        let ping = try send(["jsonrpc": "2.0", "id": "p-1", "method": "ping", "params": ["_meta": modern]])
        XCTAssertNil(ping["result"]?["ttlMs"], "only discover and the tool list are cacheable results")
        // The older era has no such fields.
        XCTAssertNil(try send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])["result"]?["cacheScope"])
    }

    func testAModernRequestNeedsAKnownVersionAndTheClientsCapabilities() throws {
        let old = try send(["jsonrpc": "2.0", "id": 2, "method": "tools/list",
                            "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2030-01-01",
                                                 "io.modelcontextprotocol/clientCapabilities": [:]]]])
        XCTAssertEqual(old["error"]?["code"]?.int, -32022)
        XCTAssertEqual(old["error"]?["data"]?["requested"]?.string, "2030-01-01")
        XCTAssertTrue(old["error"]?["data"]?["supported"]?.array?.contains("2026-07-28") ?? false)

        let bare = try send(["jsonrpc": "2.0", "id": 3, "method": "tools/list",
                             "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]])
        XCTAssertEqual(bare["error"]?["code"]?.int, -32602)

        let discover = try send(["jsonrpc": "2.0", "id": 4, "method": "server/discover"])
        XCTAssertEqual(discover["error"]?["code"]?.int, -32602)

        let number = try send(["jsonrpc": "2.0", "id": 5, "method": "tools/list",
                               "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": 7,
                                                    "io.modelcontextprotocol/clientCapabilities": [:]]]])
        XCTAssertEqual(number["error"]?["code"]?.int, -32602, "a version that isn't text is a bad parameter")
    }

    func testToolsListAndCallInBothEras() throws {
        for meta in [nil, modern] as [JSON?] {
            var params: [(String, JSON)] = []
            if let meta { params.append(("_meta", meta)) }
            let list = try send(["jsonrpc": "2.0", "id": 5, "method": "tools/list", "params": .object(params)])
            XCTAssertEqual(list["result"]?["tools"]?.array?.first?["name"], "echo")
            XCTAssertEqual(list["result"]?["resultType"], meta == nil ? nil : "complete")

            let call = try send(["jsonrpc": "2.0", "id": 6, "method": "tools/call",
                                 "params": .object(params + [("name", "echo"), ("arguments", ["text": "Hello \"there\"\nmanager"])])])
            let result = try XCTUnwrap(call["result"])
            XCTAssertEqual(result["isError"], false)
            let content = try XCTUnwrap(result["content"]?.array?.first)
            XCTAssertEqual(content["type"], "text")
            XCTAssertEqual(try JSON.parse(XCTUnwrap(content["text"]?.string))["said"], "Hello \"there\"\nmanager")
        }
    }

    func testPingAndTheErrorsJSONRPCNames() throws {
        XCTAssertEqual(try send(["jsonrpc": "2.0", "id": 7, "method": "ping"])["result"], [:])
        XCTAssertEqual(try send(["jsonrpc": "2.0", "id": 8, "method": "resources/list"])["error"]?["code"]?.int, -32601)
        XCTAssertEqual(try send(["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": "nothing"]])["error"]?["code"]?.int, -32602)
        XCTAssertEqual(try send(["jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": ["name": "echo", "arguments": [1]]])["error"]?["code"]?.int, -32602)
        let garbled = try JSON.parse(XCTUnwrap(server.handle("{not json")))
        XCTAssertEqual(garbled["error"]?["code"]?.int, -32700)
        XCTAssertEqual(garbled["id"], .null)
        XCTAssertEqual(try send(["jsonrpc": "2.0", "id": 11])["error"]?["code"]?.int, -32600)
        let batch = try send([["jsonrpc": "2.0", "id": 12, "method": "ping"], ["jsonrpc": "2.0", "id": 13, "method": "ping"]])
        XCTAssertEqual(batch["error"]?["code"]?.int, -32600)
        XCTAssertEqual(batch["id"], .null)
    }

    func testJSONKeepsOrderAndWholeNumbersAndEscapesWhatWouldBreakALine() throws {
        let value: JSON = ["b": 1, "a": 2.5, "c": 3.0, "text": "a\u{2028}b\u{1}c\td", "none": nil, "list": [true, false]]
        XCTAssertEqual(value.text, "{\"b\":1,\"a\":2.5,\"c\":3,\"text\":\"a\\u2028b\\u0001c\\td\",\"none\":null,\"list\":[true,false]}")
        let back = try JSON.parse(value.text)
        XCTAssertEqual(back["text"]?.string, "a\u{2028}b\u{1}c\td")
        XCTAssertEqual(back["c"]?.int, 3)
        XCTAssertEqual(back["list"]?.array, [true, false])
    }
}
