import Darwin
import Foundation
import StarshipCore

/// A currency as the app shows it. StarshipCore's `Currency` has no public initialiser, and this target
/// needs to build the default pound and to copy a currency with a changed symbol.
public struct DisplayCurrency: Equatable, Hashable {
    public var name: String
    public var symbol: String
    public var perPound: Double

    public init(name: String, symbol: String, perPound: Double) {
        self.name = name
        self.symbol = symbol
        self.perPound = perPound
    }

    public init(_ currency: Currency) {
        self.init(name: currency.name, symbol: currency.symbol, perPound: currency.rate)
    }
}

public enum HeightUnit: Int {
    case cm = 0
    case feetInches = 1
}

public enum WagePeriod: Int {
    case week = 0
    case month = 1
    case year = 2
}

/// Height, money and wage display, either from the app's settings or following the game's preferences.
public enum Units {
    public static var height = HeightUnit.cm
    public static var wages = WagePeriod.week
    public static var pound = DisplayCurrency(name: "United Kingdom Pound", symbol: "£", perPound: 1.0)
    public static var money = pound
    public static var currencies = [pound]

    public static func heightText(_ centimetres: Int) -> String {
        guard centimetres > 0 else { return "" }
        if height == .cm { return "\(centimetres) cm" }
        let inches = Int((Double(centimetres) / 2.54).rounded(.toNearestOrEven))
        return "\(inches / 12)'\(inches % 12)\""
    }

    public static func moneyText(_ pounds: Double) -> String {
        guard pounds > 0 else { return "" }
        let value = pounds * money.perPound
        let symbol = money.symbol
        if value >= 1_000_000_000 { return "\(symbol)\(Net.fixed(value / 1_000_000_000, max: 2))B" }
        if value >= 100_000_000 { return "\(symbol)\(Net.fixed(value / 1_000_000, max: 1))M" }
        if value >= 1_000_000 { return "\(symbol)\(Net.fixed(value / 1_000_000, max: 2))M" }
        if value >= 1_000 { return "\(symbol)\(Net.fixed(value / 1_000, max: 1))K" }
        return "\(symbol)\(Net.fixed(value, max: 0))"
    }

    public static func wageText(_ weeklyPounds: Int, withSuffix: Bool) -> String {
        guard weeklyPounds > 0 else { return "" }
        let value = wageValue(weeklyPounds) * money.perPound
        let amount = value >= 1_000_000 ? "\(Net.fixed(value / 1_000_000, max: 2))M" : Net.groupedWhole(value)
        return money.symbol + amount + (withSuffix ? " \(wageSuffix)" : "")
    }

    public static var wageSuffix: String {
        switch wages {
        case .month: return "p/m"
        case .year: return "p/a"
        case .week: return "p/w"
        }
    }

    public static var wageHeading: String {
        switch wages {
        case .month: return "Wage per month"
        case .year: return "Wage per year"
        case .week: return "Wage per week"
        }
    }

    public static func wageValue(_ weeklyPounds: Int) -> Double {
        switch wages {
        case .month: return Double(weeklyPounds) * 52.0 / 12.0
        case .year: return Double(weeklyPounds) * 52.0
        case .week: return Double(weeklyPounds)
        }
    }

    public static func toPounds(_ shown: Double) -> Double { shown / money.perPound }

    public static func toWeeklyPounds(_ shown: Double) -> Double {
        let pounds = toPounds(shown)
        switch wages {
        case .month: return pounds / 4.333333333333333
        case .year: return pounds / 52.0
        case .week: return pounds / 1.0
        }
    }

