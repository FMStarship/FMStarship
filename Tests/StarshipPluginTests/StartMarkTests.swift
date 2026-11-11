@testable import StarshipPlugin
import XCTest

/// The mark that tells the launcher a start of FM went well (`plugin/launcher.c`), written once the tab has stayed in FM's bar.
final class StartMarkTests: XCTestCase {
    func testTheMarkIsDueOnceTheTabHasStayedInLongEnough() {
        var due = StartMarkDue()
        let added = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertFalse(due.tabStillIn(at: added), "not before the tab is in")
        due.tabAdded(at: added)
        XCTAssertFalse(due.tabStillIn(at: added.addingTimeInterval(StartMark.after - 1)))
        XCTAssertTrue(due.tabStillIn(at: added.addingTimeInterval(StartMark.after)))
        XCTAssertFalse(due.tabStillIn(at: added.addingTimeInterval(StartMark.after + 60)), "once a start")
    }

    func testFMBuildingItsBarAgainStartsTheWaitAgain() {
        var due = StartMarkDue()
        let added = Date(timeIntervalSinceReferenceDate: 1000)
        due.tabAdded(at: added)
        due.tabAdded(at: added.addingTimeInterval(8))
        XCTAssertFalse(due.tabStillIn(at: added.addingTimeInterval(StartMark.after)))
        XCTAssertTrue(due.tabStillIn(at: added.addingTimeInterval(8 + StartMark.after)))
    }

    func testTheMarkGoesInTheFolderGivenAndSaysSo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var lines: [String] = []
        StartMark.write(in: folder, pid: 42) { lines.append($0) }
        // The launcher's name for it.
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("started-well"), encoding: .utf8), "pid 42\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("the launcher is told this start went well") == true, "\(lines)")
    }

    func testAMarkThatCantBeWrittenIsLoggedAndNothingMore() {
        var lines: [String] = []
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        StartMark.write(in: missing) { lines.append($0) }
        StartMark.write(in: nil) { lines.append($0) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("Couldn't tell the launcher this start went well, in \(missing.path)"), lines[0])
        XCTAssertTrue(lines[1].hasPrefix("Couldn't find the folder FM Starship was loaded from"), lines[1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testTheFolderIsTheOneThisCodeWasLoadedFrom() throws {
        let folder = try XCTUnwrap(StartMark.folder())
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue, folder.path)
        // Here that's the test bundle's code, as in FM it's the plugin's library in the launcher's folder.
        XCTAssertTrue(Bundle(for: Self.self).executablePath?.hasPrefix(folder.path + "/") == true,
                      "\(folder.path) vs \(Bundle(for: Self.self).executablePath ?? "")")
    }
}
