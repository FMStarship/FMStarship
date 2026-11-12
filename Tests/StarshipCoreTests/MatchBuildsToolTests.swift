@testable import StarshipCore
import XCTest

/// `tools/match_builds.py` takes the old build's values from `Mac27`. If it stops reading them, it checks nothing and still
/// exits 0, which patch day reads as every value found: that happened once, when the constants became `package`.
final class MatchBuildsToolTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var rules: URL { root.appendingPathComponent("Sources/StarshipCore/Emu/RulesEngine.swift") }

    /// Runs `mac27_values` on a file, giving its output and exit status.
    private func mac27Values(in file: URL) throws -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let script = """
            import sys; sys.path.insert(0, sys.argv[1]); import match_builds
            values = match_builds.mac27_values(sys.argv[2])
            print(len(values)); print(values.get('fingerprint', ''))
            """
        process.arguments = ["python3", "-I", "-c", script, root.appendingPathComponent("tools").path, file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { throw XCTSkip("python3 isn't here to run match_builds.py: \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    func testReadsEveryValueInMac27() throws {
        let source = try String(contentsOf: rules, encoding: .utf8)
        let block = try XCTUnwrap(source.range(of: "enum Mac27 {").map { source[$0.upperBound...] })
        let body = block[..<(block.range(of: "\n    }")?.lowerBound ?? block.endIndex)]
        let declared = body.split(separator: "\n").filter { $0.contains("static let ") }.count
        XCTAssertGreaterThan(declared, 20)

        let (output, status) = try mac27Values(in: rules)
        XCTAssertEqual(status, 0, output)
        let lines = output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, String(declared), "Every constant Mac27 declares")
        XCTAssertEqual(lines.dropFirst().first, RulesEngine.Mac27.fingerprint)
    }

    func testStopsWhenItFindsNoValues() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MatchBuildsToolTests-\(UUID().uuidString).swift")
        try "enum Mac27 {\n        private static var fingerprint = \"0\"\n    }\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let (_, status) = try mac27Values(in: file)
        XCTAssertNotEqual(status, 0, "Nothing found must not read as success")
    }
}
