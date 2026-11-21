@testable import StarshipCore
import XCTest

/// The reader against made-up records laid out as `MacLayout` says. An offset moved onto another field or out of its record,
/// or a reader that reads the wrong field, fails here rather than on a screen. Every name and number is made up.
final class ReaderLayoutTests: XCTestCase {
    /// Two nations in one area, two leagues, and two clubs with two teams each.
    private final class World {
        let game = FakeGame()
        let area: Int64
        let mockovia: Int64, fixtureland: Int64
        let rovers: Int64, town: Int64
        let roversFirst: Int64, roversReserves: Int64, townFirst: Int64, townUnder23: Int64

        init() {
            let continent = game.continent("Made-up Continent")
            area = game.allocate(16)
            // NZL is one of the codes that names an area, so the area both nations are in takes its name from it.
            mockovia = game.nation("Mockovia", code: "NZL", continent: continent, area: area)
            fixtureland = game.nation("Fixtureland", code: "FXL", continent: continent, area: area)
            let league = game.competition("Mock League One"), youth = game.competition("Mock Under-23 League")
            rovers = game.club(full: "Mockport Rovers FC", short: "Mockport", nation: mockovia)
            town = game.club(full: "Fixture Town AFC", short: "Fixture Town", nation: fixtureland)
            roversFirst = game.team(club: rovers, index: 0x1267, type: 0, competition: league)
            roversReserves = game.team(club: rovers, index: 0x1268, type: 1, competition: league)
            townFirst = game.team(club: town, index: 0x2301, type: 0, competition: league)
            townUnder23 = game.team(club: town, index: 0x2302, type: 9, competition: youth)
        }
    }

    func testReadsEveryFieldOfAPlayer() throws {
        try checkEveryFieldOfAPlayer { world, values in world.game.player(values) }
    }

    /// The player part of a player FM has also given a staff record reads as any player does, with the name, traits and
    /// contract from the person further on. One who only plays, contract job 1, isn't staff.
    func testReadsEveryFieldOfAPlayerWithAStaffRecord() throws {
        try checkEveryFieldOfAPlayer { world, values in
            var values = values
            values.person.contract?.job = 1
            return world.game.playerCoach(values, staff: FakeGame.StaffValues())
        }
    }

