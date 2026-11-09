import AppKit
@preconcurrency import StarshipAnalysis
@preconcurrency import StarshipCore
import StarshipFiles
import StarshipSearch
import SwiftUI

enum Screen: Hashable {
    case dashboard
    case players, staff
    case myClub, squadOverview, staffOverview, squadPlanner, signings, recommendedStaff, staffReview
    case bargains, openSquad
    case shortlists

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .players: return "Players"
        case .staff: return "Staff"
        case .myClub: return "Club reports"
        case .squadOverview: return "Squad overview"
        case .staffOverview: return "Staff overview"
        case .squadPlanner: return "Squad planner"
        case .signings: return "Recommended signings"
        case .recommendedStaff: return "Recommended staff"
        case .staffReview: return "Staff review"
        case .bargains: return "Bargains"
        case .openSquad: return "Open squad"
        case .shortlists: return "Shortlists"
        }
    }

    /// The screens that show the normal people table, with its filters and columns.
    var isList: Bool {
        switch self {
        case .players, .staff, .openSquad, .shortlists: return true
        default: return false
        }
    }
}

/// Names someone across windows. Window values must be codable, and a `Person` isn't.
package struct PersonRef: Hashable, Codable {
    let uid: UInt32
    let isStaff: Bool

    init(_ person: Person) {
        uid = person.uid
        isStaff = person is Staff
    }
}

enum WindowID {
    static let main = "main"
    static let profile = "profile"
    static let compare = "compare"
    static let compatibility = "compatibility"
    static let about = "about"
}

/// A shortlist open on screen.
struct OpenShortlist: Equatable {
    let url: URL
    let name: String
    let isStaff: Bool
    let uids: [UInt32]
}

