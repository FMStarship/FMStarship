import Foundation
import CA64
import StarshipAnalysis
import StarshipCore

// Developer probe: checks what the game looks like in memory on this build.
func hex(_ v: Int64) -> String { "0x" + String(v, radix: 16) }
let MacStaffSize = 0x228

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: fmprobe info|rtti NAME...|scan"); exit(2) }
let game = try GameProcess()

switch args[1] {
case "info":
    print("pid \(game.pid)  game_plugin \(hex(game.pluginBase)) size \(game.pluginSize)")
    let total = game.regions.reduce(Int64(0)) { $0 + $1.size }
    let rw = game.regions.filter(\.writable).reduce(Int64(0)) { $0 + $1.size }
    print("regions \(game.regions.count), readable \(total >> 20) MB, writable \(rw >> 20) MB")

case "rtti":
    let rtti = Rtti(game)
    for name in args.dropFirst(2) {
        let tables = rtti.vtables(name)
        print(name, tables.map { "\(hex(Int64($0.addressPoint)))(top \($0.offsetToTop))" }.joined(separator: " "))
    }

case "scan":
    // Starship's Markers.Refind with its Windows offsets, unchanged, to test the layout.
    let low = game.pluginBase, high = game.pluginBase + game.pluginSize
    let lock = NSLock()
    var players: [[Int64]: Int] = [:]
    var staff: [[Int64]: Int] = [:]
    let pieces = game.pieces(size: 1 << 23, overlap: 0x400, writableOnly: true)
    let started = Date()
    DispatchQueue.concurrentPerform(iterations: pieces.count) { i in
        let piece = pieces[i]
        guard let bytes = game.read(piece.address, count: piece.count) else { return }
        var localPlayers: [[Int64]: Int] = [:]
        var localStaff: [[Int64]: Int] = [:]
        bytes.withUnsafeBytes { raw in
            func w(_ o: Int) -> Int64 { raw.loadUnaligned(fromByteOffset: o, as: Int64.self) }
            var o = Int((8 - piece.address % 8) % 8)
            while o + 0x240 <= piece.count {
                let v = w(o)
                if v >= low, v < high {
                    if o + 0x170 <= piece.count {
                        let b = w(o + 0x140), c = w(o + 0x168)
                        if b >= low, b < high, c >= low, c < high, ShapeCheck.player(raw, o) {
                            localPlayers[[v, b, c], default: 0] += 1
                        }
                    }
                    let s = w(o + 0x100)
                    if s >= low, s < high, ShapeCheck.staff(raw, o) {
                        localStaff[[v, s], default: 0] += 1
                    }
                }
                o += 8
            }
        }
        lock.lock()
        players.merge(localPlayers, uniquingKeysWith: +)
        staff.merge(localStaff, uniquingKeysWith: +)
        lock.unlock()
    }
    print(String(format: "scanned %d pieces in %.1fs", pieces.count, Date().timeIntervalSince(started)))
    for (key, n) in players.sorted(by: { $0.value > $1.value }).prefix(6) {
        print("player shape x\(n):", key.map { hex($0 - game.pluginBase) }.joined(separator: " "))
    }
    for (key, n) in staff.sorted(by: { $0.value > $1.value }).prefix(6) {
        print("staff shape x\(n):", key.map { hex($0 - game.pluginBase) }.joined(separator: " "))
    }

case "objects":
    // Where instances of a class live: every aligned heap word equal to one of its vtables.
    let rtti = Rtti(game)
    for name in args.dropFirst(2) {
        let tables = rtti.vtables(name)
        let addresses = Dictionary(uniqueKeysWithValues: tables.map { (game.pluginBase + Int64($0.addressPoint), $0.offsetToTop) })
        let lock = NSLock()
        var hits: [Int64: [Int64]] = [:]
        let pieces = game.pieces(size: 1 << 23, overlap: 0, writableOnly: true)
        DispatchQueue.concurrentPerform(iterations: pieces.count) { i in
            let piece = pieces[i]
            guard let bytes = game.read(piece.address, count: piece.count) else { return }
            var local: [Int64: [Int64]] = [:]
            bytes.withUnsafeBytes { raw in
                let words = raw.bindMemory(to: Int64.self)
                for j in 0..<words.count where addresses[words[j]] != nil {
                    local[words[j], default: []].append(piece.address + Int64(j * 8))
                }
            }
            lock.lock()
            hits.merge(local, uniquingKeysWith: +)
            lock.unlock()
        }
        print(name)
        for table in tables {
            let vt = game.pluginBase + Int64(table.addressPoint)
            let found = (hits[vt] ?? []).sorted()
            print("  vt \(hex(Int64(table.addressPoint))) top \(table.offsetToTop): \(found.count) objects", found.prefix(3).map(hex).joined(separator: " "))
        }
    }

case "people":
    // Decode the first few players of a class with the provisional Mac offsets.
    let rtti = Rtti(game)
    let first = game.pluginBase + Int64(rtti.vtables(args[2])[0].addressPoint)
    let want = args.count > 3 ? Int(args[3])! : 12
    var found: [Int64] = []
    outer: for piece in game.pieces(size: 1 << 23, overlap: 0, writableOnly: true) {
        guard let bytes = game.read(piece.address, count: piece.count) else { continue }
        let hits: [Int64] = bytes.withUnsafeBytes { raw in
            let words = raw.bindMemory(to: Int64.self)
            return (0..<words.count).compactMap { words[$0] == first ? piece.address + Int64($0 * 8) : nil }
        }
        found += hits
        if found.count >= want * 40 { break outer }
    }
    for obj in stride(from: 0, to: found.count, by: max(1, found.count / want)).map({ found[$0] }).prefix(want) {
        let person = obj + 0x278
        let firstName = game.nameEntry(game.readPointer(person + 0x20))
        let second = game.nameEntry(game.readPointer(person + 0x28))
        let common = game.nameEntry(game.readPointer(person + 0x30))
        let w = game.read(obj + 0x390, count: 0x18) ?? []
        let u = w.withUnsafeBytes { $0.bindMemory(to: UInt32.self) }
        print(hex(obj), "\(firstName) \(second) [\(common)]", "idx?", u[0], u[1], u[2], u[3], "tail", String(format: "%08x %08x", u[4], u[5]))
    }

case "index":
    // Who has these database indices, the number FM's own interface refers to people by.
    let db = try GameReader(game: game) { _ in }.readAll()
    let wanted = Set(args.dropFirst(2).compactMap { UInt32($0) })
    for person in (db.players as [Person]) + db.staff where wanted.contains(person.index) {
        print(person.index, person.uid, person.fullName, person.club)
    }

case "read":
    let started = Date()
    let db = try GameReader(game: game) { print("  ", $0) }.readAll()
    print(String(format: "read in %.1fs: %d players, %d staff, %d unnamed, %d currencies", Date().timeIntervalSince(started), db.players.count, db.staff.count, db.unnamed, db.currencies.count))
    print("self-check:", db.checks, "| date", db.gameDate as Any, "| build", db.build)
    print("human clubs:", db.humanClubs.map(\.name), "budgets", db.budgets.values.map { "transfer \($0.transfer) wage room \($0.wageRoom)" })
    print("regions:", Dictionary(grouping: db.players, by: \.area).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(26))
    let mine = db.players.filter { $0.clubFull == (db.humanClubs.first?.name ?? "") }.sorted { $0.ca > $1.ca }
    print("my squad \(mine.count):")
    for p in mine.prefix(12) {
        print(String(format: "  %-22@ age%3d CA%3d PA%3d %@ %@ wage %d val %lld ends %@", p.name as NSString, p.age, p.ca, p.pa, p.bestPositions, p.squad, p.wage, p.value, (p.contractEnd?.formatted(date: .numeric, time: .omitted) ?? "-")))
    }
    let top = db.players.sorted { $0.ca > $1.ca }.prefix(25)
    for p in top {
        print(String(format: "%-26@ CA%3d PA%3d h%3d age%3d wage%8d val%10lld %@ | %@ | %@ | %@ | %@", p.name as NSString, p.ca, p.pa, p.height, p.age, p.wage, p.value, p.nation, p.club, p.league, p.personality, p.squad))
    }
    for s in db.staff.sorted(by: { $0.ca > $1.ca }).prefix(8) {
        print(String(format: "%-26@ CA%3d PA%3d rep %d job %@ | %@ | %@", s.name as NSString, s.ca, s.pa, s.repWorld, s.job, s.club, s.personality))
    }

case "uids":
    let db = try GameReader(game: game) { _ in }.readAll()
    for name in args.dropFirst(2) {
        for p in db.players where p.name == name {
            print(p.name, "index", p.index, "uid", p.uid, "flags", p.flags, String(format: "obj %llx", p.block), "traits", p.traits, "| best", p.bestPositions, "|", p.bestRoleIp, "/", p.bestRoleOop, "| end", p.contractEnd as Any)
        }
    }
    print("injured:", db.players.filter { $0.injuries != nil }.count, "with clause:", db.players.filter { $0.releaseClause > 0 }.count, "listed:", db.players.filter { $0.transferListed }.count)
    for p in db.players.filter({ $0.injuries != nil }).prefix(6) {
        print(" ", p.name, p.club, p.injuries!.map { "\($0.name) \($0.date) len \($0.length)" })
    }
    print("squads:", Dictionary(grouping: db.players, by: \.squad).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(14))
    print("loans:", db.players.filter { !$0.loanClub.isEmpty }.count, db.players.filter { !$0.loanClub.isEmpty }.prefix(3).map { "\($0.name) \($0.club)->\($0.loanClub)" })
    print("currencies:", db.currencies.prefix(6).map { "\($0.name) \($0.symbol) \($0.rate)" })
    print("regions:", Dictionary(grouping: db.players, by: \.area).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(10))

case "dates":
    // Plausible game dates inside a class instance.
    let rtti = Rtti(game)
    let vt = game.pluginBase + Int64(rtti.vtables(args[2])[0].addressPoint)
    let span = args.count > 3 ? Int(args[3])! : 0x4000
    for piece in game.pieces(size: 1 << 23, overlap: 0, writableOnly: true) {
        guard let bytes = game.read(piece.address, count: piece.count) else { continue }
        let hits: [Int64] = bytes.withUnsafeBytes { raw in
            let words = raw.bindMemory(to: Int64.self)
            return (0..<words.count).compactMap { words[$0] == vt ? piece.address + Int64($0 * 8) : nil }
        }
        for at in hits {
            guard let o = game.read(at, count: span) else { continue }
            var counts: [String: [Int]] = [:]
            for i in stride(from: 0, to: span - 4, by: 2) {
                let day = Int(o[i]) | Int(o[i + 1]) << 8, year = Int(o[i + 2]) | Int(o[i + 3]) << 8
                if (2024...2040).contains(year), (1...366).contains(day) { counts["\(year)/\(day)", default: []].append(i) }
            }
            print(hex(at), counts.sorted { $0.key < $1.key }.prefix(30).map { "\($0.key)@\($0.value.prefix(4).map { String($0, radix: 16) })" }.joined(separator: " "))
        }
    }

case "nations":
    let rtti = Rtti(game)
    let vt = game.pluginBase + Int64(rtti.vtables("NATION")[0].addressPoint)
    var rows: [String] = []
    for piece in game.pieces(size: 1 << 23, overlap: 0, writableOnly: true) {
        guard let bytes = game.read(piece.address, count: piece.count) else { continue }
        let hits: [Int64] = bytes.withUnsafeBytes { raw in
            let words = raw.bindMemory(to: Int64.self)
            return (0..<words.count).compactMap { words[$0] == vt ? piece.address + Int64($0 * 8) : nil }
        }
        for at in hits {
            let s = [0x18, 0x20, 0x28, 0x30].map { game.lengthPrefixedString(game.readPointer(at + $0)) }
            let continent = game.lengthPrefixedString(game.readPointer(game.readPointer(at + 0xf8) + 24))
            rows.append("\(s) cont=\(continent) area=\(hex(game.readPointer(at + 0x100)))")
        }
    }
    print(rows.prefix(14).joined(separator: "\n"))

case "humans":
    let rtti = Rtti(game)
    func objs(_ name: String) -> [Int64] {
        let vt = game.pluginBase + Int64(rtti.vtables(name)[0].addressPoint)
        var r: [Int64] = []
        for piece in game.pieces(size: 1 << 23, overlap: 0, writableOnly: true) {
            guard let bytes = game.read(piece.address, count: piece.count) else { continue }
            r += bytes.withUnsafeBytes { raw -> [Int64] in
                let words = raw.bindMemory(to: Int64.self)
                return (0..<words.count).compactMap { words[$0] == vt ? piece.address + Int64($0 * 8) : nil }
            }
        }
        return r
    }
    for h in objs("CLUB_HUMAN_MANAGER_DETAILS") {
        let team = game.readPointer(h + 64), club = team == 0 ? 0 : game.readPointer(team + 48)
        print("details", hex(h), "team", hex(team), "club", hex(club), club == 0 ? "" : game.lengthPrefixedString(game.readPointer(club + 192)))
    }
    for m in objs("HUMAN_NON_PLAYER") {
        let names = [0x10, 0x20, 0x28, 0x30].map { game.readPointer(m + 0xf8 + 0x10 + 0) + Int64($0) * 0 }
        print("human obj", hex(m), hex(names[0]))
    }

case "vtable":
    // The function pointers of a class's primary vtable, as image offsets.
    let rtti = Rtti(game)
    for name in args.dropFirst(2) {
        for table in rtti.vtables(name) {
            var slots: [String] = []
            var slot = table.addressPoint
            while slots.count < 160 {
                let value = rtti.word(slot) - game.pluginBase
                if value <= 0 || value >= game.pluginSize { if slots.count > 3 { break } }
                slots.append("\(slots.count):\(hex(value))")
                slot += 8
            }
            print(name, "vt", hex(Int64(table.addressPoint)), "top", table.offsetToTop, "n=\(slots.count)")
            print(" ", slots.joined(separator: " "))
        }
    }

case "interest":
    let rtti = Rtti(game)
    let sandbox = try Sandbox(game: game)
    let db = try GameReader(game: game) { _ in }.readAll()
    func object(_ name: String) -> Int64 {
        let vt = game.pluginBase + Int64(rtti.vtables(name)[0].addressPoint)
        for piece in game.pieces(size: 1 << 23, overlap: 0, writableOnly: true) {
            guard let bytes = game.read(piece.address, count: piece.count) else { continue }
            let hit: Int64? = bytes.withUnsafeBytes { raw in
                let words = raw.bindMemory(to: Int64.self)
                return (0..<words.count).first { words[$0] == vt }.map { piece.address + Int64($0 * 8) }
            }
            if let hit { return hit }
        }
        return 0
    }
    let manager = object("GAME_ACTUAL_PLAYER")
    let function = rtti.word(rtti.vtables("GAME_ACTUAL_PLAYER")[0].addressPoint + 30 * 8)
    let team = db.humanClubs[0].team
    let club = game.readPointer(team + 48)
    print("manager", hex(manager), "fn", hex(function - game.pluginBase), "team", hex(team), "club", hex(club), db.humanClubs[0].name)
    for name in args.dropFirst(2) {
        guard let p = db.players.first(where: { $0.name == name }) else { print(name, "not found"); continue }
        for (label, type) in [("transfer", 4), ("loan", 3)] {
            let started = Date()
            do {
                let score: Int32 = try sandbox.call(function, [UInt64(manager), UInt64(p.block), UInt64(club), UInt64(type), 0, 0, 0, 0]) { Int32(truncatingIfNeeded: a64_get_x($0, 0)) }
                print(String(format: "%@ %@ score=%d (%.1f ms) pages=%d", name, label, score, Date().timeIntervalSince(started) * 1000, sandbox.cachedPages))
            } catch { print(name, label, error) }
        }
    }

case "interestall":
    let rtti = Rtti(game)
    let sandbox = try Sandbox(game: game)
    let db = try GameReader(game: game) { _ in }.readAll()
    let manager = game.readPointer(game.pluginBase + 0x56d2d08)
    let function = rtti.word(rtti.vtables("GAME_ACTUAL_PLAYER")[0].addressPoint + 30 * 8)
    let status = game.pluginBase + 0xd4f9cc
    let team = db.humanClubs[0].team
    let club = game.readPointer(team + 48)
    print("manager", hex(manager), "vptr", hex(game.readPointer(manager) - game.pluginBase))
    let players = db.players
    var scores = [Int32](repeating: 0, count: players.count)
    var statuses = [Int32](repeating: 0, count: players.count)
    let lock = NSLock()
    var failures: [String: Int] = [:]
    let started = Date()
    scores.withUnsafeMutableBufferPointer { out in
    statuses.withUnsafeMutableBufferPointer { sout in
        nonisolated(unsafe) let slots = out
        nonisolated(unsafe) let sslots = sout
        DispatchQueue.concurrentPerform(iterations: players.count) { i in
            let p = UInt64(players[i].block)
            do {
                let s: UInt64 = try sandbox.call(status, [p, UInt64(team), 0, 0, 0, 0, 1, 0], stack: [0]) { a64_get_x($0, 0) & 255 }
                sslots[i] = Int32(s)
                slots[i] = try sandbox.call(function, [UInt64(manager), p, UInt64(club), 4, s, 0, 0, 0]) { Int32(truncatingIfNeeded: a64_get_x($0, 0)) }
            } catch {
                lock.lock(); failures["\(error)", default: 0] += 1; lock.unlock()
                slots[i] = Int32.min
            }
        }
    }}
    let t = Date().timeIntervalSince(started)
    let join = scores.filter { $0 >= 10000 }.count
    print(String(format: "%d players in %.1fs (%.2f ms each), pages %d: %d would join, %d failed", players.count, t, t * 1000 / Double(players.count), sandbox.cachedPages, join, failures.values.reduce(0, +)))
    for (k, v) in failures.sorted(by: { $0.value > $1.value }).prefix(12) { print("  x\(v): \(k)") }
    var dist: [Int32: Int] = [:]
    for s in statuses { dist[s, default: 0] += 1 }
    print("status values:", dist.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
    print("mine:", zip(players, zip(scores, statuses)).filter { $0.0.clubFull == db.humanClubs[0].name }.prefix(5).map { "\($0.0.name) \($0.1.0)/\($0.1.1)" })
    let best = zip(players, scores).filter { $0.1 >= 10000 && $0.0.clubFull != db.humanClubs[0].name }.sorted { $0.0.ca > $1.0.ca }.prefix(14)
    for (p, s) in best { print(String(format: "  %-24@ CA%3d age%3d %-14@ %@ %d", p.name as NSString, p.ca, p.age, p.bestPositions as NSString, p.club, s)) }

case "staffint":
    let rtti = Rtti(game)
    let db = try GameReader(game: game) { _ in }.readAll()
    guard let engine = RulesEngine(game: game, rtti: rtti) else { print("no engine"); exit(1) }
    let human = db.humanClubs[0]
    print("human", human.name, "manager", hex(human.manager))
    engine.managers[human.team] = human.manager
    let started = Date()
    var yes = [0, 0, 0], unknown = 0
    var samples: [String] = []
    let staff = db.staff
    for s in staff {
        for (i, level) in RulesEngine.staffLevels.enumerated() {
            guard let r = engine.staffInterest(staff: s, team: human.team, level: level) else { unknown += 1; continue }
            if r { yes[i] += 1; if i == 0, s.ca > 130, samples.count < 12 { samples.append("\(s.name) CA\(s.ca) \(s.job) \(s.club)") } }
        }
    }
    print(String(format: "%d staff in %.1fs yes=%@ unknown=%d", staff.count, Date().timeIntervalSince(started), "\(yes)", unknown))
    print(samples.joined(separator: " | "))
    print("last failure:", engine.lastFailure ?? "none")
    for s in staff.filter({ $0.clubFull == human.name }).prefix(4) { print(s.name, s.job, RulesEngine.staffLevels.map { engine.staffInterest(staff: s, team: human.team, level: $0) as Any }) }
    if let p = staff.first(where: { $0.name == "Pep Guardiola" }) { print(p.name, RulesEngine.staffLevels.map { engine.staffInterest(staff: p, team: human.team, level: $0) as Any }) }

case "statsprobe":
    let rtti = Rtti(game)
    let sandbox = try Sandbox(game: game)
    let db = try GameReader(game: game) { _ in }.readAll()
    func className(_ object: Int64) -> String {
        let vt = game.readPointer(object)
        guard vt > game.pluginBase, vt < game.pluginBase + game.pluginSize else { return "-" }
        let info = game.readPointer(vt - 8) & 0x7fff_ffff_ffff
        guard info > game.pluginBase, info < game.pluginBase + game.pluginSize else { return "?" }
        let namePointer = game.readPointer(info + 8) & 0x7fff_ffff_ffff
        guard let bytes = game.read(namePointer, count: 90) else { return "?" }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    guard let p = db.players.first(where: { $0.name == "Emil Breivik" }) else { exit(1) }
    let tables = rtti.vtables(args[2])
    print(args[2], tables.map { "\(hex(Int64($0.addressPoint)))/\($0.offsetToTop)" })
    guard let table = tables.first(where: { $0.offsetToTop == 0 }) else { exit(1) }
    let vt = game.pluginBase + Int64(table.addressPoint)
    var manager: Int64 = 0
    for piece in game.pieces(size: 1 << 23, overlap: 0, writableOnly: true) where manager == 0 {
        guard let bytes = game.read(piece.address, count: piece.count) else { continue }
        manager = bytes.withUnsafeBytes { raw -> Int64 in
            let words = raw.bindMemory(to: Int64.self)
            return (0..<words.count).first { words[$0] == vt }.map { piece.address + Int64($0 * 8) } ?? 0
        }
    }
    print("instance", hex(manager))
    guard manager != 0 else { exit(1) }
    for slot in 0..<(args.count > 3 ? Int(args[3])! : 90) {
        let fn = rtti.word(table.addressPoint + slot * 8)
        guard fn > game.pluginBase, fn < game.pluginBase + game.pluginSize else { break }
        for flag in [UInt64(1), 0] {
            do {
                let r: UInt64 = try sandbox.call(fn, [UInt64(manager), UInt64(p.block), flag, 0], maxSteps: 3_000_000) { a64_get_x($0, 0) }
                if r > 0x1000000, r != UInt64(manager), r != UInt64(p.block) {
                    let at = Int64(truncatingIfNeeded: r)
                    print("slot \(slot) \(hex(fn - game.pluginBase)) flag \(flag) -> \(hex(at)) \(className(at))")
                }
            } catch {}
        }
    }

case "statobj":
    let rtti = Rtti(game)
    let sandbox = try Sandbox(game: game)
    let db = try GameReader(game: game) { _ in }.readAll()
    let manager = game.readPointer(game.pluginBase + 0x56d2d08)
    let table = rtti.vtables("GAME_ACTUAL_PLAYER")[0].addressPoint
    let fn = rtti.word(table + 64 * 8)
    print("manager", hex(manager), "fn", hex(fn - game.pluginBase))
    for name in args.dropFirst(2) {
        guard let p = db.players.first(where: { $0.name == name }) else { continue }
        let r: UInt64 = try sandbox.call(fn, [UInt64(manager), UInt64(p.block), 1, 0], maxSteps: 3_000_000) { a64_get_x($0, 0) }
        print(name, hex(p.block), "->", hex(Int64(truncatingIfNeeded: r)))
        if let bytes = game.read(Int64(truncatingIfNeeded: r), count: 96) {
            for row in stride(from: 0, to: 96, by: 16) { print(String(format: "%04x ", row) + bytes[row..<row + 16].map { String(format: "%02x", $0) }.joined(separator: " ")) }
        }
    }

case "season":
    let rtti = Rtti(game)
    let db = try GameReader(game: game) { _ in }.readAll()
    guard let engine = RulesEngine(game: game, rtti: rtti) else { exit(1) }
    for name in args.dropFirst(2) {
        guard let p = db.players.first(where: { $0.name == name }) else { print(name, "?"); continue }
        print(name, "form:", engine.form(player: p) ?? "nil", "injury:", p.injuryText, p.injuryDays)
        if let s = engine.seasonStats(player: p, season: 5) {
            print(String(format: "%-20@ apps %d (%d+%d) min %d gls %d ast %d rat %.2f pom %d yel %d red %d xG %.2f xA %.2f pass%% %d", name as NSString, s.apps, s.starts, s.subs, s.minutes, s.goals, s.assists, s.rating, s.playerOfTheMatch, s.yellow, s.red, s.xG, s.xA, s.passPercent))
        } else { print(name, "nil", engine.lastFailure ?? "") }
    }
    let started = Date()
    let mine = db.players.filter { $0.ca > 100 }
    var got = 0
    for p in mine.prefix(2000) { if let s = engine.seasonStats(player: p, season: 5), s.apps > 0 { got += 1 } }
    print(String(format: "%d of first 2000 have stats, %.2fs, last failure %@", got, Date().timeIntervalSince(started), engine.lastFailure ?? "none"))

case "jobprefs":
    let db = try GameReader(game: game) { _ in }.readAll()
    var hits: [Int: Int] = [:]
    let sample = db.staff.filter { !$0.job.isEmpty }.prefix(300)
    for s in sample {
        guard let b = game.read(s.block, count: MacStaffSize) else { continue }
        b.withUnsafeBytes { raw in
            for o in stride(from: 0, to: MacStaffSize - 8, by: 8) {
                let v = raw.loadUnaligned(fromByteOffset: o, as: Int64.self)
                guard v > 0x1000000, v < 0x7fff_ffff_ffff, let t = game.read(v, count: 15) else { continue }
                if t.allSatisfy({ $0 <= 20 }), t.contains(where: { $0 > 0 }), Set(t).count >= 3 { hits[o, default: 0] += 1 }
            }
        }
    }
    print("offsets holding a 15-byte block of values 0...20:", hits.sorted { $0.value > $1.value }.prefix(8).map { (String($0.key, radix: 16), $0.value) })
    for s in sample.prefix(6) {
        for (o, _) in hits.sorted(by: { $0.value > $1.value }).prefix(2) {
            let p = game.readPointer(s.block + Int64(o))
            print(s.name, s.job, String(o, radix: 16), game.read(p, count: 15)?.map(String.init).joined(separator: " ") ?? "-")
        }
    }

case "limits":
    let rtti = Rtti(game)
    let sandbox = try Sandbox(game: game)
    let db = try GameReader(game: game) { _ in }.readAll()
    let team = db.humanClubs[0].team, club = game.readPointer(team + 48)
    for name in ["GAME_STAFF_NUMBERS", "EXTERN_STAFF_NUMBERS", "STAFF_NUMBERS"] {
        let tables = rtti.vtables(name)
        print(name, tables.map { hex(Int64($0.addressPoint)) + "/\($0.offsetToTop)" })
    }
    guard let table = rtti.vtables("GAME_STAFF_NUMBERS").first(where: { $0.offsetToTop == 0 }) else { exit(1) }
    let vt = game.pluginBase + Int64(table.addressPoint)
    var object: Int64 = 0
    for piece in game.pieces(size: 1 << 23, overlap: 0, writableOnly: true) where object == 0 {
        guard let bytes = game.read(piece.address, count: piece.count) else { continue }
        object = bytes.withUnsafeBytes { raw -> Int64 in
            let words = raw.bindMemory(to: Int64.self)
            return (0..<words.count).first { words[$0] == vt }.map { piece.address + Int64($0 * 8) } ?? 0
        }
    }
    print("object", hex(object), "club", hex(club))
    let out = UInt64(A64_SCRATCH)
    for slot in 2..<12 {
        let fn = rtti.word(table.addressPoint + slot * 8)
        for mode in [UInt64(0), 3] {
            do {
                let bytes: [UInt8] = try sandbox.call(fn, [UInt64(object), UInt64(club), mode], prepare: { a64_set_x($0, 8, out) }) { cpu in
                    var b = [UInt8](repeating: 0, count: 24)
                    a64_read_bytes(cpu, out, &b, 24)
                    return b
                }
                print("slot \(slot) \(hex(fn - game.pluginBase)) mode \(mode):", bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
            } catch { print("slot \(slot) mode \(mode): \(error)") }
        }
    }

case "fingerprint":
    let started = Date()
    print(GameBuild.fingerprint(pluginPath: game.pluginPath) ?? "none", String(format: "%.2fs", Date().timeIntervalSince(started)))
    print("engine", RulesEngine(game: game, rtti: Rtti(game)) != nil ? "starts" : "refused")

case "loansin":
    // The planner matches a loan's club to the user's by name, so the two have to be spelled alike.
    let db = try GameReader(game: game) { _ in }.readAll()
    let clubs = Set(db.players.map(\.clubFull))
    let loans = db.players.filter { !$0.loanClubFull.isEmpty }
    print("on loan", loans.count, "at a club known by that name", loans.filter { clubs.contains($0.loanClubFull) }.count)
    let objects = Set(db.players.map(\.clubObject))
    print("at a club known by that object", loans.filter { objects.contains($0.loanClubObject) }.count)
    let strangers = Dictionary(grouping: loans.filter { !clubs.contains($0.loanClubFull) }, by: \.loanClubFull)
    print("named differently:", strangers.sorted { $0.value.count > $1.value.count }.prefix(14).map { "\($0.key) x\($0.value.count)" })
    for sample in loans.filter({ !clubs.contains($0.loanClubFull) }).prefix(4) {
        print("  ", sample.name, "| club", sample.clubFull, "| short", sample.loanClub, "| full", sample.loanClubFull, "| object", sample.loanClubObject, objects.contains(sample.loanClubObject))
    }
    for human in db.humanClubs {
        let object = db.players.first { $0.clubFull == human.name }?.clubObject
        print("human club", human.name, "object", object ?? 0, "spellings", Set(loans.filter { $0.loanClubObject == object }.map(\.loanClubFull)))
        for player in loans where player.loanClubObject == object || player.loanClubFull == human.name {
            print(player.name, "from", player.club, "CA", player.ca, "shown as", player.loanClubFull)
        }
        // FM keeps a club's own B team as a club of its own, so a player sent there reads as a loan.
        let mine = db.players.filter { $0.clubFull == human.name }
        print("at the club", mine.count, "by squad", Dictionary(grouping: mine, by: { $0.loanClub.isEmpty ? $0.squad : "out: " + $0.loanClubFull }).mapValues(\.count).sorted { $0.value > $1.value })
    }

case "loanend":
    // How many loans the reader found an end date for, when they end, and which clubs look like B teams.
    let db = try GameReader(game: game) { _ in }.readAll()
    let today = db.gameDate ?? Date()
    let loans = db.players.filter { !$0.loanClubFull.isEmpty }
    let dated = loans.filter { $0.loanEnd != nil }
    print("game date", today, "loans", loans.count, "dated", dated.count, "already over", dated.filter { $0.loanEnd! < today }.count)
    print("after the contract", dated.filter { player in player.contractEnd.map { player.loanEnd! > $0 } ?? false }.count)
    print("by month", Dictionary(grouping: dated) { String(format: "%04d-%02d", GameDate.calendar.component(.year, from: $0.loanEnd!), GameDate.calendar.component(.month, from: $0.loanEnd!)) }.mapValues(\.count).sorted { $0.key < $1.key })
    let undated = loans.filter { $0.loanEnd == nil && !$0.isAtOwnBTeam }
    print("no date, not a B team", undated.count)
    for player in undated.prefix(12) { print("  no date:", player.name, "|", player.clubFull, "->", player.loanClubFull) }
    print("B teams", loans.filter(\.isAtOwnBTeam).count)
    let sides = loans.filter { $0.loanClubFull.hasPrefix($0.clubFull + " ") || $0.loanClub.hasPrefix($0.club + " ") }
    print("named after the parent", sides.count, Dictionary(grouping: sides) { $0.loanClubFull.hasPrefix($0.clubFull + " ") ? String($0.loanClubFull.dropFirst($0.clubFull.count + 1)) : String($0.loanClub.dropFirst($0.club.count + 1)) }.mapValues(\.count).sorted { $0.value > $1.value }.prefix(30))
    let clubs = Set(db.players.map(\.clubFull))
    let rest = loans.filter { player in !clubs.contains(player.loanClubFull) && !player.isAtOwnBTeam }
    print("left over", rest.count, Dictionary(grouping: rest) { "\($0.clubFull) -> \($0.loanClubFull)" }.mapValues(\.count).sorted { $0.value > $1.value }.prefix(40).map { "\($0.key) x\($0.value)" })

case "dupes":
    let db = try GameReader(game: game) { _ in }.readAll()
    print("players", db.players.count, "staff", db.staff.count, "date", db.gameDate as Any)
    var regions: [Int64: (Int, Int)] = [:]
    for p in db.players { regions[p.block >> 32, default: (0, 0)].0 += 1 }
    for p in db.staff { regions[p.block >> 32, default: (0, 0)].1 += 1 }
    print("by address high bits:", regions.sorted { $0.key < $1.key }.map { "\(String($0.key, radix: 16)):\($0.value.0)/\($0.value.1)" }.joined(separator: " "))
    let byUid = Dictionary(grouping: db.players, by: \.uid)
    let doubled = byUid.filter { $0.value.count > 1 }
    print("distinct uids", byUid.count, "with copies", doubled.count)
    for (_, copies) in doubled.prefix(4) {
        print(copies.map { "\($0.name) \(hex($0.block)) ca\($0.ca) idx\($0.index) \($0.club) \($0.wage)" })
    }
    print("Breivik:", db.players.filter { $0.name == "Emil Breivik" }.map { "\(hex($0.block)) \($0.club) ca\($0.ca)" })
    print("manager global", hex(game.readPointer(game.pluginBase + 0x56d2d08)))
    var ownerMatch: [String: [Int]] = ["7d": [0, 0], "70": [0, 0]]
    for p in db.players {
        let contract = game.readPointer(p.block + 0x278 + 0x78)
        let owner = contract == 0 ? 0 : game.readPointer(contract + 8)
        let key = p.block >> 32 == 0x7d ? "7d" : "70"
        ownerMatch[key]![owner == p.block + 0x388 ? 0 : 1] += 1
    }
    print("contract owner == self (yes/no):", ownerMatch)
    for (_, copies) in doubled.prefix(2) {
        for p in copies {
            let contract = game.readPointer(p.block + 0x278 + 0x78)
            print(hex(p.block), "contract", hex(contract), "owner", hex(contract == 0 ? 0 : game.readPointer(contract + 8)), "identity", hex(p.block + 0x388))
        }
    }

case "form":
    let db = try GameReader(game: game) { _ in }.readAll()
    guard let p = db.players.first(where: { $0.name == args[2] }) else { exit(1) }
    for slot in stride(from: 0x90, to: 0x140, by: 8) {
        let v1 = game.readPointer(p.block + Int64(slot))
        guard v1 > 0x100000 else { continue }
        for inner in stride(from: 0, to: 0x100, by: 8) {
            let v2 = game.readPointer(v1 + Int64(inner))
            guard v2 > 0x100000 else { continue }
            let begin = game.readPointer(v2), end = game.readPointer(v2 + 8)
            guard begin > 0x100000, end > begin, end - begin < 0x400, (end - begin) % 8 == 0 else { continue }
            let first = game.readPointer(begin)
            guard first > 0x100000, let count = game.read(first + 16, count: 1)?.first, count > 0, count < 40 else { continue }
            let entry = game.readPointer(first + 24)
            guard entry > 0x100000, let e = game.read(entry, count: 24) else { continue }
            let day = (Int(e[16]) | Int(e[17]) << 8) & 0x1ff, year = Int(e[18]) | Int(e[19]) << 8
            print("slot", String(slot, radix: 16), "inner", String(inner, radix: 16), "n", (end - begin) / 8, "count", count, "date", year, day)
        }
    }

case "roletry":
    let sandbox = try Sandbox(game: game)
    let db = try GameReader(game: game) { _ in }.readAll()
    let fnRVA = Int64(args[2].replacingOccurrences(of: "0x", with: ""), radix: 16)!
    let fn = game.pluginBase + fnRVA
    let viewer = db.staff.first { $0.clubFull == db.humanClubs[0].name && $0.job.contains("Coach") }!
    print("viewer", viewer.name, viewer.job)
    for name in args.dropFirst(3) {
        guard let p = db.players.first(where: { $0.name == name }) else { continue }
        let posIndex = (0..<15).max { p.pos[$0] < p.pos[$1] }!
        let gamePos = Names.posToGame[posIndex]
        print(name, "pos", Names.positions[posIndex], "game", gamePos, "best roles", p.bestRoleIp, "| top", p.topRoles)
        var out: [String] = []
        for role in 0..<40 {
            do {
                let r: Int32 = try sandbox.call(fn, [UInt64(p.block), 1 << UInt64(gamePos), 1 << UInt64(role), 0, 0, 2, UInt64(viewer.block + 0x208), 0], stack: [1, 0], maxSteps: 3_000_000) { Int32(truncatingIfNeeded: a64_get_x($0, 0)) }
                out.append("\(role):\(r)")
            } catch { out.append("\(role):ERR"); if role == 0 { print(error) } }
        }
        print(out.joined(separator: " "))
    }

case "hunt":
    // Runs every function in the game through the sandbox and keeps those that reproduce an answer the
    // game has already stored. Crashes and wild jumps only ever stop one emulated call.
    let sandbox = try Sandbox(game: game)
    let db = try GameReader(game: game) { _ in }.readAll()
    let starts = try String(contentsOfFile: args[3], encoding: .utf8).split(separator: "\n").compactMap { Int64($0.dropFirst(2), radix: 16) }
    let club = db.humanClubs[0].name
    let viewer = (db.staff.first { $0.clubFull == club && $0.job == "Assistant Manager" }
        ?? db.staff.filter { $0.clubFull == club }.max { $0.a("Judging Player Ability") < $1.a("Judging Player Ability") })!
    let testers = db.players.filter { $0.clubFull == club && $0.ca > 110 && Set($0.topRoles).count == 6 }.prefix(8).map { $0 }
    print("viewer", viewer.name, viewer.job, "testers", testers.map { "\($0.name) \($0.topRoles)" })
    let outOfPossession = args[2] == "oop"
    let offset = outOfPossession ? 3 : 0
    func rate(_ fn: Int64, _ p: Player, _ role: Int) -> Int32? {
        let index = (0..<15).max { p.pos[$0] < p.pos[$1] }!
        let pos = UInt64(1) << UInt64(Names.posToGame[index]), mask = UInt64(1) << UInt64(role)
        let registers: [UInt64] = outOfPossession
            ? [UInt64(p.block), pos, mask, 2, UInt64(viewer.block), 0, 1, 0]
            : [UInt64(p.block), pos, mask, 0, 0, 2, UInt64(viewer.block), 0]
        return try? sandbox.call(fn, registers, stack: outOfPossession ? [] : [1, 0], maxSteps: 1_500_000) { Int32(truncatingIfNeeded: a64_get_x($0, 0)) }
    }
    // Strict test: the game's stored best role must beat every other role, for each tester in turn.
    func ranksCorrectly(_ fn: Int64, _ p: Player) -> Bool {
        let top = p.topRoles[offset..<(offset + 3)].map(Int.init)
        guard let best = rate(fn, p, top[0]), best > 0, let second = rate(fn, p, top[1]), let third = rate(fn, p, top[2]),
              best >= second, second >= third, third > 0 else { return false }
        var values = Set<Int32>()
        for role in 0..<64 where !top.contains(role) {
            guard let value = rate(fn, p, role) else { continue }
            if value > best { return false }
            values.insert(value)
        }
        return values.count >= 3
    }
    let lock = NSLock()
    var hits: [(Int64, Int)] = []
    var done = 0
    let started = Date()
    let first = testers[0]
    let a = Int(first.topRoles[offset]), b = Int(first.topRoles[offset + 2])
    DispatchQueue.concurrentPerform(iterations: starts.count) { i in
        let fn = game.pluginBase + starts[i]
        if let ra = rate(fn, first, a), ra > 0, ra < 2_000_000, let rb = rate(fn, first, b), ra >= rb, rb > 0, ranksCorrectly(fn, first) {
            let good = testers.filter { ranksCorrectly(fn, $0) }.count
            lock.lock(); print("CANDIDATE", hex(starts[i]), "\(good)/\(testers.count)"); fflush(stdout)
            if good >= testers.count - 2 { hits.append((starts[i], good)) }
            lock.unlock()
        }
        lock.lock(); done += 1
        if done % 20000 == 0 { print("...", done, String(format: "%.0fs", Date().timeIntervalSince(started)), "pages", sandbox.cachedPages); fflush(stdout) }
        lock.unlock()
    }
    print("finished", String(format: "%.0fs", Date().timeIntervalSince(started)), "strong hits", hits.map { (hex($0.0), $0.1) })

case "injtest":
    let sandbox = try Sandbox(game: game)
    let db = try GameReader(game: game) { _ in }.readAll()
    let injured = db.players.filter { $0.injury != nil && $0.contractEnd != nil }.prefix(6).map { $0 }
    print("injured", injured.map { "\($0.name) \($0.injuryText) \($0.injuryDays)d" })
    let bag = UInt64(A64_SCRATCH) + 0x400
    final class Seen { var pairs: [(UInt64, UInt64)] = [] }
    for rva in args.dropFirst(2).compactMap({ Int64($0.dropFirst(2), radix: 16) }) {
        for p in injured.prefix(3) {
            let contract = game.readPointer(p.block + 0x278 + 0x78)
            let team = game.readPointer(contract + 24)
            let seen = Seen()
            let context = Unmanaged.passUnretained(seen).toOpaque()
            do {
                try sandbox.call(game.pluginBase + rva, [UInt64(p.injury!.record), UInt64(p.block), UInt64(team), bag], maxSteps: 5_000_000, prepare: { cpu in
                    a64_set_watch(cpu, 0, UInt64(game.pluginBase + 0x43f7050))
                    a64_set_watch(cpu, 1, UInt64(game.pluginBase + 0x43f8708))
                    a64_set_watch_handler(cpu, { context, cpu, key, value in
                        Unmanaged<Seen>.fromOpaque(context!).takeUnretainedValue().pairs.append((key, a64_read(cpu!, value + 8, 4)))
                    }, context)
                }) { _ in () }
                print(hex(rva), p.name, "expected", p.injuryDays, "bag:", seen.pairs.map { (String($0.0, radix: 16), $0.1) })
            } catch { print(hex(rva), p.name, "stopped:", error) }
        }
    }

case "huntmore":
    // The same idea for other answers the game has already given us.
    let sandbox = try Sandbox(game: game)
    let db = try GameReader(game: game) { _ in }.readAll()
    let starts = try String(contentsOfFile: args[3], encoding: .utf8).split(separator: "\n").compactMap { Int64($0.dropFirst(2), radix: 16) }
    let lock = NSLock()
    var done = 0
    let started = Date()
    func report(_ text: String) { lock.lock(); print(text); fflush(stdout); lock.unlock() }
    func tick() {
        lock.lock(); done += 1
        if done % 30000 == 0 { print("...", done, String(format: "%.0fs", Date().timeIntervalSince(started))); fflush(stdout) }
        lock.unlock()
    }
    switch args[2] {
    case "job":
        // Staff with one clear favourite job: FM's "preferred job" must name it.
        let testers: [(Staff, UInt64, Int)] = db.staff.compactMap { s in
            let block = game.readPointer(s.block + 0x198)
            guard block != 0, let prefs = game.read(block, count: 15), let top = prefs.max(), top >= 15,
                  prefs.filter({ $0 == top }).count == 1, let at = prefs.firstIndex(of: top), at < Names.prefJobs.count else { return nil }
            return (s, UInt64(block), Names.prefJobs[at])
        }.shuffled().prefix(24).map { $0 }
        print("testers", testers.count, testers.prefix(4).map { "\($0.0.name) \($0.2)" })
        DispatchQueue.concurrentPerform(iterations: starts.count) { i in
            let fn = game.pluginBase + starts[i]
            var good = 0
            for (n, t) in testers.enumerated() {
                guard let r: UInt64 = try? sandbox.call(fn, [t.1, UInt64(t.0.block)], maxSteps: 300_000, result: { a64_get_x($0, 0) & 255 }) else { break }
                if Int(r) == t.2 { good += 1 } else if n >= 2 && good == 0 { break }
            }
            if good >= testers.count * 2 / 3 { report("JOB \(hex(starts[i])) \(good)/\(testers.count)") }
            tick()
        }
    case "injury":
        final class Seen { var value: UInt64?; var key: UInt64 = 0 }
        let injured = db.players.filter { $0.injury != nil && $0.contractEnd != nil && $0.injuryDays > 3 }.prefix(10).map { $0 }
        print("testers", injured.map { "\($0.name) \($0.injuryDays)" })
        let bag = UInt64(A64_SCRATCH) + 0x400
        DispatchQueue.concurrentPerform(iterations: starts.count) { i in
            let fn = game.pluginBase + starts[i]
            var good = 0
            var shown: [String] = []
            for p in injured {
                let team = game.readPointer(game.readPointer(p.block + 0x278 + 0x78) + 24)
                let seen = Seen()
                let context = Unmanaged.passUnretained(seen).toOpaque()
                _ = try? sandbox.call(fn, [UInt64(p.injury!.record), UInt64(p.block), UInt64(team), bag], maxSteps: 1_000_000, prepare: { cpu in
                    a64_set_watch(cpu, 0, UInt64(game.pluginBase + 0x43f7050))
                    a64_set_watch_handler(cpu, { context, cpu, key, value in
                        if key & 0xffff_ffff == 0x5050_4d69 { Unmanaged<Seen>.fromOpaque(context!).takeUnretainedValue().value = a64_read(cpu!, value + 8, 4) }
                    }, context)
                }) { _ in () }
                guard let v = seen.value else { break }
                shown.append("\(p.injuryDays):\(v)")
                good += 1
            }
            if good >= 3 { report("INJURY \(hex(starts[i])) \(good)/\(injured.count) \(shown)") }
            tick()
        }
    case "rolelist2":
        // Takes a pointer to the position mask, like the in-possession builder.
        let testers = db.players.filter { $0.ca > 100 && Set($0.topRoles).count == 6 }.shuffled().prefix(30).map { $0 }
        let offset = 3
        DispatchQueue.concurrentPerform(iterations: starts.count) { i in
            let fn = game.pluginBase + starts[i]
            var good = 0
            var masks = Set<UInt64>()
            let cell = UInt64(A64_SCRATCH) + 0x100
            for (n, p) in testers.enumerated() {
                let index = (0..<15).max { p.pos[$0] < p.pos[$1] }!
                let pos = Names.posToGame[index]
                guard let mask: UInt64 = try? sandbox.call(fn, [cell, 0, 0], maxSteps: 100_000, prepare: { a64_write($0, cell, UInt64(1) << UInt64(pos), 4) }, result: { a64_get_x($0, 0) }) else { break }
                let top = p.topRoles[offset..<(offset + 3)]
                if top.allSatisfy({ $0 < 64 && mask >> UInt64($0) & 1 == 1 }), mask.nonzeroBitCount < 40 { good += 1 }
                masks.insert(mask)
                if n >= 4 && good == 0 { break }
            }
            if good >= testers.count / 2, masks.count >= 3 { report("ROLELIST2 \(hex(starts[i])) \(good)/\(testers.count) distinct \(masks.count)") }
            tick()
        }
    case "rolelist3":
        // Relaxed: stored best roles can come from a neighbouring position, so only ask that a good
        // share of players at a position have their top role listed, and that lists differ by position.
        let form = Int(args[4])!
        var byPosition: [Int: [Int]] = [:]
        for p in db.players where p.ca > 80 {
            let order = (0..<15).sorted { p.pos[$0] > p.pos[$1] }
            guard p.pos[order[0]] >= 18, p.pos[order[1]] < 15 else { continue }
            byPosition[Names.posToGame[order[0]], default: []].append(Int(p.topRoles[3]))
        }
        let positions = byPosition.keys.filter { byPosition[$0]!.count >= 40 }.sorted()
        print("positions", positions.map { "\($0):\(byPosition[$0]!.count)" })
        DispatchQueue.concurrentPerform(iterations: starts.count) { i in
            let fn = game.pluginBase + starts[i]
            let cell = UInt64(A64_SCRATCH) + 0x100
            var masks: [Int: UInt64] = [:]
            var share = 0.0
            for pos in positions {
                let regs: [UInt64] = form == 0 ? [UInt64(pos), 0, 0, 0] : form == 1 ? [cell, 0, 0] : form == 2 ? [UInt64(1) << UInt64(pos), 0, 0] : [cell, 0, 0, 2]
                guard let mask: UInt64 = try? sandbox.call(fn, regs, maxSteps: 80_000, prepare: { a64_write($0, cell, UInt64(1) << UInt64(pos), 4) }, result: { a64_get_x($0, 0) }) else { break }
                let count = mask.nonzeroBitCount
                guard count >= 2, count <= 16 else { break }
                masks[pos] = mask
                let roles = byPosition[pos]!
                share += Double(roles.filter { mask >> UInt64($0) & 1 == 1 }.count) / Double(roles.count)
            }
            guard masks.count == positions.count, Set(masks.values).count >= positions.count - 2 else { tick(); return }
            let average = share / Double(positions.count)
            if average > 0.3 { report(String(format: "LIST form %d %@ share %.2f distinct %d", form, hex(starts[i]), average, Set(masks.values).count)) }
            tick()
        }
    case "rolelist":
        // Which roles a position allows: every player's stored best roles must be in the list for his position.
        let testers = db.players.filter { $0.ca > 100 && Set($0.topRoles).count == 6 }.shuffled().prefix(30).map { $0 }
        let oop = args.count > 4
        let offset = oop ? 3 : 0
        DispatchQueue.concurrentPerform(iterations: starts.count) { i in
            let fn = game.pluginBase + starts[i]
            var good = 0
            var masks = Set<UInt64>()
            for p in testers {
                let index = (0..<15).max { p.pos[$0] < p.pos[$1] }!
                let pos = Names.posToGame[index]
                let scratch = UInt64(A64_SCRATCH) + 0xc00
                guard let mask: UInt64 = try? sandbox.call(fn, [UInt64(pos), scratch, scratch + 8, 0], maxSteps: 60_000, prepare: { cpu in
                    a64_write(cpu, scratch, UInt64(1) << UInt64(pos & 31), 4)
                    a64_write(cpu, scratch + 8, 0x1a03_0001, 4)
                }, result: { a64_get_x($0, 0) }) else { break }
                let top = p.topRoles[offset..<(offset + 3)]
                if top.allSatisfy({ $0 < 64 && mask >> UInt64($0) & 1 == 1 }), mask.nonzeroBitCount < 40 { good += 1 }
                masks.insert(mask)
                if good == 0 && masks.count >= 3 { break }
                if mask == 0 && masks.count == 1 { break }
            }
            if good >= testers.count * 2 / 3, masks.count >= 4 { report("ROLELIST \(hex(starts[i])) \(good)/\(testers.count) distinct \(masks.count)") }
            tick()
        }
    default: break
    }
    print("finished", String(format: "%.0fs", Date().timeIntervalSince(started)))

case "rolesample":
    let sandbox = try Sandbox(game: game)
    let db = try GameReader(game: game) { _ in }.readAll()
    let club = db.humanClubs[0].name
    let viewer = db.staff.first { $0.clubFull == club && $0.job == "Assistant Manager" }!
    let oop = args[2] == "oop"
    let tester = db.players.filter { $0.clubFull == club && $0.ca > 110 && Set($0.topRoles).count == 6 }.prefix(2)
    for rva in args.dropFirst(3).compactMap({ Int64($0.dropFirst(2), radix: 16) }) {
        for p in tester {
            let index = (0..<15).max { p.pos[$0] < p.pos[$1] }!
            let pos = UInt64(1) << UInt64(Names.posToGame[index])
            var row: [String] = []
            for role in 0..<64 {
                let mask = UInt64(1) << UInt64(role)
                let regs: [UInt64] = oop ? [UInt64(p.block), pos, mask, 2, UInt64(viewer.block), 0, 1, 0] : [UInt64(p.block), pos, mask, 0, 0, 2, UInt64(viewer.block), 0]
                let r: Int32? = try? sandbox.call(game.pluginBase + rva, regs, stack: oop ? [] : [1, 0], maxSteps: 1_500_000) { Int32(truncatingIfNeeded: a64_get_x($0, 0)) }
                row.append(r.map(String.init) ?? "x")
            }
            print(hex(rva), p.name, Names.positions[index], "top", p.topRoles.map(String.init).joined(separator: ","), ":", row.joined(separator: " "))
        }
    }

case "roles":
    let (db, engine) = try GameReader.connect { _ in }
    guard let engine else { print("no engine"); exit(1) }
    let team = db.humanClubs[0].team
    for name in args.dropFirst(2) {
        guard let p = db.players.first(where: { $0.name == name }) else { print(name, "?"); continue }
        print(name, "best", p.bestPositions, "| stored top:", p.topRoles.prefix(3).map { Names.rolesIp[Int($0)] ?? "?" }, "/", p.topRoles.suffix(3).map { Names.rolesOop[Int($0)] ?? "?" })
        guard let rows = engine.roleRows(player: p, team: team) else { print(" no rows", engine.lastFailure ?? ""); continue }
        for r in rows.sorted(by: { ($0.outOfPossession ? 1 : 0, -$0.rating) < ($1.outOfPossession ? 1 : 0, -$1.rating) }) {
            print(String(format: "   %@ %-34@ %d..%d half-stars  rating %d", r.outOfPossession ? "OOP" : "IP ", r.role as NSString, r.minHalfStars, r.maxHalfStars, r.rating))
        }
    }

case "huntlimits":
    let sandbox = try Sandbox(game: game)
    let rtti = Rtti(game)
    let db = try GameReader(game: game) { _ in }.readAll()
    let team = db.humanClubs[0].team, club = game.readPointer(team + 48)
    let name = db.humanClubs[0].name
    var jobs: [String: Int] = [:]
    for s in db.staff where s.clubFull == name { jobs[s.job, default: 0] += 1 }
    print("Molde staff:", jobs.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    // Every global that points at a heap object with a vtable in the game.
    let low = game.pluginBase, high = game.pluginBase + game.pluginSize
    var objects: [Int64: Int64] = [:]
    for at in stride(from: 0x5400000, to: Int(game.pluginSize) - 8, by: 8) {
        let value = rtti.word(at)
        guard value > 0x7000000000, value < 0x7fff_ffff_ffff, objects[value] == nil else { continue }
        let vt = game.readPointer(value)
        if vt > low, vt < high { objects[value] = Int64(at) }
    }
    print("global objects", objects.count)
    let keys = Array(objects.keys)
    let out = UInt64(A64_SCRATCH) + 0x800
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: keys.count) { i in
        let object = keys[i]
        let vt = game.readPointer(object)
        for slot in 0..<24 {
            let fn = game.readPointer(vt + Int64(slot * 8))
            guard fn > low, fn < high else { break }
            for (form, regs) in [(0, [UInt64(object), UInt64(club), 0]), (1, [UInt64(object), out, UInt64(club), 0])] as [(Int, [UInt64])] {
                guard let b: [UInt8] = try? sandbox.call(fn, regs, maxSteps: 400_000, prepare: { a64_set_x($0, 8, out) }, result: { cpu in
                    var b = [UInt8](repeating: 0, count: 24)
                    a64_read_bytes(cpu, out, &b, 24)
                    return b
                }) else { continue }
                let head = b.prefix(11)
                let pointer = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self) }
                guard head.allSatisfy({ $0 <= 60 }), head.filter({ $0 > 0 }).count >= 3, pointer != 0 else { continue }
                lock.lock()
                print("LIMITS global", hex(objects[object]!), "slot", slot, "form", form, "fn", hex(fn - game.pluginBase), head.map(String.init).joined(separator: " "), "ptr", hex(Int64(truncatingIfNeeded: pointer)))
                fflush(stdout)
                lock.unlock()
            }
        }
    }
    print("finished")

case "oopmask":
    let sandbox = try Sandbox(game: game)
    for pos in 0..<16 {
        let m: UInt64 = (try? sandbox.call(game.pluginBase + Int64(args[2].dropFirst(2), radix: 16)!, [UInt64(pos), 0, 0, 0]) { a64_get_x($0, 0) }) ?? 1
        print(pos, String(m, radix: 16), (0..<64).filter { m >> UInt64($0) & 1 == 1 }.map { Names.rolesOop[$0] ?? "#\($0)" }.prefix(8))
    }

case "limits2":
    let sandbox = try Sandbox(game: game)
    let db = try GameReader(game: game) { _ in }.readAll()
    let team = db.humanClubs[0].team, club = game.readPointer(team + 48)
    let object = game.readPointer(game.pluginBase + 0x56d2b80), vt = game.readPointer(object)
    let flags = game.read(game.pluginBase + 0x56d4950, count: 2) ?? []
    print("flags", flags, "teams:", (0..<8).map { i -> String in
        let begin = game.readPointer(club + 24), end = game.readPointer(club + 32)
        guard begin + Int64(i * 8) < end else { return "" }
        let t = game.readPointer(begin + Int64(i * 8))
        return "\(game.read(t + 40, count: 1)?.first ?? 255)"
    }.filter { !$0.isEmpty })
    let out = UInt64(A64_SCRATCH) + 0x800
    for slot in 5..<12 {
        let fn = game.readPointer(vt + Int64(slot * 8))
        for mode in [UInt64(0), 1, 2, 3] {
            guard let text: String = try? sandbox.call(fn, [UInt64(object), out, UInt64(club), mode], maxSteps: 3_000_000, result: { cpu in
                var b = [UInt8](repeating: 0, count: 24)
                a64_read_bytes(cpu, out, &b, 24)
                let list = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self) }
                var rows: [String] = []
                if list != 0 {
                    let base = a64_read(cpu, list, 8), count = a64_read(cpu, list &+ 8, 4)
                    for i in 0..<min(count, 8) {
                        var r = [UInt8](repeating: 0, count: 9)
                        a64_read_bytes(cpu, base &+ 16 &* i &+ 4, &r, 9)
                        rows.append(r.map(String.init).joined(separator: " "))
                    }
                }
                return b.prefix(11).map(String.init).joined(separator: " ") + " | " + rows.joined(separator: " / ")
            }) else { print("slot", slot, "mode", mode, "stopped"); continue }
            print("slot", slot, "mode", mode, ":", text)
        }
    }

