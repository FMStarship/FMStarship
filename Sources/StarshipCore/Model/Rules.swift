/// Personality, media handling and coach ratings: FM's published-by-behaviour rules, as in FM Moleman.
public enum Rules {
    static let labels: [Int: String] = [
        1: "Professional", 2: "Determined", 3: "Temperamental", 4: "Balanced", 5: "Model Professional",
        6: "Driven", 7: "Slack", 8: "Casual", 9: "Very Ambitious", 10: "Ambitious", 11: "Unambitious",
        12: "Honest", 13: "Sporting", 14: "Unsporting", 15: "Realist", 16: "Easily Discouraged",
        17: "Low Determination", 18: "Very Loyal", 19: "Loyal", 20: "Mercenary", 21: "Fickle",
        22: "Iron Willed", 23: "Resilient", 24: "Spineless", 25: "Low Self Belief", 26: "Born Leader",
        27: "Natural Leader", 28: "Leader", 29: "Devoted", 30: "Light-Hearted", 31: "Jovial", 32: "Spirited",
        33: "Resolute", 34: "Fairly Determined", 35: "Fairly Professional", 36: "Fairly Ambitious",
        37: "Fairly Loyal", 38: "Fairly Sporting", 39: "Perfectionist", 40: "Model Citizen",
    ]

    static let mediaNames: [(Int, String)] = [
        (1, "Outspoken"), (2, "Evasive"), (4, "Volatile"), (16, "Unflappable"), (32, "Media-friendly"),
        (64, "Level-headed"), (128, "Reserved"), (256, "Short-tempered"), (512, "Confrontational"),
    ]

    public static func personalityId(determination d: Int, ambition am: Int, sportsmanship s: Int, loyalty l: Int,
                                     professionalism pr: Int, temperament t: Int, pressure pre: Int, age: Int,
                                     leadership: Int?, male: Bool) -> Int {
        if s >= 15, l >= 15, pr >= 15, d >= 14, am >= 12, t >= 15, pre > 13 { return 40 }
        if d >= 14, am >= 14, pr >= 14, t < 10 { return 39 }
        if pr <= 10, t <= 4, male { return 3 }
        if age >= 23, let lead = leadership, lead >= 19 {
            if d == 20, lead == 20 { return 26 }
            return s >= 18 && t >= 18 ? 27 : 28
        }
        if pr >= 18, t >= 10 { return pr == 20 && age >= 23 ? 5 : 1 }
        if d >= 18 { return am >= 12 ? 6 : 2 }
        if pr < 5, d < 10, male { return pr == 1 ? 7 : 8 }
        if l < 7, am >= 16, male { return l >= 4 ? 21 : 20 }
        if am >= 16, l <= 9 { return am == 20 ? 9 : 10 }
        if am < 6, l >= 11, male { return 11 }
        if d <= 9, s >= 18 { return s == 20 ? 12 : 13 }
        if s < 5, d >= 11, male { return s == 1 ? 14 : 15 }
        if d < 6, am < 10, male { return d == 1 ? 16 : 17 }
        if am <= 7, l >= 18 { return l == 20 ? 18 : 19 }
        if d >= 15, pre >= 17 { return pre == 20 ? 22 : 23 }
        if d < 10, pre < 4, male { return pre == 1 ? 24 : 25 }
        if t >= 10, pre >= 15 {
            if s >= 15 { return 30 }
            return pr >= 11 ? 32 : 31
        }
        if d >= 15 { return pr >= 15 ? 33 : 34 }
        if pr > 14 { return 35 }
        if am > 14 { return 36 }
        if l >= 15 { return 37 }
        return s >= 15 ? 38 : 4
    }

    public static func media(temperament t: Int, professionalism pr: Int, controversy c: Int, sportsmanship s: Int,
                             loyalty l: Int, pressure p: Int, male: Bool) -> String {
        var bits = t < 3 ? 256 : t < 7 ? 4 : 0
        if pr >= 15, t <= 15, p >= 15, s > 12 || c < 15 {
            bits |= 2
        } else if c >= 15 {
            bits |= 1
        } else if l < 11 || (s < 12 && pr < 13) {
            bits |= 32
        }
        if s <= 7, t <= 7 {
            bits |= 512
        } else if t >= 15, p > 14 {
            bits |= 16
        } else if c <= 5, pr >= 15, bits & 0x104 == 0 {
            bits |= 128
        }
        if bits == 0 { bits = 64 }
        if !male, bits & 0x304 != 0 { bits = (bits & 250) | 1 }
        return mediaNames.filter { bits & $0.0 > 0 }.map(\.1).joined(separator: ", ")
    }

    static func apply(_ person: Person, determination: Int, leadership: Int?) {
        let male = person.flags & 8 > 0
        let ambition = person.p("Ambition"), sportsmanship = person.p("Sportsmanship"), loyalty = person.p("Loyalty")
        let professionalism = person.p("Professionalism"), temperament = person.p("Temperament")
        let pressure = person.p("Pressure"), controversy = person.p("Controversy")
        let id = personalityId(determination: determination, ambition: ambition, sportsmanship: sportsmanship,
                               loyalty: loyalty, professionalism: professionalism, temperament: temperament,
                               pressure: pressure, age: max(0, person.age), leadership: leadership, male: male)
        person.personality = labels[id] ?? ""
        person.media = media(temperament: temperament, professionalism: professionalism, controversy: controversy,
                             sportsmanship: sportsmanship, loyalty: loyalty, pressure: pressure, male: male)
    }

    public static func coachRating(_ staff: Staff, area: Int) -> Int {
        let attacking = staff.a("Coaching Attacking"), defending = staff.a("Coaching Defending")
        let tactical = staff.a("Coaching Tactical"), technical = staff.a("Coaching Technical")
        let possession = staff.a("Coaching Possession")
        let base = (staff.a("Determination") + staff.a("Level Of Discipline") + staff.a("Motivating")) * 40 / 60
        let core: Int
        switch area {
        case 0: core = 2 * attacking + tactical
        case 1: core = 2 * attacking + technical
        case 2: core = 2 * defending + tactical
        case 3: core = 2 * defending + technical
        case 4: core = possession + 2 * tactical
        case 5: core = possession + 2 * technical
        case 6: core = 3 * staff.a("Coaching Goalkeepers")
        case 7: core = 3 * staff.a("Coaching Fitness")
        default: core = 2 * staff.a("Coaching Set Pieces") + staff.a("Tactical Knowledge")
        }
        let rating = core + base
        return staff.secondJob == 0 ? rating : Int(Double(rating) * 0.75)
    }

    public static func sharedRating(_ rating: Int, share: Int) -> Int { rating - rating / 2 * (100 - share) / 100 }
    public static func stars(_ rating: Int) -> Double { rating < 1 ? 0 : Double(min(20, 11 + rating / 10)) / 4.0 }

    static func coachStars(_ staff: Staff) {
        for area in 0..<9 { staff.stars[area] = stars(coachRating(staff, area: area)) }
    }
}
