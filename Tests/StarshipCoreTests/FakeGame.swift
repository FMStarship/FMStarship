@testable import StarshipCore
import Darwin
import XCTest

/// Made-up game memory for testing the reader without FM. Records are laid out as `MacLayout` says, in memory of the test's
/// own, and read through `GameProcess` the way the plugin reads FM: straight from memory. A stand-in for game_plugin holds
/// just enough RTTI for the reader to find the classes it sweeps for. Every name and number in it is made up.
final class FakeGame {
    /// The classes whose records the reader finds by their vtables.
    static let classes = ["ACTUAL_PLAYER", "ACTUAL_NON_PLAYER", "TEAM"]

    private let image: UnsafeMutableRawPointer
    private let imageSize = 0x1000
    private let heap: UnsafeMutableRawPointer
    private let heapSize: Int
    private var used = 0
    private var vtables: [String: Int64] = [:]
    /// Fields that didn't fit their records. The reader traps on those, as it would inside FM and close it, so `read` won't run.
    fileprivate var fieldsOutside = 0
    private var failures = Set<String>()

    struct FieldsOutsideRecords: Error {}

    /// Each problem once, not once for each of a thousand records.
    fileprivate func fail(_ message: String) {
        if failures.insert(message).inserted { XCTFail(message) }
    }

    init(heapSize: Int = 4 << 20) {
        self.heapSize = heapSize
        image = FakeGame.map(imageSize)
        heap = FakeGame.map(heapSize)
        let base = FakeGame.address(image)
        for (i, name) in FakeGame.classes.enumerated() {
            // Itanium RTTI, as `Rtti` walks it: the word before a vtable's address point points at the type_info, whose
            // second word points at the class's mangled name. The word before that is the offset to the top, here 0.
            let slot = i * 0x100
            let mangled = Array(Rtti.mangled(name)[0].utf8)
            (image + slot + 8).copyMemory(from: mangled, byteCount: mangled.count)
            image.storeBytes(of: base + Int64(slot + 8), toByteOffset: slot + 0x48, as: Int64.self)
            image.storeBytes(of: base + Int64(slot + 0x40), toByteOffset: slot + 0x68, as: Int64.self)
            vtables[name] = base + Int64(slot + 0x70)
        }
        mprotect(image, imageSize, PROT_READ)
    }

    deinit {
        munmap(image, imageSize)
        munmap(heap, heapSize)
    }

