import Foundation
import StarshipAnalysis
import StarshipCore
import StarshipSearch

/// How a club's players have developed, from the record `DevelopmentStore` keeps: a snapshot of the squad each game day FM
/// Starship read the save, in the app or in its tab inside FM. FM keeps no such history itself. Only read here, never written.
extension Toolbox {
    static let developmentAbout = "FM Starship's own record, not FM's history: a snapshot of the club's squad on each game day FM "
        + "Starship read the save, in the app (Load Save) or in its tab inside FM, one per game day, the last "
        + "\(DevelopmentStore.keep) kept. A gap between dates is days nobody read the save with FM Starship, not days without change. "
        + "Attributes are FM's 1-20."
    /// How far back the club view compares when since isn't given, so a long record doesn't bring in players long gone.
    static let developmentDays = 90

    /// Why there's nothing to compare, and how the record is made.
    private static func noRecord(_ club: String, others: [String]) -> ToolError {
        var sentence = "FM Starship has no development record of \(club) yet. It makes one itself: each time FM Starship reads the "
            + "save, in the app (Load Save) or in its tab inside FM, it keeps a snapshot of the squad of the club picked in FM "
            + "Starship, one per game day. Once it has read the save on two game days, this can compare them."
        if !others.isEmpty { sentence += " Clubs it has a record of: \(others.joined(separator: ", "))." }
        return ToolError(sentence)
    }