    /// Lays out a player with `make` and checks every field the reader takes from it.
    private func checkEveryFieldOfAPlayer(_ make: (World, FakeGame.PlayerValues) -> FakeRecord) throws {
        let world = World()
        var values = FakeGame.PlayerValues()
        values.ca = 143
        values.pa = 167
        values.value = 12_345_678
        values.positions = (0..<15).map { UInt8(1 + $0 * 7 % 20) }
        values.attributes = (0..<54).map { UInt8(5 + $0 * 37 % 96) }
        values.height = 187
        values.topRoles = [11, 22, 33, 41, 52, 63]
        values.traits = 0x8000_0000_0000_0005
        values.person.index = 4_321
        values.person.uid = 98_765_432
        values.person.flags = 0x0c
        values.person.fullName = "Mock Anders Playerson"
        values.person.firstName = "Mock"
        values.person.secondName = "Playerson"
        values.person.commonName = ""
        values.person.nation = world.fixtureland
        values.person.birth = (day: 200, year: 2004)
        values.person.personality = [3, 14, 15, 9, 2, 6, 5, 18]
        var contract = FakeGame.ContractValues()
        contract.team = world.roversFirst
        // Only asked when the team has no club.
        contract.fallbackTeam = world.townFirst
        contract.wage = 23_456
        // The low 23 bits are the index of the team the player is in, here the reserves.
        contract.teamIndex = 0x0080_1268
        contract.end = (day: 151, year: 2029)
        // Only the low 9 bits of a listing's day are the day.
        contract.listed = (day: 0x0200 | 45, year: 2027)
        contract.statusFlags = 0x43
        contract.clauses = [(2_500_000, 0), (0xffff_ffff, 0), (1_800_000, 16), (900_000, 18), (4_444, 7)]
        values.person.contract = contract
        let record = make(world, values)

        let database = try world.game.read()
        XCTAssertEqual(database.players.count, 1)
        XCTAssertEqual(database.staff.count, 0)
        let player = try XCTUnwrap(database.players.first)
        XCTAssertEqual(player.block, record.address)

        XCTAssertEqual(player.index, 4_321)
        XCTAssertEqual(player.uid, 98_765_432)
        XCTAssertEqual(player.flags, 0x0c)
        XCTAssertFalse(player.isWoman)

        XCTAssertEqual(player.fullName, "Mock Anders Playerson")
        XCTAssertEqual(player.firstName, "Mock")
        XCTAssertEqual(player.secondName, "Playerson")
        XCTAssertEqual(player.commonName, "")
        XCTAssertEqual(player.name, "Mock Playerson")
        XCTAssertEqual(player.nation, "Fixtureland")
        XCTAssertEqual(player.birthDay, 200)
        XCTAssertEqual(player.birthYear, 2004)
        XCTAssertEqual(player.pers, [3, 14, 15, 9, 2, 6, 5, 18])
        XCTAssertEqual(player.traitBits, 0x8000_0000_0000_0005)

        XCTAssertEqual(player.ca, 143)
        XCTAssertEqual(player.pa, 167)
        XCTAssertEqual(player.value, 12_345_678)
        XCTAssertEqual(player.pos, values.positions)
        XCTAssertEqual(player.raw, values.attributes)
        XCTAssertEqual(player.height, 187)
        XCTAssertEqual(player.topRoles, [11, 22, 33, 41, 52, 63])
        XCTAssertNil(player.injuries)

        XCTAssertEqual(player.wage, 23_456)
        XCTAssertEqual(player.teamIndex, 0x0080_1268)
        XCTAssertEqual(player.endDay, 151)
        XCTAssertEqual(player.endYear, 2029)
        XCTAssertEqual(player.listedDay, 45)
        XCTAssertEqual(player.listedYear, 2027)
        XCTAssertEqual(player.statusFlags, 0x43)
        XCTAssertEqual(player.releaseClause, 2_500_000)
        XCTAssertEqual(player.releaseForeign, 1_800_000)
        XCTAssertEqual(player.releaseDomestic, 900_000)

        XCTAssertEqual(player.club, "Mockport")
        XCTAssertEqual(player.clubFull, "Mockport Rovers FC")
        XCTAssertEqual(player.clubObject, world.rovers)
        XCTAssertEqual(player.league, "Mock League One")
        XCTAssertEqual(player.clubNation, "Mockovia")
        XCTAssertEqual(player.region, "Made-up Continent")
        XCTAssertEqual(player.areaRecord, world.area)
        XCTAssertEqual(player.area, "Australasia")
        XCTAssertEqual(player.squad, "Reserves")
        XCTAssertEqual(player.loanClub, "")
    }

