import Foundation
import StarshipCore

/// A cell's underlying value. The cases follow what the Windows columns boxed, because the HTML
/// colouring only ever looks at `int` (a C# int) and `double`.
public enum ExportValue: Equatable {
    case none
    case int(Int)
    case long(Int64)
    case double(Double)
    case string(String)
    case date(Date)
    case bool(Bool)
}

public struct ExportCell: Equatable {
    public var value: ExportValue
    /// What the column's formatter shows, if it has one.
    public var text: String?

    public init(_ value: ExportValue, text: String? = nil) {
        self.value = value
        self.text = text
    }
}

public struct ExportColumn: Equatable {
    public var name: String
    public var group: String
    public var numeric: Bool
    public var hidden: Bool
    public var ability: Bool
    /// The short heading, where the column has one.
    public var shortName: String?

    public init(name: String, group: String = "", numeric: Bool = false, hidden: Bool = false, ability: Bool = false, shortName: String? = nil) {
        self.name = name
        self.group = group
        self.numeric = numeric
        self.hidden = hidden
        self.ability = ability
        self.shortName = shortName
    }

    public var header: String { shortName ?? name }
}

public enum ExportFormat: CaseIterable {
    case csv, html, txt

    /// Anything that isn't a web page or text table is written as CSV.
    public init(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "html", "htm": self = .html
        case "txt": self = .txt
        default: self = .csv
        }
    }

    public var title: String {
        switch self {
        case .csv: return "Spreadsheet (CSV)"
        case .html: return "Web page (HTML)"
        case .txt: return "Text table (TXT)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .html: return "html"
        case .txt: return "txt"
        }
    }
}

/// The export formats as pure functions: each returns the exact bytes of the file, and every row
/// must have one cell per column. CSV and TXT keep the Windows BOM and CRLF line ends, which is
/// also what Excel wants; HTML has neither.
public enum Export {
    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let newline = "\r\n"
    /// Column widths in the text table are measured over this many rows at most.
    private static let measuredRows = 0x1388
    private static let maxColumnWidth = 40

    public static func file(_ format: ExportFormat, columns: [ExportColumn], rows: [[ExportCell]], title: String, exportedAt: Date = Date(), timeZone: TimeZone = .current) -> Data {
        switch format {
        case .csv: return csv(columns: columns, rows: rows)
        case .html: return html(columns: columns, rows: rows, title: title, exportedAt: exportedAt, timeZone: timeZone)
        case .txt: return txt(columns: columns, rows: rows, title: title)
        }
    }

    /// The heading of the TXT and HTML exports.
    public static func title(rowCount: Int, isStaff: Bool, build: String, gameDate: Date?) -> String {
        var date = ""
        if let gameDate {
            date = ", " + formatter("dd MMM yyyy", .gmt).string(from: gameDate)
        }
        let count = rowCount.formatted(.number.locale(Locale(identifier: "en_US")))
        return "FM Starship - \(count) \(isStaff ? "staff" : "players") (\(build)\(date))"
    }

    /// The suggested file name, without an extension.
    public static func defaultFileName(isStaff: Bool, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        "\(isStaff ? "staff" : "players")-\(formatter("yyyy-MM-dd", timeZone).string(from: date))"
    }

    // MARK: CSV

    /// CSV takes full names and raw values, never the formatted text.
    public static func csv(columns: [ExportColumn], rows: [[ExportCell]]) -> Data {
        var text = columns.map { quote($0.name) }.joined(separator: ",") + newline
        for row in rows {
            text += row.map { quote($0.value.raw) }.joined(separator: ",") + newline
        }
        return Data(byteOrderMark + Array(text.utf8))
    }

