@preconcurrency import StarshipAnalysis
@preconcurrency import StarshipCore
import StarshipFiles
import SwiftUI

struct FeatureCheck: Identifiable {
    let name: String
    let works: Bool
    let detail: String
    var id: String { name }
}

/// Help > Compatibility. Asks the game one sample question per feature, so a line only says ✓ if the feature
/// actually answered on this build.
enum Compatibility {
    static func check(_ db: Database, session: AnalysisSession?) -> [FeatureCheck] {
        let live = GameRules.engine != nil
        let missing = live ? "Not available on this version" : "Needs the live game"
        var checks: [FeatureCheck] = []
        func add(_ name: String, _ works: Bool, _ detail: String, otherwise: String? = nil) {
            checks.append(FeatureCheck(name: name, works: works, detail: works ? detail : otherwise ?? missing))
        }

        add("Players and staff", db.checks == "PASS",
            "\(db.players.count.formatted()) players, \(db.staff.count.formatted()) staff; self-checks pass",
            otherwise: "Self-checks: \(db.checks)")
        add("Ages (game date)", db.gameDate != nil, db.gameDate.map { "Game date \(GameDateText.day($0))" } ?? "", otherwise: "Game date not found")
        add("Contracts and money", db.players.contains { $0.wage > 0 }, "Wages, contract end, value, release clauses", otherwise: "Not found")
        add("Squads", db.players.contains { !$0.squad.isEmpty }, "Player and staff squads", otherwise: "Not found")
        add("Regions", db.players.contains { !$0.region.isEmpty }, "Continents and the game's regions", otherwise: "Not found")
        add("Human managers", !db.humanClubs.isEmpty, db.humanClubs.map(\.name).joined(separator: ", "), otherwise: "None found")
        add("Men's and women's football", db.knowsSides, "Your club is only offered players from its own side",
            otherwise: "Not known here, so suggestions can include both")
        add("Your budgets", !db.budgets.isEmpty, "Transfer budget and wage room", otherwise: "Not found")

        let team = session?.club.team ?? 0
        let engine = GameRules.engine
        let player = db.players.first { $0.block != 0 && !$0.club.isEmpty && $0.clubFull != session?.club.name }
        let injured = db.players.first { $0.block != 0 && $0.injury != nil }
        let staff = db.staff.first { $0.block != 0 && !$0.job.isEmpty && $0.clubFull != session?.club.name }

        func answered<Value>(_ ask: (GameRulesEngine) -> Value?) -> Bool {
            engine.map { ask($0) != nil } ?? false
        }

        add("Player interest", answered { engine in player.flatMap { engine.interest(player: $0, team: team) } },
            "The game's own check")
        add("Staff interest", session?.checks.canCheckStaffInterest == true
            && answered { engine in staff.flatMap { engine.staffInterest(staff: $0, team: team, level: GameChecks.staffLevels[0]) } },
            "Who would join your first team, reserves and youth team")
        add("Role ratings (stars)", answered { engine in player.flatMap { engine.roleRows(player: $0, team: team) } },
            "The game's own role stars")
        add("Injury days", engine?.supportsInjuryDays == true && answered { engine in injured.flatMap { engine.injuryReturnDays(player: $0) } },
            "The game's own \"returns in N days\"", otherwise: "Estimated from the injury dates")
        add("Season stats", answered { engine in player.flatMap { engine.seasonStats(player: $0, season: GameScope.clubTotal) } },
            "The game's own figures")
        add("Form", answered { engine in player.flatMap { engine.form(player: $0) } }, "Last five ratings")
        add("Preferred job", answered { engine in staff.flatMap { engine.jobPreferences(staff: $0) } },
            "How keen staff are on each job")
        add("Staff numbers", StaffLimits.read(team: team) != nil, "The board's staff limits (Recommended staff)")
        add("FM's tactics", FMData.library != nil, FMData.library.map { "\($0.presets.count) presets, read from the game's files" } ?? "", otherwise: "FM's tactic files couldn't be read")
        add("Your tactic", db.tactics[team] != nil, db.tactics[team].map { "\($0.shape(in: FMData.library)), with your roles and XI" } ?? "Your formation, roles and XI (Squad planner)")
        return checks
    }
}

private enum GameDateText {
    private static let format: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_GB")
        format.timeZone = GameDate.calendar.timeZone
        format.dateFormat = "dd/MM/yyyy"
        return format
    }()

    static func day(_ date: Date) -> String { format.string(from: date) }
}

struct CompatibilityWindow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appColors) private var colors
    @State private var checks: [FeatureCheck] = []
    @State private var working = false

    private var isSnapshot: Bool { GameRules.engine == nil }

    var body: some View {
        Group {
            if let database = model.database {
                VStack(alignment: .leading, spacing: 10) {
                    Text(database.build.isEmpty ? database.source : database.build).font(.headline)
                    Text("Source: \(database.source)").font(.callout).foregroundStyle(.secondary)
                    summary
                    List(checks) { check in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: check.works ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(Color(nsColor: check.works ? colors.good : colors.bad))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(check.name)
                                Text(check.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.inset)
                    .overlay {
                        if working { ProgressCard(text: "Asking the game...", onCancel: nil) }
                    }
                }
                .padding(16)
            } else {
                ContentUnavailableView("Press Load Save first", systemImage: "questionmark.diamond",
                                       description: Text("With Football Manager running and a save loaded, this shows what works on your version of the game."))
            }
        }
        .frame(minWidth: 480, minHeight: 500)
        .task(id: model.database?.readAt) { await run() }
    }

    @ViewBuilder
    private var summary: some View {
        let off = checks.filter { !$0.works }.map(\.name)
        if !checks.isEmpty {
            if off.isEmpty {
                Text("Everything works on this version.")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Off here: " + off.joined(separator: ", ") + ".").fontWeight(.medium)
                    Text(isSnapshot
                         ? "This is a snapshot, so nothing can ask the game. Press Load Save with the game running to bring those back."
                         : "Anything marked with a cross is switched off rather than showing wrong numbers.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func run() async {
        guard let database = model.database else { return }
        working = true
        let session = model.session
        checks = await offMain { Compatibility.check(database, session: session) }
        working = false
    }
}