    private static func map(_ size: Int) -> UnsafeMutableRawPointer {
        guard let memory = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), memory != MAP_FAILED else {
            fatalError("No memory for a made-up game")
        }
        return memory
    }

    private static func address(_ pointer: UnsafeMutableRawPointer) -> Int64 { Int64(Int(bitPattern: pointer)) }
    private static func pointer(_ address: Int64) -> UnsafeMutableRawPointer { UnsafeMutableRawPointer(bitPattern: Int(address))! }

    /// The game as the plugin sees FM, with the made-up records as all the memory there is to sweep.
    func process() -> GameProcess {
        GameProcess.inside(plugin: (base: FakeGame.address(image), size: Int64(imageSize), path: "/made-up/game_plugin"),
                           regions: [(base: FakeGame.address(heap), size: Int64(heapSize), writable: true)])
    }

    /// Everything the reader makes of the made-up records.
    func read() throws -> Database {
        guard fieldsOutside == 0 else { throw FieldsOutsideRecords() }
        return try GameReader(game: process(), status: { _ in }).readAll()
    }

    /// Zeroed room, as FM's heap would hand it out.
    func allocate(_ size: Int) -> Int64 {
        let start = (used + 15) & ~15
        precondition(start + size <= heapSize, "The made-up game needs a larger heap")
        used = start + size
        return FakeGame.address(heap) + Int64(start)
    }

    private func store<T>(_ value: T, _ address: Int64) {
        FakeGame.pointer(address).storeBytes(of: value, as: T.self)
    }

    /// A record of this size, starting with the vtable of `vtable`'s class if it has one.
    func record(_ kind: String, size: Int, vtable: String? = nil) -> FakeRecord {
        let record = FakeRecord(address: allocate(size), size: size, kind: kind, game: self)
        if let vtable { record.set("vtable", 0, vtables[vtable]!) }
        return record
    }

    /// A byte-for-byte copy of a record somewhere else, as FM's dead second copy of the world holds.
    func copy(_ record: FakeRecord) -> Int64 {
        let at = allocate(record.size)
        FakeGame.pointer(at).copyMemory(from: FakeGame.pointer(record.address), byteCount: record.size)
        return at
    }

    // MARK: Text

    /// FM's string: a 32-bit length, then UTF-8. Nothing for no text.
    func string(_ text: String) -> Int64 {
        guard !text.isEmpty else { return 0 }
        let bytes = Array(text.utf8)
        let at = allocate(4 + bytes.count)
        store(Int32(bytes.count), at)
        (FakeGame.pointer(at) + 4).copyMemory(from: bytes, byteCount: bytes.count)
        return at
    }

    /// An entry in FM's table of first, second and common names, which points at the name.
    func nameEntry(_ text: String) -> Int64 {
        guard !text.isEmpty else { return 0 }
        let at = allocate(8)
        store(string(text), at)
        return at
    }

    // MARK: Places

    func continent(_ name: String) -> Int64 {
        let record = self.record("Continent", size: MacLayout.continentName + 8)
        record.set("name", MacLayout.continentName, string(name))
        return record.address
    }

    /// `area` is the record FM groups nations by. FM Starship only uses it to tell areas apart.
    func nation(_ name: String, code: String, continent: Int64, area: Int64) -> Int64 {
        typealias N = MacLayout.Nation
        let record = self.record("Nation", size: max(N.name, N.code, N.continent, N.area) + 8)
        record.set("name", N.name, string(name))
        record.set("code", N.code, string(code))
        record.set("continent", N.continent, continent)
        record.set("area", N.area, area)
        return record.address
    }

    func competition(_ name: String) -> Int64 {
        let record = self.record("Competition", size: MacLayout.competitionName + 8)
        record.set("name", MacLayout.competitionName, string(name))
        return record.address
    }

    func club(full: String, short: String, nation: Int64, womens: Bool = false) -> Int64 {
        typealias C = MacLayout.Club
        let record = self.record("Club", size: max(C.womens, C.fullName, C.shortName, C.nation) + 8)
        record.set("womens", C.womens, UInt8(womens ? 1 : 0))
        record.set("fullName", C.fullName, string(full))
        record.set("shortName", C.shortName, string(short))
        record.set("nation", C.nation, nation)
        return record.address
    }

    /// One of a club's teams. `type` is FM's number for the squad: 0 the first team, 1 the reserves, 9 the under-23s.
    func team(club: Int64, index: UInt32, type: UInt8, competition: Int64) -> Int64 {
        typealias T = MacLayout.Team
        let record = self.record("Team", size: max(T.index, T.type, T.club, T.competition) + 8, vtable: "TEAM")
        record.set("index", T.index, index)
        record.set("type", T.type, type)
        record.set("club", T.club, club)
        record.set("competition", T.competition, competition)
        return record.address
    }

    // MARK: People

    struct ContractValues {
        var team: Int64 = 0
        var fallbackTeam: Int64 = 0
        var wage: UInt32 = 0
        var job: UInt8 = 0
        var secondJob: UInt8 = 0
        var teamIndex: UInt32 = 0
        var end: (day: UInt16, year: UInt16) = (0, 0)
        var listed: (day: UInt16, year: UInt16) = (0, 0)
        var statusFlags: UInt8 = 0
        /// Each clause's amount, and FM's number for its kind.
        var clauses: [(amount: UInt32, kind: UInt16)] = []
    }

    struct PersonValues {
        var index: UInt32 = 1
        var uid: UInt32 = 1
        var flags: UInt8 = 8
        var woman = false
        var fullName = ""
        var firstName = ""
        var secondName = ""
        /// The reader leaves out people with no name at all.
        var commonName = "Made-up Person"
        var nation: Int64 = 0
        var birth: (day: UInt16, year: UInt16) = (0, 0)
        var personality: [UInt8] = [10, 10, 10, 10, 10, 10, 10, 10]
        /// Nil for a free agent.
        var contract: ContractValues? = ContractValues()
    }

    struct PlayerValues {
        var person = PersonValues()
        var ca: UInt16 = 100
        var pa: Int16 = 120
        var value: UInt32 = 0
        var positions = [UInt8](repeating: 1, count: 15)
        var attributes = [UInt8](repeating: 50, count: 54)
        var height: UInt16 = 180
        var topRoles = [UInt8](repeating: 0, count: 6)
        var traits: UInt64 = 0
        var currentTeam: Int64 = 0
    }

    struct StaffValues {
        var person = PersonValues()
        var ca: UInt16 = 100
        var pa: Int16 = 120
        var reputation: (current: UInt16, home: UInt16, world: UInt16) = (0, 0, 0)
        /// As FM stores them: 1-20, apart from the 14th and the last 26, which are 1-100.
        var attributes = [UInt8](repeating: 10, count: 52)
    }

    @discardableResult
    func player(_ values: PlayerValues) -> FakeRecord {
        typealias L = MacLayout.Player
        let record = self.record("Player", size: L.size, vtable: "ACTUAL_PLAYER")
        let a = L.attributes
        record.set("positions", a + L.positions, bytes: values.positions)
        record.set("attributes", a + L.raw, bytes: values.attributes)
        record.set("height", a + L.height, values.height)
        record.set("value", a + L.value, values.value)
        record.set("ca", a + L.ca, values.ca)
        record.set("pa", a + L.pa, values.pa)
        record.set("topRoles", a + L.topRoles, bytes: values.topRoles)
        record.set("currentTeam", L.currentTeam, values.currentTeam)
        record.set("injuries", L.injuries, Int64(0))
        record.set("traits", L.person + MacLayout.Person.traits, values.traits)
        person(values.person, in: record, person: L.person, identity: L.identity)
        return record
    }

    @discardableResult
    func staff(_ values: StaffValues) -> FakeRecord {
        typealias L = MacLayout.Staff
        let record = self.record("Staff", size: L.size, vtable: "ACTUAL_NON_PLAYER")
        record.set("attributes", L.attributes, bytes: values.attributes)
        record.set("repCurrent", L.repCurrent, values.reputation.current)
        record.set("repHome", L.repHome, values.reputation.home)
        record.set("repWorld", L.repWorld, values.reputation.world)
        record.set("ca", L.ca, values.ca)
        record.set("pa", L.pa, values.pa)
        person(values.person, in: record, person: L.person, identity: L.identity)
        return record
    }

    /// The parts players and staff share: the person subobject at `base`, and the identity subobject.
    private func person(_ values: PersonValues, in record: FakeRecord, person base: Int, identity: Int) {
        typealias P = MacLayout.Person
        typealias I = MacLayout.Identity
        record.set("index", identity + I.index, values.index)
        record.set("uid", identity + I.uid, values.uid)
        record.set("flags", identity + I.flags, values.flags)
        record.set("sex", identity + I.sex, values.woman ? I.woman : 0)
        record.set("fullName", base + P.fullName, string(values.fullName))
        record.set("firstName", base + P.firstName, nameEntry(values.firstName))
        record.set("secondName", base + P.secondName, nameEntry(values.secondName))
        record.set("commonName", base + P.commonName, nameEntry(values.commonName))
        record.set("nation", base + P.nation, values.nation)
        record.set("personality", base + P.personality, bytes: values.personality)
        record.set("birthDay", base + P.birthDay, values.birth.day)
        record.set("birthYear", base + P.birthYear, values.birth.year)
        let contract = values.contract.map { self.contract($0, owner: record.address + Int64(identity)) } ?? 0
        record.set("contract", base + P.contract, contract)
    }

    /// A contract, owned by the person whose identity subobject is at `owner`.
    func contract(_ values: ContractValues, owner: Int64) -> Int64 {
        typealias C = MacLayout.Contract
        let record = self.record("Contract", size: C.size)
        record.set("owner", C.owner, owner)
        record.set("fallbackTeam", C.fallbackTeam, values.fallbackTeam)
        record.set("team", C.team, values.team)
        record.set("wage", C.wage, values.wage)
        record.set("job", C.job, values.job)
        record.set("teamIndex", C.teamIndex, values.teamIndex)
        record.set("endDay", C.endDay, values.end.day)
        record.set("endYear", C.endYear, values.end.year)
        record.set("listedDay", C.listedDay, values.listed.day)
        record.set("listedYear", C.listedYear, values.listed.year)
        record.set("statusFlags", C.statusFlags, values.statusFlags)
        record.set("secondJob", C.secondJob, values.secondJob)
        var begin: Int64 = 0, end: Int64 = 0
        if !values.clauses.isEmpty {
            // Eight bytes each: the amount first, and the kind in the last two.
            begin = allocate(values.clauses.count * 8)
            end = begin + Int64(values.clauses.count * 8)
            for (i, clause) in values.clauses.enumerated() {
                store(clause.amount, begin + Int64(i * 8))
                store(clause.kind, begin + Int64(i * 8 + 6))
            }
        }
        record.set("clausesBegin", C.clausesBegin, begin)
        record.set("clausesEnd", C.clausesEnd, end)
        return record.address
    }
}