case "listflags":
    let sandbox = try Sandbox(game: game)
    let fn = game.pluginBase + 0x491d348
    let cell = UInt64(A64_SCRATCH) + 0x100
    for pos in [4, 10, 14] {
        for (a, b) in [(0, 0), (1, 0), (0, 1), (1, 1), (2, 0), (0, 2)] as [(UInt64, UInt64)] {
            let result: String = (try? sandbox.call(fn, [cell, a, b], maxSteps: 3_000_000, prepare: { a64_write($0, cell, UInt64(1) << UInt64(pos), 4) }) { cpu in
                let m = a64_get_x(cpu, 0)
                let ip = (0..<64).filter { m >> UInt64($0) & 1 == 1 }
                return String(m, radix: 16) + " ip:" + ip.prefix(5).map { Names.rolesIp[$0] ?? "#\($0)" }.joined(separator: ",") + " oop:" + ip.prefix(5).map { Names.rolesOop[$0] ?? "#\($0)" }.joined(separator: ",")
            }) ?? "stopped"
            print("pos", pos, "flags", a, b, result)
        }
    }

case "tablescan":
    let rtti = Rtti(game)
    let db = try GameReader(game: game) { _ in }.readAll()
    let testers = db.players.filter { $0.ca > 90 && Set($0.topRoles).count == 6 }.prefix(400).map { p -> (Int, [UInt8]) in
        let index = (0..<15).max { p.pos[$0] < p.pos[$1] }!
        return (Names.posToGame[index], Array(p.topRoles[3..<6]))
    }
    print("testers", testers.count)
    var hits: [(Int, Int)] = []
    let words = rtti.image.count / 8
    rtti.image.withUnsafeBytes { raw in
        let w = raw.bindMemory(to: UInt64.self)
        // Try both pointer sizes of stride: FM's tables hold one mask per position, 8 or 16 bytes apart.
        for strideWords in [1, 2] {
            for start in 0..<(words - 32 * strideWords) {
                var good = 0, bad = 0
                for (pos, top) in testers {
                    let mask = w[start + pos * strideWords]
                    if mask == 0 || mask.nonzeroBitCount > 30 { bad += 1 } else if top.allSatisfy({ mask >> UInt64($0) & 1 == 1 }) { good += 1 } else { bad += 1 }
                    if bad > testers.count / 3 { break }
                }
                if good >= testers.count * 2 / 3 { hits.append((start * 8, strideWords * 8)) }
            }
        }
    }
    print("hits", hits.prefix(12).map { (hex(Int64($0.0)), $0.1) })
    for (at, step) in hits.prefix(2) {
        for pos in [4, 10, 14] {
            let m = UInt64(bitPattern: rtti.word(at + pos * step))
            print(hex(Int64(at)), "pos", pos, (0..<64).filter { m >> UInt64($0) & 1 == 1 }.map { Names.rolesOop[$0] ?? "#\($0)" })
        }
    }

