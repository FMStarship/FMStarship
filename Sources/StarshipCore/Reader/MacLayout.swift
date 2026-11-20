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
        static let injuries = attributes - 80   // also holds the recent matches and bans, see History
        /// Relative to the start of the record. Condition and sharpness are 0-10000, and only FM's for the day in
        /// `fitnessUpdated`: FM's getters catch them up to today first.
        static let condition = 0x250
        static let sharpness = 0x254
        /// The day of the year in the low 9 bits, then the year.
        static let fitnessUpdated = 0x1f8
        /// 1-20.
        static let morale = 0x264
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

    /// ACTUAL_PLAYER_AND_NON_PLAYER: a player FM has also given a staff record, as it does for most players from about 30,
    /// and for player-coaches. The player part at the start is laid out as a player's, and the staff part as a member of
    /// staff's, around one shared person.
    enum PlayerCoach {
        static let size = 0x4a0
        static let staff = 0x278                        // read as `Staff` from here
        static let person = staff + Staff.person        // 0x370
        static let identity = staff + Staff.identity    // 0x480
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
        /// How happy a player is with his playing time, −100 to 100. A signed byte.
        static let playingTime = 0x5c
        static let secondJob = 194
    }

    /// The record `Player.injuries` points to.
    enum History {
        /// A vector of `Ban` pointers. FM removes a ban once it's served.
        static let bans = 0x18
        static let matches = 88
    }

    /// One suspension, 0x20 bytes.
    enum Ban {
        static let size = 0x20
        /// The football association's nation, by its index as at `Nation.index`. Not always a nation FM Starship reads.
        static let association = 0
        /// Which of that association's rule sets: in Norway 6 is the league, 5 the cup.
        static let scope = 5
        /// The `BanMatch` of a red card, 0 for a ban for bookings.
        static let match = 8
        /// The day of the year in the low 9 bits, then the year.
        static let day = 0x10
        static let year = 0x12
        /// 0 for bookings, 2 or 6 for the two kinds of red card, which aren't told apart.
        static let kind = 0x1a
        static let matches = 0x1c
        static let served = 0x1d
        static let bookings: UInt8 = 0
        static let redCards: Set<UInt8> = [2, 6]
    }

    /// The match a red card was in, which `Ban.match` points at.
    enum BanMatch {
        /// A `FixtureName`.
        static let name: Int64 = 0
        static let home: Int64 = 8
        static let away: Int64 = 0x10
    }

    /// `History.matches` points at a vector of these, one for each team the player has played for:
    /// `PLAYER_TEAM_FORM_CONCRETE<20>`, so only the last 20 matches for each team.
    enum FormGroup {
        static let team = 8
        static let count = 16
        static let entries = 24
        static let kept = 20
    }

    /// One match in a player's history: 0x20 bytes.
    enum FormEntry {
        static let size = 0x20
        static let opponent = 0
        /// Zero when he was in the squad but didn't play.
        static let record = 8
        /// The day of the year in the low 9 bits, then the year.
        static let day = 0x10
        static let year = 0x12
        /// The competition's database index, as at `Comp.index`.
        static let competition = 0x14
        /// Why he didn't play, when `record` is zero. 5 for a suspended player: the three suspended for a match on Molde's
        /// save on 27.1.0 had it. 12 for most of the others, on the bench or left out; what 6 and 0x4c mean isn't known.
        static let reason = 0x18
        static let suspended: UInt8 = 5
    }

    /// The player's own match record, 0x28 bytes, which `FormEntry.record` points at.
    enum MatchRecord {
        static let size = 0x28
        /// xG × 100, for outfield players only: a goalkeeper's means something else.
        static let xG = 4
        /// 0 for a goalkeeper.
        static let position = 6
        static let goals = 7
        static let assists = 0x0b
        static let red = 0x10
        static let minutes = 0x15
        /// Rating × 10.
        static let rating = 0x16
        /// 2 when sent off for a second yellow.
        static let yellow = 0x24
    }

    /// `sicomps::FIXTURE`: one match, played or not.
    enum Fixture {
        static let size = 0x58
        static let home = 8
        static let away = 0x10
        static let name = 0x20
        /// The season it belongs to, by the year it starts in.
        static let season = 0x30
        /// 0-based, for league fixtures.
        static let round = 0x3b
        /// The day of the year in the low 9 bits and the kick-off code above them, then the year.
        static let date = 0x4c
        static let year = 0x4e
    }

    /// `sicomps::FIXTURE_RESULT`: a fixture with the result after it.
    enum FixtureResult {
        static let size = 0x80
        /// Rises with the date. 0xffffffff in a half-made copy, whose score reads 0-0.
        static let matchNumber = 0x58
        static let attendance = 0x5c
        static let homeGoals = 0x64
        /// 0xff unless it's the second leg of a two-legged tie.
        static let homeAggregate = 0x67
        static let awayGoals = 0x69
        static let awayAggregate = 0x6c
        /// A vector of `Goal`s.
        static let goals = 0x78
    }

    /// One entry of a result's goal list, 16 bytes.
    enum Goal {
        static let size = 16
        static let scorer = 0
        /// 0xffffffff for none.
        static let assist = 4
        /// 0 home, 1 away.
        static let side = 12
        /// 0, 1 and 2 count towards the score, 3 doesn't.
        static let kind = 13
        static let minute = 14
        static let addedMinute = 15
        static let countedKinds: Set<UInt8> = [0, 1, 2]
    }

    /// `db::FIXTURE_NAME`, which a fixture's `name` points at.
    enum FixtureName {
        static let comp: Int64 = 0x18
        /// A `db::STAGE_NAME`, whose text is at `stageText`.
        static let stage: Int64 = 0x20
        static let stageText: Int64 = 0x18
    }

    /// `db::COMP`, which `Team.competition` and `FixtureName.comp` point at. Its name is at `competitionName`.
    enum Comp {
        static let index: Int64 = 8
        /// The `sicomps::ACTUAL_COMP` that runs it this season.
        static let actual: Int64 = 0xb0
    }

    enum ActualComp {
        /// A vector of stage pointers. A league's table is its `sicomps::LEAGUE_STAGE`.
        static let stages: Int64 = 0x1d8
    }

    enum LeagueStage {
        /// A vector of `TableRow` pointers, in table order.
        static let rows: Int64 = 0xc0
    }

    /// One club's row in a league table, 0x100 bytes. Each record is 0x18 bytes: u16 goals for, u16 against,
    /// u16 points, u8 played, then won, drawn and lost at +8, +9 and +10.
    /// +0x50 and +0x68 hold two more records whose meaning isn't known (+0x68 isn't the last five: P6 for a club on 21
    /// played), so they aren't read.
    enum TableRow {
        static let size = 0x100
        static let overall = 0x08
        static let home = 0x20
        static let away = 0x38
        static let team = 0x88
        enum Record {
            static let goalsFor = 0, goalsAgainst = 2, points = 4, played = 6, won = 8, drawn = 9, lost = 10
        }
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
        /// What `Ban.association` names it by.
        static let index = 8
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
        /// FM's `transfer_budget`: what's left to spend, which FM shows as Available. The next word is the budget as
        /// the board last set it, before the signings and sales since.
        static let transferBudget = 0x7c4
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
        static let sessionArrays: [Int64] = [0x1010, 0x21e8, 0x33a8]
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
