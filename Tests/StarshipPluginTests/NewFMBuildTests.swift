import Darwin
@testable import StarshipPlugin
import XCTest

/// What the plugin does on a build of FM it hasn't been checked on: what it kept from another build isn't used, columns
/// FM no longer has are left out, and a screen that can't be built says so.
@MainActor
final class NewFMBuildTests: XCTestCase {
    private let build = "27.0.0.2493426 18C040AA-177A-3278-8CBD-E5289254D4FA"
    private let guids = ["factory", "", "header", "menu"]

    func testAssetGUIDsAreUsedOnlyOnTheBuildTheyWereKeptOn() throws {
        let data = try JSONEncoder().encode(FMTable.SavedAssets(build: build, guids: guids))
        XCTAssertEqual(FMTable.savedGUIDs(data, build: build), guids)
        XCTAssertNil(FMTable.savedGUIDs(data, build: "27.0.1.2500000 0D1E2F3A-0000-0000-0000-000000000000"))
        XCTAssertNil(FMTable.savedGUIDs(data, build: nil), "With FM's build unknown, nothing kept is trusted")
    }

    func testAFileKeptBeforeBuildsWereRecordedIsIgnored() throws {
        // As the plugin wrote them until now: the GUIDs alone.
        XCTAssertNil(FMTable.savedGUIDs(try JSONEncoder().encode(guids), build: build))
        XCTAssertNil(FMTable.savedGUIDs(Data("not json".utf8), build: build))
    }

    func testOutsideFMThereIsNoBuildToKeepGUIDsFor() {
        XCTAssertNil(IL2CPP.gameAssemblyUUID())
        XCTAssertNil(FMTable.fmBuild)
    }

    func testColumnsFMNoLongerHasAreLeftOutInOrder() {
        let (kept, dropped) = FMTable.available(["name", "age", "gone", "wage", "also-gone"], known: ["name", "age", "wage", "club"])
        XCTAssertEqual(kept, ["name", "age", "wage"])
        XCTAssertEqual(dropped, ["gone", "also-gone"])
    }

    func testUntilFMsColumnsAreKnownAllAreKept() {
        let (kept, dropped) = FMTable.available(["name", "age"], known: [])
        XCTAssertEqual(kept, ["name", "age"])
        XCTAssertEqual(dropped, [])
    }

    func testAScreenThatCantBeBuiltSaysWhatWentWrongInOneLine() {
        let text = FMInterface.cantBuild("set_text: System.NullReferenceException: Object reference not set\n  at SI.Bindable.SIText.set_text ()\n")
        XCTAssertTrue(text.hasPrefix("FM Starship couldn't build this screen on this build of FM"))
        XCTAssertTrue(text.contains("FM's own screens work as usual"))
        XCTAssertTrue(text.hasSuffix("What went wrong: set_text: System.NullReferenceException: Object reference not set"))
        XCTAssertFalse(text.contains("\n"))
        XCTAssertTrue(FMInterface.cantBuild("IStyle.flexGrow takes 12 bytes, not 8").hasSuffix("What went wrong: IStyle.flexGrow takes 12 bytes, not 8"))
    }

    // MARK: GameAssembly's UUID

    private let uuid = UUID(uuidString: "18C040AA-177A-3278-8CBD-E5289254D4FA")!

    /// A 64-bit Mach-O header with a command of another kind, then LC_UUID if there's a UUID.
    private func machO(magic: UInt32 = MH_MAGIC_64, uuid: UUID?, sizeofcmds: UInt32? = nil) -> [UInt8] {
        var bytes: [UInt8] = []
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { bytes += $0 } }
        let size = 16 + (uuid == nil ? 0 : MemoryLayout<uuid_command>.size)
        append(mach_header_64(magic: magic, cputype: 0x0100_000c, cpusubtype: 0, filetype: 6, ncmds: uuid == nil ? 1 : 2,
                              sizeofcmds: sizeofcmds ?? UInt32(size), flags: 0, reserved: 0))
        append(load_command(cmd: UInt32(LC_SYMTAB), cmdsize: 16))
        append(UInt64(0))
        if let uuid { append(uuid_command(cmd: UInt32(LC_UUID), cmdsize: UInt32(MemoryLayout<uuid_command>.size), uuid: uuid.uuid)) }
        return bytes
    }

    private func read(_ bytes: [UInt8]) -> String? {
        bytes.withUnsafeBytes { IL2CPP.uuid(ofMachO: $0.baseAddress!) }
    }

    func testTheUUIDIsFoundAmongTheLoadCommands() {
        XCTAssertEqual(read(machO(uuid: uuid)), "18C040AA-177A-3278-8CBD-E5289254D4FA")
    }

    func testNoUUIDOrNoMachOGivesNone() {
        XCTAssertNil(read(machO(uuid: nil)))
        XCTAssertNil(read(machO(magic: MH_MAGIC, uuid: uuid)), "32-bit")
        XCTAssertNil(read(machO(magic: 0xcafe_babe, uuid: uuid)), "A universal file's header, not an image's")
    }

    func testCommandsRunningPastTheirSizeAreNotRead() {
        XCTAssertNil(read(machO(uuid: uuid, sizeofcmds: 20)))
    }

    func testARealImageHasOne() throws {
        let header = try XCTUnwrap(_dyld_get_image_header(0))
        XCTAssertNotNil(IL2CPP.uuid(ofMachO: UnsafeRawPointer(header)))
    }
}
