import Foundation

/// Someone a news item points at: a player or member of staff, by the identity FM names people by.
public struct NewsPerson: Equatable {
    public let uid: UInt32
    public let index: UInt32
    public let isPlayer: Bool
    /// As FM's record of the person names them, for one FM Starship doesn't read.
    public let name: String

    public init(uid: UInt32, index: UInt32, isPlayer: Bool, name: String) {
        self.uid = uid
        self.index = index
        self.isPlayer = isPlayer
        self.name = name
    }
}

/// What an item is about, for the kinds whose fields were found on every item of them. Nothing for the others.
public enum NewsSubject: Equatable {
    /// The physio's report: the player, FM's name for the injury in the game's language, its day and its length in days.
    case injury(player: NewsPerson, injury: String, on: Date?, days: Int)
    /// Contracts running out soon, by each person's database index.
    case contractsExpiring(indexes: [UInt32])
    /// A transfer completed: the person and the other club, without which way it went.
    case transfer(person: NewsPerson, club: String)
    /// A player asking for a move to a club.
    case comeAndGetMe(player: NewsPerson, club: String)
}

/// One item in the user's inbox. FM keeps no text for it, only its class and fields.
public struct InboxItem {
    public let serial: UInt32
    public let date: Date
    /// FM's class, such as INJURY_REPORT_NEWS_ITEM.
    public let className: String
    /// The addressed team's database index, nil for news FM copied in from the world's.
    public let team: UInt32?
    /// The person who sent it, nil when it's from no one FM Starship reads.
    public let sender: NewsPerson?
    /// Set when it's from an agent rather than a person.
    public let fromAgent: Bool
    /// The sender's job as the item gives it, from FM's list of jobs.
    public let senderJob: String?
    public let subject: NewsSubject?

    public init(serial: UInt32, date: Date, className: String, team: UInt32?, sender: NewsPerson?, fromAgent: Bool = false,
                senderJob: String?, subject: NewsSubject? = nil) {
        self.serial = serial
        self.date = date
        self.className = className
        self.team = team
        self.sender = sender
        self.fromAgent = fromAgent
        self.senderJob = senderJob
        self.subject = subject
    }

    /// The class in plain words: INJURY_REPORT_NEWS_ITEM is "injury report".
    public var kind: String { InboxReader.kind(className) }
}

/// The user's inbox as FM holds it, oldest first, or why it can't be read.
public enum Inbox {
    case items([InboxItem])
    case failed(String)
}

/// The user's inbox: FM's news items for a human manager, read where FM keeps them, each time it's asked for, as new items
/// come in without the date moving. Pointers read from memory are only added to with &+, so a bad one can't trap.
public final class InboxReader {
    typealias L = MacLayout.Inbox
    private let game: GameProcess
    private let rtti: Rtti
    private var classes: [Int64: String?] = [:]
    /// The most items it reads: FM held 150.
    static let most = 4096

    public init(game: GameProcess, rtti: Rtti) {
        self.game = game
        self.rtti = rtti
    }

