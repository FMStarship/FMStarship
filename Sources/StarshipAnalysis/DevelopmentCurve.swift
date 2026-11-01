import Foundation
import StarshipCore

/// How far players have come towards their potential at each age, measured across the whole world at this load.
/// Potential is a ceiling most never touch, so these lines say how much of it someone is likely to reach and when.
/// Someone keeps to their line: a teenager ahead of others of the same age and potential is projected to stay ahead.
///
/// Mentality decides how far along that line anyone gets, so the same players also give the odds: of those at their
/// prime with this potential and this Determination, Professionalism and Ambition, how many got close to it. The hidden
/// stats only count when the user shows them.
public struct DevelopmentCurve {
    /// Whether a young player is likely to live up to their potential.
    public struct Talent {
        public enum Verdict {
            case likely, even, unlikely

            public var title: String {
                switch self {
                case .likely: return "Likely to get there"
                case .even: return "Could go either way"
                case .unlikely: return "Unlikely to get there"
                }
            }

            public var tone: Tone {
                switch self {
                case .likely: return .good
                case .even: return .text
                case .unlikely: return .fair
                }
            }
        }

        public let determination: Int
        public let professionalism: Int
        public let ambition: Int
        public let injuryProneness: Int
        /// Of a hundred players like this, how many got within a tenth of their potential.
        public let chance: Int

        public var verdict: Verdict { chance >= 65 ? .likely : chance >= 45 ? .even : .unlikely }
        public var injuryProne: Bool { injuryProneness >= DevelopmentCurve.injuryProne }
        /// "Pro 13, Det 14, Amb 15", with the one that matters most first.
        public var mentality: String { "Pro \(professionalism), Det \(determination), Amb \(ambition)" }
        /// "7 in 10", the way a person says odds.
        public var odds: String { "\(max(1, min(9, (chance + 5) / 10))) in 10" }
    }

    private struct Point {
        var low: Double
        var middle: Double
        var high: Double

        /// `line` runs from 0 on the low line, through 1 in the middle, to 2 on the high line.
        func share(line: Double) -> Double {
            line <= 1 ? low + (middle - low) * line : middle + (high - middle) * (line - 1)
        }

        func line(for share: Double) -> Double {
            if share <= low { return 0 }
            if share >= high { return 2 }
            if share < middle { return middle > low ? (share - low) / (middle - low) : 1 }
            return high > middle ? 1 + (share - middle) / (high - middle) : 1
        }
    }

    /// Players are at their best around here, and past it the lines start to fall with age.
    public static let peakAge = 28
    private static let bands = [100...119, 120...139, 140...159, 160...200]
    private static let ages = 15...peakAge
    /// A line through fewer players than this is noise.
    private static let enough = 8
    /// Past this age there's little growth left to wait for, and a gain below this isn't worth waiting for.
    private static let oldestProspect = 22
    private static let growthWorthWaitingFor = 8
    /// Players this old have shown what they were going to be.
    private static let prime = 25...29
    /// Got close: past this share of their potential.
    private static let closeToPotential = 0.9
    /// Determination, Professionalism and Ambition added up, in bands: nobody reads a single point's difference.
    private static let mentalityBands = [29, 33, 37, 41, 45]
    private static let injuryBands = [8, 13]
    fileprivate static let injuryProne = 14
    /// A band with fewer players than this falls back on everyone with that potential.
    private static let enoughForOdds = 15
    /// Nobody is a certainty.
    private static let surest = 0.95

    private struct Outcome {
        var reached = 0
        var shares: [Double] = []

        var odds: Double { shares.isEmpty ? 0 : Double(reached) / Double(shares.count) }
        var median: Double { shares.isEmpty ? 0 : shares.sorted()[shares.count / 2] }

        mutating func add(_ share: Double) {
            shares.append(share)
            if share >= DevelopmentCurve.closeToPotential { reached += 1 }
        }
    }

    /// By band of potential, then by age.
    private let points: [[Point]]
    /// By band of potential: everyone at their prime, then by mentality.
    private let outcomes: [Outcome]
    private let outcomesByMentality: [[Outcome]]
    /// How much likelier than average someone at each injury band was to get there.
    private let injuryFactors: [Double]
    private let usesHidden: Bool

    /// Below this band few get close whatever their mentality, so the verdict would say more about the band than the player.
    private static let lowestOddsBand = 1

    private static func band(_ value: Int, in edges: [Int]) -> Int { edges.firstIndex { value <= $0 } ?? edges.count }

    private static func mentality(_ player: Player) -> Int {
        player.a("Determination") + player.p("Professionalism") + player.p("Ambition")
    }

