/// Where FM27 for Mac keeps things. The record contents match FM Moleman's Windows offsets; the
/// differences come from C++ ABI: Itanium places the person base differently and moves the
/// identity base class (index, uid, flags) to the end of the object.
enum MacLayout {
    enum Player {
        static let size = 0x3a8
        static let attributes = 0x140   // Windows "block": positions, attributes, CA, PA, value
        /// A vector of `BookingCount` pointers: his yellow cards under each rule set he has played under this season.
        static let bookingCounts = 0x08
        static let person = 0x278
        static let identity = 0x388
        static let currentTeam = attributes - 24
        static let injuries = attributes - 80   // also holds the recent matches and bans, see History
        /// Relative to the start of the record. Condition and sharpness are 0-10000, as FM stored them on the day in
        /// `fitnessUpdated`. They were told apart right after a match, when FM writes both for everyone who played:
        /// condition fell with the minutes played and sharpness went to 100 (FM 27.1.0, the user's screens agreeing).
        static let condition = 0x254
        static let sharpness = 0x250
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
        /// The clauses are 8 bytes each: the amount, u32, in pounds (0xffffffff for none); the count it needs, u16; the
        /// code, u16. Code 10 is goals in the season: Kristian Lonebu's at 10 came into force the day after his 10th league
        /// goal of 2029, his 9 in Europe by then not counting, and it was still in his contract, unchanged, four weeks on.
        static let seasonGoalsClause = 10
        /// The release clauses: any club, foreign clubs, clubs in his own nation.
        static let releaseClauses: Set<Int> = [0, 16, 18]
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
        /// u16: the rules index of the rule set it was given under, as `DisciplineRules.index`. 200 on every Norwegian league
        /// ban and 201 on every cup ban on Molde's save (FM 27.1.0).
        static let rules = 0x14
        /// The yellow-card count it came at: 4, 6 or 8 for a Norwegian league ban for bookings, 2 or 3 for a cup one, 1 for a
        /// red card.
        static let bookingsAt = 0x18
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
        /// Why he didn't play, when `record` is zero, from Molde's save on 27.1.0, checked against three matches' squads as
        /// FM stored them: 12 named on the bench and not brought on, 0 left out of the matchday squad, 5 suspended, 6 injured
        /// (one proof). What 4, 13 and 0x4c mean isn't known.
        static let reason = 0x18
        static let notInSquad: UInt8 = 0
        static let suspended: UInt8 = 5
        static let injured: UInt8 = 6
        static let unusedSubstitute: UInt8 = 12
    }

    /// The player's own match record, 0x28 bytes, which `FormEntry.record` points at.
    enum MatchRecord {
        static let size = 0x28
        /// xG × 100 for an outfield player. A goalkeeper's is the xG of the shots he faced, which adds up to the
        /// opponent's in the match's summary.
        static let xG = 4
        /// 0 for a goalkeeper.
        static let position = 6
        static let goals = 7
        static let shots = 0x09
        static let shotsOnTarget = 0x0a
        static let assists = 0x0b
        static let fouls = 0x0d
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
        /// An own goal: its scorer plays for the other side.
        static let ownGoalKind: UInt8 = 1
    }

    /// The summary of one of the user's club's matches that FM keeps in each post-match news item about it, such as
    /// `MATCH_REPORT_NEWS` (at +0x1e0), 0xe0 bytes after the item's `db::SCORELINE`. Found by `MatchStatsReader`'s sweep.
    enum MatchSummary {
        /// The user's club's team, home or away, then the opponent's.
        static let team = 0x10
        static let opponent = 0x18
        /// u32 possession %, ours then theirs, which add up to 100.
        static let possession = 0x20
        /// u16 xG × 100, ours then theirs.
        static let xG = 0x28
        /// u8 each, ours then theirs.
        static let fouls = 0x2c
        static let shots = 0x2d
        static let shotsOnTarget = 0x2e
        static let theirFouls = 0x2f
        static let theirShots = 0x30
        static let theirShotsOnTarget = 0x31
        static let goals = 0x37
        /// 0 when the user's club was at home, 1 away.
        static let away = 0x38
        static let theirGoals = 0x3c
        /// The match's `GAME_MATCH_STATS`, in some copies, whose `result` is its `sicomps::FIXTURE_RESULT`.
        static let matchStats = 0x68
        static let matchStatsResult: Int64 = 0x18
        static let size = 0x70
        /// The SCORELINE's date, before the summary: u16 day of the year, then u16 year.
        static let day = -0xc4
        static let year = -0xc2
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
        /// u8, FM's type of competition. Read on FM 27.1.0's Molde save on 21 Nov 2026 for all 257 competitions its fixtures
        /// name: club friendlies (pre-season, testimonials, the Bosman tournament) are 9, and friendlies between national
        /// teams of every age 24. No league, cup, continental, international or youth competition has either.
        static let type: Int64 = 0xf8
        static let friendlyTypes: Set<UInt8> = [9, 24]
        /// Every other type seen on that save: 0 and 1 leagues, 2 to 5 cups and super cups, 6, 7, 10, 11, 12 and 15 to 20
        /// international competitions, 21 and 22 continental, 25, 27 and 35 to 41 youth. A type not in either set isn't known.
        static let competitiveTypes: Set<UInt8> = [0, 1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 15, 16, 17, 18, 19, 20, 21, 22, 25, 27,
                                                   35, 36, 37, 38, 39, 41]
    }

