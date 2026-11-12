@testable import StarshipCore
import XCTest

/// The plugin stays out of any build of FM nobody has checked. The build is FM's version with GameAssembly's UUID, read
/// from fm.app's files. These use stand-in files in a temporary folder, never FM's own.
final class CheckedBuildsTests: XCTestCase {
    private let old = FMBuild(version: "27.0.0.2493426", gameAssembly: "18C040AA-177A-3278-8CBD-E5289254D4FA")
    private let current = FMBuild(version: "27.0.1.2494769", gameAssembly: "94BE5439-0807-3A78-8C32-E1F12FE5E7BB")
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CheckedBuildsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    // MARK: The list

    func testBothBuildsSoFarAreChecked() {
        XCTAssertTrue(CheckedBuilds.contains(old))
        XCTAssertTrue(CheckedBuilds.contains(current))
        XCTAssertTrue(CheckedBuilds.contains(FMBuild(version: "27.0.1.2494769", gameAssembly: "94be5439-0807-3a78-8c32-e1f12fe5e7bb")),
                      "A UUID is the same in either case")
    }

    func testABuildIsBothItsVersionAndItsGameAssembly() {
        XCTAssertFalse(CheckedBuilds.contains(FMBuild(version: "27.0.2.2500000", gameAssembly: "94BE5439-0807-3A78-8C32-E1F12FE5E7BB")),
                       "A new version with the same GameAssembly")
        XCTAssertFalse(CheckedBuilds.contains(FMBuild(version: "27.0.1.2494769", gameAssembly: "0D1E2F3A-0000-0000-0000-000000000000")),
                       "The same version with new game code")
        XCTAssertFalse(CheckedBuilds.contains(FMBuild(version: "27.0.0.2493426", gameAssembly: "94BE5439-0807-3A78-8C32-E1F12FE5E7BB")),
                       "One build's version with another's GameAssembly")
    }

    // MARK: The gate

    func testACheckedBuildRuns() {
        XCTAssertEqual(PluginGate.decide(current, developer: false), .run)
        XCTAssertEqual(PluginGate.decide(current, developer: true), .run)
    }

    func testAnUncheckedBuildIsOffUnlessItsADeveloperBuild() {
        let new = FMBuild(version: "27.0.2.2500000", gameAssembly: "0D1E2F3A-0000-0000-0000-000000000000")
        XCTAssertEqual(PluginGate.decide(new, developer: false), .off)
        XCTAssertEqual(PluginGate.decide(new, developer: true), .runUnchecked)
    }

    func testABuildThatCouldntBeReadCountsAsUnchecked() {
        XCTAssertEqual(PluginGate.decide(nil, developer: false), .off)
        XCTAssertEqual(PluginGate.decide(nil, developer: true), .runUnchecked)
    }

    func testTheGateGoesByTheListItsGiven() {
        XCTAssertEqual(PluginGate.decide(current, developer: false, checked: [old]), .off)
        XCTAssertEqual(PluginGate.decide(current, developer: false, checked: []), .off)
    }

    // MARK: Reading fm.app

    func testTheUUIDOfAUniversalFilesArm64Slice() throws {
        let file = root.appendingPathComponent("universal")
        try Self.universal([(Self.x86, "324555AC-C565-3AEE-9896-8B8D49C13511"), (MachO.arm64, current.gameAssembly)]).write(to: file)
        XCTAssertEqual(MachO.arm64UUID(ofFile: file), current.gameAssembly)
    }

    func testTheUUIDOfAUniversalFileWith64BitOffsets() throws {
        let file = root.appendingPathComponent("universal64")
        try Self.universal([(Self.x86, "324555AC-C565-3AEE-9896-8B8D49C13511"), (MachO.arm64, old.gameAssembly)], wide: true).write(to: file)
        XCTAssertEqual(MachO.arm64UUID(ofFile: file), old.gameAssembly)
    }

    func testTheUUIDOfASingleArchitectureFile() throws {
        let file = root.appendingPathComponent("thin")
        try Self.thin(cpu: MachO.arm64, uuid: current.gameAssembly).write(to: file)
        XCTAssertEqual(MachO.arm64UUID(ofFile: file), current.gameAssembly)
    }

    func testNoArm64CodeOrABrokenFileGivesNoUUID() throws {
        let intel = root.appendingPathComponent("intel")
        try Self.universal([(Self.x86, current.gameAssembly)]).write(to: intel)
        XCTAssertNil(MachO.arm64UUID(ofFile: intel))
        let thinIntel = root.appendingPathComponent("thin-intel")
        try Self.thin(cpu: Self.x86, uuid: current.gameAssembly).write(to: thinIntel)
        XCTAssertNil(MachO.arm64UUID(ofFile: thinIntel))
        XCTAssertNil(MachO.arm64UUID(ofFile: root.appendingPathComponent("missing")))
        let whole = Self.universal([(MachO.arm64, current.gameAssembly)])
        for length in [0, 3, 8, 27, 4096, 4096 + 31, 4096 + 40, whole.count - 1] {
            let cut = root.appendingPathComponent("cut-\(length)")
            try whole.prefix(length).write(to: cut)
            XCTAssertNil(MachO.arm64UUID(ofFile: cut), "Cut to \(length) bytes")
        }
        let text = root.appendingPathComponent("text")
        try Data("not a Mach-O file at all".utf8).write(to: text)
        XCTAssertNil(MachO.arm64UUID(ofFile: text))
    }

