@preconcurrency import StarshipAnalysis
@preconcurrency import StarshipCore
import StarshipSearch
import SwiftUI

/// Everything about one person. Several can be open at once, one window per person.
struct ProfileWindow: View {
    @EnvironmentObject private var model: AppModel
    let ref: PersonRef?

    var body: some View {
        if let ref, let person = model.person(ref) {
            ProfileContent(person: person)
                .id(ref)
                .navigationTitle(person.name)
                .navigationSubtitle(person.clubFull)
        } else {
            ContentUnavailableView("Nothing to show", systemImage: "person.crop.circle.badge.questionmark",
                                   description: Text("Press Load Save, then double-click someone."))
                .frame(minWidth: 500, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        }
    }
}

/// What the game has to be asked for, worked out off the main thread once the window is up.
@MainActor
final class ProfileFacts: ObservableObject {
    enum Roles {
        case working
        case rows([RoleRow])
        case unavailable(String)
    }

    enum Season {
        case working
        case rows([(scope: String, stats: SeasonStats)])
        case unavailable(String)
    }

    @Published var roles = Roles.working
    @Published var season = Season.working
    @Published var daysOut: Int?
    @Published var transferInterest: String?
    @Published var loanInterest: String?
    @Published var staffInterest: String?
    @Published var preferredJob: String?

    private nonisolated static let scopes = [(1, "League"), (3, "Cup"), (2, "Continental"), (4, "International"), (0, "Friendlies"), (GameScope.clubTotal, "Club total")]

    func load(_ person: Person, session: AnalysisSession?) async {
        guard let session else { return }
        let checks = session.checks
        if let player = person as? Player {
            let answers = await offMain { () -> (days: Int?, interest: JoinAnswer?, season: Season) in
                let days = player.injury == nil ? nil : checks.injuryCheck(player)
                let interest = player.clubFull == session.club.name ? nil : checks.check(player)
                return (days, interest, Self.readSeason(player, checks: checks))
            }
            daysOut = answers.days
            season = answers.season
            if let interest = answers.interest {
                transferInterest = interest.transfer ? "Interested" : "Not interested"
                loanInterest = interest.loan ? "Interested" : player.loanUnavailable ? "Not available" : "Not interested"
            }
        } else if let staff = person as? Staff {
            let answers = await offMain { () -> (join: String?, job: String) in
                let join = checks.staffCheck(staff) == nil ? nil : checks.staffText(staff)
                return (join, checks.preferredJob(staff))
            }
            staffInterest = answers.join
            preferredJob = answers.job.isEmpty ? nil : answers.job
        }
    }

    private nonisolated static func readSeason(_ player: Player, checks: GameChecks) -> Season {
        let total = checks.ensureSeason(player)
        guard let engine = GameRules.engine, player.block != 0 else {
            if let total { return .rows([(scope: "Club total", stats: total)]) }
            return .unavailable("Needs the live game")
        }
        var asked = false
        var rows: [(scope: String, stats: SeasonStats)] = []
        for (scope, name) in scopes {
            guard let stats = engine.seasonStats(player: player, season: scope) else { continue }
            asked = true
            if stats.apps > 0 { rows.append((name, stats)) }
        }
        if !asked {
            if let total { return .rows([(scope: "Club total", stats: total)]) }
            return .unavailable("Not available on this version")
        }
        return .rows(rows)
    }

    func loadRoles(_ player: Player, position: Int, session: AnalysisSession?) async {
        roles = .working
        guard let engine = GameRules.engine else {
            roles = .unavailable("Role ratings need the live game.")
            return
        }
        let team = session.map { $0.club.team != 0 ? $0.club.team : $0.db.humanClubs.first?.team ?? 0 } ?? 0
        let best = RoleState.bestPos(player)
        let answer = await offMain { () -> [RoleRow]? in
            if let positional = engine as? PositionalRoleEngine {
                return positional.roleRows(player: player, position: position, team: team)
            }
            return position == best ? engine.roleRows(player: player, team: team) : nil
        }
        if let answer {
            roles = .rows(answer)
        } else {
            roles = .unavailable(engine is PositionalRoleEngine || position == best
                ? "Not available on this version"
                : "Not available at this position on this version")
        }
    }
}

private enum ProfileFormat {
    static let day: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_GB")
        format.timeZone = GameDate.calendar.timeZone
        format.dateFormat = "d MMM yyyy"
        return format
    }()

