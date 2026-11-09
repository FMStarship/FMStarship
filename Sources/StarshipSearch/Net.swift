import Foundation
import StarshipCore

/// The .NET string and number behaviour the original app leans on. Swift's own parsing, rounding and
/// comparison differ in small ways that change which rows match, so they are spelled out once here.
enum Net {
    /// `String.Trim()`.
    static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// `String.IsNullOrWhiteSpace`.
    static func isBlank(_ text: String) -> Bool { trim(text).isEmpty }

    /// `String.TrimStart(chars)`.
    static func trimStart(_ text: String, _ chars: Set<Unicode.Scalar>) -> String {
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, chars.contains(first) { scalars.removeFirst() }
        return String(scalars)
    }

    /// `Int32.TryParse`: 32-bit, optional sign, surrounding whitespace allowed.
    static func int32(_ text: String) -> Int? { Int32(trim(text)).map(Int.init) }

    /// `Double.TryParse(text, NumberStyles.Float, InvariantCulture)`. Stricter than `Double(_:)`, which
    /// also takes hex floats and "inf".
    static func double(_ text: String) -> Double? {
        let trimmed = trim(text)
        switch trimmed.lowercased() {
        case "nan", "+nan", "-nan": return .nan
        case "infinity", "+infinity": return .infinity
        case "-infinity": return -.infinity
        default: break
        }
        return isFloat(trimmed) ? Double(trimmed) : nil
    }

    private static func isFloat(_ text: String) -> Bool {
        var bytes = Substring(text).utf8
        func digits() -> Int {
            var count = 0
            while let byte = bytes.first, (48...57).contains(byte) { bytes.removeFirst(); count += 1 }
            return count
        }
        if let sign = bytes.first, sign == 43 || sign == 45 { bytes.removeFirst() }
        var mantissa = digits()
        if bytes.first == 46 {
            bytes.removeFirst()
            mantissa += digits()
        }
        guard mantissa > 0 else { return false }
        if let e = bytes.first, e == 101 || e == 69 {
            bytes.removeFirst()
            if let sign = bytes.first, sign == 43 || sign == 45 { bytes.removeFirst() }
            guard digits() > 0 else { return false }
        }
        return bytes.isEmpty
    }

    /// Custom numeric formats "0", "0.#", "0.##", "0.0", "0.00": `max` decimals of which `min` always show.
    /// .NET takes 15 significant digits and then rounds half up, so 1.005 gives "1.01" where printf gives
    /// "1.00". The separator is always ".", where the original used the Windows culture. `truncating` cuts the
    /// digits off instead, the way FM shows money.
    static func fixed(_ value: Double, min minDecimals: Int = 0, max maxDecimals: Int, truncating: Bool = false) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : value < 0 ? "-Infinity" : "Infinity" }

        let scientific = String(format: "%.14e", abs(value))
        let parts = scientific.split(separator: "e")
        var digits = parts[0].utf8.filter { $0 != 46 }.map { Int($0) - 48 }
        var point = Int(parts[1])! + 1

        let keep = point + maxDecimals
        if keep < 0 {
            digits = []
        } else if keep < digits.count {
            let roundUp = !truncating && digits[keep] >= 5
            digits.removeSubrange(keep...)
            if roundUp {
                var index = keep - 1
                while index >= 0, digits[index] == 9 {
                    digits[index] = 0
                    index -= 1
                }
                if index >= 0 {
                    digits[index] += 1
                } else {
                    digits.insert(1, at: 0)
                    point += 1
                }
            }
        }

        let isZero = digits.allSatisfy { $0 == 0 }
        var whole = ""
        var fraction = ""
        for position in 0..<(max(point, 0) + maxDecimals) {
            let index = position + min(point, 0)
            let digit = index >= 0 && index < digits.count ? digits[index] : 0
            if position < max(point, 0) {
                whole.append(String(digit))
            } else {
                fraction.append(String(digit))
            }
        }
        if whole.isEmpty { whole = "0" }
        while fraction.count > minDecimals, fraction.last == "0" { fraction.removeLast() }

        let sign = value < 0 && !isZero ? "-" : ""
        return fraction.isEmpty ? sign + whole : "\(sign)\(whole).\(fraction)"
    }

    /// A whole amount of money with thousands separators, cut off like FM's.
    static func groupedMoney(_ value: Double) -> String {
        let plain = fixed(abs(value), max: 0, truncating: true)
        var grouped = ""
        for (offset, digit) in plain.enumerated() {
            if offset > 0, (plain.count - offset) % 3 == 0 { grouped.append(",") }
            grouped.append(digit)
        }
        return value < 0 && plain != "0" ? "-" + grouped : grouped
    }

    /// `OrderBy(s => s)`: the default string comparer follows the user's culture.
    static func cultureSorted(_ items: [String]) -> [String] {
        items.sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    /// `Distinct()`: keeps the first of each.
    static func distinct(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    /// `String.Join(", ", values.Where(v => !string.IsNullOrEmpty(v)))`.
    static func join(_ values: [String?], separator: String = ", ") -> String {
        values.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: separator)
    }

    /// "dd/MM/yyyy" with the Windows default separator.
    static func dayMonthYear(_ date: Date) -> String {
        let parts = GameDate.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%02d/%02d/%04d", parts.day ?? 0, parts.month ?? 0, parts.year ?? 0)
    }

    /// The year of a date, in UTC like every date in the data model.
    static func year(_ date: Date) -> Int { GameDate.calendar.component(.year, from: date) }
}