    /// The inbox of the human manager whose HUMAN_NON_PLAYER is at `manager`. `teams` are the club's teams by database
    /// index, as `Database.humanTeams` gives them; the items must be addressed to one of them or be world news. Checked as a
    /// whole: serials rise along the list, dates never go back, none is after `today`, and every item reads. Any failure
    /// gives `.failed` with why, never part of the list.
    public func inbox(manager: Int64, teams: [UInt32: Int], today: Date?) -> Inbox {
        guard manager != 0 else { return .failed("FM Starship doesn't know which manager is the user") }
        let vector = game.readPointer(manager &+ L.items)
        guard vector != 0, let head = game.read(vector, count: 24) else { return .failed("FM's inbox list wasn't where FM Starship looks") }
        let begin = Self.i64(head, 0), end = Self.i64(head, 8), capacity = Self.i64(head, 16)
        if begin == 0, end == 0 { return .items([]) }
        guard begin > 0, end >= begin, capacity >= end, (end &- begin) % 8 == 0, (end &- begin) / 8 <= Self.most else {
            return .failed("FM's inbox list doesn't read as a list")
        }
        let count = Int((end &- begin) / 8)
        guard count > 0 else { return .items([]) }
        guard let slots = game.read(begin, count: count * 8) else { return .failed("FM's inbox list couldn't be read") }

        var items: [InboxItem] = []
        for slot in 0..<count {
            let item = Self.i64(slots, slot * 8)
            guard item > 0, item % 8 == 0, let b = game.read(item, count: L.header) else {
                return .failed("item \(slot + 1) of \(count) couldn't be read")
            }
            guard let type = className(Self.i64(b, 0)) else {
                return .failed("item \(slot + 1) of \(count) isn't one of FM's objects")
            }
            let day = Self.u16(b, Int(L.day)) & 0x1ff, year = Self.u16(b, Int(L.year))
            guard let date = GameDate.checked(year: year, dayOfYear: day) else {
                return .failed("item \(slot + 1) of \(count), \(type), has no date")
            }
            let team = Self.u32(b, Int(L.team))
            guard team == L.world || teams[team] != nil else {
                return .failed("item \(slot + 1) of \(count), \(type), is addressed to a team that isn't the user's club's")
            }
            let serial = Self.u32(b, Int(L.serial))
            if let last = items.last {
                guard serial > last.serial else { return .failed("FM's counter doesn't rise along the list at item \(slot + 1)") }
                guard date >= last.date else { return .failed("the dates go back along the list at item \(slot + 1)") }
            }
            if let today, date > today { return .failed("item \(slot + 1) of \(count) is dated after the game date") }

            let from = Self.i64(b, Int(L.sender))
            let sender = person(from)
            let fromAgent = sender == nil && from != 0 && className(game.readPointer(from)) == "AGENT"
            let job = sender == nil ? nil : Names.jobs[Int(b[Int(L.senderJob)])]
            items.append(InboxItem(serial: serial, date: date, className: type, team: team == L.world ? nil : team,
                                   sender: sender, fromAgent: fromAgent, senderJob: job, subject: subject(item, type)))
        }
        return .items(items)
    }