    static func joined(_ parts: [String], _ separator: String = "   ·   ") -> String {
        parts.filter { !$0.isEmpty }.joined(separator: separator)
    }
}

private struct ProfileContent: View {
    @EnvironmentObject private var model: AppModel
    let person: Person
    @StateObject private var facts = ProfileFacts()
    @State private var rolePosition: Int

    init(person: Person) {
        self.person = person
        _rolePosition = State(initialValue: (person as? Player).map(RoleState.bestPos) ?? -1)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.gap) {
                ProfileHeader(person: person, facts: facts)
                if let player = person as? Player {
                    PlayerBody(player: player, facts: facts, rolePosition: $rolePosition)
                } else if let staff = person as? Staff {
                    StaffBody(staff: staff, facts: facts)
                }
            }
            .padding(Metric.gutter)
        }
        .frame(minWidth: person is Player ? 1040 : 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let isStaff = person is Staff
                    model.menus.popUp(model.shortlistEntries([person], isStaff: isStaff))
                } label: {
                    Label("Add to shortlist", systemImage: "text.badge.plus")
                }
                .help("Add \(person.name) to an FM shortlist")
            }
        }
        .task(id: model.analysisVersion) { await facts.load(person, session: model.session) }
        .task(id: rolePosition) {
            if let player = person as? Player, rolePosition >= 0 {
                await facts.loadRoles(player, position: rolePosition, session: model.session)
            }
        }
    }
}

private struct ProfileHeader: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appColors) private var colors
    let person: Person
    @ObservedObject var facts: ProfileFacts

    private var player: Player? { person as? Player }
    private var staff: Staff? { person as? Staff }

    private func ability(_ value: Int) -> String {
        switch model.reveal {
        case .exact: return "\(value)"
        case .stars: return Columns.abilityStars(value)
        case .hidden: return "-"
        }
    }

    private var line: String {
        ProfileFormat.joined([
            person.age >= 0 ? "\(person.age) years" : "",
            person.birth.map { "born " + ProfileFormat.day.string(from: $0) } ?? "",
            player.map { Units.heightText($0.height) } ?? "",
            person.nation,
            player?.bestPositions ?? staff?.job ?? "",
        ])
    }

    private var club: String {
        guard !person.clubFull.isEmpty else { return "No club" }
        let squad = person.squad.isEmpty || person.squad == "First team" ? "" : "  ·  \(person.squad)"
        let league = person.league.isEmpty ? "" : "  (\(person.league))"
        return person.clubFull + squad + league
    }

    /// The game's own days when it can say; otherwise worked out from the injury's dates, and marked as such.
    private var injuryLine: String? {
        guard let player, !player.injuryText.isEmpty else { return nil }
        if let days = facts.daysOut, days > 0 {
            return "Injured: \(player.injuryText)  ·  " + (days > 1 ? "back in \(days) days" : "back in a day or so")
        }
        if player.injuryDays > 0 {
            return "Injured: \(player.injuryText)  ·  back in about \(player.injuryDays) days (estimated from the injury dates)"
        }
        return "Injured: \(player.injuryText)"
    }

    var body: some View {
        Panel {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(person.name).font(.title.weight(.semibold)).textSelection(.enabled)
                    Text(line).foregroundStyle(colors.ui.muted)
                    Text(club)
                    if let injuryLine {
                        Text(injuryLine).foregroundStyle(colors.ui.bad)
                    }
                    let about = ProfileFormat.joined([person.personality, person.media])
                    if !about.isEmpty { Text(about).foregroundStyle(colors.ui.muted) }
                }
                Spacer(minLength: 12)
                HStack(alignment: .top, spacing: 24) {
                    tile("Current ability", ability(player?.ca ?? staff?.ca ?? 0))
                    tile("Potential", ability(player?.pa ?? staff?.pa ?? 0), colors.ui.good)
                    if let player {
                        if player.notForSale {
                            tile("Value", "Not for sale", colors.ui.muted)
                        } else {
                            tile("Value", Columns.money(player.value))
                        }
                    }
                    tile(Units.wageHeading, person.wage > 0 ? Units.moneyText(Units.wageValue(person.wage)) : "—")
                }
                .fixedSize()
            }
            .padding(Metric.inset)
        }
    }

    private func tile(_ title: String, _ value: String, _ color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(colors.ui.muted)
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(color ?? colors.ui.text).monospacedDigit()
        }
    }
}

