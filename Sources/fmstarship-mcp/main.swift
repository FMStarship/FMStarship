import Darwin
import Foundation
import StarshipMCP

// FM Starship's MCP server. An agent's app starts it and talks to it over stdin and stdout, one JSON-RPC message per
// line. stdout carries those messages and nothing else; anything else goes to stderr. It ends when stdin closes. It opens
// no socket of its own and reads FM only through FM Starship's agent, when a tool first needs the save.

// A client that hangs up mid-answer gives a failed write, not SIGPIPE, and that ends the server quietly.
signal(SIGPIPE, SIG_IGN)

let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
let server = MCPServer(tools: Toolbox.live(), version: version)
try? FileHandle.standardError.write(contentsOf: Data("fmstarship-mcp \(version): ready\n".utf8))

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let answer = server.handle(line) else { continue }
    do {
        try FileHandle.standardOutput.write(contentsOf: Data((answer + "\n").utf8))
    } catch {
        exit(0)
    }
}