case "rolederive":
    let sandbox = try Sandbox(game: game)
    let db = try GameReader(game: game) { _ in }.readAll()
    // Only players clearly suited to one position, so a role really belongs to it.
    func derive(_ range: Range<Int>, threshold: Double) -> [Int: [Int: Int]] {
        var seen: [Int: [Int: Int]] = [:]
        for p in db.players where p.ca >= 60 {
            let order = (0..<15).sorted { p.pos[$0] > p.pos[$1] }
            guard p.pos[order[0]] >= 18, p.pos[order[1]] < 15 else { continue }
            let pos = Names.posToGame[order[0]]
            for role in p.topRoles[range] where role < 64 { seen[pos, default: [:]][Int(role), default: 0] += 1 }
        }
        return seen
    }
    let ip = derive(0..<3, threshold: 0)
    var exact = 0, total = 0
    for index in 0..<15 {
        let pos = Names.posToGame[index]
        let cell = UInt64(A64_SCRATCH) + 0x100
        let real: UInt64 = (try? sandbox.call(game.pluginBase + 0x4918c5c, [UInt64(pos)]) { a64_get_x($0, 0) }) ?? 0
        let realSet = Set((0..<64).filter { real >> UInt64($0) & 1 == 1 })
        let counts = ip[pos] ?? [:]
        let sum = counts.values.reduce(0, +)
        let derived = Set(counts.filter { Double($0.value) >= Double(sum) * 0.005 }.keys)
        total += 1
        if derived == realSet { exact += 1 }
        print(Names.positions[index], "players", sum, "real", realSet.count, "derived", derived.count, "missing", realSet.subtracting(derived).compactMap { Names.rolesIp[$0] }, "extra", derived.subtracting(realSet).compactMap { Names.rolesIp[$0] })
        _ = cell
    }
    print("exact", exact, "of", total)

