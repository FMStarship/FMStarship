/// Where FM27 for Mac keeps things. The record contents match FM Moleman's Windows offsets; the
/// differences come from C++ ABI: Itanium places the person base differently and moves the
/// identity base class (index, uid, flags) to the end of the object.
enum MacLayout {
    enum Player {
        static let size = 0x3a8
        static let attributes = 0x140   // Windows "block": positions, attributes, CA, PA, value
        static let person = 0x278
        static let identity = 0x388
        static let currentTeam = attributes - 24
        static let injuries = attributes - 80   // also holds the recent matches, see History
        // Relative to `attributes`, unchanged from Windows.
        static let positions = 8
        static let raw = 23
        static let height = 230
        static let value = 236
        static let ca = 0x11c
        static let pa = 0x11e
        static let topRoles = 0x131
    }

    enum Staff {
        static let size = 0x228
        static let attributes = 16
        static let repCurrent = 212
        static let repHome = 214
        static let repWorld = 216
        static let ca = 218
        static let pa = 220
        static let person = 0xf8
        static let identity = 0x208
        static let jobPreferences = 0x198
    }

    /// Shared by players and staff, relative to the person subobject.
    enum Person {
        static let fullName = 0x10
        static let firstName = 0x20
        static let secondName = 0x28
        static let commonName = 0x30
        static let nation = 0x38
        static let personality = 0x40
        static let birthDay = 0x58
        static let birthYear = 0x5a
        static let contract = 0x78
        static let traits = 0x90
    }

    /// Relative to the identity subobject.
    enum Identity {
        static let index = 8
        static let uid = 12
        static let flags = 0x18
        static let sex = 0x19
        static let woman: UInt8 = 0x10
    }

    enum Contract {
        static let size = 196
        static let owner = 8   // the identity subobject of the person who holds this contract
        static let fallbackTeam = 16
        static let team = 24
        static let wage = 32
        static let job = 38
        static let teamIndex = 64
        static let endDay = 72
        static let endYear = 74
        static let listedDay = 80
        static let listedYear = 82
        static let statusFlags = 87
        static let clausesBegin = 104
        static let clausesEnd = 112
        static let secondJob = 194
    }

    /// The record `Player.injuries` points to.
    enum History {
        static let matches = 88
    }

    enum Team {
        static let index = 8
        static let type = 40
        static let club = 48
        static let competition = 80
    }

    enum Club {
        /// A byte, 1 for a women's club. FM keeps a club's men and women as two clubs.
        static let womens = 185
        static let fullName = 192
        static let shortName = 200
        static let nation = 216
    }

    enum Nation {
        static let name = 24
        static let code = 40
        static let continent = 248
        static let area = 256
    }

    enum Human {
        static let team = 64
        static let managerPerson = 0x438
        /// FM's rules are handed the identity subobject, not the start of the object.
        static let managerIdentity = 0x548
    }

    enum Finance {
        static let clubOffset = 0x150
        static let transferBudget = 0x7c8
        static let wageRoom = 0x808
        static let wageSpent = 0x814
    }

    /// TRANSFER_MANAGER keeps today's date as a day-of-year and a year, both 16-bit.
    static let gameDate = 0x7fc

    static let competitionName = 72
    static let continentName = 24

    /// A TACTIC_EDIT_SESSION holds three PREPARED_TACTICS_CREATOR_ARRAYs: the next opponent, then the
    /// user's first and second elevens. Each lists its players and points at a TACTICS_CREATOR.
    enum Tactic {
        static let sessionOwner = 8
        static let sessionArrays: [Int64] = [0x1008, 0x21d8, 0x3390]
        static let arrayCreators: Int64 = 8
        static let arrayPlayers: Int64 = 0x28
        static let slots = 11
        static let withBall: Int64 = 0x120
        static let withoutBall: Int64 = 0x440
        static let slotSize: Int64 = 0x48
        static let slotRole = 0x40
        /// The position word: one bit in FM's numbering, plus which side of a pair.
        static let left: UInt64 = 0x10_0000
        static let right: UInt64 = 0x20_0000
        /// The role word: one role bit. These three mean something else, and no role uses them.
        static let notRoles: UInt64 = 0xe0_0000
    }

    enum Currency {
        static let name = 24
        static let symbol = 48
        static let rate = 56
    }
}