    func testReadsEveryFieldOfAMemberOfStaff() throws {
        let world = World()
        // As FM Starship shows them, 1-20. FM keeps the 14th and the last 26 as 1-100.
        let shown = (0..<52).map { UInt8(1 + $0 * 7 % 20) }
        var values = FakeGame.StaffValues()
        values.ca = 131
        values.pa = 152
        values.reputation = (current: 6_500, home: 7_200, world: 5_100)
        values.attributes = shown.indices.map { $0 == 13 || $0 >= 26 ? shown[$0] * 5 : shown[$0] }
        values.person.index = 7_001
        values.person.uid = 55_501
        values.person.flags = 0x08
        values.person.fullName = "Fake Coachman"
        values.person.firstName = "Fake"
        values.person.secondName = "Coachman"
        values.person.commonName = "Fakey"
        values.person.nation = world.mockovia
        values.person.birth = (day: 31, year: 1975)
        values.person.personality = [12, 7, 19, 4, 16, 11, 8, 1]
        var contract = FakeGame.ContractValues()
        // No team of its own, so the club and the squad come from the other one.
        contract.fallbackTeam = world.townUnder23
        contract.wage = 4_800
        contract.job = 2
        contract.secondJob = 12
        contract.end = (day: 181, year: 2028)
        values.person.contract = contract
        let record = world.game.staff(values)

        let database = try world.game.read()
        XCTAssertEqual(database.staff.count, 1)
        XCTAssertEqual(database.players.count, 0)
        let staff = try XCTUnwrap(database.staff.first)
        XCTAssertEqual(staff.block, record.address)

        XCTAssertEqual(staff.index, 7_001)
        XCTAssertEqual(staff.uid, 55_501)
        XCTAssertEqual(staff.flags, 0x08)
        XCTAssertFalse(staff.isWoman)

        XCTAssertEqual(staff.fullName, "Fake Coachman")
        XCTAssertEqual(staff.firstName, "Fake")
        XCTAssertEqual(staff.secondName, "Coachman")
        XCTAssertEqual(staff.commonName, "Fakey")
        XCTAssertEqual(staff.name, "Fakey")
        XCTAssertEqual(staff.nation, "Mockovia")
        XCTAssertEqual(staff.birthDay, 31)
        XCTAssertEqual(staff.birthYear, 1975)
        XCTAssertEqual(staff.pers, [12, 7, 19, 4, 16, 11, 8, 1])

        XCTAssertEqual(staff.ca, 131)
        XCTAssertEqual(staff.pa, 152)
        XCTAssertEqual(staff.repCurrent, 6_500)
        XCTAssertEqual(staff.repHome, 7_200)
        XCTAssertEqual(staff.repWorld, 5_100)
        XCTAssertEqual(staff.attr, shown)

        XCTAssertEqual(staff.wage, 4_800)
        XCTAssertEqual(staff.job, "Coach")
        XCTAssertEqual(staff.secondJob, 12)
        XCTAssertEqual(staff.endDay, 181)
        XCTAssertEqual(staff.endYear, 2028)

        XCTAssertEqual(staff.club, "Fixture Town")
        XCTAssertEqual(staff.clubFull, "Fixture Town AFC")
        XCTAssertEqual(staff.clubObject, world.town)
        XCTAssertEqual(staff.league, "Mock Under-23 League")
        XCTAssertEqual(staff.clubNation, "Fixtureland")
        XCTAssertEqual(staff.region, "Made-up Continent")
        XCTAssertEqual(staff.areaRecord, world.area)
        XCTAssertEqual(staff.squad, "U23")
    }