case "jobs":
    let (db, engine) = try GameReader.connect { _ in }
    guard let engine else { exit(1) }
    let team = db.humanClubs[0].team
    let limits = engine.staffNumbers(team: team)
    print("limits allowed", limits?.allowed as Any, "current", limits?.current as Any, "modes", limits?.modeA as Any, limits?.modeB as Any)
    print("team rows", limits?.teams.map(\.type) as Any)
    for s in db.staff.filter({ $0.clubFull == db.humanClubs[0].name }).prefix(8) {
        print(s.name, "|", s.job, "| prefers:", engine.preferredJob(staff: s).flatMap { Names.jobs[$0] } ?? "?", "| prefs", engine.jobPreferences(staff: s) ?? [])
    }

case "staffmap":
    // Which job each entry of the board's staff table counts: the table against who actually holds the job, club by club.
    let sandbox = try Sandbox(game: game)
    let db = try GameReader(game: game) { _ in }.readAll()
    let object = game.readPointer(game.pluginBase + 0x56d2b80), vt = game.readPointer(object)
    let slot = args.count > 2 ? Int(args[2])! : 8
    let fn = game.readPointer(vt + Int64(slot * 8))
    let out = UInt64(A64_SCRATCH) + 0x800
    var clubs: [Int64: [Staff]] = [:]
    for person in db.staff where person.clubObject != 0 { clubs[person.clubObject, default: []].append(person) }
    let human = game.readPointer(db.humanClubs[0].team + 48)
    print("human club object", hex(human), "known:", clubs[human] != nil)
    let picked = clubs.keys.sorted { (clubs[$0]?.count ?? 0) > (clubs[$1]?.count ?? 0) }.prefix(args.count > 3 ? Int(args[3])! : 400)
    for club in picked {
        guard let row: [UInt8] = try? sandbox.call(fn, [UInt64(object), out, UInt64(club), 3], maxSteps: 3_000_000, result: { cpu in
            var head = [UInt8](repeating: 0, count: 11)
            a64_read_bytes(cpu, out, &head, 11)
            return head
        }) else { continue }
        var jobs: [String: Int] = [:]
        for person in clubs[club] ?? [] where !person.job.isEmpty { jobs[person.job, default: 0] += 1 }
        print(row.map(String.init).joined(separator: ","), "|", jobs.map { "\($0.key)=\($0.value)" }.joined(separator: ";"))
    }