    func testALoadCommandThatRunsPastTheEndGivesNoUUID() throws {
        var data = Self.thin(cpu: MachO.arm64, uuid: current.gameAssembly)
        // The first command's size, made larger than all the commands together.
        data.replaceSubrange(36..<40, with: Self.little(0x10000))
        let file = root.appendingPathComponent("broken")
        try data.write(to: file)
        XCTAssertNil(MachO.arm64UUID(ofFile: file))
    }

    func testTheBuildOfAnInstalledFM() throws {
        let app = root.appendingPathComponent("fm.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Frameworks"), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": current.version], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertNil(FMBuild.installed(app: app), "No GameAssembly")
        try Self.universal([(Self.x86, old.gameAssembly), (MachO.arm64, current.gameAssembly)])
            .write(to: app.appendingPathComponent("Contents/Frameworks/GameAssembly.dylib"))
        XCTAssertEqual(FMBuild.installed(app: app), current)
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertNil(FMBuild.installed(app: app), "No version")
    }

    /// FM's own fm.app, read only, when it's installed.
    func testTheInstalledFMHasABuild() throws {
        guard let app = GameLauncher.gameApp else { throw XCTSkip("Football Manager 27 isn't installed") }
        let build = try XCTUnwrap(FMBuild.installed(app: app))
        XCTAssertFalse(build.version.isEmpty)
        XCTAssertNotNil(UUID(uuidString: build.gameAssembly))
    }

    // MARK: The status file

    func testTheStatusFileIsWrittenWholeAndReadBack() throws {
        let home = root.appendingPathComponent("home")
        let file = PluginStatus.file(home: home)
        XCTAssertEqual(file.path, home.path + "/Library/Application Support/FMStarship/Plugin/status.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertNil(PluginStatus.read(from: file))
        let build = FMBuild(version: "27.0.2.2500000", gameAssembly: "0d1e2f3a-0000-0000-0000-000000000000")
        let status = PluginStatus.keptOut(build, at: Date(timeIntervalSince1970: 1_794_398_400))
        try status.write(to: file)
        XCTAssertEqual(PluginStatus.read(from: file), status)
        XCTAssertEqual(PluginStatus.read(from: file)?.build, build)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String])
        XCTAssertEqual(json, ["plugin": "off", "reason": "unchecked-build",
                              "detail": "FM has updated to 27.0.2.2500000, and FM Starship's tab inside FM comes back with the next FM Starship update.",
                              "at": "2026-11-11T12:00:00Z", "fm": "27.0.2.2500000",
                              "gameAssembly": "0D1E2F3A-0000-0000-0000-000000000000"])
        PluginStatus.remove(at: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        PluginStatus.remove(at: file)
    }

    func testABuildThatCouldntBeReadHasItsOwnReason() {
        let status = PluginStatus.keptOut(nil)
        XCTAssertEqual(status.reason, PluginStatus.unreadableBuild)
        XCTAssertEqual(status.detail, PluginStatus.unreadableDetail)
        XCTAssertEqual(status.fm, "")
        XCTAssertNil(status.build)
    }

    /// The launcher's C writes the first five fields only, and may leave the version empty.
    func testAStatusWithoutGameAssemblyStillReads() throws {
        let json = #"{"plugin": "off", "reason": "crash-loop", "detail": "x", "at": "2026-11-11T12:00:00Z", "fm": "27.0.1.2494769"}"#
        let status = try JSONDecoder().decode(PluginStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.gameAssembly, "")
        XCTAssertNil(status.build)
        XCTAssertNil(PluginStatus(reason: PluginStatus.crashLoop, detail: "x", at: "", fm: "", gameAssembly: "94BE5439-0807-3A78-8C32-E1F12FE5E7BB").build)
    }

    /// As the launcher finds the plugin, so a run with another HOME never touches the real folder.
    func testTheHomeFolderGoesByHOME() {
        let real = getenv("HOME").map { String(cString: $0) }
        defer { if let real { setenv("HOME", real, 1) } else { unsetenv("HOME") } }
        setenv("HOME", root.path, 1)
        XCTAssertEqual(PluginStatus.home.path, root.path)
        XCTAssertNotEqual(PluginStatus.home.path, FileManager.default.homeDirectoryForCurrentUser.path)
    }

    // MARK: Stand-in Mach-O files

    static let x86: UInt32 = 0x0100_0007

    static func little(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    static func big(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func big64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    /// A 64-bit Mach-O header, a symbol table command, then the UUID command.
    static func thin(cpu: UInt32, uuid: String) -> Data {
        var data = Data()
        let commands = 24 + 24
        for word in [0xfeed_facf, cpu, 0, 6, 2, UInt32(commands), 0, 0] { data += little(word) }
        data += little(0x2) + little(24) + Data(count: 16)
        data += little(0x1b) + little(24)
        withUnsafeBytes(of: UUID(uuidString: uuid)!.uuid) { data += Data($0) }
        return data
    }

    /// A universal file with each slice on a 4 KB boundary, as lipo makes them.
    static func universal(_ slices: [(cpu: UInt32, uuid: String)], wide: Bool = false) -> Data {
        var data = big(wide ? 0xcafe_babf : 0xcafe_babe) + big(UInt32(slices.count))
        var bodies = Data()
        for (index, slice) in slices.enumerated() {
            let body = thin(cpu: slice.cpu, uuid: slice.uuid)
            let offset = UInt32(4096 * (index + 1))
            data += big(slice.cpu) + big(UInt32(0))
            data += wide ? big64(UInt64(offset)) + big64(UInt64(body.count)) : big(offset) + big(UInt32(body.count))
            data += big(UInt32(12))
            if wide { data += big(UInt32(0)) }
            bodies += Data(count: Int(offset) - 4096 - (bodies.count)) + body
        }
        return data + Data(count: 4096 - data.count) + bodies
    }
}