    /// A player/manager is a player and a member of staff: one record, read twice. The staff side's CA, PA, reputation
    /// and attributes are its own, and its job is the staff job the contract gives alongside playing.
    func testReadsAPlayerManagerAsAPlayerAndAMemberOfStaff() throws {
        let world = World()
        var player = FakeGame.PlayerValues()
        player.ca = 84
        player.pa = 97
        player.person.index = 18_115
        player.person.uid = 77_001
        player.person.commonName = "Mock Playmanager"
        player.person.birth = (day: 90, year: 1998)
        player.person.contract?.team = world.roversFirst
        player.person.contract?.wage = 3_100
        // Bit 0 is "plays", and 16 is Manager.
        player.person.contract?.job = 17
        let shown = (0..<52).map { UInt8(1 + $0 * 3 % 20) }
        var staff = FakeGame.StaffValues()
        staff.ca = 128
        staff.pa = 150
        staff.reputation = (current: 2_100, home: 2_400, world: 900)
        staff.attributes = shown.indices.map { $0 == 13 || $0 >= 26 ? shown[$0] * 5 : shown[$0] }
        let record = world.game.playerCoach(player, staff: staff)

        let database = try world.game.read()
        XCTAssertEqual(database.players.count, 1)
        XCTAssertEqual(database.staff.count, 1)
        let asPlayer = try XCTUnwrap(database.players.first), asStaff = try XCTUnwrap(database.staff.first)
        XCTAssertEqual(asPlayer.block, record.address)
        XCTAssertEqual(asStaff.block, record.address + Int64(MacLayout.PlayerCoach.staff))
        for person in [asPlayer, asStaff] as [Person] {
            XCTAssertEqual(person.index, 18_115)
            XCTAssertEqual(person.uid, 77_001)
            XCTAssertEqual(person.name, "Mock Playmanager")
            XCTAssertEqual(person.birthYear, 1998)
            XCTAssertEqual(person.clubFull, "Mockport Rovers FC")
            XCTAssertEqual(person.wage, 3_100)
        }
        XCTAssertEqual(asPlayer.ca, 84)
        XCTAssertEqual(asPlayer.pa, 97)
        XCTAssertEqual(asPlayer.squad, "First team")
        XCTAssertEqual(asStaff.ca, 128)
        XCTAssertEqual(asStaff.pa, 150)
        XCTAssertEqual(asStaff.repCurrent, 2_100)
        XCTAssertEqual(asStaff.repHome, 2_400)
        XCTAssertEqual(asStaff.repWorld, 900)
        XCTAssertEqual(asStaff.attr, shown)
        XCTAssertEqual(asStaff.job, "Manager")
    }

    /// A member of staff's contract job is even, so taking off the "plays" bit leaves it as it was.
    func testStaffJobsKeepTheirNames() throws {
        let world = World()
        for (uid, job) in [(1, 16), (2, 20), (3, 64)] as [(UInt32, UInt8)] {
            var staff = FakeGame.StaffValues()
            staff.person.uid = uid
            staff.person.index = uid
            staff.person.contract?.fallbackTeam = world.townFirst
            staff.person.contract?.job = job
            world.game.staff(staff)
        }

        let jobs = try world.game.read().staff.sorted { $0.uid < $1.uid }.map(\.job)
        XCTAssertEqual(jobs, ["Manager", "Assistant Manager", "Head of Youth Development"])
    }

    /// FM keeps a PA it hasn't settled as a negative range, and a value it doesn't know as all ones.
    func testReadsARangedPotentialAndAnUnknownValue() throws {
        let world = World()
        var player = FakeGame.PlayerValues()
        player.ca = 80
        player.pa = -85
        player.value = .max
        player.person.uid = 1
        player.person.contract?.team = world.roversFirst
        world.game.player(player)
        var staff = FakeGame.StaffValues()
        staff.ca = 90
        staff.pa = -9
        staff.person.uid = 2
        staff.person.contract?.fallbackTeam = world.townFirst
        world.game.staff(staff)

        let database = try world.game.read()
        XCTAssertEqual(database.players.first?.pa, 155)
        XCTAssertEqual(database.players.first?.value, 0)
        XCTAssertEqual(database.staff.first?.pa, 165)
    }

    /// The team a player is with now: another club's means a loan, and another of his own club's is his squad.
    func testCurrentTeamGivesTheLoanClubOrTheSquad() throws {
        let world = World()
        var loaned = FakeGame.PlayerValues()
        loaned.person.uid = 1
        loaned.person.contract?.team = world.roversFirst
        loaned.currentTeam = world.townFirst
        world.game.player(loaned)
        var reserve = FakeGame.PlayerValues()
        reserve.person.uid = 2
        reserve.person.contract?.team = world.roversFirst
        reserve.currentTeam = world.roversReserves
        world.game.player(reserve)

        let players = try Dictionary(uniqueKeysWithValues: world.game.read().players.map { ($0.uid, $0) })
        let onLoan = try XCTUnwrap(players[1]), atHome = try XCTUnwrap(players[2])
        XCTAssertEqual(onLoan.club, "Mockport")
        XCTAssertEqual(onLoan.loanClub, "Fixture Town")
        XCTAssertEqual(onLoan.loanClubFull, "Fixture Town AFC")
        XCTAssertEqual(onLoan.loanClubObject, world.town)
        XCTAssertEqual(atHome.club, "Mockport")
        XCTAssertEqual(atHome.loanClub, "")
        XCTAssertEqual(atHome.squad, "Reserves")
    }