/// One made-up record. A field that lands outside the record, or on a field already there, fails the test: an offset in
/// `MacLayout` has moved onto something else, and on a real save the reader would read the wrong thing, or stop FM with it.
final class FakeRecord {
    let address: Int64
    let size: Int
    let kind: String
    private unowned let game: FakeGame
    private var fields: [(range: Range<Int>, name: String)] = []

    fileprivate init(address: Int64, size: Int, kind: String, game: FakeGame) {
        self.address = address
        self.size = size
        self.kind = kind
        self.game = game
    }

    func set<T>(_ name: String, _ offset: Int, _ value: T) {
        withUnsafeBytes(of: value) { set(name, offset, bytes: Array($0)) }
    }

    func set(_ name: String, _ offset: Int, bytes: [UInt8]) {
        let range = offset..<offset + bytes.count
        guard range.lowerBound >= 0, range.upperBound <= size else {
            game.fail("\(kind).\(name) at \(offset) runs outside the \(size)-byte record")
            game.fieldsOutside += 1
            return
        }
        if let other = fields.first(where: { $0.range.overlaps(range) }) {
            game.fail("\(kind).\(name) at \(offset) lands on \(kind).\(other.name) at \(other.range.lowerBound)")
        }
        fields.append((range, name))
        UnsafeMutableRawPointer(bitPattern: Int(address))!.advanced(by: offset).copyMemory(from: bytes, byteCount: bytes.count)
    }
}