// MARK: Attributes

private struct AttributeRow: Identifiable {
    let name: String
    let value: Int
    let hidden: Bool
    var id: String { name }
}

private struct AttributeColumn: View {
    @Environment(\.appColors) private var colors
    let title: String
    let rows: [AttributeRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // The heading marks the whole column as hidden, once.
            Text(title).font(.headline).foregroundStyle(rows.first?.hidden == true ? colors.ui.hidden : colors.ui.text).padding(.bottom, 3)
            ForEach(rows) { row in
                let style = colors.attribute(row.value, name: row.name, hidden: false)
                HStack {
                    Text(row.name)
                    Spacer(minLength: 6)
                    Text("\(row.value)")
                        .monospacedDigit()
                        .fontWeight(style.bold ? .bold : .regular)
                        .foregroundStyle(style.color)
                }
            }
        }
        .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Players

private struct PlayerBody: View {
    @EnvironmentObject private var model: AppModel
    let player: Player
    @ObservedObject var facts: ProfileFacts
    @Binding var rolePosition: Int

    private func rows(_ names: [String], hidden: Bool = false) -> [AttributeRow] {
        names.map { AttributeRow(name: $0, value: player.a($0), hidden: hidden) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Metric.gap) {
            VStack(alignment: .leading, spacing: Metric.gap) {
                Panel {
                    HStack(alignment: .top, spacing: 22) {
                        if player.pos[0] >= 10 {
                            AttributeColumn(title: "Goalkeeping", rows: rows(Names.goalkeeping))
                        }
                        AttributeColumn(title: "Technical", rows: rows(Names.technical))
                        AttributeColumn(title: "Mental", rows: rows(Names.mental))
                        VStack(alignment: .leading, spacing: 14) {
                            AttributeColumn(title: "Physical", rows: rows(Names.physical + ["Left Foot", "Right Foot"]))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Traits").font(.headline).padding(.bottom, 3)
                                let traits = player.traits
                                if traits.isEmpty {
                                    Text("None").foregroundStyle(.secondary)
                                } else {
                                    ForEach(traits.components(separatedBy: "; "), id: \.self) { Text($0) }
                                }
                            }
                        }
                        if model.showHidden {
                            VStack(alignment: .leading, spacing: 14) {
                                AttributeColumn(title: "Hidden", rows: rows(Names.hidden, hidden: true))
                                AttributeColumn(title: "Personality", rows: Names.personality.map {
                                    AttributeRow(name: $0, value: player.p($0), hidden: true)
                                })
                            }
                        }
                    }
                    .padding(Metric.inset)
                }
                DevelopmentSection(player: player)
                RolesSection(position: rolePosition, facts: facts)
                InjuriesSection(player: player)
            }

            VStack(alignment: .leading, spacing: Metric.gap) {
                Panel(title: "Positions") {
                    PitchView(player: player, selected: $rolePosition)
                        .padding(.horizontal, Metric.inset)
                        .padding(.bottom, 12)
                }
                ContractSection(person: player, facts: facts)
                SeasonSection(player: player, facts: facts)
            }
            .frame(width: 280)
        }
    }
}

