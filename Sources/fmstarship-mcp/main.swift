import Darwin
import Foundation
import StarshipMCP

// FM Starship's MCP server. An agent's app starts it and talks to it over stdin and stdout, one JSON-RPC message per
// line. stdout carries those messages and nothing else; anything else goes to stderr. It ends when stdin closes. It opens
// no socket of its own and reads FM only through FM Starship's agent, when a tool first needs the save.

// A client that hangs up mid-answer mustn't kill it with SIGPIPE before stdin's end is seen.
signal(SIGPIPE, SIG_IGN)

let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
let server = MCPServer(tools: Toolbox.live(), version: version)
FileHandle.standardError.write(Data("fmstarship-mcp \(version): ready\n".utf8))

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let answer = server.handle(line) else { continue }
    FileHandle.standardOutput.write(Data((answer + "\n").utf8))
}