    enum ActualComp {
        /// A vector of stage pointers. A league's table is its `sicomps::LEAGUE_STAGE`.
        static let stages: Int64 = 0x1d8
        /// i8: which entry of `CompRules.list` the competition plays under, -1 for none (friendlies, some youth and
        /// regional cups). The path FM's own "one booking from a ban" check takes.
        static let rulesSlot: Int64 = 0x48
        /// An object FM Starship doesn't name, whose `CompRules.holder` holds the list of rule sets.
        static let rulesOwner: Int64 = 0x388
        /// i8: which entry of `CompRules.fixtureRules` holds the competition's squad rules, -1 for none. FM's import code
        /// writes it as it adds the competition's `FixtureRules`. Eliteserien 0, the Champions League 1 in UEFA's list.
        static let fixtureRulesSlot: Int64 = 0x49
    }

    /// From `ActualComp.rulesOwner` to the rule sets a competition can play under.
    enum CompRules {
        static let holder: Int64 = 0x1f0
        /// A vector of `DisciplineRules` pointers, the same objects as `Discipline.rules` holds.
        static let list: Int64 = 0x48
        /// A vector of `FixtureRules` pointers.
        static let fixtureRules: Int64 = 0x60
    }

    /// `sicomps::FIXTURE_RULES`, 0x138 bytes with no vtable: among other things, the squad rules of the competitions that play
    /// under it.
    enum FixtureRules {
        /// A pointer to a vector of `SquadRule` pointers: the rules now. Empty for a cup with none.
        static let squadRules: Int64 = 0x70
        /// The `ActualComp.rulesOwner` it belongs to.
        static let owner: Int64 = 0x88
        /// u8, its own entry in `CompRules.fixtureRules`.
        static let slot: Int64 = 0x120
        /// i8, FM's squad-selection group, which FM's per-player rule value is asked with: Eliteserien 8, the Champions
        /// League 0, -1 for none.
        static let group: Int64 = 0x125
    }

    /// `SQUAD_SELECTION_RULE`, 0x20 bytes: one rule as a type FM's own table names, a limit and a direction.
    enum SquadRule {
        static let size = 0x20
        /// 0x18 bytes of a condition, zero for every Norwegian and UEFA rule. In some American sets it holds a short tag,
        /// which looks like it limits the rule to one kind of team.
        static let condition = 0
        static let conditionSize = 0x18
        /// i32.
        static let limit = 0x18
        /// u16, a type in FM's table at `RulesEngine.Mac27.squadRuleNames`.
        static let type = 0x1c
        /// i8: -1 at most, 0 exactly, 1 at least, as FM's table at `RulesEngine.Mac27.squadRuleDirections` names them
        /// less_than, equals and more_than. Molde's squad sits exactly at three of its maximums and minimums, which a strict
        /// "less than" would make breaches, and FM's one text for these rules says "Maximum of".
        static let direction = 0x1e
    }

    /// `GAME_DISCIPLINE`, FM's one holder of disciplinary rule sets, reached from `RulesEngine.Mac27.disciplineGlobal`.
    enum Discipline {
        /// The path from the global's object: [[global] + holder] + object.
        static let holder: Int64 = 0x158
        static let object: Int64 = 0x70
        /// A vector of `DisciplineRules` pointers, by rules index.
        static let rules: Int64 = 0x08
    }

    /// `sicomps::DISCIPLINE_RULES`, one rule set, 0xa0 bytes with no vtable. Which counts bring a ban isn't stored as numbers:
    /// FM works them out from a sequence type, so FM Starship asks FM's own function.
    enum DisciplineRules {
        static let size = 0xa0
        /// u16, its own rules index: 281 of 281 on Molde's save.
        static let index: Int64 = 0x3c
        /// 0 for a plain count of yellow cards. Others count points or a window of matches, which FM Starship hasn't checked.
        static let countType: Int64 = 0x70
        static let plainCount: UInt8 = 0
    }

