import StarshipAnalysis
import StarshipCore

extension RulesEngine: PositionalRoleEngine {
    public func roleRows(player: Player, position: Int, team: Int64) -> [RoleRow]? {
        roleTable(player: player, position: position, team: team)
    }
}

extension RulesEngine: StaffLimitsEngine {
    public func staffLimits(team: Int64) -> StaffLimits? {
        staffNumbers(team: team).map {
            StaffLimits(allowed: $0.allowed, current: $0.current, teams: $0.teams.map { StaffLimits.Team(object: $0.object, type: $0.type) },
                        teamAllowed: $0.teamAllowed, teamCurrent: $0.teamCurrent, modeA: $0.modeA, modeB: $0.modeB)
        }
    }
}