    /// FM keeps a club's men and women as two clubs, often with one name. Who is a woman and which clubs are women's are
    /// both read, and where the names clash, the women's side gets a name of its own.
    func testTellsWomenAndWomensClubsApart() throws {
        let world = World()
        let womens = world.game.club(full: "Mockport Rovers FC", short: "Mockport", nation: world.mockovia, womens: true)
        let womensFirst = world.game.team(club: womens, index: 0x3001, type: 0, competition: 0)
        var man = FakeGame.PlayerValues()
        man.person.uid = 1
        man.person.contract?.team = world.roversFirst
        world.game.player(man)
        var woman = FakeGame.PlayerValues()
        woman.person.uid = 2
        woman.person.flags = 0
        woman.person.woman = true
        woman.person.contract?.team = womensFirst
        world.game.player(woman)

        let database = try world.game.read()
        let players = Dictionary(uniqueKeysWithValues: database.players.map { ($0.uid, $0) })
        let men = try XCTUnwrap(players[1]), women = try XCTUnwrap(players[2])
        XCTAssertTrue(database.knowsSides)
        XCTAssertFalse(men.isWoman)
        XCTAssertTrue(women.isWoman)
        XCTAssertEqual(men.club, "Mockport")
        XCTAssertEqual(men.clubFull, "Mockport Rovers FC")
        XCTAssertEqual(women.clubObject, womens)
        XCTAssertEqual(women.club, "Mockport Women")
        XCTAssertEqual(women.clubFull, "Mockport Rovers FC Women")
    }

    /// FM can keep a dead copy of the world, whose records still point at the live contracts. A contract names only the
    /// live person as its owner, so the copies are left out.
    func testLeavesOutADeadCopy() throws {
        let world = World()
        var player = FakeGame.PlayerValues()
        player.person.uid = 1
        player.person.contract?.team = world.roversFirst
        let livePlayer = world.game.player(player)
        var staff = FakeGame.StaffValues()
        staff.person.uid = 2
        staff.person.contract?.fallbackTeam = world.townFirst
        let liveStaff = world.game.staff(staff)
        _ = world.game.copy(livePlayer)
        _ = world.game.copy(liveStaff)

        let database = try world.game.read()
        XCTAssertEqual(database.players.map(\.block), [livePlayer.address])
        XCTAssertEqual(database.staff.map(\.block), [liveStaff.address])
    }

    /// FM can leave copies whose contract field holds something that isn't a pointer, such as text. They're left out,
    /// rather than read as contracted players.
    func testLeavesOutACopyWhoseContractCantBeRead() throws {
        let world = World()
        var player = FakeGame.PlayerValues()
        player.person.uid = 1
        player.person.contract?.team = world.roversFirst
        let live = world.game.player(player)
        var junk = FakeGame.PlayerValues()
        junk.person.uid = 0
        junk.person.contract = nil
        let copy = world.game.player(junk)
        world.game.overwrite(copy.address + Int64(MacLayout.Player.person + MacLayout.Person.contract), with: 0x0042_002e_0049_0053)

        let database = try world.game.read()
        XCTAssertEqual(database.players.map(\.block), [live.address])
    }