    /// `sicomps::PLAYER_BOOKING_COUNT`, 16 bytes: a player's count under one rule set. For a plain count it's the season's
    /// yellow cards under it, at any club, not reset by a ban, and without the two yellows of a sending-off.
    enum BookingCount {
        static let size = 16
        /// i16.
        static let rules = 8
        /// u8.
        static let count = 0x0a
    }

    enum LeagueStage {
        /// A vector of `TableRow` pointers, in table order.
        static let rows: Int64 = 0xc0
        /// The stage's `LeagueSettings`.
        static let settings: Int64 = 0xf0
    }

    /// `sicomps::LEAGUE_SETTINGS`, a league stage's settings. Read on FM 27.1.0's Molde save on 21 Nov 2026 for the league
    /// stages of the competitions its fixtures name.
    enum LeagueSettings {
        /// The `db::STAGE_NAME` the stage's fixtures name at `FixtureName.stage`: the Champions League's, Europa League's and
        /// Conference League's league phases share one ("ligafase"). Null for a league whose fixtures name no stage, such as
        /// Eliteserien.
        static let stageName: Int64 = 0x28
        /// u8, how many clubs the stage has: 36 for each league phase, 16 for Eliteserien.
        static let clubs: Int64 = 0x87
        /// Four u8 counts of places: from the top, straight on (promotion, or the next stage) and a play-off for it; from the
        /// bottom, a relegation play-off and relegation. Eliteserien 0 0 1 2, 1. divisjon 2 4 1 2, Ligue 2 2 3 1 2, League One
        /// 2 4 0 4, League Two 3 4 0 2, all as their rules have it. The Champions, Europa and Conference League's league
        /// phases 8 16 0 0 (1-8 to the round of 16, 9-24 to the knockout play-offs), the women's Champions League's 4 8 0 0.
        /// Some competitions run a play-off FM doesn't count here: Serie B's six-club play-off reads 0.
        static let places: Int64 = 0x90
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

    /// A TACTIC_EDIT_SESSION holds three PREPARED_TACTICS_CREATOR_ARRAYs: the user's first and second elevens are the
    /// second and third. The first was meant to be the next opponent, but on Molde's save it was an empty 4-4-2 in every
    /// session. Each lists its players and points at a TACTICS_CREATOR.
    enum Tactic {
        static let sessionOwner = 8
        static let sessionArrays: [Int64] = [0x1010, 0x21e8, 0x33a8]
        static let arrayCreators: Int64 = 8
        /// 26 database indexes (`Identity.index`): the eleven in the creator's order, then the substitutes in bench order.
        /// `empty` for a place with nobody. The tactics screen's copy keeps the user's gaps on the bench; FM's copy for a
        /// match is closed up, and FM names only as many substitutes as the competition allows, in this order.
        static let arrayPlayers: Int64 = 0x28
        static let slots = 11
        static let places = 26
        static let empty: UInt32 = 0xffff_ffff
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

    /// SCOUT_TEAM_REPORT_NEWS, FM's opposition report as a news item. It holds two GAME_TACTIC_INFOs, which were the same
    /// on Molde's save: the scout's predicted line-up of the team it's about, as a PREPARED_TACTICS_CREATOR_ARRAY at
    /// `tacticArray` in each, read as `Tactic` reads the user's. Nothing in it found so far names the team.
    enum ScoutReport {
        /// The report's date: the day of the year in the low 9 bits, then the year, both 16-bit.
        static let day: Int64 = 0x88
        static let year: Int64 = 0x8a
        static let tactics: [Int64] = [0xa0, 0x2198]
        static let tacticArray: Int64 = 0x1008
    }

    /// The user's inbox: FM's news items for one human manager, from Molde's save on 27.1.0 (150 items over 26 days, every
    /// one checked). An item holds no text: FM writes it from the item's class and fields when it's shown.
    enum Inbox {
        /// HUMAN_NON_PLAYER: a pointer to a vector (begin, end, capacity) of pointers to the items, oldest first.
        static let items: Int64 = 0x350
        /// Common to every news item.
        static let sender: Int64 = 0x78
        /// The day of the year in the low 9 bits, then the year, both 16-bit.
        static let day: Int64 = 0x88
        static let year: Int64 = 0x8a
        /// The addressed team's database index (`Team.index`), or `world` for news FM copied in from the world's.
        static let team: Int64 = 0x8c
        static let world: UInt32 = 0xffff_ffff
        /// FM's counter, rising along the list, ties within a day included.
        static let serial: Int64 = 0x90
        /// The sender's job, as a contract's `job`: matched on eight senders.
        static let senderJob: Int64 = 0x9a
        static let header = 0xa0