    private static func quote(_ value: String) -> String {
        guard value.utf8.contains(where: { $0 == 0x2C || $0 == 0x22 || $0 == 0x0A }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Text table

    public static func txt(columns: [ExportColumn], rows: [[ExportCell]], title: String) -> Data {
        let cells = rows.map { $0.map(\.shown) }
        let widths = columns.indices.map { index -> Int in
            let measured = cells.prefix(measuredRows).map { $0[index].utf16.count }.max() ?? 0
            return min(maxColumnWidth, max(columns[index].header.utf16.count, measured))
        }
        func line(_ texts: [String]) -> String {
            texts.indices.map { fit(texts[$0], widths[$0], rightAligned: columns[$0].numeric) }.joined(separator: "  ")
        }

        var text = title + newline + newline
        text += line(columns.map(\.header)) + newline
        text += widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ") + newline
        for row in cells { text += line(row) + newline }
        return Data(byteOrderMark + Array(text.utf8))
    }

    private static func fit(_ value: String, _ width: Int, rightAligned: Bool) -> String {
        var text = value
        if text.utf16.count > width {
            text = String(text.prefix(utf16Length: width - 1)) + "…"
        }
        let padding = String(repeating: " ", count: max(0, width - text.utf16.count))
        return rightAligned ? padding + text : text + padding
    }

    // MARK: HTML

    public static func html(columns: [ExportColumn], rows: [[ExportCell]], title: String, exportedAt: Date = Date(), timeZone: TimeZone = .current) -> Data {
        var out = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n" +
        "<title>"
        out += encoded(title)
        out += "</title><style>\n" +
        ":root{--bg:#f4f6f8;--panel:#fff;--alt:#f5f7fa;--line:#d5dae0;--text:#1a1a1a;--muted:#666;--good:#0b6b2e;--bad:#b3261e;--hid:#a35a00;--head:#e9ecef}\n" +
        "@media (prefers-color-scheme:dark){:root{--bg:#0e1217;--panel:#151b22;--alt:#1b232c;--line:#263140;--text:#e8ecf1;--muted:#9aa5b4;--good:#4ade9a;--bad:#ff8a73;--hid:#f2b544;--head:#121820}}\n" +
        "body{margin:0;background:var(--bg);color:var(--text);font:13px/1.4 'Segoe UI',system-ui,sans-serif}\n" +
        "header{padding:14px 18px}h1{margin:0;font-size:20px;font-weight:600}header p{margin:4px 0 0;color:var(--muted)}\n" +
        ".wrap{overflow:auto;max-height:calc(100vh - 80px);margin:0 18px 18px;border:1px solid var(--line);border-radius:8px;background:var(--panel)}\n" +
        "table{border-collapse:collapse;width:100%}th,td{padding:4px 8px;white-space:nowrap;border-bottom:1px solid var(--line)}\n" +
        "th{position:sticky;top:0;background:var(--head);color:var(--muted);text-align:left;font-weight:600;cursor:pointer}\n" +
        "tr:nth-child(even) td{background:var(--alt)}td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}\n" +
        ".g{color:var(--good);font-weight:600}.b{color:var(--bad);font-weight:600}.m{color:var(--muted)}th.h{color:var(--hid)}\n" +
        "</style></head><body><header><h1>"
        out += encoded(title)
        out += "</h1><p>Exported by FM Starship · "
        out += formatter("dd/MM/yyyy HH:mm", timeZone).string(from: exportedAt)
        out += " · click a heading to sort</p></header>\n" +
        "<div class=\"wrap\"><table><thead><tr>"

        for column in columns {
            out += "<th class=\"\(column.numeric ? "n" : "")\(column.hidden ? " h" : "")\" title=\"\(encoded(column.name))\">\(encoded(column.header))</th>"
        }
        out += "</tr></thead><tbody>"

        for row in rows {
            out += "<tr>"
            for (column, cell) in zip(columns, row) {
                let style = cssClass(column, cell.value).trimmingCharacters(in: .whitespaces)
                out += "<td class=\"\(style)\" data-v=\"\(encoded(cell.value.raw))\">\(encoded(cell.text ?? cell.value.display))</td>"
            }
            out += "</tr>\n"
        }

        out += "</tbody></table></div><script>\n" +
        "document.querySelectorAll('th').forEach((th,i)=>th.addEventListener('click',()=>{const tb=th.closest('table').tBodies[0];const rows=[...tb.rows];\n" +
        "const num=th.classList.contains('n');const dir=th.dataset.d=th.dataset.d==='a'?'d':'a';\n" +
        "rows.sort((a,b)=>{let x=a.cells[i].dataset.v??a.cells[i].textContent,y=b.cells[i].dataset.v??b.cells[i].textContent;if(num){x=parseFloat(x)||-1e9;y=parseFloat(y)||-1e9;return dir==='a'?x-y:y-x}return dir==='a'?x.localeCompare(y):y.localeCompare(x)});\n" +
        "rows.forEach(r=>tb.appendChild(r))}));</script></body></html>"
        return Data(out.utf8)
    }

    /// Colours the 1-20 attributes and the coaching stars. For the three attributes where high
    /// is bad, the good and bad ends swap.
    private static func cssClass(_ column: ExportColumn, _ value: ExportValue) -> String {
        let base = column.numeric ? "n" : ""
        switch value {
        case .int(let number) where column.numeric && number <= 20 && !column.ability && column.group != "General":
            if ["Injury Proneness", "Dirtiness", "Controversy"].contains(column.name) {
                return base + (number <= 5 ? " g" : number >= 15 ? " b" : "")
            }
            return base + (number >= 16 ? " g" : number <= 6 ? " m" : "")
        case .double(let number) where column.group == "Coaching stars":
            return base + (number >= 4.75 ? " g" : number < 3.75 ? " m" : "")
        default:
            return base
        }
    }

    /// System.Net.WebUtility.HtmlEncode: Latin-1 symbols and anything outside the BMP go out as
    /// numeric references.
    private static func encoded(_ value: String) -> String {
        let isPlain = value.utf8.allSatisfy { $0 < 0x80 && $0 != 0x3C && $0 != 0x3E && $0 != 0x22 && $0 != 0x27 && $0 != 0x26 }
        if isPlain { return value }

        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            case "&": out += "&amp;"
            case _ where (160..<256).contains(scalar.value) || scalar.value >= 0x10000:
                out += "&#\(scalar.value);"
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: Values

    // Game dates are built in UTC, so that's the zone they're shown in.
    fileprivate static let sortableDate = formatter("yyyy-MM-dd", .gmt)
    fileprivate static let shownDate = formatter("dd/MM/yyyy", .gmt)

    private static func formatter(_ pattern: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter
    }
}

private extension ExportValue {
    /// Storage.Raw: the invariant form, used by CSV and the HTML sort keys.
    var raw: String {
        if case .date(let date) = self { return Export.sortableDate.string(from: date) }
        return plain
    }

    /// What the HTML shows for a column with no formatter.
    var display: String {
        if case .date(let date) = self { return Export.shownDate.string(from: date) }
        return plain
    }

    private var plain: String {
        switch self {
        case .none, .date: return ""
        case .int(let value): return String(value)
        case .long(let value): return String(value)
        case .string(let value): return value
        case .bool(let value): return value ? "True" : "False"
        case .double(let value):
            // .NET prints 4.0 as "4".
            if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
            return String(value)
        }
    }
}

private extension ExportCell {
    /// Storage.Cell: the formatter's text, or the raw value.
    var shown: String { text ?? value.raw }
}

private extension String {
    /// The longest prefix of at most this many UTF-16 units, which is how .NET measures strings.
    func prefix(utf16Length length: Int) -> Substring {
        self[..<utf16.index(startIndex, offsetBy: length)]
    }
}
