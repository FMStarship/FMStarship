import StarshipFiles
import XCTest

final class ExportTests: XCTestCase {
    private let columns = [ExportColumn(name: "Name"), ExportColumn(name: "CA", numeric: true)]
    private let rows = [[ExportCell(.string("Ødegaard, \"Martin\"")), ExportCell(.int(173))],
                        [ExportCell(.string("<b>Dahl</b>")), ExportCell(.none)]]

    private func text(_ format: ExportFormat) -> String {
        String(decoding: Export.file(format, columns: columns, rows: rows, title: "Test"), as: UTF8.self)
    }

    func testCSVQuotesCommasAndQuotes() {
        let lines = text(.csv).split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("Name,CA"))
        XCTAssertEqual(lines[1], "\"Ødegaard, \"\"Martin\"\"\",173")
    }

    func testHTMLEscapesText() {
        let html = text(.html)
        XCTAssertTrue(html.contains("&lt;b&gt;Dahl&lt;/b&gt;"))
        XCTAssertFalse(html.contains("<b>Dahl"))
    }

    func testTXTHasEveryRow() {
        let txt = text(.txt)
        XCTAssertTrue(txt.contains("Test"))
        XCTAssertTrue(txt.contains("173"))
        XCTAssertTrue(txt.contains("<b>Dahl</b>"))
    }
}