    public static func setCurrencies(_ list: [Currency]) {
        guard !list.isEmpty else { return }
        let first = ["United Kingdom Pound", "European Euro", "United States Dollar", "Japanese Yen"]
        let all = list.map { currency -> DisplayCurrency in
            var copy = DisplayCurrency(currency)
            copy.symbol = copy.symbol.replacingOccurrences(of: "\u{FFE5}", with: "\u{A5}")
            // FM's database has no symbol for the krone; its preferences use "Kr".
            if copy.name == "Norwegian Krone" { copy.symbol = "Kr " }
            return copy
        }
        let leading = all.filter { first.contains($0.name) }
            .sorted { first.firstIndex(of: $0.name)! < first.firstIndex(of: $1.name)! }
        let rest = all.filter { !first.contains($0.name) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        currencies = leading + rest
        if let found = currencies.first(where: { $0.name == "United Kingdom Pound" }) { pound = found }
    }

    public static func apply() {
        let settings = Settings.current
        if settings.unitsFollowFm {
            fromFm()
            return
        }
        height = settings.heightUnit == "ft" ? .feetInches : .cm
        switch settings.wagePeriod {
        case "month": wages = .month
        case "year": wages = .year
        default: wages = .week
        }
        money = currencies.first { $0.name == settings.currencyName } ?? pound
    }

    public static func fromFm() {
        let folder = preferencesFolder()
        height = pref("height_scale", in: folder) == 2 ? .feetInches : .cm

        switch pref("wage_string_type", in: folder) {
        case 0: wages = .year
        case 2: wages = .month
        default: wages = .week
        }

        let chosen = pref("selected_currency", in: folder) ?? 0
        let want = fmCurrencies.indices.contains(chosen) ? fmCurrencies[chosen] : nil
        money = currencies.first { $0.name == want } ?? pound
    }

    /// FM27's preferences list, in the order `selected_currency` counts it. Two entries match no
    /// currency in FM's database, and show as pounds.
    private static let fmCurrencies: [String?] = [
        "United Kingdom Pound", "Argentinian Peso", "Australian Dollar", "Belgian Franc", "Brazilian Real", "Croatian Kuna",
        "Danish Krone", "European Euro", "Finnish Markka", "French Franc", "German Deutschmark", "Dutch Guilder",
        "Greek Drachma", "Irish Pound", "Italian Lire", "Japanese Yen", "Norwegian Krone", "Polish Zloty",
        "Portuguese Escudo", "Russian Ruble", "Spanish Peseta", "Swedish Krona", "Swiss Franc", "Turkish Lira",
        "United States Dollar", "South Korean Won", "Austrian Schilling", "Belarus Ruble", "Chilean Peso", "Colombian Peso",
        "Peruvian Nuevo Sol", "Uruguayan Peso", "Bulgarian Lev", "Chinese Yuan", "Czech Koruna", "Hong Kong Dollar",
        "Hungarian Forint", "Indonesian Rupiah", "Indian Rupee", "Icelandic Króna", "Israeli New Shekel", "Malaysian Ringgit",
        "Mexican Peso", "Romanian New Leu", "South Africa Rand", "Singaporean Dollar", "Slovakian Koruna", "Slovenian Tolar",
        "Thai Baht", "Serbian Dinar", "Albanian Lek", "Bosnian Convertible Marka", "Macedonian Denar", "Ukrainian Hrivna",
        "Canadian Dollar", "Filipino Peso", "New Zealand Dollar", nil, "Saudi Arabian Riyal", "United Arab Emirates Dirham",
        "Costa Rican Colón", nil, "Kuwaiti Dinar", "Qatari Riyal", "Vietnamese Dong", "Egyptian Pound",
    ]

    private static var sportsInteractive: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sports Interactive")
    }

    private static func preferencesFolder() -> URL? {
        sportsInteractive?.appendingPathComponent(gameFolderName()).appendingPathComponent("Preferences")
    }

    /// The newest `<name>.xml` under the game's Preferences folder, read as `value="<int>"`.
    private static func pref(_ name: String, in folder: URL?) -> Int? {
        guard let folder else { return nil }
        let wanted = "\(name).xml"
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            return nil
        }

        var newest: (url: URL, modified: Date)?
        for case let url as URL in files where url.lastPathComponent.caseInsensitiveCompare(wanted) == .orderedSame {
            let modified = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            if newest == nil || modified > newest!.modified { newest = (url, modified) }
        }

        guard let url = newest?.url, let text = try? String(contentsOf: url, encoding: .utf8),
              let match = text.firstMatch(of: #/value="(-?\d+)"/#) else { return nil }
        return Int32(match.1).map(Int.init)
    }

    /// `GameProcess.GameFolderName`: the running game's folder if there is one, otherwise the newest
    /// "Football Manager NN" that has a Preferences folder.
    private static func gameFolderName() -> String {
        if let pid = GameProcess.runningPID() {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                let path = String(cString: buffer)
                let parts = path.split(separator: "/").map(String.init)
                if let folder = parts.first(where: { $0.wholeMatch(of: #/Football Manager \d\d/#) != nil }) {
                    return folder
                }
            }
        }

        if let root = sportsInteractive,
           let folders = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            let found = folders
                .filter { $0.wholeMatch(of: #/Football Manager ../#) != nil }
                .filter {
                    var isFolder: ObjCBool = false
                    let preferences = root.appendingPathComponent($0).appendingPathComponent("Preferences")
                    return FileManager.default.fileExists(atPath: preferences.path, isDirectory: &isFolder)
                        && isFolder.boolValue
                }
            if let newest = Net.cultureSorted(found).last { return newest }
        }
        return "Football Manager 26"
    }
}
