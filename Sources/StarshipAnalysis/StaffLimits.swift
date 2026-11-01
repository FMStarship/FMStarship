import StarshipCore

/// What the board allows and who is in post, job by job: `Emu.StaffLimits`.
public struct StaffLimits {
    public static let manager = 0
    public static let assistant = 1
    public static let coach = 2
    public static let goalkeeping = 3
    public static let fitness = 4
    public static let analyst = 5
    public static let physio = 6
    public static let sportsScience = 7
    public static let assistantsCoach = 8

    /// The club-wide table, in the game's order. `fmprobe staffmap` matched each entry to its job at 600 clubs.
    public enum Club {
        public static let scouts = 0
        public static let headOfYouth = 1
        public static let loanManager = 2
        public static let technicalDirector = 3
        public static let directorOfFootball = 4
        public static let chiefScout = 5
        public static let headPhysio = 6
        public static let headOfSportsScience = 7
        public static let headPerformanceAnalyst = 8
        public static let recruitmentAnalysts = 9
        public static let setPieceCoach = 10
    }

    public struct Team: Equatable {
        public var object: Int64
        public var type: Int

        public init(object: Int64, type: Int) {
            self.object = object
            self.type = type
        }
    }

    public struct Places: Equatable {
        public var allowed: Int
        public var current: Int
        /// True when coaches, goalkeeping and fitness coaches share one pool of places.
        public var shared: Bool

        public init(allowed: Int, current: Int, shared: Bool) {
            self.allowed = allowed
            self.current = current
            self.shared = shared
        }
    }

    public var allowed: [UInt8]
    public var current: [UInt8]
    public var teams: [Team]
    public var teamAllowed: [[UInt8]]
    public var teamCurrent: [[UInt8]]
    public var modeA: Int
    public var modeB: Int

    public init(allowed: [UInt8], current: [UInt8], teams: [Team], teamAllowed: [[UInt8]], teamCurrent: [[UInt8]],
                modeA: Int, modeB: Int) {
        self.allowed = allowed
        self.current = current
        self.teams = teams
        self.teamAllowed = teamAllowed
        self.teamCurrent = teamCurrent
        self.modeA = modeA
        self.modeB = modeB
    }

    /// Which row of the per-team tables a team uses: its own, or the first when the club shares one.
    public func row(_ team: Int) -> Int {
        let perTeam: Bool
        if modeB == 2 {
            perTeam = (1...3).contains(modeA)
        } else if modeB == 1 {
            perTeam = true
        } else {
            perTeam = modeA != 2 && modeA != 3 && modeA != 1
        }
        return perTeam ? team : 0
    }

    /// The club's team at a level (0 first team, 1 reserves or B, 2 youth), or -1.
    public func teamFor(_ level: Int) -> Int {
        for (index, team) in teams.enumerated() {
            let type = team.type
            let matches: Bool
            switch level {
            case 0: matches = type == 0
            case 1: matches = type == 1 || type == 3 || type == 9 || type == 10 || (15...18).contains(type)
            default: matches = type == 11 || type == 12 || type == 21 || type == 36
            }
            if matches { return index }
        }
        return -1
    }

    public func count(team: Int, job: Int) -> Places? {
        guard team >= 0 else { return nil }
        let row = self.row(team)
        guard row < teamAllowed.count, row < teamCurrent.count else { return nil }
        let allowed = teamAllowed[row], current = teamCurrent[row]
        let shared = StaffLimits.value(allowed, StaffLimits.assistantsCoach) > 0
        if (2...4).contains(job) || (job == StaffLimits.assistant && shared) {
            var places = (2...4).reduce(0) { $0 + StaffLimits.value(allowed, $1) }
            var filled = (2...4).reduce(0) { $0 + StaffLimits.value(current, $1) }
            if shared {
                places += StaffLimits.value(allowed, 1)
                filled += StaffLimits.value(current, 1)
            }
            return Places(allowed: places, current: filled, shared: true)
        }
        return Places(allowed: StaffLimits.value(allowed, job), current: StaffLimits.value(current, job), shared: false)
    }

    /// Club-wide places for a job, by `Club`.
    public func allowedCount(_ job: Int) -> Int { StaffLimits.value(allowed, job) }
    public func currentCount(_ job: Int) -> Int { StaffLimits.value(current, job) }

    /// These tables come from the game, so a short one reads as no places rather than a crash.
    private static func value(_ table: [UInt8], _ index: Int) -> Int {
        index >= 0 && index < table.count ? Int(table[index]) : 0
    }
}

/// `InterestEngine.StaffNumbers`. `GameRulesEngine` has no such question, so an engine that can
/// answer it adopts this protocol too.
public protocol StaffLimitsEngine: AnyObject {
    func staffLimits(team: Int64) -> StaffLimits?
}

extension StaffLimits {
    /// The board's limits for a team, when the engine can tell.
    public static func read(team: Int64) -> StaffLimits? {
        guard team != 0 else { return nil }
        return (GameRules.engine as? StaffLimitsEngine)?.staffLimits(team: team)
    }
}