    /// Such copies don't count against their region: two of them beside one contracted player mustn't make the region look
    /// dead, which would leave out its free agents too.
    func testCopiesWhoseContractCantBeReadDontLeaveOutFreeAgents() throws {
        let world = World()
        var player = FakeGame.PlayerValues()
        player.person.uid = 1
        player.person.contract?.team = world.roversFirst
        let live = world.game.player(player)
        var free = FakeGame.PlayerValues()
        free.person.uid = 3
        free.person.commonName = "Made-up Free Agent"
        free.person.contract = nil
        let freeAgent = world.game.player(free)
        for _ in 0..<2 {
            var junk = FakeGame.PlayerValues()
            junk.person.uid = 0
            junk.person.contract = nil
            let copy = world.game.player(junk)
            world.game.overwrite(copy.address + Int64(MacLayout.Player.person + MacLayout.Person.contract), with: 0x0042_002e_0049_0053)
        }

        let database = try world.game.read()
        XCTAssertEqual(Set(database.players.map(\.block)), [live.address, freeAgent.address])
    }

    /// A dead copy of a player/manager points at the live contract too, which names only the live record, so neither its
    /// player side nor its staff side is read.
    func testLeavesOutADeadCopyOfAPlayerManager() throws {
        let world = World()
        var player = FakeGame.PlayerValues()
        player.person.contract?.team = world.roversFirst
        player.person.contract?.job = 17
        let live = world.game.playerCoach(player, staff: FakeGame.StaffValues())
        _ = world.game.copy(live)

        let database = try world.game.read()
        XCTAssertEqual(database.players.map(\.block), [live.address])
        XCTAssertEqual(database.staff.map(\.block), [live.address + Int64(MacLayout.PlayerCoach.staff)])
    }

    /// With no contract there's no staff job, so a free agent FM has given a staff record is a player only.
    func testReadsAFreeAgentWithAStaffRecordAsAPlayer() throws {
        let world = World()
        var player = FakeGame.PlayerValues()
        player.person.commonName = "Made-up Veteran"
        player.person.contract = nil
        let record = world.game.playerCoach(player, staff: FakeGame.StaffValues())

        let database = try world.game.read()
        XCTAssertEqual(database.players.map(\.block), [record.address])
        XCTAssertEqual(database.players.first?.name, "Made-up Veteran")
        XCTAssertEqual(database.staff.count, 0)
    }

    func testReadsAFreeAgent() throws {
        let world = World()
        var player = FakeGame.PlayerValues()
        player.person.commonName = "Made-up Free Agent"
        player.person.contract = nil
        let record = world.game.player(player)

        let database = try world.game.read()
        XCTAssertEqual(database.players.map(\.block), [record.address])
        XCTAssertEqual(database.players.first?.name, "Made-up Free Agent")
        XCTAssertEqual(database.players.first?.club, "")
    }

    /// The check that warns, after a patch, that the numbers may be wrong. It passes on a healthy world read through the reader.
    func testAHealthyWorldPassesTheSelfCheck() throws {
        let world = World()
        for uid in 1...1000 {
            var player = FakeGame.PlayerValues()
            player.person.uid = UInt32(uid)
            player.person.index = UInt32(uid)
            player.person.commonName = "Made-up Player \(uid)"
            player.person.contract?.team = uid.isMultiple(of: 2) ? world.roversFirst : world.townFirst
            // Some are player/managers, read as players and as staff, which isn't a duplicate.
            if uid.isMultiple(of: 100) {
                player.person.contract?.job = 17
                world.game.playerCoach(player, staff: FakeGame.StaffValues())
            } else {
                world.game.player(player)
            }
        }

        let database = try world.game.read()
        XCTAssertEqual(database.players.count, 1000)
        XCTAssertEqual(database.staff.count, 10)
        XCTAssertEqual(database.checks, "PASS")
    }

    /// What every test here leans on: the made-up records fail a test when an offset lands on another field or outside its record.
    func testAMovedOffsetFails() {
        let game = FakeGame()
        withExtendedLifetime(game) {
            let record = game.record("Made-up", size: 16)
            record.set("first", 0, Int64(1))
            XCTExpectFailure("A field on top of another") {
                record.set("second", 4, Int32(2))
            }
            XCTExpectFailure("A field past the end") {
                record.set("third", 12, Int64(3))
            }
        }
    }
}