case "agecurve":
    // How far along players of each age are towards their potential, across the whole world.
    let db = try GameReader(game: game) { _ in }.readAll()
    func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
    for band in [(100, 119), (120, 139), (140, 159), (160, 200)] {
        print("PA \(band.0)-\(band.1)")
        for age in 15...33 {
            let here = db.players.filter { $0.age == age && $0.pa >= band.0 && $0.pa <= band.1 && $0.ca > 0 }
            guard here.count >= 8 else { continue }
            let ratios = here.map { Double($0.ca) / Double($0.pa) }.sorted()
            print(String(format: "  %2d n=%5d low %.2f median %.2f high %.2f", age, here.count, ratios[ratios.count / 4], median(ratios), ratios[ratios.count * 3 / 4]))
        }
    }
    let name = db.humanClubs[0].name
    print("squad of", name)
    for player in db.players.filter({ $0.clubFull == name }).sorted(by: { $0.pa > $1.pa }).prefix(34) {
        print(player.name, "age", player.age, "CA", player.ca, "PA", player.pa, player.bestPositions, "|", player.squad, "| loan", player.loanClub, "| prof", player.p("Professionalism"), "det", player.a("Determination"))
    }

case "talent":
    // What the app says about the club's young players, and the world's best teenagers.
    let db = try GameReader(game: game) { _ in }.readAll()
    let curve = DevelopmentCurve(players: db.players)
    let name = db.humanClubs[0].name
    func show(_ player: Player) {
        let talent = curve.talent(player)
        print(player.name, "| age", player.age, "| CA", player.ca, "PA", player.pa, "peak", curve.peak(player), "|", talent?.verdict.title ?? "-", talent.map { "\($0.chance)%" } ?? "", "|", talent?.mentality ?? "", "| inj", player.a("Injury Proneness"), "|", player.personality, "|", player.loanClub.isEmpty ? player.squad : "loan " + player.loanClub)
    }
    print("Club, 23 and under")
    db.players.filter { $0.clubFull == name && $0.age >= 0 && $0.age <= 23 }.sorted { curve.peak($0) > curve.peak($1) }.forEach(show)
    print("Highest PA in the world, 21 and under, that the model doubts")
    db.players.filter { $0.age <= 21 && $0.pa >= 150 && curve.talent($0)?.verdict == .unlikely }.sorted { $0.pa > $1.pa }.prefix(10).forEach(show)
    print("And the ones it trusts most")
    db.players.filter { $0.age <= 21 && $0.pa >= 150 && curve.talent($0)?.verdict == .likely }.sorted { (curve.talent($0)?.chance ?? 0, $0.pa) > (curve.talent($1)?.chance ?? 0, $1.pa) }.prefix(8).forEach(show)

