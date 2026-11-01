import Foundation
import StarshipCore

/// The best the club can put out in the user's own tactic: the same places and roles, with FM's stars choosing
/// who plays in them.
public struct BestEleven {
    public struct Place {
        /// Holds the player this eleven puts here.
        public let slot: TacticSlot
        public let stars: Int
        /// Who the user has here now.
        public let current: Player?
        public let currentStars: Int

        public var isChange: Bool { slot.player?.uid != current?.uid }
    }

    /// Stars decide. Where they tie the user's pick stays, because a change that can't be seen isn't advice, and
    /// only then does FM's finer rating count. Over eleven places each weight still outruns everything below it.
    private static let starWeight = 1 << 44, keepWeight = 1 << 38
    /// Out for this long, a player can't be picked.
    private static let longTerm = 21

    public static let columns = [
        TableColumn("Position", 8), TableColumn("With the ball", 20), TableColumn("Without the ball", 20), TableColumn("Player", 20),
        TableColumn("Stars", 7), TableColumn("CA", 5), TableColumn("Your pick", 20), TableColumn("Change", 7),
    ]

    public let shape: String
    /// Goalkeeper first, up to the strikers.
    public let places: [Place]
    /// What moves and why, in sentences.
    public let notes: [String]
    /// Left out for being out for weeks.
    public let leftOut: Int
    public let table: AnalysisTable

    /// Nil without the live game or a tactic to go on.
    public init?(session: AnalysisSession) {
        guard let tactic = session.db.tactics[session.club.team], let book = RoleBook(session) else { return nil }
        let slots = tactic.slots.stableSorted { $0.pitchOrder < $1.pitchOrder }
        let club = session.club.name
        var pool = session.db.players.filter { $0.block != 0 && $0.ca > 0 && Self.canPlay($0, for: club) }
        var known = Set(pool.map(\.uid))
        pool += slots.compactMap(\.player).filter { known.insert($0.uid).inserted }
        let fit = pool.filter { $0.injury == nil || session.checks.daysOut($0) < Self.longTerm }

        let ratings = fit.map { player in slots.map { book.rate(player, in: $0) } }
        let chosen = Self.choose(ratings, current: slots.map { slot in fit.firstIndex { $0.uid == slot.player?.uid } }, places: slots.count)
        places = zip(slots, chosen).map { slot, index in
            var slot = slot
            let current = slot.player
            slot.player = index.map { fit[$0] }
            return Place(slot: slot, stars: slot.player.flatMap { book.rate($0, in: slot)?.combined } ?? 0,
                         current: current, currentStars: current.flatMap { book.rate($0, in: slot)?.combined } ?? 0)
        }
        shape = tactic.shape(in: session.library)
        leftOut = pool.count - fit.count
        notes = Self.notes(places, fit: fit, book: book, session: session)
        table = Self.table(places, display: session.display)
    }

    /// Whoever the manager could name: the whole club, youth and B teams too, and loans in, but not loans out.
    static func canPlay(_ player: Player, for club: String) -> Bool {
        (player.clubFull == club && (player.loanClub.isEmpty || player.isAtOwnBTeam)) || player.loanClubFull == club
    }

    /// For each place, the index of the player who goes there. `ratings[player][place]`, nil where FM has no rating;
    /// `current[place]` is the player there now. A place is only left empty when the players run out.
    static func choose(_ ratings: [[RoleBook.Rating?]], current: [Int?], places: Int) -> [Int?] {
        let scores = ratings.enumerated().map { player, row in
            row.enumerated().map { place, rating in
                (rating?.combined ?? 0) * starWeight + (current[place] == player ? keepWeight : 0) + max(0, rating?.score ?? 0)
            }
        }
        let nobody = [[Int]](repeating: [Int](repeating: 0, count: places), count: max(0, places - ratings.count))
        return (TacticOptimizer.assign(scores + nobody, places: places) ?? []).map { $0 < ratings.count ? $0 : nil }
    }

    /// "+0.5★", "-1★", as the overviews write a gain. "½★" would draw as a half star and a whole one.
    static func gain(_ halves: Int) -> String {
        (halves > 0 ? "+" : "") + NetFormat.fixed(Double(halves) / 2, min: 0, max: 1) + "★"
    }

    private static func average(_ stars: [Int]) -> String {
        NetFormat.fixed(stars.isEmpty ? 0 : Double(stars.reduce(0, +)) / Double(stars.count) / 2, min: 2, max: 2) + "★"
    }

    /// The answer in a sentence.
    public var headline: String { Self.headline(places) }