    /// The fields of the classes they were found on, each checked to be what it should be. Nil for any other class, or
    /// when a field isn't.
    private func subject(_ item: Int64, _ type: String) -> NewsSubject? {
        switch type {
        case "INJURY_REPORT_NEWS_ITEM":
            typealias I = L.InjuryReport
            let injury = game.readPointer(item &+ I.injury)
            guard let player = person(game.readPointer(item &+ I.player)), player.isPlayer, injury != 0,
                  className(game.readPointer(injury)) == "INJURY", let b = game.read(item &+ I.injuredOn, count: 0x10) else { return nil }
            let text = game.lengthPrefixedString(game.readPointer(injury &+ MacLayout.Injury.name))
            let days = Int(Self.u16(b, Int(I.days - I.injuredOn)))
            let on = GameDate.checked(year: Self.u16(b, 2), dayOfYear: Self.u16(b, 0) & 0x1ff)
            return .injury(player: player, injury: text.prefix(1).uppercased() + text.dropFirst(), on: on, days: days)
        case "CONTRACT_EXPIRES_SOON_NEWS":
            typealias C = L.ContractsExpiring
            guard let head = game.read(item &+ C.people, count: 16) else { return nil }
            let begin = Self.i64(head, 0), end = Self.i64(head, 8)
            guard begin > 0, end > begin, (end &- begin) % C.size == 0, (end &- begin) / C.size <= 500,
                  let records = game.read(begin, count: Int(end &- begin)) else { return nil }
            var indexes: [UInt32] = []
            for at in stride(from: 0, to: records.count, by: Int(C.size)) {
                // Every record starts with the person's club, so a wrong size is caught at the second record.
                guard className(game.readPointer(Self.i64(records, at + Int(C.club)))) == "CLUB" else { return nil }
                indexes.append(Self.u32(records, at + Int(C.index)))
            }
            return .contractsExpiring(indexes: indexes)
        case "TRANSFER_COMPLETED_NEWS":
            typealias T = L.TransferCompleted
            guard let person = person(game.readPointer(item &+ T.person)), let club = club(game.readPointer(item &+ T.team)) else { return nil }
            return .transfer(person: person, club: club)
        case "PLAYER_COME_AND_GET_ME_PLEA_NEWS_ITEM":
            typealias P = L.ComeAndGetMe
            guard let player = person(game.readPointer(item &+ P.player)), player.isPlayer,
                  let club = club(game.readPointer(item &+ P.team)) else { return nil }
            return .comeAndGetMe(player: player, club: club)
        default:
            return nil
        }
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
    private static func i64(_ b: [UInt8], _ o: Int) -> Int64 { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int64.self) } }

    /// A person by the identity subobject a news item points at, which FM's RTTI names by the whole record's class.
    private func person(_ identity: Int64) -> NewsPerson? {
        guard identity != 0 else { return nil }
        let isPlayer: Bool
        switch className(game.readPointer(identity)) {
        case "ACTUAL_PLAYER": isPlayer = true
        case "ACTUAL_NON_PLAYER", "HUMAN_NON_PLAYER": isPlayer = false
        default: return nil
        }
        guard let id = game.read(identity &+ Int64(MacLayout.Identity.index), count: 8) else { return nil }
        let person = identity &- Int64(MacLayout.Player.identity - MacLayout.Player.person)
        typealias P = MacLayout.Person
        var name = game.nameEntry(game.readPointer(person &+ Int64(P.commonName)))
        if name.isEmpty {
            name = [P.firstName, P.secondName].map { game.nameEntry(game.readPointer(person &+ Int64($0))) }
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        return NewsPerson(uid: Self.u32(id, 4), index: Self.u32(id, 0), isPlayer: isPlayer, name: name)
    }

    /// A team's club's name, when `team` is one of FM's teams.
    private func club(_ team: Int64) -> String? {
        guard team != 0, className(game.readPointer(team)) == "TEAM" else { return nil }
        let name = GameReader.clubName(team: team, in: game)
        return name.isEmpty ? nil : name
    }

    /// The class of the object with this vtable, as written in FM's code: INJURY_REPORT_NEWS_ITEM.
    private func className(_ vtable: Int64) -> String? {
        if let known = classes[vtable] { return known }
        let name = rtti.className(vtable: vtable).map(Self.plain)
        classes[vtable] = name
        return name
    }

    /// A class name as RTTI spells it, "N2db23INJURY_REPORT_NEWS_ITEME" or "4CLUB", without the namespaces.
    static func plain(_ mangled: String) -> String {
        var rest = Substring(mangled)
        if rest.first == "N" { rest = rest.dropFirst() }
        var last = ""
        while let first = rest.first, first.isNumber {
            let digits = rest.prefix(while: \.isNumber)
            guard let length = Int(digits), length > 0 else { break }
            let start = digits.endIndex
            guard rest.distance(from: start, to: rest.endIndex) >= length else { break }
            let stop = rest.index(start, offsetBy: length)
            last = String(rest[start..<stop])
            rest = rest[stop...]
        }
        return last.isEmpty ? mangled : last
    }

    /// FM's class in plain words: INJURY_REPORT_NEWS_ITEM is "injury report", BOARD_CONFIDENCE_UPDATE_NEWS "board
    /// confidence update".
    public static func kind(_ className: String) -> String {
        var name = className
        for suffix in ["_NEWS_ITEM", "_NEWS", "_ITEM"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name.lowercased().replacingOccurrences(of: "_", with: " ")
    }
}