case "hiddencsv":
    // Every player's hidden stats and how far along they are, for working out what development depends on.
    let db = try GameReader(game: game) { _ in }.readAll()
    let personality = Names.personality, attributes = ["Determination", "Consistency", "Important Matches", "Injury Proneness", "Versatility", "Dirtiness", "Natural Fitness", "Work Rate", "Leadership"]
    var clubs: [String: [Int]] = [:]
    for player in db.players where !player.clubFull.isEmpty { clubs[player.clubFull, default: []].append(player.ca) }
    let levels = clubs.mapValues { abilities -> Int in
        let best = abilities.sorted(by: >).prefix(11)
        return best.reduce(0, +) / max(1, best.count)
    }
    print((["uid", "age", "ca", "pa", "club", "personality"] + personality + attributes).joined(separator: ","))
    for player in db.players where player.ca > 0 && player.pa >= 90 {
        let cells = ["\(player.uid)", "\(player.age)", "\(player.ca)", "\(player.pa)", "\(levels[player.clubFull] ?? 0)", player.personality.replacingOccurrences(of: ",", with: " ")]
        print((cells + personality.map { "\(player.p($0))" } + attributes.map { "\(player.a($0))" }).joined(separator: ","))
    }

case "injuries":
    let (db, engine) = try GameReader.connect { _ in }
    guard let engine else { exit(1) }
    let injured = db.players.filter { $0.injury != nil }
    var same = 0, near = 0, none = 0
    for p in injured {
        guard let days = engine.injuryReturnDays(player: p) else { none += 1; continue }
        if days == p.injuryDays { same += 1 } else if abs(days - p.injuryDays) <= 7 { near += 1 }
    }
    print("injured", injured.count, "identical", same, "within a week", near, "no answer", none, engine.lastFailure ?? "")
    for p in injured.prefix(10) { print(" ", p.name, "|", p.injuryText, "| estimate", p.injuryDays, "| FM", engine.injuryReturnDays(player: p) as Any) }

