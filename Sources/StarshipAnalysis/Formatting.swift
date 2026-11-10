import Foundation
import StarshipCore

/// .NET's number and date formats, so that what is shown matches the original to the digit.
enum NetFormat {
    /// A custom format such as "0.0", "0.#" or "0.##". .NET cuts a double to 15 significant digits
    /// and then rounds those half up, which is not what printf does (2.675 gives "2.68"). `truncating` cuts the
    /// digits off instead, the way FM shows money.
    static func fixed(_ value: Double, min: Int, max: Int, truncating: Bool = false) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : value < 0 ? "-∞" : "∞" }
        var (digits, scale) = significantDigits(Swift.abs(value))
        round(&digits, &scale, at: scale + max, up: !truncating)
        if digits.isEmpty { return min > 0 ? "0." + String(repeating: "0", count: min) : "0" }

        var whole = ""
        for i in 0..<Swift.max(scale, 0) { whole.append(i < digits.count ? character(digits[i]) : "0") }
        if whole.isEmpty { whole = "0" }

        var fraction: [Character] = []
        for k in 0..<max {
            let i = scale + k
            fraction.append(i >= 0 && i < digits.count ? character(digits[i]) : "0")
        }
        while fraction.count > min, fraction.last == "0" { fraction.removeLast() }

        let number = fraction.isEmpty ? whole : whole + "." + String(fraction)
        return value < 0 ? "-" + number : number
    }

    /// "+0.0;-0.0;0": a difference that rounds to nothing falls through to the zero section.
    static func signedOneDecimal(_ value: Double) -> String {
        let number = fixed(Swift.abs(value), min: 1, max: 1)
        if number == "0.0" { return "0" }
        return (value < 0 ? "-" : "+") + number
    }

    /// "+0;-0;0"
    static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    /// "+0;-0", which has no section of its own for zero.
    static func signedNoZero(_ value: Int) -> String {
        value < 0 ? "\(value)" : "+\(value)"
    }

    /// "N0"
    static func grouped(_ value: Int) -> String {
        grouped(String(Swift.abs(value)), negative: value < 0)
    }

    /// A whole amount of money with thousands separators, cut off like FM's.
    static func groupedMoney(_ value: Double) -> String {
        guard value.isFinite else { return "\(value)" }
        return grouped(fixed(Swift.abs(value), min: 0, max: 0, truncating: true), negative: value < 0)
    }

    private static func grouped(_ digits: String, negative: Bool) -> String {
        var out: [Character] = []
        for (i, c) in digits.reversed().enumerated() {
            if i > 0, i % 3 == 0 { out.append(",") }
            out.append(c)
        }
        let number = String(out.reversed())
        return negative && number != "0" ? "-" + number : number
    }

    static func monthYear(_ date: Date) -> String { monthYearFormatter.string(from: date) }     // "MMM yyyy"
    static func dayMonthYear(_ date: Date) -> String { dayMonthYearFormatter.string(from: date) } // "d MMM yyyy"
    static func numericDate(_ date: Date) -> String { numericDateFormatter.string(from: date) }   // "dd/MM/yyyy"

    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = GameDate.calendar.timeZone
        f.dateFormat = pattern
        return f
    }

    private static let monthYearFormatter = formatter("MMM yyyy")
    private static let dayMonthYearFormatter = formatter("d MMM yyyy")
    private static let numericDateFormatter = formatter("dd/MM/yyyy")

    private static func character(_ digit: UInt8) -> Character {
        Character(UnicodeScalar(48 + digit))
    }

    private static func significantDigits(_ value: Double) -> (digits: [UInt8], scale: Int) {
        guard value > 0 else { return ([], 0) }
        let text = String(format: "%.14e", value)
        guard let e = text.firstIndex(of: "e"), let exponent = Int(text[text.index(after: e)...]) else { return ([], 0) }
        var digits = text[..<e].compactMap { $0.wholeNumberValue }.map { UInt8($0) }
        while digits.last == 0 { digits.removeLast() }
        return (digits, exponent + 1)
    }

    /// `Number.RoundNumber`, or with `up` false, the digits cut off there.
    private static func round(_ digits: inout [UInt8], _ scale: inout Int, at position: Int, up: Bool = true) {
        var i = Swift.min(Swift.max(position, 0), digits.count)
        if up, position >= 0, i == position, i < digits.count, digits[i] >= 5 {
            while i > 0, digits[i - 1] == 9 { i -= 1 }
            if i > 0 {
                digits[i - 1] += 1
            } else {
                scale += 1
                digits = [1]
                i = 1
            }
        } else if position < 0 {
            i = 0
        } else {
            while i > 0, digits[i - 1] == 0 { i -= 1 }
        }
        if i == 0 { scale = 0 }
        digits.removeLast(digits.count - i)
    }
}

/// `Double.TryParse(text, NumberStyles.Float, Invariant)`, without the named infinities.
func parseInvariantDouble(_ text: String) -> Double? {
    let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var i = s.startIndex
    if i < s.endIndex, s[i] == "+" || s[i] == "-" { i = s.index(after: i) }
    var digits = 0
    while i < s.endIndex, s[i].isASCII, s[i].isNumber { digits += 1; i = s.index(after: i) }
    if i < s.endIndex, s[i] == "." {
        i = s.index(after: i)
        while i < s.endIndex, s[i].isASCII, s[i].isNumber { digits += 1; i = s.index(after: i) }
    }
    guard digits > 0 else { return nil }
    if i < s.endIndex, s[i] == "e" || s[i] == "E" {
        i = s.index(after: i)
        if i < s.endIndex, s[i] == "+" || s[i] == "-" { i = s.index(after: i) }
        var exponentDigits = 0
        while i < s.endIndex, s[i].isASCII, s[i].isNumber { exponentDigits += 1; i = s.index(after: i) }
        guard exponentDigits > 0 else { return nil }
    }
    guard i == s.endIndex else { return nil }
    var number = s
    if number.hasPrefix("+") { number.removeFirst() }
    return Double(number.hasSuffix(".") ? number + "0" : number)
}

