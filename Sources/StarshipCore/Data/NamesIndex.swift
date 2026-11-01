extension Names {
    private static func index(_ names: [String]) -> [String: Int] {
        Dictionary(names.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public static let playerIndex = index(playerAttrs)
    public static let staffIndex = index(staffAttrs)
    public static let personalityIndex = index(personality)

    /// FM Starship matches anchors by English nation name, which fails in a translated game.
    /// Nation codes are the same in every language.
    static let areaAnchorCodes: [String: String] = [
        "ENG": "UK & Ireland", "NOR": "Scandinavia", "ESP": "France & Iberia", "GER": "Central Europe",
        "ITA": "Italy & Adriatic", "ROU": "Balkans & Danube", "GRE": "Greece, Turkey & Caucasus",
        "RUS": "Baltics & Eastern Europe", "KSA": "Middle East", "ISR": "Middle East", "UZB": "Central Asia",
        "KAZ": "Central Asia", "JPN": "East Asia", "IND": "South Asia", "THA": "South-East Asia",
        "AUS": "Australasia", "NZL": "Australasia", "MAR": "North Africa", "NGA": "West Africa",
        "CMR": "Central Africa", "KEN": "East Africa", "RSA": "Southern Africa", "BRA": "Southern South America",
        "COL": "Northern South America", "SUR": "Northern South America", "USA": "USA, Canada & Mexico",
        "CRC": "Central America", "JAM": "Caribbean",
    ]

    public static func squadName(_ type: Int) -> String {
        switch type {
        case 0: return "First team"
        case 1: return "Reserves"
        case 3: return "B team"
        case 9: return "U23"
        case 10: return "U21"
        case 11: return "U19"
        case 12: return "U18"
        case 14: return "Amateurs"
        case 15: return "II"
        case 16: return "2nd team"
        case 17: return "III"
        case 18: return "U20"
        case 21: return "Youths"
        case 36: return "U19 B"
        default: return "Other (\(type))"
        }
    }

    public static func fmStars(_ a: Int, _ b: Int) -> Int { min(10, max(1, a * (b + 25) / 400)) }

    public static func keenness(_ score: Int) -> String {
        if score >= 20 { return "favourite" }
        if score >= 15 { return "keen" }
        if score >= 10 { return "open to it" }
        return score >= 5 ? "reluctant" : "no"
    }
}