        /// Fields of one class, each seen on every item of it.
        enum InjuryReport {
            static let injuredOn: Int64 = 0xc0
            /// 16-bit, in days, matching the player's own injury record.
            static let days: Int64 = 0xc8
            /// FM's injury, whose name is at `Injury.name`.
            static let injury: Int64 = 0xf8
            static let player: Int64 = 0x110
        }
        enum ContractsExpiring {
            /// A vector (begin, end) of pointers to records, one for each person whose contract runs out: 2 and 21 on the
            /// two items seen. The records hold no date.
            static let people: Int64 = 0x3a0
            /// What's read of a record: as far as the index. FM allocates them 0x50 apart, so each is at most that.
            static let size = 0x30
            /// The person's club, then a second club (unknown), the team at +0x10 for a player or +0x18 for staff, and the nation.
            static let club = 0
            /// The person's database index (`Identity.index`), matched to the person's name on all 23 records.
            static let index = 0x28
        }
        /// PLAYER_UNHAPPINESS_TRAINING_NEWS: the player, then the coach who sent it and the team (one item, and its copy).
        enum UnhappyWithTraining {
            static let player: Int64 = 0xa0
        }
        /// FINE_NEWS: the player fined, then the user, the club and its team (two items, each with a copy). The two differ
        /// only in the player and one byte, so no amount was found.
        enum Fine {
            static let player: Int64 = 0xf8
        }
        /// COACH_FEEDBACK_ON_PLAYER_NEWS_ITEM: the user, then the player the coach reports on (three items, each with a copy).
        enum CoachFeedback {
            static let player: Int64 = 0x258
        }
        enum TransferCompleted {
            static let person: Int64 = 0x140
            static let team: Int64 = 0x148
        }
        enum ComeAndGetMe {
            static let player: Int64 = 0x258
            static let team: Int64 = 0x270
        }
        /// CONTRACT_ADD_ON_ACTIVATED_NEWS (one item, and its copy): a pointer to the club's CLUB and a vector (begin, end,
        /// capacity) of pointers to the add-ons that came into force.
        enum AddOnActivated {
            static let record: Int64 = 0xa0
            static let club: Int64 = 0
            static let addOns: Int64 = 8
            /// One add-on: the player's identity, then at `clause` the 8 bytes of the clause as his contract's list holds it
            /// (`Contract.clausesBegin`), byte for byte: the amount, u32, in pounds; the count it needs, u16; its code, u16.
            static let player: Int64 = 0
            static let clause: Int64 = 0x1c
            static let size = 0x24
            /// The code of the clause for goals in a season. Kristian Lonebu's, at 10, came into force the day after his
            /// 10th league goal of 2029; his 9 in Europe by then didn't count. 920 of the 1,061 players with one are strikers.
            static let seasonGoals = 10
        }
        /// TRANSFER_OFFER_CONFIRMATION_NEWS (one item, and its copy): the person, the user's team (at +0x2f0 to +0x310, five
        /// times), the other club's team and the fee.
        enum OfferConfirmation {
            static let person: Int64 = 0x2b0
            static let team: Int64 = 0x2f0
            static let otherTeam: Int64 = 0x320
            /// u32, in pounds, four times. 122,960 for Max Urwantschky from Pisa, as in FM's transfer history entry for the
            /// move (TRANSFER_TIMELINE_EVENT +0x54) and the offer itself (FULL_TRANSFER_OFFER +0x58). Given only when the four agree.
            static let fees: [Int64] = [0x3a4, 0x3a8, 0x3bc, 0x3e0]
        }
    }

    /// One entry of FM's transfer timeline, TRANSFER_TIMELINE_EVENT: the human manager's notable moves, as FM's profile of
    /// the manager shows them. Read on Molde's save for ten moves both ways (Urwantschky from Pisa, Young from Sparta
    /// Rotterdam, Atcheson to Monaco, Løvik to Villarreal and others): the person's identity is the live one, each player
    /// sold is at the club he went to, and the fees are FM's (Urwantschky 122,960, as his offer confirmation gives it).
    enum TransferTimeline {
        static let className = "TRANSFER_TIMELINE_EVENT"
        /// As far as the fee.
        static let size = 0x58
        /// The day of the year in the low 9 bits, then the year, both 16-bit, as a news item's date.
        static let day = 0x28
        static let year = 0x2a
        /// The team the person left and the one they joined, and the person's identity subobject.
        static let fromTeam = 0x38
        static let toTeam = 0x40
        static let person = 0x48
        /// u32, in pounds.
        static let fee = 0x54
    }

    /// FM's injury, shared by everyone with one: its name, in the game's language, is a string this points at.
    enum Injury {
        static let name: Int64 = 0x20
    }

    enum Currency {
        static let name = 24
        static let symbol = 48
        static let rate = 56
    }
}