    static func headline(_ places: [Place]) -> String {
        let changes = places.filter(\.isChange).count
        guard changes > 0 else { return "Your eleven is already the best the club has for this tactic." }
        let from = average(places.map(\.currentStars)), to = average(places.map(\.stars))
        return "\(changes) \(changes == 1 ? "change takes" : "changes take") your eleven's average from \(from) to \(to)."
    }

    public var title: String { "Best eleven for your \(shape)" }

    public var footnote: String {
        let out = leftOut > 0 ? " (\(leftOut))" : ""
        return "Stars are FM's own, for the roles in your tactic. This is the highest star total with each player used once, and where stars tie your pick stays. Anyone at the club can be picked, youth teams and loans in too, but not loans out or anyone out for 3+ weeks\(out)."
    }

    private static func table(_ places: [Place], display: DisplayOptions) -> AnalysisTable {
        var table = AnalysisTable(columns: columns)
        for place in places {
            let slot = place.slot
            let without = slot.position == slot.positionWithoutBall ? slot.roleNameWithoutBall
                                                                    : "\(Names.positions[slot.positionWithoutBall]): \(slot.roleNameWithoutBall)"
            let halves = place.stars - place.currentStars
            // The surname, so the column can't push the last one out of the panel. The notes have the full names.
            let pick = place.current.map { "\(SquadOverview.surname($0)) \(RoleBook.stars(place.currentStars))" } ?? "Nobody picked"
            table.rows.append(TableRow(cells: [
                slot.label, slot.roleName, without, slot.player?.name ?? "Nobody left",
                RoleBook.stars(place.stars), slot.player.map { display.ability($0.ca) } ?? "",
                place.isChange ? pick : "",
                !place.isChange ? "Same" : halves == 0 ? "Level" : gain(halves),
            ], person: slot.player, tone: !place.isChange || halves == 0 ? nil : halves > 0 ? .good : .fair, toneColumn: 7, bold: place.isChange))
        }
        return display.fit(table)
    }

    private static func notes(_ places: [Place], fit: [Player], book: RoleBook, session: AnalysisSession) -> [String] {
        var notes: [String] = []
        let eleven = Set(places.compactMap { $0.slot.player?.uid })
        for place in places where place.isChange {
            guard let player = place.slot.player else { continue }
            let label = place.slot.label
            if let from = places.first(where: { $0.current?.uid == player.uid }) {
                notes.append("\(player.name) moves from \(from.slot.label) to \(label), \(RoleBook.stars(from.currentStars)) to \(RoleBook.stars(place.stars)).")
                continue
            }
            let squad = player.squad.isEmpty || player.squad == "First team" ? "" : " from the \(player.squad)"
            if let current = place.current {
                notes.append("\(player.name) comes in\(squad) at \(label) for \(current.name), \(RoleBook.stars(place.currentStars)) to \(RoleBook.stars(place.stars)).")
            } else {
                notes.append("\(player.name) comes in\(squad) at \(label), where nobody is picked.")
            }
        }

        let curve = session.development
        let level = AnalysisSession.level(of: SquadPlanner.analysedSquad(session))
        let isTalent = { (player: Player) in curve.isProspect(player) && curve.peak(player) >= level - 8 }
        for player in places.compactMap(\.current) where !eleven.contains(player.uid) {
            let days = player.injury == nil ? 0 : session.checks.daysOut(player)
            if days >= longTerm {
                notes.append("\(player.name) is out for \(days) days, so they can't be in this eleven.")
            } else if isTalent(player) {
                // Stars are about today, and the minutes are how a talent gets there.
                notes.append("\(player.name) is \(player.age) and still developing, so the minutes may be worth more to them than the stars are to the team.")
            }
        }

        // A tie keeps the user's pick, but a talent who ties is a chance to give them the minutes for nothing.
        var waiting = fit.filter { !eleven.contains($0.uid) && isTalent($0) }.stableSorted { curve.peak($0) > curve.peak($1) }
        for place in places {
            guard let starter = place.slot.player,
                  let talent = waiting.firstIndex(where: { (book.rate($0, in: place.slot)?.combined ?? 0) >= place.stars }) else { continue }
            let player = waiting.remove(at: talent)
            notes.append("\(player.name) is level with \(starter.name) at \(place.slot.label), \(RoleBook.stars(place.stars)), and still developing at \(player.age), so playing them costs the team nothing.")
        }

        for player in places.compactMap(\.slot.player) where player.injury != nil {
            notes.append("\(player.name) is injured for another \(session.checks.daysOut(player)) days.")
        }
        return notes
    }
}