@MainActor
package final class AppModel: ObservableObject {
    @Published var database: Database? { didSet { updateMenuState() } }
    @Published var status = "Start Football Manager from here, load your save, then press Load Save."
    @Published var loading = false { didSet { updateMenuState() } }
    @Published var gameState = GameLauncher.state
    @Published var alert: String?

    @Published private(set) var screen: Screen = .dashboard { didSet { updateMenuState() } }
    @Published var reveal = Reveal(setting: Settings.current.reveal) {
        didSet {
            Settings.current.reveal = reveal.rawValue
            visibilityChanged()
        }
    }
    @Published var showHidden = Settings.current.showHidden {
        didSet {
            Settings.current.showHidden = showHidden
            visibilityChanged()
        }
    }
    /// CA and PA are hidden in FM too, so the eye comes first and `reveal` only says how they show.
    var shownReveal: Reveal { showHidden ? reveal : .hidden }
    var showsAbility: Bool { shownReveal != .hidden }

    // Each kind of list keeps its own filters, so opening a squad doesn't disturb a search.
    @Published var playerFilter = PlayerFilter()
    @Published var staffFilter = StaffFilter()
    @Published var squadPlayerFilter = PlayerFilter()
    @Published var squadStaffFilter = StaffFilter()
    @Published var listPlayerFilter = PlayerFilter()
    @Published var listStaffFilter = StaffFilter()

    @Published var playerColumns: [Col] = []
    @Published var staffColumns: [Col] = []
    @Published var columnsVersion = 0
    @Published var playerColumnFilters: [String: String] = [:]
    @Published var staffColumnFilters: [String: String] = [:]
    @Published var players: [Player] = []
    @Published var staff: [Staff] = []
    @Published var searching = false
    @Published var rowsVersion = 0
    @Published var cellsVersion = 0
    @Published var editingFilter = false
    @Published var editingColumns = false
    @Published var selection: [Person] = [] { didSet { updateMenuState() } }
    /// People the last interest check got no answer for.
    @Published var unanswered = 0
    @Published var focusSearch = 0

    @Published private(set) var playerSort = SortState()
    @Published private(set) var staffSort = SortState()

    /// One per load, and rebuilt if you switch club in a network save.
    @Published private(set) var session: AnalysisSession?
    /// Goes up when what the analysis screens show would change: a new session, units, reveal or hidden.
    @Published private(set) var analysisVersion = 0
    @Published private(set) var playerOptions = SearchOptions()
    @Published private(set) var staffOptions = SearchOptions()
    @Published private(set) var readingSeasonStats = false
    /// False once the game has turned down every question about season stats.
    @Published private(set) var seasonStatsAvailable = true
    @Published private(set) var colors = AppColors()

    // Open squad
    @Published var squadClub = ""
    @Published var squadName = OpenSquad.allSquads
    @Published var squadShowsStaff = false
    @Published private(set) var squadCatalogue: OpenSquad?

    // Shortlists
    @Published private(set) var openShortlist: OpenShortlist?
    @Published private(set) var shortlistsVersion = 0

    let menuState = MenuState()
    let fileJob = BackgroundJob<String>()
    let snapshotJob = BackgroundJob<Database>()

    lazy var dashboard = DashboardState(model: self)
    lazy var myClub = MyClubState(model: self)
    lazy var squadOverview = OverviewState(model: self, preparing: "Going through your squad...") { SquadOverview(session: $0) }
    lazy var staffOverview = OverviewState(model: self, preparing: "Going through your backroom...") { StaffOverview(session: $0) }
    lazy var planner = PlannerState(model: self)
    lazy var signings = SigningsState(model: self)
    lazy var recommendedStaff = RecommendedStaffState(model: self)
    lazy var staffReview = StaffReviewState(model: self)
    lazy var bargains = BargainsState(model: self)
    let menus = MenuBuilder()

    struct SortState: Equatable {
        var column: String?
        var descending = true
    }

    static let restartHelp = "Football Manager is running, but it wasn't started by FM Starship, so macOS won't let it read the game. Save and quit Football Manager, then start it from here. FM Starship will never close the game for you."

    /// Filled in by the main window, the only way to open windows from outside a view.
    var openWindow: OpenWindowAction?
    /// Inside FM there are no SwiftUI scenes to open, so the plugin opens its own windows, and sets their appearance
    /// rather than the whole game's.
    package var openInsideGame: ((StarshipWindow) -> Void)?
    package var applyAppearanceInsideGame: ((NSAppearance?) -> Void)?

    private(set) var allPlayerColumns: [Col] = []
    private(set) var allStaffColumns: [Col] = []
    private var searchToken: CancelToken?
    private var seasonToken: CancelToken?
    private var poll: Timer?
    private var playersByUID: [UInt32: Player] = [:]
    private var staffByUID: [UInt32: Staff] = [:]
    private var laterChecks = LaterChecks()
    /// What the poll below costs. Inside FM it runs on FM's main thread, and the plugin logs it.
    package let checkGameCost = TimerCost()

    init() {
        tellFilters()
        colors = AppColors(themeNamed: Settings.current.theme)
        reloadColumns()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.checkGameCost.measure { self.checkGame() }
            }
        }
    }

    func persist() { Settings.save() }

    private func updateMenuState() {
        let state = MenuState.Values(hasData: database != nil, isList: screen.isList, canCompare: canCompare, loading: loading)
        if menuState.values != state { menuState.values = state }
    }

    // MARK: Screens

    func go(to destination: Screen) {
        guard destination != screen else { return }
        screen = destination
        selection = []
        search()
    }

    var title: String {
        guard screen == .shortlists, let openShortlist else { return screen.title }
        return openShortlist.name
    }

    /// The dashboard says whose club it is in big letters already.
    var subtitle: String {
        screen == .dashboard ? "" : session?.club.name ?? ""
    }

    func openTalent() {
        myClub.tab = .talent
        go(to: .myClub)
    }

    func openHealthCheck() {
        myClub.tab = .health
        go(to: .myClub)
    }

    /// Whether the table on screen is staff. Rows and columns must always agree on this.
    var listIsStaff: Bool {
        switch screen {
        case .staff: return true
        case .openSquad: return squadShowsStaff
        case .shortlists: return openShortlist?.isStaff ?? false
        default: return false
        }
    }

    var activePlayerFilter: PlayerFilter {
        get {
            switch screen {
            case .openSquad: return squadPlayerFilter
            case .shortlists: return listPlayerFilter
            default: return playerFilter
            }
        }
        set {
            switch screen {
            case .openSquad: squadPlayerFilter = newValue
            case .shortlists: listPlayerFilter = newValue
            default: playerFilter = newValue
            }
        }
    }

    var activeStaffFilter: StaffFilter {
        get {
            switch screen {
            case .openSquad: return squadStaffFilter
            case .shortlists: return listStaffFilter
            default: return staffFilter
            }
        }
        set {
            switch screen {
            case .openSquad: squadStaffFilter = newValue
            case .shortlists: listStaffFilter = newValue
            default: staffFilter = newValue
            }
        }
    }

    /// The toolbar's search field.
    var searchText: String {
        get { listIsStaff ? activeStaffFilter.name : activePlayerFilter.name }
        set {
            if listIsStaff { activeStaffFilter.name = newValue } else { activePlayerFilter.name = newValue }
            search(after: .milliseconds(350))
        }
    }

    var filterSummary: String {
        listIsStaff ? activeStaffFilter.describe() : activePlayerFilter.describe()
    }

    func resetFilters() {
        if listIsStaff { activeStaffFilter.reset() } else { activePlayerFilter.reset() }
        search()
    }

    /// Set when the "would join" boxes are ticked but the game can't be asked, so the list isn't narrowed by them.
    var interestUnavailable: String? {
        if listIsStaff {
            let filter = activeStaffFilter
            let wanted = filter.interestWanted
            guard filter.firstTeam || filter.reserves || filter.youthTeam,
                  !(wanted.firstTeam || wanted.reserves || wanted.youth) else { return nil }
            return RulesState.shared.staffInterestNote
        }
        let filter = activePlayerFilter
        let wanted = filter.interestWanted
        guard filter.onTransfer || filter.onLoan, !(wanted.transfer || wanted.loan) else { return nil }
        let note = RulesState.shared.interestNote
        return note.isEmpty ? "Needs the live game: press Load Save." : note
    }

    var rowsShown: Int { listIsStaff ? staff.count : players.count }

    /// Under the sidebar, so it is always plain where the numbers come from.
    var sourceLine: String {
        guard let database else { return "" }
        let date = database.gameDate.map { Self.gameDateFormat.string(from: $0) } ?? "no game date"
        return "\(database.source)  ·  \(date)"
    }

    /// The same with everything else there is to say about the read, for its tooltip.
    var sourceDetail: String {
        guard let database else { return "" }
        var parts = ["Source: \(database.source)"]
        if !database.build.isEmpty { parts.append(database.build) }
        parts.append("read \(Self.readFormat.string(from: database.readAt))")
        parts.append("self-checks: \(database.checks)")
        parts.append(database.gameDate.map { "game date \(Self.gameDateFormat.string(from: $0))" } ?? "game date not found for this version (ages blank)")
        return parts.joined(separator: "  ·  ")
    }

    private static let readFormat: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "dd/MM HH:mm"
        return format
    }()

    private static let gameDateFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_GB")
        format.timeZone = GameDate.calendar.timeZone
        format.dateFormat = "EEE dd/MM/yyyy"
        return format
    }()

    // MARK: Game

    /// The agent travels inside the app bundle. When running from a build folder it sits next to the package.
    var agentURL: URL {
        if let bundled = Bundle.main.url(forResource: "libStarshipAgent", withExtension: "dylib") { return bundled }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/libStarshipAgent.dylib")
    }

    func launchGame() {
        do {
            try GameLauncher.launch(agent: agentURL)
            status = "Starting Football Manager. Load your save there, then press Load Save."
        } catch {
            alert = "\(error)"
        }
        gameState = GameLauncher.state
    }

    func loadSave() {
        guard !loading else { return }
        loading = true
        status = "Connecting to Football Manager..."
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let (database, engine) = try GameReader.connect(status: { text in
                    Task { @MainActor in self?.status = text }
                }, log: AppLog.write)
                await self?.finished(database, engine)
            } catch {
                await self?.failed("\(error)")
            }
        }
    }

    private func finished(_ database: Database, _ engine: RulesEngine?) {
        GameRules.engine = engine
        loading = false
        install(database)
        let club = session?.club.name ?? ""
        DispatchQueue.global(qos: .utility).async { DevelopmentStore().save(db: database, club: club) }
        if let engine { loadSeasonStats(database, engine) }
    }

    private func failed(_ message: String) {
        loading = false
        status = message
        alert = message
    }

    /// Everything that follows new data, wherever it came from.
    func install(_ database: Database) {
        seasonToken?.cancel()
        readingSeasonStats = false
        seasonStatsAvailable = true
        laterChecks = LaterChecks()

        RulesState.shared.reset()
        RulesState.shared.fill(database)
        Units.setCurrencies(database.currencies)
        Units.apply()
        reloadColumns()

        self.database = database
        playersByUID = Dictionary(database.players.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        staffByUID = Dictionary(database.staff.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        playerOptions = SearchOptions(database.players)
        staffOptions = SearchOptions(database.staff)
        for keyPath in [\AppModel.playerFilter, \.squadPlayerFilter, \.listPlayerFilter] { self[keyPath: keyPath].fill(playerOptions) }
        for keyPath in [\AppModel.staffFilter, \.squadStaffFilter, \.listStaffFilter] { self[keyPath: keyPath].fill(staffOptions) }

        session = AnalysisSession(db: database, club: chosenClub(in: database), display: displayOptions, library: FMData.library)
        squadCatalogue = session.map { OpenSquad(session: $0) }
        analysisVersion += 1
        openShortlist = nil
        selection = []
        search()
        if let problems = database.checkProblems {
            alert = "FM Starship's self-checks failed on this save (\(problems)), so the numbers on screen may be wrong. If FM has just been patched, see Help > Compatibility."
        }
    }

    /// The rules read addresses that only mean something in the game they came from. When that game
    /// closes they go, and what was loaded stays on screen as plain data.
    private func checkGame() {
        gameState = GameLauncher.state
        guard let engine = GameRules.engine as? RulesEngine, GameProcess.runningPID() != engine.pid else { return }
        seasonToken?.cancel()
        GameRules.engine = nil
        RulesState.shared.reset()
        status = "Football Manager closed. Showing what was last loaded."
        cellsVersion += 1
    }

    func loadSeasonStats(_ database: Database, _ engine: GameRulesEngine) {
        let token = CancelToken()
        seasonToken = token
        readingSeasonStats = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rules = engine as? RulesEngine
            let clock = rules.map { ReadClock($0.game) }
            let players = database.players.filter { $0.block > 0 }
            var found = [SeasonStats?](repeating: nil, count: players.count)
            var forms = [String](repeating: "", count: players.count)
            // Only a fresh look at the first few: if the game answers none of them, it won't answer the rest.
            let probe = Array(players.prefix(32))
            let works = probe.isEmpty || probe.contains { engine.seasonStats(player: $0, season: GameScope.clubTotal) != nil }
            if works {
                let workers = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
                found.withUnsafeMutableBufferPointer { results in
                    forms.withUnsafeMutableBufferPointer { formResults in
                        let results = results, formResults = formResults
                        concurrently(Array(players.indices), workers: workers, token: token) { index in
                            results[index] = engine.seasonStats(player: players[index], season: GameScope.clubTotal)
                            if (results[index]?.apps ?? 0) > 0 { formResults[index] = engine.form(player: players[index]) ?? "" }
                            if players[index].injury != nil { _ = RulesState.shared.injuryCheck(players[index]) }
                        }
                    }
                }
            }
            if let rules, let clock {
                clock.lap(token.isCancelled ? "stopped after" : works ? "answered in" : "not answered, in")
                AppLog.write("Season stats for \(players.count) players \(clock.line), \(rules.cachedPages) of FM's pages copied")
            }
            let answers = found, formAnswers = forms
            Task { @MainActor in
                guard let self, self.seasonToken === token, !token.isCancelled else { return }
                for (index, player) in players.enumerated() where (answers[index]?.apps ?? 0) > 0 {
                    player.season = answers[index]
                    player.form = formAnswers[index]
                }
                self.readingSeasonStats = false
                self.seasonStatsAvailable = works
                self.cellsVersion += 1
                if !self.searching { self.status = self.idleStatus() }
                if self.activePlayerFilter.usesSeasonStats || self.sortIsOnSeasonStats { self.search() }
            }
        }
    }

    private var sortIsOnSeasonStats: Bool {
        guard let name = playerSort.column else { return false }
        return allPlayerColumns.first { $0.name == name }?.group == "Season stats"
    }

    // MARK: Club and display

    private func chosenClub(in database: Database) -> ChosenClub {
        let rules = RulesState.shared
        if rules.team != 0 { return ChosenClub(team: rules.team, name: rules.clubName, manager: rules.manager) }
        // With no game to ask, RulesState picks nobody, but a snapshot still knows whose club it is.
        let clubs = ChosenClub.humanClubs(in: database)
        return clubs.first { $0.name == Settings.current.interestClub } ?? clubs.first ?? ChosenClub()
    }

    var clubChoices: [String] {
        guard let database else { return [] }
        return ChosenClub.humanClubs(in: database).map(\.name)
    }

    func pickClub(_ name: String) {
        Settings.current.interestClub = name
        persist()
        RulesState.shared.pickClub(name)
        syncSession()
    }

    /// The filter window can change the club too, so every search makes sure the session still matches.
    private func syncSession() {
        guard let database, let session else { return }
        let wanted = chosenClub(in: database)
        guard wanted != session.club else { return }
        self.session = AnalysisSession(db: database, club: wanted, display: displayOptions, library: FMData.library)
        analysisVersion += 1
    }

    var displayOptions: DisplayOptions {
        let reveal: AbilityReveal
        switch shownReveal {
        case .exact: reveal = .numbers
        case .stars: reveal = .stars
        case .hidden: reveal = .hidden
        }
        let wages: MoneyUnits.WagePeriod
        switch Units.wages {
        case .week: wages = .week
        case .month: wages = .month
        case .year: wages = .year
        }
        let units = MoneyUnits(symbol: Units.money.symbol, perPound: Units.money.perPound, wagePeriod: wages,
                               feetAndInches: Units.height == .feetInches)
        return DisplayOptions(reveal: reveal, showHidden: showHidden, units: units)
    }

    private func tellFilters() {
        for keyPath in [\AppModel.playerFilter, \.squadPlayerFilter, \.listPlayerFilter] {
            self[keyPath: keyPath].showHidden = showHidden
            self[keyPath: keyPath].showAbility = showsAbility
        }
        for keyPath in [\AppModel.staffFilter, \.squadStaffFilter, \.listStaffFilter] { self[keyPath: keyPath].showHidden = showHidden }
    }

    private func visibilityChanged() {
        persist()
        tellFilters()
        rebuildShownColumns()
        captureColumns()
        displayChanged()
        search()
    }

    private func displayChanged() {
        session?.display = displayOptions
        analysisVersion += 1
        cellsVersion += 1
    }

    /// After a change in Settings. The wage heading is fixed when a column is built.
    func unitsChanged() {
        persist()
        Units.apply()
        reloadColumns()
        displayChanged()
        search()
    }

    func setTheme(_ name: String) {
        Settings.current.theme = name
        colors = AppColors(themeNamed: name)
        if let palette = colors.palette { Settings.current.dark = palette.dark }
        applyAppearance()
        persist()
    }

    /// A palette is light or dark whatever macOS is set to.
    func applyAppearance() {
        if let applyAppearanceInsideGame {
            applyAppearanceInsideGame(colors.appearance)
        } else {
            NSApp.appearance = colors.appearance
        }
    }

    // MARK: Columns

    func reloadColumns() {
        allPlayerColumns = Columns.forPlayers()
        allStaffColumns = Columns.forStaff()
        Columns.restoreVisibility(&allPlayerColumns, saved: Settings.current.playerColumns)
        Columns.restoreVisibility(&allStaffColumns, saved: Settings.current.staffColumns)
        rebuildShownColumns()
    }

    private func rebuildShownColumns() {
        playerColumns = Columns.restoreLayout(shown: Columns.shown(allPlayerColumns, showHidden: showHidden, showAbility: showsAbility), all: allPlayerColumns,
                                              saved: Settings.current.playerColumns, restoreWidths: true)
        staffColumns = Columns.restoreLayout(shown: Columns.shown(allStaffColumns, showHidden: showHidden, showAbility: showsAbility), all: allStaffColumns,
                                             saved: Settings.current.staffColumns, restoreWidths: true)
        columnsVersion += 1
    }

    private func captureColumns() {
        Settings.current.playerColumns = Columns.capture(all: allPlayerColumns, shown: playerColumns, saved: Settings.current.playerColumns)
        Settings.current.staffColumns = Columns.capture(all: allStaffColumns, shown: staffColumns, saved: Settings.current.staffColumns)
        persist()
    }

    /// Dragged in the table: it already looks right, so this only records it.
    func columnsLaidOut(staff isStaff: Bool, order: [String], widths: [String: Int]) {
        func arranged(_ columns: [Col]) -> [Col] {
            let byName = Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            return order.compactMap { name in
                guard var col = byName[name] else { return nil }
                if let width = widths[name] { col.width = width }
                return col
            }
        }
        if isStaff { staffColumns = arranged(staffColumns) } else { playerColumns = arranged(playerColumns) }
        captureColumns()
    }

    /// From the columns sheet: which show, and in what order.
    func chooseColumns(staff isStaff: Bool, visible: Set<String>, order: [String]) {
        var all = isStaff ? allStaffColumns : allPlayerColumns
        let widths = Dictionary((isStaff ? staffColumns : playerColumns).map { ($0.name, $0.width) }, uniquingKeysWith: { first, _ in first })
        for index in all.indices {
            all[index].visible = visible.contains(all[index].name)
            if let width = widths[all[index].name] { all[index].width = width }
        }
        let shown = Columns.shown(all, showHidden: showHidden, showAbility: showsAbility)
        let ordered = order.compactMap { name in shown.first { $0.name == name } }
            + shown.filter { !order.contains($0.name) }
        if isStaff {
            allStaffColumns = all
            staffColumns = ordered
        } else {
            allPlayerColumns = all
            playerColumns = ordered
        }
        columnsVersion += 1
        captureColumns()
        search()
    }

    func hideColumn(_ col: Col, staff isStaff: Bool) {
        let current = isStaff ? staffColumns : playerColumns
        let order = current.map(\.name).filter { $0 != col.name }
        let visible = Set((isStaff ? allStaffColumns : allPlayerColumns).filter(\.visible).map(\.name)).subtracting([col.name])
        chooseColumns(staff: isStaff, visible: visible, order: order)
    }

    func resetColumns(staff isStaff: Bool) {
        if isStaff {
            Columns.resetToDefault(&allStaffColumns)
            Settings.current.staffColumns = nil
        } else {
            Columns.resetToDefault(&allPlayerColumns)
            Settings.current.playerColumns = nil
        }
        rebuildShownColumns()
        captureColumns()
        status = "Columns reset to the default."
        search()
    }

    func columnFilter(_ col: Col, staff isStaff: Bool) -> String {
        (isStaff ? staffColumnFilters : playerColumnFilters)[col.name] ?? ""
    }

    func setColumnFilter(_ col: Col, _ text: String, staff isStaff: Bool) {
        let value = text.isEmpty ? nil : text
        if isStaff { staffColumnFilters[col.name] = value } else { playerColumnFilters[col.name] = value }
        search(after: .milliseconds(350))
    }

    func clearColumnFilters() {
        if listIsStaff { staffColumnFilters = [:] } else { playerColumnFilters = [:] }
        search()
    }

    private func parsedFilters(_ columns: [Col], _ texts: [String: String]) -> [(col: Col, filter: ColumnFilter)] {
        columns.compactMap { col in
            guard let text = texts[col.name], let filter = ColumnFilter.parse(text, numeric: col.numeric) else { return nil }
            return (col, filter)
        }
    }

    // MARK: Search

    /// Same order as the original: criteria, column filters, shortlist, the "would join" checks, then sorting.
    func search(after delay: Duration = .zero) {
        guard let database, screen.isList else { return }
        syncSession()
        searchToken?.cancel()
        searching = false
        guard screen != .shortlists || openShortlist != nil else { return }
        let token = CancelToken()
        searchToken = token
        searching = true
        unanswered = 0
        if !searchIsQuick { status = "Filtering..." }
        let wait = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        if listIsStaff {
            let run = staffSearch(database)
            start(run, wait: wait, token: token) { [weak self] rows in self?.staff = rows }
        } else {
            let run = playerSearch(database)
            start(run, wait: wait, token: token) { [weak self] rows in self?.players = rows }
        }
    }

    private func playerSearch(_ database: Database) -> PeopleSearch<Player> {
        let filter = activePlayerFilter
        let wanted = filter.interestWanted
        let sortBy = playerColumns.first { $0.name == playerSort.column }
        let descending = playerSort.descending
        let byAbility = showsAbility
        var interest: InterestStep<Player>?
        if wanted.transfer || wanted.loan {
            interest = InterestStep(
                label: "Checking interest in joining \(RulesState.shared.clubName)",
                check: Self.timingFirstBatch("players") { batch, token in RulesState.shared.checkAll(batch, cancelled: { token.isCancelled }) },
                passes: { filter.matchesInterest($0) },
                answered: { RulesState.shared.known($0) != nil })
        }
        let shortlist = openShortlistFilter(isStaff: false)
        return PeopleSearch(people: database.players, match: { filter.criteria().filter($0) },
                            columnFilters: parsedFilters(playerColumns, playerColumnFilters), shortlist: shortlist,
                            interest: interest, sortBy: sortBy, descending: descending,
                            ordered: { Columns.ordered(players: $0, sortBy: sortBy, descending: descending, byAbility: byAbility) })
    }

    private func staffSearch(_ database: Database) -> PeopleSearch<Staff> {
        let filter = activeStaffFilter
        let wanted = filter.interestWanted
        let sortBy = staffColumns.first { $0.name == staffSort.column }
        let descending = staffSort.descending
        let rankArea = filter.rankArea
        var interest: InterestStep<Staff>?
        if wanted.firstTeam || wanted.reserves || wanted.youth {
            interest = InterestStep(
                label: "Checking which staff would join \(RulesState.shared.clubName)",
                check: Self.timingFirstBatch("staff") { batch, token in RulesState.shared.checkAllStaff(batch, cancelled: { token.isCancelled }) },
                passes: { filter.matchesInterest($0) },
                answered: { RulesState.shared.staffKnown($0) != nil })
        }
        let shortlist = openShortlistFilter(isStaff: true)
        return PeopleSearch(people: database.staff, match: { filter.criteria().filter($0) },
                            columnFilters: parsedFilters(staffColumns, staffColumnFilters), shortlist: shortlist,
                            interest: interest, sortBy: sortBy, descending: descending,
                            ordered: { Columns.ordered(staff: $0, sortBy: sortBy, descending: descending, rankArea: rankArea) })
    }

    /// Logs how long a search's first batch of checks took. After a read, that's the batch that copies FM's memory
    /// into the sandbox.
    nonisolated private static func timingFirstBatch<Row>(_ people: String, _ check: @escaping ([Row], CancelToken) -> Void)
        -> ([Row], CancelToken) -> Void {
        var first = true
        return { batch, token in
            let clock = first ? (GameRules.engine as? RulesEngine).map { ReadClock($0.game) } : nil
            first = false
            check(batch, token)
            guard let clock, !token.isCancelled else { return }
            clock.lap("First interest batch, \(batch.count) \(people),")
            AppLog.write(clock.line)
        }
    }

    private func openShortlistFilter(isStaff: Bool) -> ShortlistFilter? {
        guard screen == .shortlists, let openShortlist else { return nil }
        // A shortlist of the other kind would otherwise show everyone.
        guard openShortlist.isStaff == isStaff else { return nil }
        return ShortlistFilter(uids: Set(openShortlist.uids), myClub: isStaff ? "" : session?.club.name ?? "")
    }

    private func start<Row>(_ run: PeopleSearch<Row>, wait: Double, token: CancelToken, show: @escaping ([Row]) -> Void) {
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            if token.isCancelled { return }
            let outcome = run.run(token: token, status: { text in
                Task { @MainActor in
                    if self?.searchToken === token { self?.status = text }
                }
            }, partial: { rows in
                Task { @MainActor in
                    guard let self, self.searchToken === token else { return }
                    show(rows)
                    self.rowsVersion += 1
                }
            })
            guard let outcome else { return }
            Task { @MainActor in
                guard let self, self.searchToken === token else { return }
                show(outcome.rows)
                self.rowsVersion += 1
                self.searching = false
                self.unanswered = outcome.unanswered
                self.status = self.idleStatus()
            }
        }
    }

    /// A plain search takes milliseconds; only the checks are worth a card with a cancel button.
    var searchIsQuick: Bool {
        if listIsStaff {
            let wanted = activeStaffFilter.interestWanted
            return !(wanted.firstTeam || wanted.reserves || wanted.youth)
        }
        let wanted = activePlayerFilter.interestWanted
        return !(wanted.transfer || wanted.loan)
    }

    func cancelSearch() {
        searchToken?.cancel()
        searching = false
        status = "Stopped. The list shows what was found so far."
    }

    private func idleStatus() -> String {
        if screen == .shortlists, let openShortlist {
            var line = "Shortlist \"\(openShortlist.name)\": \(rowsShown.formatted()) of \(openShortlist.uids.count.formatted()) shown"
            if !openShortlist.isStaff, let club = session?.club.name, !club.isEmpty, let database {
                let uids = Set(openShortlist.uids)
                let mine = database.players.filter { $0.clubFull == club && uids.contains($0.uid) }.count
                if mine > 0 { line += " (\(mine) already at \(club) left out)" }
            }
            return line + "  ·  double-click for the full profile"
        }
        var line = "Double-click for the full profile  ·  Cmd-click two or three rows, then Compare  ·  Cmd-C copies the selected rows"
        if !listIsStaff {
            if readingSeasonStats { line += "  ·  reading season stats..." }
            if !seasonStatsAvailable { line += "  ·  season stats: not available on this version" }
        }
        return line
    }

    func sort(by column: String) {
        if listIsStaff {
            staffSort = staffSort.column == column ? SortState(column: column, descending: !staffSort.descending) : SortState(column: column)
        } else {
            playerSort = playerSort.column == column ? SortState(column: column, descending: !playerSort.descending) : SortState(column: column)
        }
        search()
    }

    // MARK: Cells that need the game

    /// Rows on screen ask for what they're missing, newest first, so scrolling doesn't queue the whole list.
    func cellNeedsCheck(_ person: Person, _ col: Col) {
        guard GameRules.engine != nil, person.block != 0, col.name != "Interest" || RulesState.shared.team != 0,
              laterChecks.begin(person, column: col.name), !laterChecks.running else { return }
        laterChecks.running = true
        drainChecks()
    }

    private func drainChecks() {
        let batch = laterChecks.next(16)
        guard !batch.isEmpty else {
            laterChecks.running = false
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for item in batch {
                switch item.person {
                case let player as Player where item.column == "Days out": _ = RulesState.shared.injuryCheck(player)
                case let player as Player: _ = RulesState.shared.check(player)
                case let staff as Staff: _ = RulesState.shared.staffCheck(staff)
                default: break
                }
            }
            Task { @MainActor in
                self?.cellsVersion += 1
                self?.drainChecks()
            }
        }
    }

    // MARK: People

    func person(_ ref: PersonRef) -> Person? {
        ref.isStaff ? staffByUID[ref.uid] : playersByUID[ref.uid]
    }

    func openProfile(_ person: Person) {
        if let openInsideGame {
            openInsideGame(.profile(PersonRef(person)))
        } else {
            openWindow?(id: WindowID.profile, value: PersonRef(person))
        }
    }

    var canCompare: Bool { Self.canCompare(selection) }

    static func canCompare(_ people: [Person]) -> Bool {
        (2...3).contains(people.count) && (people.allSatisfy { $0 is Player } || people.allSatisfy { $0 is Staff })
    }

    func compare(_ people: [Person]) {
        guard Self.canCompare(people) else { return }
        if let openInsideGame {
            openInsideGame(.compare(people.map(PersonRef.init)))
        } else {
            openWindow?(id: WindowID.compare, value: people.map(PersonRef.init))
        }
    }

    /// `PersonMenu.Build`.
    func menuItems(for people: [Person]) -> [MenuEntry] {
        guard let first = people.first else { return [] }
        let isStaff = first is Staff
        let comparable = Self.canCompare(people)
        let who = people.count == 1 ? first.name : "\(people.count) \(isStaff ? "staff" : "players")"
        return [
            MenuEntry(people.count == 1 ? "Open \(first.name)'s profile" : "Open \(first.name)'s profile (first selected)") { [weak self] in
                self?.openProfile(first)
            },
            MenuEntry(comparable ? "Compare these \(people.count)" : "Compare (select 2 or 3 rows)", enabled: comparable) { [weak self] in
                self?.compare(people)
            },
            .separator,
            MenuEntry("Add \(who) to shortlist", submenu: { [weak self] in self?.shortlistEntries(people, isStaff: isStaff) ?? [] }),
            MenuEntry(first.clubFull.isEmpty ? "Open club" : "Open \(first.clubFull)", enabled: !first.clubFull.isEmpty) { [weak self] in
                self?.openClub(first.clubFull)
            },
        ]
    }

    // MARK: Open squad

    func openClub(_ club: String) {
        squadClub = club
        squadName = OpenSquad.allSquads
        go(to: .openSquad)
        showSquad()
    }

    /// `OpenSquad`. A typed name that isn't a club says so rather than showing nothing.
    func showSquad() {
        guard let catalogue = squadCatalogue else { return }
        guard let club = catalogue.club(matching: squadClub) else {
            alert = OpenSquad.noSuchClub(squadClub)
            return
        }
        squadClub = club
        if squadShowsStaff {
            squadStaffFilter.openClub(club)
        } else {
            squadPlayerFilter.openSquad(club: club, squad: squadName == OpenSquad.allSquads ? nil : squadName)
        }
        search()
    }

    func showShortlist(_ shortlist: OpenShortlist?) {
        openShortlist = shortlist
        // The original starts from a clean filter too: a shortlist should show everyone on it.
        if shortlist?.isStaff == true {
            listStaffFilter = StaffFilter()
            listStaffFilter.job = "Any job"
            listStaffFilter.rank = StaffFilter.noRanking
            listStaffFilter.markDefaults()
            listStaffFilter.showHidden = showHidden
        } else {
            listPlayerFilter = PlayerFilter()
            listPlayerFilter.showHidden = showHidden
            listPlayerFilter.showAbility = showsAbility
        }
        if screen == .shortlists { search() }
    }

    func shortlistsChanged() { shortlistsVersion += 1 }

    func refreshOpenShortlist(_ url: URL, uids: [UInt32]) {
        guard let open = openShortlist, open.url == url else { return }
        showShortlist(OpenShortlist(url: url, name: open.name, isStaff: open.isStaff, uids: uids))
    }
}

/// What the menu bar depends on. Menus are expensive to rebuild, so they watch this and not the whole model,
/// which publishes on every row of a running search.
@MainActor
final class MenuState: ObservableObject {
    struct Values: Equatable {
        var hasData = false
        var isList = true
        var canCompare = false
        var loading = false
    }

    @Published var values = Values()
}

/// GameChecks' "Club total" scope, which is what the season columns show.
enum GameScope {
    static let clubTotal = 5
}

/// The queue behind `cellNeedsCheck`.
private struct LaterChecks {
    struct Item {
        let person: Person
        let column: String
    }

    private var waiting: [Item] = []
    private var asked = Set<String>()
    var running = false

    /// False if already asked: an answer of "don't know" mustn't be asked for again on every redraw.
    mutating func begin(_ person: Person, column: String) -> Bool {
        let key = "\(column)|\(person is Staff ? "s" : "p")\(person.uid)"
        guard asked.insert(key).inserted else { return false }
        waiting.append(Item(person: person, column: column))
        return true
    }

    mutating func next(_ count: Int) -> [Item] {
        let batch = Array(waiting.suffix(count).reversed())
        waiting.removeLast(batch.count)
        return batch
    }
}