case "refs":
    // Every aligned word holding one of these values, anywhere writable.
    let wanted = Set(args.dropFirst(2).map { Int64($0.replacingOccurrences(of: "0x", with: ""), radix: 16)! })
    let lock = NSLock()
    var found: [(Int64, Int64)] = []
    let pieces = game.pieces(size: 1 << 23, overlap: 0, writableOnly: true)
    DispatchQueue.concurrentPerform(iterations: pieces.count) { i in
        let piece = pieces[i]
        guard let bytes = game.read(piece.address, count: piece.count) else { return }
        var local: [(Int64, Int64)] = []
        bytes.withUnsafeBytes { raw in
            let words = raw.bindMemory(to: Int64.self)
            for j in 0..<words.count where wanted.contains(words[j]) { local.append((piece.address + Int64(j * 8), words[j])) }
        }
        lock.lock(); found += local; lock.unlock()
    }
    for hit in found.sorted(by: { $0.0 < $1.0 }) { print(hex(hit.0), hex(hit.1)) }

case "cluster":
    // Where several people are mentioned close together: pointers to them, or their UIDs.
    let db = try GameReader(game: game) { _ in }.readAll()
    var who: [Int64: String] = [:]
    var uids: [UInt32: String] = [:]
    for name in args.dropFirst(2) {
        guard let p = db.players.first(where: { $0.name.localizedCaseInsensitiveContains(name) && $0.clubFull.contains("Molde") }) else { print("no", name); continue }
        print(name, "->", p.name, String(format: "%llx", p.block), p.uid)
        for offset in [0, 0x278, 0x388] { who[p.block + Int64(offset)] = name + "+\(String(offset, radix: 16))" }
        uids[p.uid] = name + ".uid"
        uids[UInt32(p.index)] = name + ".idx"
    }
    let lock = NSLock()
    var found: [(Int64, String)] = []
    let pieces = game.pieces(size: 1 << 23, overlap: 0, writableOnly: true)
    DispatchQueue.concurrentPerform(iterations: pieces.count) { i in
        let piece = pieces[i]
        guard let bytes = game.read(piece.address, count: piece.count) else { return }
        var local: [(Int64, String)] = []
        bytes.withUnsafeBytes { raw in
            let words = raw.bindMemory(to: Int64.self)
            for j in 0..<words.count { if let n = who[words[j]] { local.append((piece.address + Int64(j * 8), n)) } }
            let ints = raw.bindMemory(to: UInt32.self)
            for j in 0..<ints.count { if let n = uids[ints[j]] { local.append((piece.address + Int64(j * 4), n)) } }
        }
        lock.lock(); found += local; lock.unlock()
    }
    found.sort { $0.0 < $1.0 }
    print("hits", found.count)
    if let out = ProcessInfo.processInfo.environment["OUT"] {
        try found.map { "\(String($0.0, radix: 16)) \($0.1)" }.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        exit(0)
    }
    var start = 0
    while start < found.count {
        var end = start
        while end + 1 < found.count, found[end + 1].0 - found[end].0 < 0x400 { end += 1 }
        let names = Set(found[start...end].map { $0.1.split(separator: "+")[0].split(separator: ".")[0] })
        if names.count >= (ProcessInfo.processInfo.environment["MINPEOPLE"].flatMap(Int.init) ?? 6), found[start...end].contains(where: { $0.1.hasSuffix(ProcessInfo.processInfo.environment["SUFFIX"] ?? "") }) {
            print("--", hex(found[start].0), "..", hex(found[end].0), names.count, "people", end - start + 1, "hits")
            print("  ", found[start...min(end, start + 40)].map { "\(String($0.0 - found[start].0, radix: 16)):\($0.1)" }.joined(separator: " "))
        }
        start = end + 1
    }