    /// The clubs this game's development folder has a record of, by their files' names.
    private func recordedClubs(_ db: Database) -> [String] {
        let folder = developmentStore.path(db: db, club: "x").deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// The club asked about and its records, oldest first: the user's, or a named one with a record.
    private func developmentRecord(_ named: String?, _ context: CallContext) throws -> (club: String, snaps: [DevelopmentStore.Snap]) {
        let db = context.db
        let club = try named.map { named in
            if let found = context.humanClubs.first(where: { $0.name.caseInsensitiveCompare(named) == .orderedSame })?.name
                ?? db.players.first(where: { $0.clubFull.caseInsensitiveCompare(named) == .orderedSame })?.clubFull {
                return found
            }
            // A club that's left the save: its file's name is the club's.
            let file = developmentStore.path(db: db, club: named).lastPathComponent.dropLast(5)
            return recordedClubs(db).first { $0.caseInsensitiveCompare(file) == .orderedSame } ?? named
        } ?? context.ownClub(nil).name
        let snaps = developmentStore.load(db: db, club: club)
        guard !snaps.isEmpty else { throw Self.noRecord(club, others: recordedClubs(db).filter { $0 != club }) }
        return (club, snaps.sorted { $0.gameDate < $1.gameDate })
    }

    func development(_ args: Arguments, _ context: CallContext) throws -> JSON {
        let (club, snaps) = try developmentRecord(try args.string("club"), context)
        let since = try Self.date(args, "since").map(Output.iso), until = try Self.date(args, "until").map(Output.iso)
        let uid = try args.int("uid", in: 0...Int(UInt32.max)).map(UInt32.init)
        let dates = snaps.map { Output.iso($0.gameDate) }
        var window = snaps.filter { snap in
            let day = Output.iso(snap.gameDate)
            return (since.map { day >= $0 } ?? true) && (until.map { day <= $0 } ?? true)
        }
        // Without since, the club view compares the last 90 days up to the newest record, not the whole record.
        var chosen: String?
        if uid == nil, since == nil, let newest = window.last,
           let cutoff = GameDate.calendar.date(byAdding: .day, value: -Self.developmentDays, to: newest.gameDate) {
            let start = Output.iso(cutoff)
            let recent = window.filter { Output.iso($0.gameDate) >= start }
            if recent.count > 1 {
                chosen = "from is the oldest record in the \(Self.developmentDays) days up to to, as since wasn't given. Give "
                    + "since to compare over longer."
                window = recent
            } else if let before = window.last(where: { Output.iso($0.gameDate) < start }) {
                chosen = "No other record is in the \(Self.developmentDays) days up to to, so from is the latest one before them, "
                    + "as since wasn't given. Give since to compare from further back."
                window = [before] + recent
            }
        }
        let recorded: JSON = .object([("records", .int(snaps.count)), ("dates", .array(dates.map { .string($0) }))])
        let span: String
        switch (since, until) {
        case let (from?, to?): span = "from \(from) to \(to)"
        case let (from?, nil): span = "from \(from)"
        case let (nil, to?): span = "up to \(to)"
        default: span = ""
        }
        guard let first = window.first, let last = window.last else {
            throw ToolError("FM Starship has no record of \(club) \(span). Its records are from \(dates.first ?? "") to \(dates.last ?? "").")
        }

        let visibility = context.visibility
        let hidden = Set(Names.hidden.compactMap { Names.playerIndex[$0] })
        let shown = (0..<min(54, Names.playerAttrs.count)).filter { visibility.showHidden || !hidden.contains($0) }
        func ability(_ value: Int) -> JSON { visibility.reveal == .stars ? .string(Columns.abilityStars(value)) : .int(value) }
        /// The attributes that changed, largest first, as up and down.
        func changes(_ old: DevelopmentStore.Row, _ new: DevelopmentStore.Row) -> (up: JSON?, down: JSON?, net: Int) {
            var moved: [(index: Int, by: Int)] = []
            for index in shown where index < old.attr.count && index < new.attr.count {
                let by = Int(new.attr[index]) - Int(old.attr[index])
                if by != 0 { moved.append((index, by)) }
            }
            moved.sort { abs($0.by) != abs($1.by) ? abs($0.by) > abs($1.by) : $0.index < $1.index }
            func object(_ items: [(index: Int, by: Int)]) -> JSON? {
                items.isEmpty ? nil : .object(items.map { (Names.playerAttrs[$0.index], JSON.int($0.by)) })
            }
            return (object(moved.filter { $0.by > 0 }), object(moved.filter { $0.by < 0 }), moved.reduce(0) { $0 + $1.by })
        }
        func live(_ uid: UInt32) -> Player? { (try? context.person(Int(uid))) as? Player }
        // By the squad he's in now, as `squad` names them, with "On loan" for those out on loan.
        let squad = try args.string("squad")
        if let squad {
            // Refused like squad refuses one, so an unknown name can't read as "nobody developed".
            let atClub = context.db.players.filter { $0.clubFull == club }
            var known = Set(atClub.filter { $0.loanClubFull.isEmpty && !$0.squad.isEmpty }.map(\.squad))
            if atClub.contains(where: { !$0.loanClubFull.isEmpty }) { known.insert("On loan") }
            guard known.contains(where: { $0.caseInsensitiveCompare(squad) == .orderedSame }) else {
                let order = Names.squadOrder + ["On loan"]
                var listed: [String] = []
                for name in order.filter(known.contains) + known.subtracting(order).sorted() where !listed.contains(name) { listed.append(name) }
                throw ToolError("\(club) has no squad called \(squad). Its squads: \(listed.joined(separator: ", ")).")
            }
        }
        func inSquad(_ uid: UInt32) -> Bool {
            guard let squad else { return true }
            guard let player = live(uid) else { return false }
            if squad.caseInsensitiveCompare("On loan") == .orderedSame { return !player.loanClubFull.isEmpty }
            return player.loanClubFull.isEmpty && player.squad.caseInsensitiveCompare(squad) == .orderedSame
        }
        func days(_ from: Date, _ to: Date) -> Int { GameDate.calendar.dateComponents([.day], from: from, to: to).day ?? 0 }

        var pairs: [(String, JSON)] = [("club", .string(club)), ("about", .string(Self.developmentAbout)), ("recorded", recorded)]
        if let today = context.db.gameDate, until == nil, Output.iso(last.gameDate) < Output.iso(today) {
            pairs.append(("newest_record", .string("The newest record is from \(Output.iso(last.gameDate)), \(days(last.gameDate, today)) days "
                + "before the game date, \(Output.iso(today)): FM Starship hasn't read the save since. person gives a player as he is now.")))
        }

        if let uid {
            let his = window.compactMap { snap in snap.players[uid].map { (date: snap.gameDate, row: $0) } }
            guard let oldest = his.first, let newest = his.last else {
                throw ToolError("Nobody with uid \(uid) is in FM Starship's record of \(club)\(span.isEmpty ? "" : " " + span).")
            }
            // The attributes that moved most over these dates, as there's no list of key attributes for a player's position.
            var moves: [(index: Int, range: Int, by: Int)] = []
            for index in shown {
                let values: [Int] = his.compactMap { index < $0.row.attr.count ? Int($0.row.attr[index]) : nil }
                guard let low = values.min(), let high = values.max(), high > low, let start = values.first, let end = values.last else { continue }
                moves.append((index, high - low, end - start))
            }
            moves.sort { a, b in
                if a.range != b.range { return a.range > b.range }
                if abs(a.by) != abs(b.by) { return abs(a.by) > abs(b.by) }
                return a.index < b.index
            }
            let key = moves.prefix(6).map(\.index)
            let titles: [JSON] = ["Date"] + (visibility.showsAbility ? ["CA", "PA"] : []) + key.map { .string(Names.playerAttrs[$0]) }
            let rows: [JSON] = his.map { entry in
                .array([.string(Output.iso(entry.date))] + (visibility.showsAbility ? [ability(entry.row.ca), ability(entry.row.pa)] : [])
                       + key.map { $0 < entry.row.attr.count ? .int(Int(entry.row.attr[$0])) : .null })
            }
            let moved = changes(oldest.row, newest.row)
            var change: [(String, JSON?)] = [("from", .string(Output.iso(oldest.date))), ("to", .string(Output.iso(newest.date)))]
            if visibility.reveal == .exact { change += [("CA", .int(newest.row.ca - oldest.row.ca)), ("PA", .int(newest.row.pa - oldest.row.pa))] }
            change += [("up", moved.up), ("down", moved.down)]
            return .object(pairs + [
                ("player", .object(dropping: [("uid", .int(Int(uid))), ("name", .string(newest.row.name)),
                                              ("age", live(uid).flatMap { $0.age >= 0 ? .int($0.age) : nil })])),
                ("note", "The columns are the attributes that moved most over these dates; change has every one that went up or down."),
                ("columns", .array(titles)), ("rows", .array(rows)), ("change", .object(dropping: change)),
            ])
        }

        guard window.count > 1 else {
            throw ToolError("FM Starship has only one record of \(club)\(span.isEmpty ? "" : " " + span), from \(Output.iso(first.gameDate)), "
                + "so there's nothing to compare it with. Its records are from \(dates.first ?? "") to \(dates.last ?? "").")
        }
        let exact = visibility.reveal == .exact
        var titles: [JSON] = ["uid", "Name", "Age"]
        if visibility.showsAbility { titles += exact ? ["CA from", "CA to", "CA change", "PA", "PA change"] : ["CA from", "CA to", "PA"] }
        titles += ["Up", "Down", "From"]
        var rows: [(row: JSON, order: Int, then: Int, name: String)] = []
        for (uid, new) in last.players where inSquad(uid) {
            // A player who joined after `from` is compared from his first record in the window, and From says when.
            var start = first.players[uid].map { (row: $0, date: Date?.none) }
            if start == nil, let snap = window.first(where: { $0.players[uid] != nil && $0.gameDate < last.gameDate }),
               let row = snap.players[uid] {
                start = (row, snap.gameDate)
            }
            guard let start else { continue }
            let old = start.row
            let moved = changes(old, new)
            var cells: [JSON] = [.int(Int(uid)), .string(new.name), live(uid).flatMap { $0.age >= 0 ? .int($0.age) : nil } ?? .null]
            if visibility.showsAbility {
                cells += [ability(old.ca), ability(new.ca)]
                if exact { cells.append(.int(new.ca - old.ca)) }
                cells.append(ability(new.pa))
                if exact { cells.append(.int(new.pa - old.pa)) }
            }
            cells += [moved.up ?? .null, moved.down ?? .null, start.date.map { .string(Output.iso($0)) } ?? .null]
            // With Ability off the order comes from the attributes in the row, which anyone can see, as the app's screen does.
            rows.append((.array(cells), visibility.showsAbility ? new.ca - old.ca : moved.net, visibility.showsAbility ? new.pa : 0, new.name))
        }
        rows.sort { $0.order != $1.order ? $0.order > $1.order : $0.then != $1.then ? $0.then > $1.then
                                                     : $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        func entry(_ uid: UInt32, _ row: DevelopmentStore.Row, _ key: String, _ date: Date, now: Bool) -> JSON {
            var fields: [(String, JSON?)] = [("uid", .int(Int(uid))), ("name", .string(row.name)), (key, .string(Output.iso(date)))]
            if now {
                let player = live(uid)
                fields.append(("now_at", player.map { .string($0.clubFull.isEmpty ? "no club" : $0.clubFull) }
                                         ?? .string("not in the save, so most likely retired")))
            }
            return .object(dropping: fields)
        }
        let joined: [JSON] = last.players.filter { first.players[$0.key] == nil && inSquad($0.key) }.sorted { $0.value.name < $1.value.name }.compactMap { uid, row in
            window.first { $0.players[uid] != nil }.map { entry(uid, row, "first_recorded", $0.gameDate, now: false) }
        }
        let left: [JSON] = first.players.filter { last.players[$0.key] == nil }.sorted { $0.value.name < $1.value.name }.compactMap { uid, row in
            window.last { $0.players[uid] != nil }.map { snap in entry(uid, snap.players[uid] ?? row, "last_recorded", snap.gameDate, now: true) }
        }
        pairs += [
            ("compared", .object(dropping: [("from", .string(Output.iso(first.gameDate))), ("to", .string(Output.iso(last.gameDate))),
                                            ("game_days", .int(days(first.gameDate, last.gameDate))),
                                            ("why", chosen.map { .string($0) })])),
            ("order", .string(visibility.showsAbility ? "CA gained, most first" : "attributes gained less those lost, most first")),
            ("note", .string("Up and Down have every attribute that went up or down between from and to, by how much, largest first. "
                + "From is empty for a player compared from `from`; for one who joined after it, it's his first record, which he's "
                + "compared from, and he's in joined too.")),
            ("columns", .array(titles)), ("rows", .array(rows.map(\.row))),
        ]
        if let squad { pairs.append(("squad", .string("\(squad): players in that squad now. Left is everyone who left, whatever squad."))) }
        if !joined.isEmpty { pairs.append(("joined", .array(joined))) }
        if !left.isEmpty { pairs.append(("left", .array(left))) }
        return .object(pairs)
    }
}