/// `StringComparison.OrdinalIgnoreCase`: one UTF-16 unit at a time, through a simple-uppercase table.
enum OrdinalCase {
    static let upper: [UInt16] = {
        var table = (0...0xFFFF).map { UInt16($0) }
        for unit in 0x61...0x7A { table[unit] = UInt16(unit - 32) }
        for unit in 0x80...0xFFFF {
            guard let scalar = Unicode.Scalar(UInt16(unit)) else { continue }
            let mapped = scalar.properties.uppercaseMapping.unicodeScalars
            if mapped.count == 1, let target = mapped.first, target.value <= 0xFFFF {
                table[unit] = UInt16(target.value)
            }
        }
        // .NET keeps ordinal comparison free of the Turkish i and the long s.
        table[0x131] = 0x131
        table[0x17F] = 0x17F
        return table
    }()

    static func fold(_ text: String) -> [UInt16] {
        let table = upper
        return text.utf16.map { table[Int($0)] }
    }
}

/// `SearchBase.Has`, prepared once per search: blank or "Any" passes everything, a leading "=" asks for an
/// exact match (ignoring case), anything else is a case-insensitive "contains".
struct TextTest {
    private enum Mode {
        case any
        case contains([UInt16])
        case equals([UInt16])
    }

    private let mode: Mode
    private let table: [UInt16]

    init(_ filter: String) {
        table = OrdinalCase.upper
        if Net.isBlank(filter) || filter == "Any" {
            mode = .any
        } else if filter.utf16.first == 61 {
            mode = .equals(OrdinalCase.fold(Net.trim(String(filter.unicodeScalars.dropFirst()))))
        } else {
            mode = .contains(OrdinalCase.fold(Net.trim(filter)))
        }
    }

    /// A plain "contains" with no special meaning for "=" or "Any".
    init(literal text: String) {
        table = OrdinalCase.upper
        mode = .contains(OrdinalCase.fold(text))
    }

    func matches(_ text: String) -> Bool {
        switch mode {
        case .any:
            return true
        case .equals(let needle):
            guard text.utf16.count == needle.count else { return false }
            return zip(text.utf16, needle).allSatisfy { table[Int($0)] == $1 }
        case .contains(let needle):
            guard !needle.isEmpty else { return true }
            let hay = Array(text.utf16)
            guard hay.count >= needle.count else { return false }
            for start in 0...(hay.count - needle.count) {
                var offset = 0
                while offset < needle.count, table[Int(hay[start + offset])] == needle[offset] { offset += 1 }
                if offset == needle.count { return true }
            }
            return false
        }
    }
}

/// `SearchBase.HasName`: an ordinal search of the already-lowercased search text.
struct NameTest {
    private let needle: [UInt8]?

    init(_ filter: String) {
        needle = Net.isBlank(filter) ? nil : Array(Net.trim(filter).lowercased().utf8)
    }

    var isActive: Bool { needle != nil }

    func matches(_ haystack: String) -> Bool {
        guard let needle else { return true }
        var text = haystack
        return text.withUTF8 { hay in
            needle.withUnsafeBytes { memmem(hay.baseAddress, hay.count, $0.baseAddress, $0.count) != nil }
        }
    }
}