/// `Int32.TryParse(text.Trim())`.
func parseInvariantInt(_ text: String) -> Int? {
    Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)).map(Int.init)
}

/// C# casts of a double wrap or saturate; a Swift cast would trap on a silly typed value.
func clampedInt64(_ value: Double) -> Int64 {
    guard value.isFinite else { return 0 }
    return value >= 9.2e18 ? Int64.max : value <= -9.2e18 ? Int64.min : Int64(value)
}

func clampedInt32(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    return value >= 2147483647 ? 2147483647 : value <= -2147483648 ? -2147483648 : Int(value)
}

/// `Units`: the currency, wage period and height unit that money and heights are shown in.
public struct MoneyUnits: Equatable {
    public enum WagePeriod: Int, CaseIterable {
        case week, month, year
    }

    public var symbol: String
    public var perPound: Double
    public var wagePeriod: WagePeriod
    public var feetAndInches: Bool

    public init(symbol: String = "£", perPound: Double = 1.0, wagePeriod: WagePeriod = .week, feetAndInches: Bool = false) {
        self.symbol = symbol
        self.perPound = perPound
        self.wagePeriod = wagePeriod
        self.feetAndInches = feetAndInches
    }

    public init(currency: Currency, wagePeriod: WagePeriod = .week, feetAndInches: Bool = false) {
        self.init(symbol: currency.symbol, perPound: currency.rate, wagePeriod: wagePeriod, feetAndInches: feetAndInches)
    }

    public func moneyText(_ amount: Double) -> String {
        guard amount > 0 else { return "" }
        let v = amount * perPound
        if v >= 1_000_000_000 { return symbol + NetFormat.fixed(v / 1_000_000_000, min: 0, max: 2, truncating: true) + "B" }
        if v >= 100_000_000 { return symbol + NetFormat.fixed(v / 1_000_000, min: 0, max: 1, truncating: true) + "M" }
        if v >= 1_000_000 { return symbol + NetFormat.fixed(v / 1_000_000, min: 0, max: 2, truncating: true) + "M" }
        if v >= 1000 { return symbol + NetFormat.fixed(v / 1000, min: 0, max: 1, truncating: true) + "K" }
        return symbol + NetFormat.fixed(v, min: 0, max: 0, truncating: true)
    }

    /// `Columns.Money` given a long.
    public func money(_ amount: Int64) -> String { moneyText(Double(amount)) }

    public func wageText(_ pounds: Int, suffix: Bool = false) -> String {
        guard pounds > 0 else { return "" }
        let v = wageValue(pounds) * perPound
        let number = v >= 1_000_000 ? NetFormat.fixed(v / 1_000_000, min: 0, max: 2, truncating: true) + "M" : NetFormat.groupedMoney(v)
        return symbol + number + (suffix ? " " + wageSuffix : "")
    }

    public var wageSuffix: String {
        switch wagePeriod {
        case .week: return "p/w"
        case .month: return "p/m"
        case .year: return "p/a"
        }
    }

    public func wageValue(_ pounds: Int) -> Double {
        switch wagePeriod {
        case .week: return Double(pounds)
        case .month: return Double(pounds) * 52 / 12
        case .year: return Double(pounds) * 52
        }
    }

    public func toPounds(_ amount: Double) -> Double { amount / perPound }

    public func toWeeklyPounds(_ amount: Double) -> Double {
        let pounds = toPounds(amount)
        switch wagePeriod {
        case .week: return pounds
        case .month: return pounds / 4.333333333333333
        case .year: return pounds / 52
        }
    }

    public func heightText(_ centimetres: Int) -> String {
        guard centimetres > 0 else { return "" }
        guard feetAndInches else { return "\(centimetres) cm" }
        let inches = Int((Double(centimetres) / 2.54).rounded(.toNearestOrEven))
        return "\(inches / 12)'\(inches % 12)\""
    }

    /// The max-fee box: a number of millions, with or without the currency symbol.
    func feeLimit(_ text: String) -> Double? {
        parseInvariantDouble(trimmedSymbol(text)).map { toPounds($0 * 1_000_000) }
    }

    /// The max-wage box: a number of thousands in the shown wage period.
    func wageLimit(_ text: String) -> Double? {
        parseInvariantDouble(trimmedSymbol(text)).map { toWeeklyPounds($0 * 1000) }
    }

    func trimmedSymbol(_ text: String) -> String {
        let symbols = Set(symbol)
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { symbols.contains($0) }))
    }
}

extension SeasonStats {
    var appsText: String { subs > 0 ? "\(starts) (\(subs))" : "\(apps)" }
    var ratingShown: Double { ((rating * 100) + 0.001).rounded(.down) / 100 }
    func per90(_ value: Int) -> Double { minutes > 0 ? Double(value) * 90 / Double(minutes) : 0 }
}

/// `Math.Round(value, digits)`: banker's rounding.
func roundedEven(_ value: Double, digits: Int) -> Double {
    let scale = pow(10, Double(digits))
    return (value * scale).rounded(.toNearestOrEven) / scale
}
