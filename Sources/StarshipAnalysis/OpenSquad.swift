import Foundation
import StarshipCore

/// The "Open squad" dialog: which clubs and squads there are to pick from. What it opens is a
/// search, `club` as "=name" and the squad filter, which belongs to the search screens.
public struct OpenSquad {
    public static let title = "Open Squad"
    public static let clubLabel = "Club"
    public static let squadLabel = "Squad"
    public static let allSquads = "All squads"

    private let session: AnalysisSession
    private var squadsOf: [String: [String]] = [:]
    public let clubs: [String]

    public init(session: AnalysisSession) {
        self.session = session
        var names: [String] = []
        var seen = Set<String>()
        var hasLoans = Set<String>()
        var squads: [String: [String]] = [:]

        func add(_ name: String) {
            if seen.insert(name.lowercased()).inserted { names.append(name) }
        }

        for p in session.db.players where !p.clubFull.isEmpty {
            add(p.clubFull)
            let key = p.clubFull.lowercased()
            if !p.squad.isEmpty, squads[key]?.contains(p.squad) != true { squads[key, default: []].append(p.squad) }
            if !p.loanClub.isEmpty { hasLoans.insert(key) }
        }
        for key in hasLoans where squads[key]?.contains("On loan") != true { squads[key, default: []].append("On loan") }
        for s in session.db.staff where !s.clubFull.isEmpty { add(s.clubFull) }

        squadsOf = squads
        clubs = names.stableSorted {
            $0.compare($1, options: [.caseInsensitive], locale: Locale(identifier: "en_GB")) == .orderedAscending
        }
    }

    /// The club box starts at the last one opened, else your club.
    public func startingClub(lastOpened: String? = nil) -> String {
        if let lastOpened { return lastOpened }
        return session.club.name.isEmpty ? session.db.humanClubs.first?.name ?? "" : session.club.name
    }

    /// The squad box for what is typed in the club box: "All squads", then the usual order, then the rest.
    public func squads(for club: String) -> [String] {
        let here = squadsOf[club.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] ?? []
        return [OpenSquad.allSquads] + Names.squadOrder.filter(here.contains)
            + here.filter { !$0.isEmpty && !Names.squadOrder.contains($0) }
    }

    public func startingSquadIndex(for club: String) -> Int {
        squads(for: club).count > 1 ? 1 : 0
    }

    public func club(matching typed: String) -> String? {
        let wanted = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return clubs.first { $0.lowercased() == wanted }
    }

    public static func noSuchClub(_ typed: String) -> String {
        "No club called \"\(typed)\" - pick one from the list."
    }
}