case "who":
    // What an address is: the class of the vtable at its start, and of any near it.
    let rtti = Rtti(game)
    for arg in args.dropFirst(2) {
        let address = Int64(arg.replacingOccurrences(of: "0x", with: ""), radix: 16)!
        guard let b = game.read(address, count: 64) else { print(arg, "unreadable"); continue }
        var line = [arg]
        for o in stride(from: 0, to: 64, by: 8) {
            let w = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int64.self) }
            if let name = rtti.className(vtable: w) { line.append("+\(o):\(name)") }
        }
        print(line.joined(separator: " "))
    }

case "census":
    // Live objects of every class whose name matches: how many there are, and a few addresses.
    let rtti = Rtti(game)
    let pattern = try NSRegularExpression(pattern: args[2])
    let low = game.pluginBase, high = game.pluginBase + game.pluginSize
    let lock = NSLock()
    var seen = Set<Int64>()
    let pieces = game.pieces(size: 1 << 23, overlap: 0, writableOnly: true)
    DispatchQueue.concurrentPerform(iterations: pieces.count) { i in
        guard let bytes = game.read(pieces[i].address, count: pieces[i].count) else { return }
        var local = Set<Int64>()
        bytes.withUnsafeBytes { raw in
            for w in raw.bindMemory(to: Int64.self) where w > low && w < high { local.insert(w) }
        }
        lock.lock(); seen.formUnion(local); lock.unlock()
    }
    var wanted: [Int64: String] = [:]
    for w in seen {
        if let name = rtti.className(vtable: w), pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil { wanted[w] = name }
    }
    var hits: [Int64: [Int64]] = [:]
    DispatchQueue.concurrentPerform(iterations: pieces.count) { i in
        guard let bytes = game.read(pieces[i].address, count: pieces[i].count) else { return }
        var local: [Int64: [Int64]] = [:]
        bytes.withUnsafeBytes { raw in
            let words = raw.bindMemory(to: Int64.self)
            for j in 0..<words.count where wanted[words[j]] != nil { local[words[j], default: []].append(pieces[i].address + Int64(j * 8)) }
        }
        lock.lock(); hits.merge(local, uniquingKeysWith: +); lock.unlock()
    }
    let shown = ProcessInfo.processInfo.environment["ALL"] == nil ? 4 : 1000
    for (vt, found) in hits.sorted(by: { wanted[$0.key]! < wanted[$1.key]! }) {
        print(wanted[vt]!.prefix(96), hex(vt - game.pluginBase), found.count, found.sorted().prefix(shown).map(hex).joined(separator: " "))
    }

case "fields":
    // Each word of an object that points at something with a vtable.
    let rtti = Rtti(game)
    let address = Int64(args[2].replacingOccurrences(of: "0x", with: ""), radix: 16)!
    let count = args.count > 3 ? Int(args[3])! : 1024
    guard let b = game.read(address, count: count) else { print("unreadable"); exit(1) }
    for o in stride(from: 0, to: count - 7, by: 8) {
        let w = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int64.self) }
        if let name = rtti.className(vtable: w) { print(String(o, radix: 16), "vt", name.prefix(90)); continue }
        guard w > 0x100000000, let target = game.read(w, count: 8) else { continue }
        let inner = target.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
        print(String(o, radix: 16), hex(w), rtti.className(vtable: inner).map { String($0.prefix(90)) } ?? "")
    }

case "tactic":
    let db = try GameReader(game: game) { _ in }.readAll()
    for (team, tactic) in db.tactics {
        print(hex(team), tactic.shape(in: nil), "/", tactic.shapeWithoutBall(in: nil))
        for slot in tactic.slots { print("  ", slot.label, slot.player?.name ?? "-", "|", slot.roleName, "|", Names.positions[slot.positionWithoutBall], slot.roleNameWithoutBall) }
    }

case "shapenames":
    // Every entry of FM's built-in formation table, named by FM's own routine: an id byte, a pad byte, then eleven words.
    let places: [Int: (String, TacticSlot.Side)] = [
        -15: ("GK", .centre), -13: ("DR", .centre), -12: ("DC", .right), -11: ("DC", .centre), -10: ("DC", .left), -9: ("DL", .centre),
        -8: ("WBR", .centre), -7: ("DM", .right), -6: ("DM", .centre), -5: ("DM", .left), -4: ("WBL", .centre),
        -3: ("MR", .centre), -2: ("MC", .right), -1: ("MC", .centre), 0: ("MC", .left), 1: ("ML", .centre),
        2: ("AMR", .centre), 3: ("AMC", .right), 4: ("AMC", .centre), 5: ("AMC", .left), 6: ("AML", .centre),
        8: ("ST", .right), 9: ("ST", .centre), 10: ("ST", .left),
    ]
    guard let table = game.read(game.pluginBase + 0x573cfa0, count: 64 * 24), let engine = RulesEngine(game: game, rtti: Rtti(game)) else { print("no engine"); exit(1) }
    for record in 0..<64 {
        let at = record * 24
        let shape: [(position: Int, side: TacticSlot.Side)] = (0..<11).compactMap { slot in
            let word = table.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at + 2 + slot * 2, as: UInt16.self) }
            guard let place = places[Int(Int16(truncatingIfNeeded: word << 10) >> 10)] else { return nil }
            return (Names.positions.firstIndex(of: place.0)!, place.1)
        }
        print(table[at], shape.count == 11 ? engine.shapeName(shape) ?? "no name" : "not a formation")
    }

case "currencies":
    let base = Int64(args[2].replacingOccurrences(of: "0x", with: ""), radix: 16)!
    for i in 0..<173 {
        let at = base + Int64(i) * 0x58
        guard let b = game.read(at, count: 88) else { continue }
        let word: (Int) -> Int64 = { o in b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int64.self) } }
        let int: (Int) -> Int32 = { o in b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int32.self) } }
        let rate = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 56, as: Float.self) }
        print(i, int(8), int(12), int(16), game.lengthPrefixedString(word(24)), "|", game.lengthPrefixedString(word(32)), "|", game.lengthPrefixedString(word(48)), "|", rate)
    }

case "finance":
    // Each human club's CLUB_FINANCE record as 32-bit words, to find a figure FM shows. Molde's Available Kr 9.01M was
    // transfer_budget at 0x7c4.
    let rtti = Rtti(game)
    let size = args.count > 2 ? Int(args[2])! : 4096
    let vt = game.pluginBase + Int64(rtti.vtables("CLUB_HUMAN_MANAGER_DETAILS")[0].addressPoint)
    var clubs = Set<Int64>()
    for piece in game.pieces(size: 1 << 23, overlap: 0, writableOnly: true) {
        guard let bytes = game.read(piece.address, count: piece.count) else { continue }
        let details = bytes.withUnsafeBytes { raw -> [Int64] in
            let words = raw.bindMemory(to: Int64.self)
            return (0..<words.count).compactMap { words[$0] == vt ? piece.address + Int64($0 * 8) : nil }
        }
        for detail in details {
            let team = game.readPointer(detail + 64), club = team == 0 ? 0 : game.readPointer(team + 48)
            if club != 0 { clubs.insert(club) }
        }
    }
    for club in clubs.sorted() {
        let finance = game.readPointer(club + 0x150)
        print(game.lengthPrefixedString(game.readPointer(club + 192)), "finance", hex(finance), rtti.className(vtable: game.readPointer(finance)) ?? "?")
        guard finance != 0, let b = game.read(finance, count: size) else { continue }
        for o in stride(from: 0, to: size, by: 4) {
            let v = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int32.self) }
            if v != 0 { print(String(format: "  %04x %11d", o, v)) }
        }
    }

case "dump":
    let address = Int64(args[2].replacingOccurrences(of: "0x", with: ""), radix: 16)!
    let count = args.count > 3 ? Int(args[3])! : 256
    guard let bytes = game.read(address, count: count) else { print("unreadable"); exit(1) }
    for row in stride(from: 0, to: count, by: 16) {
        let slice = bytes[row..<min(row + 16, count)]
        let text = slice.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
        print(String(format: "%04x ", row) + slice.map { String(format: "%02x", $0) }.joined(separator: " ") + "  " + text)
    }

default:
    print("unknown command")
}