/// Whether a young player is likely to live up to their potential.
private struct DevelopmentSection: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appColors) private var colors
    let player: Player

    private var display: DisplayOptions? { model.session?.display }

    var body: some View {
        if let curve = model.session?.development, player.age >= 0, player.age <= 23, let talent = curve.talent(player) {
            Panel(title: "Development") {
                VStack(alignment: .leading, spacing: 4) {
                    if let display, display.reveal != .hidden {
                        RangeBar(now: display.shown(player.ca), peak: display.shown(curve.peak(player)), potential: display.shown(player.pa),
                                 scale: 40...max(display.shown(player.pa), 120))
                            .padding(.bottom, 4)
                    }
                    Text(talent.verdict.title).fontWeight(.medium).foregroundStyle(colors.ui.tone(talent.verdict.tone))
                    Text((display?.labelled("Likely peak", curve.peak(player)).map { "\($0), PA \(display?.ability(player.pa) ?? ""). " } ?? "") + "\(talent.odds) with this mentality get close to their PA.")
                        .font(.callout)
                    Text(talent.mentality + (talent.injuryProne ? ", Injury Proneness \(talent.injuryProneness)" : ""))
                        .font(.callout)
                        .foregroundStyle(colors.ui.hidden)
                }
                .padding(.horizontal, Metric.inset)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct RolesSection: View {
    let position: Int
    @ObservedObject var facts: ProfileFacts

    var body: some View {
        Panel(title: position >= 0 ? "Roles at \(Names.positions[position])" : "Roles", note: "Click a position on the pitch to change it.") {
            VStack(alignment: .leading, spacing: 8) {
                switch facts.roles {
                case .working:
                    Text("Working out role ratings...").foregroundStyle(.secondary)
                case .unavailable(let reason):
                    Text(reason).foregroundStyle(.secondary)
                case .rows(let rows):
                    HStack(alignment: .top, spacing: 30) {
                        side("In possession", rows.filter { !$0.outOfPossession })
                        side("Out of possession", rows.filter(\.outOfPossession))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metric.inset)
            .padding(.bottom, 12)
        }
    }

    private func side(_ title: String, _ rows: [RoleRow]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(rows, id: \.role) { row in
                HStack(spacing: 6) {
                    StarRating(stars: Double(row.maxHalfStars) / 2)
                    Text(row.role)
                    if row.minHalfStars < row.maxHalfStars {
                        Text("(\(half(row.minHalfStars))-\(half(row.maxHalfStars)))").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
        }
    }

    private func half(_ value: Int) -> String {
        value % 2 == 0 ? "\(value / 2)" : "\(value / 2).5"
    }
}

private struct InjuriesSection: View {
    let player: Player

    private var history: [Injury] {
        (player.injuries ?? []).filter { !$0.name.isEmpty }.sorted { $0.date > $1.date }
    }

    var body: some View {
        Panel(title: "Injuries") {
            VStack(alignment: .leading, spacing: 4) {
                if history.isEmpty {
                    Text("None on record").foregroundStyle(.secondary)
                }
                ForEach(Array(history.enumerated()), id: \.offset) { _, injury in
                    HStack(alignment: .firstTextBaseline) {
                        Text(injury.name)
                        Spacer()
                        Text(ProfileFormat.joined([
                            injury.date == .distantPast ? "" : ProfileFormat.day.string(from: injury.date),
                            injury.length > 0 ? "\(injury.length) days" : "",
                        ], "  ·  "))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metric.inset)
            .padding(.bottom, 12)
        }
    }
}

private struct SeasonSection: View {
    @Environment(\.appColors) private var colors
    let player: Player
    @ObservedObject var facts: ProfileFacts

    var body: some View {
        Panel(title: "This season") {
            VStack(alignment: .leading, spacing: 6) {
                switch facts.season {
                case .working:
                    Text("Working out...").foregroundStyle(.secondary)
                case .unavailable(let reason):
                    Text(reason).foregroundStyle(.secondary)
                case .rows(let rows) where rows.isEmpty:
                    Text("No games this season").foregroundStyle(.secondary)
                case .rows(let rows):
                    Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 3) {
                        GridRow {
                            Text("").gridColumnAlignment(.leading)
                            ForEach(["Apps", "Gls", "Ast", "Av"], id: \.self) { Text($0).foregroundStyle(.secondary) }
                        }
                        .font(.subheadline)
                        ForEach(rows, id: \.scope) { row in
                            let total = row.scope == "Club total"
                            GridRow {
                                Text(row.scope).foregroundStyle(total ? .primary : .secondary)
                                Text(row.stats.appsText)
                                Text("\(row.stats.goals)")
                                Text("\(row.stats.assists)")
                                Text(row.stats.ratingText)
                                    .foregroundStyle(row.stats.rating >= 7.3 ? Color(nsColor: colors.good) : .primary)
                            }
                            .fontWeight(total ? .semibold : .regular)
                            .monospacedDigit()
                        }
                    }
                }
                if !player.form.isEmpty {
                    Text("Form  \(player.form)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metric.inset)
            .padding(.bottom, 12)
        }
    }
}

// MARK: Staff

private struct StaffBody: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appColors) private var colors
    let staff: Staff
    @ObservedObject var facts: ProfileFacts

    private func rows(_ names: [String]) -> [AttributeRow] {
        names.map { AttributeRow(name: $0.replacingOccurrences(of: "Coaching ", with: ""), value: staff.a($0), hidden: false) }
    }

    private var hiddenAttributes: [String] {
        let shown = Set(Names.staffShown)
        var seen = Set<String>()
        return Names.staffAttrs.filter { !shown.contains($0) && !$0.hasPrefix("Unnamed") && seen.insert($0).inserted }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Metric.gap) {
            Panel {
                HStack(alignment: .top, spacing: 22) {
                    AttributeColumn(title: "Coaching", rows: rows([
                        "Coaching Attacking", "Coaching Defending", "Coaching Fitness", "Coaching Goalkeepers", "GK Handling",
                        "GK Distribution", "Coaching Possession", "Coaching Set Pieces", "Coaching Tactical", "Coaching Technical",
                        "Working With Youngsters",
                    ]))
                    AttributeColumn(title: "Mental & knowledge", rows: rows([
                        "Determination", "Level Of Discipline", "Motivating", "Man Management", "Judging Player Ability",
                        "Judging Player Potential", "Judging Staff Ability", "Tactical Knowledge", "Analysing Data", "Negotiating",
                    ]))
                    AttributeColumn(title: "Medical", rows: rows(["Physiotherapy", "Sports Science"]))
                    if model.showHidden {
                        VStack(alignment: .leading, spacing: 14) {
                            AttributeColumn(title: "Hidden", rows: hiddenAttributes.map {
                                AttributeRow(name: $0, value: staff.a($0), hidden: true)
                            })
                            AttributeColumn(title: "Personality", rows: Names.personality.map {
                                AttributeRow(name: $0, value: staff.p($0), hidden: true)
                            })
                        }
                    }
                }
                .padding(Metric.inset)
            }

            VStack(alignment: .leading, spacing: Metric.gap) {
                Panel(title: "Training areas") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(0..<9, id: \.self) { area in
                            HStack {
                                Text(Names.areasLong[area])
                                Spacer()
                                if let stars = Columns.starText(staff, area) {
                                    StarRating(stars: stars)
                                } else {
                                    Text("—").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metric.inset)
                    .padding(.bottom, 12)
                }
                ContractSection(person: staff, facts: facts)
            }
            .frame(width: 300)
        }
    }
}

// MARK: Shared parts

private struct ContractSection: View {
    let person: Person
    @ObservedObject var facts: ProfileFacts

    private var rows: [(String, String)] {
        var rows = [
            ("Wage", person.wage > 0 ? Units.wageText(person.wage, withSuffix: true) : "—"),
            ("Ends", person.contractEnd.map(ProfileFormat.day.string(from:)) ?? "—"),
        ]
        if person.transferListed {
            rows.append(("Transfer status", "Listed" + (person.listedDate.map { " (\(ProfileFormat.day.string(from: $0)))" } ?? "")))
        }
        if !person.loanStatus.isEmpty { rows.append(("Loan status", person.loanStatus)) }
        if !person.squad.isEmpty, person is Player { rows.append(("Squad", person.squad)) }
        if !person.loanClub.isEmpty { rows.append(("On loan at", person.loanClubFull.isEmpty ? person.loanClub : person.loanClubFull)) }
        if let end = person.loanEnd { rows.append(("Loan ends", ProfileFormat.day.string(from: end))) }
        if let transfer = facts.transferInterest { rows.append(("Transfer interest", transfer)) }
        if let loan = facts.loanInterest { rows.append(("Loan interest", loan)) }
        if let join = facts.staffInterest { rows.append(("Would join you", join)) }
        if let job = facts.preferredJob { rows.append(("Prefers", job)) }
        if person.releaseClause > 0 { rows.append(("Release clause", Columns.money(person.releaseClause))) }
        if person.releaseForeign > 0 { rows.append(("Release (foreign)", Columns.money(person.releaseForeign))) }
        if person.releaseDomestic > 0 { rows.append(("Release (domestic)", Columns.money(person.releaseDomestic))) }
        return rows
    }

    var body: some View {
        Panel(title: "Contract") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows, id: \.0) { label, value in
                    HStack(alignment: .firstTextBaseline) {
                        Text(label).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metric.inset)
            .padding(.bottom, 12)
        }
    }
}

/// Half-stars, in the star colour of the palette.
struct StarRating: View {
    @Environment(\.appColors) private var colors
    let stars: Double

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: symbol(index))
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(Color(nsColor: colors.star))
        .accessibilityLabel("\(stars.formatted()) stars")
    }

    private func symbol(_ index: Int) -> String {
        let left = stars - Double(index)
        return left >= 1 ? "star.fill" : left >= 0.5 ? "star.leadinghalf.filled" : "star"
    }
}