    public init(players: [Player], usesHidden: Bool = true) {
        self.usesHidden = usesHidden
        var outcomes = [Outcome](repeating: Outcome(), count: Self.bands.count)
        var byMentality = [[Outcome]](repeating: [Outcome](repeating: Outcome(), count: Self.mentalityBands.count + 1), count: Self.bands.count)
        var byInjury = [Outcome](repeating: Outcome(), count: Self.injuryBands.count + 1)
        var everyone = Outcome()
        for player in players where player.ca > 0 && Self.prime.contains(player.age) {
            guard let found = Self.bands.firstIndex(where: { $0.contains(player.pa) }) else { continue }
            let band = max(found, Self.lowestOddsBand)
            let share = Double(player.ca) / Double(player.pa)
            outcomes[band].add(share)
            byMentality[band][Self.band(Self.mentality(player), in: Self.mentalityBands)].add(share)
            byInjury[Self.band(player.a("Injury Proneness"), in: Self.injuryBands)].add(share)
            everyone.add(share)
        }
        self.outcomes = outcomes
        outcomesByMentality = byMentality
        injuryFactors = byInjury.map { everyone.odds > 0 && $0.shares.count >= Self.enoughForOdds ? $0.odds / everyone.odds : 1 }

        var shares = [[[Double]]](repeating: [[Double]](repeating: [], count: Self.ages.count), count: Self.bands.count)
        for player in players where player.ca > 0 && Self.ages.contains(player.age) {
            guard let band = Self.bands.firstIndex(where: { $0.contains(player.pa) }) else { continue }
            shares[band][player.age - Self.ages.lowerBound].append(Double(player.ca) / Double(player.pa))
        }
        points = shares.map { band in
            let found = band.map { group -> Point? in
                guard group.count >= Self.enough else { return nil }
                let sorted = group.sorted()
                return Point(low: sorted[sorted.count / 4], middle: sorted[sorted.count / 2], high: sorted[sorted.count * 3 / 4])
            }
            guard var last = found.compactMap({ $0 }).first else { return [] }
            // A thin age takes the one before it, and sampling noise never makes a line fall.
            return found.map { point in
                if let point {
                    last = Point(low: max(last.low, point.low), middle: max(last.middle, point.middle), high: max(last.high, point.high))
                }
                return last
            }
        }
    }

    /// The same players without the hidden stats, for someone who has them switched off.
    func hidingMentality() -> DevelopmentCurve { DevelopmentCurve(self, usesHidden: false) }

    private init(_ other: DevelopmentCurve, usesHidden: Bool) {
        points = other.points
        outcomes = other.outcomes
        outcomesByMentality = other.outcomesByMentality
        injuryFactors = other.injuryFactors
        self.usesHidden = usesHidden
    }

    private func outcome(_ player: Player) -> (band: Outcome, mentality: Outcome)? {
        guard !outcomes.isEmpty else { return nil }
        let band = max(Self.bands.firstIndex { player.pa <= $0.upperBound } ?? Self.bands.count - 1, Self.lowestOddsBand)
        let own = outcomesByMentality[band][Self.band(Self.mentality(player), in: Self.mentalityBands)]
        return own.shares.count >= Self.enoughForOdds ? (outcomes[band], own) : (outcomes[band], outcomes[band])
    }

    /// How far above or below the usual for their potential this mentality takes someone at their prime.
    private func mentalityShift(_ player: Player) -> Double {
        guard usesHidden, let outcome = outcome(player), !outcome.band.shares.isEmpty else { return 0 }
        return outcome.mentality.median - outcome.band.median
    }

    /// The odds for someone young. Nil with the hidden stats off, or with nobody to judge by.
    public func talent(_ player: Player) -> Talent? {
        guard usesHidden, let outcome = outcome(player), !outcome.mentality.shares.isEmpty else { return nil }
        let injury = player.a("Injury Proneness")
        let odds = min(Self.surest, outcome.mentality.odds * injuryFactors[Self.band(injury, in: Self.injuryBands)])
        // The further along someone already is, the less can go wrong.
        let along = progress(player)
        return Talent(determination: player.a("Determination"), professionalism: player.p("Professionalism"), ambition: player.p("Ambition"),
                      injuryProneness: injury, chance: Int(((odds + (Self.surest - odds) * along * along) * 100).rounded()))
    }

    /// From the low line at their age, at 0, to already being close to their potential, at 1.
    private func progress(_ player: Player) -> Double {
        let line = line(player)
        guard !line.isEmpty, player.pa > 0, player.age >= 0 else { return 0 }
        let low = line[Self.ageIndex(player.age)].low
        guard low < Self.closeToPotential else { return 1 }
        return min(1, max(0, (Double(player.ca) / Double(player.pa) - low) / (Self.closeToPotential - low)))
    }

    private static func ageIndex(_ age: Int) -> Int { min(max(age, ages.lowerBound), ages.upperBound) - ages.lowerBound }

    private func line(_ player: Player) -> [Point] {
        let band = Self.bands.firstIndex { player.pa <= $0.upperBound } ?? Self.bands.count - 1
        return band < points.count ? points[band] : []
    }

    /// The ability to expect at an age, for someone who keeps to their line. Never below where they are now.
    public func expected(_ player: Player, atAge age: Int) -> Int {
        let line = line(player)
        guard !line.isEmpty, player.pa > 0, player.age >= 0, age > player.age else { return player.ca }
        let position = line[Self.ageIndex(player.age)].line(for: Double(player.ca) / Double(player.pa))
        let projected = Int((Double(player.pa) * (line[Self.ageIndex(age)].share(line: position) + mentalityShift(player))).rounded())
        return max(player.ca, min(player.pa, projected))
    }

    public func peak(_ player: Player) -> Int { expected(player, atAge: Self.peakAge) }

    /// Young, and likely to improve by enough to be worth the wait.
    public func isProspect(_ player: Player) -> Bool {
        player.age >= 0 && player.age <= Self.oldestProspect && peak(player) >= player.ca + Self.growthWorthWaitingFor
    }
}
