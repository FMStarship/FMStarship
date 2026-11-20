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

/// A database, and what `AppModel.install` needs from it that takes a while to build. The background task that read
/// the data builds it, so the main thread doesn't have to, and inside FM the main thread is FM's.
struct NewData {
    let database: Database
    let playerOptions: SearchOptions
    let staffOptions: SearchOptions
    let squads: OpenSquad.Choices

    init(_ database: Database) {
        self.database = database
        playerOptions = SearchOptions(database.players)
        staffOptions = SearchOptions(database.staff)
        squads = OpenSquad.Choices(db: database)
    }
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
    // They start with hidden values off, and `init` gives them the real setting. The Players search starts on the
    // chosen club's side; a squad or a shortlist shows everyone in it.
    @Published var playerFilter = PlayerFilter(showHidden: false, showAbility: false, gender: PlayerFilter.ownSide)
    @Published var staffFilter = StaffFilter(showHidden: false, showAbility: false)
    @Published var squadPlayerFilter = PlayerFilter(showHidden: false, showAbility: false)
    @Published var squadStaffFilter = StaffFilter(showHidden: false, showAbility: false)
    @Published var listPlayerFilter = PlayerFilter(showHidden: false, showAbility: false)
    @Published var listStaffFilter = StaffFilter(showHidden: false, showAbility: false)

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
    /// Set while FM's save is on a later day than the one loaded here.
    @Published private(set) var saveMovedOn: SaveProgress?
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
    let snapshotJob = BackgroundJob<NewData>()

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
    /// While `followSettingsFile` sets what it took from the file, which saves nothing.
    private var following = false
    private var playersByUID: [UInt32: Player] = [:]
    private var staffByUID: [UInt32: Staff] = [:]
    private var laterChecks = LaterChecks()
    /// The save and day a read was started for on showing the window, so that showing it again starts no more for them.
    private var readOnShowFor: SaveProgress?
    /// The day the last look at FM's date saw, when on the clock a look first saw it, and when the poll last saw it still.
    private var lastDaySeen: Date?
    private var daySeen: (first: TimeInterval, last: TimeInterval) = (0, 0)
    /// How long the poll must have seen FM on the same day before it isn't pressing on through days. FM can take more
    /// than the poll's 2 s over a day.
    static let settleTime: TimeInterval = 10
    /// The longest the poll's looks can be apart and still count as FM staying on its day. A longer gap is FM's main
    /// thread held up, as over a day, or the poll held back, so what FM did meanwhile wasn't seen.
    static let pollGap: TimeInterval = 4
    /// How long after the window is shown a read can still start for it. Inside FM the window can stay up while the
    /// player goes on pressing Continue, so the day FM holds 10 s on much later isn't one the player showed it for.
    static let showWait: TimeInterval = 60
    /// Outside FM a look at the date goes through the agent, off the main thread, one at a time.
    private var lookingAtDate = false
    /// Set when the window is shown, so a look at the date can start a read. It stays set while FM hasn't yet stayed on
    /// its day for `settleTime`, until the window is hidden, the app goes to the back, a read starts, or `showWait` is up.
    private var readIfMovedOn = false
    /// Until when on the clock `readIfMovedOn` lasts: `showWait` after the window was shown.
    private var readIfMovedOnUntil: TimeInterval = 0
    /// Starts a read nobody asked for. A test sets its own, so nothing reaches for FM.
    var readOnItsOwn: (AppModel) -> Void = { $0.loadSave(automatic: true) }
    /// Where each read's development snapshot is kept. Only `startUp()` sets it, so a test never writes to the player's.
    var developmentStore: DevelopmentStore?
    /// A read started on showing the window that finished while the player was in the middle of something, kept until
    /// they're done with it.
    private var heldRead: (data: NewData, engine: RulesEngine?)?
    /// What a read started on its own found wrong in the self-checks, kept on the status line rather than in an alert.
    private var quietSelfCheck: String?
    /// Whether one of FM Starship's windows has a sheet up: an export or shortlist panel, or a question. A test sets its own.
    var sheetShown: () -> Bool = { NSApp?.windows.contains { $0.attachedSheet != nil } ?? false }
    /// What the poll below costs, and installing a held read when it does. Inside FM they run on FM's main thread,
    /// and the plugin logs them.
    package let checkGameCost = TimerCost()
    package let heldReadCost = TimerCost()

    init() {
        tellFilters()
        colors = AppColors(themeNamed: Settings.current.theme)
        reloadColumns()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollGame() }
        }
    }

    func persist() { Settings.save() }

    /// Hidden attributes and Ability as last set in the other window, the app's or FM Starship's tab inside FM, once the
    /// settings file changes. Through the setters, so the screens follow and Off means gone in both. A follow saves nothing:
    /// what's taken from the file isn't this window's change, and capturing the columns would write this window's layout
    /// over the other's. First, a change a failed save left behind is saved, so the other window follows it too.
    func followSettingsFile() {
        Settings.saveIfPending()
        guard Settings.followFile() else { return }
        following = true
        defer { following = false }
        if showHidden != Settings.current.showHidden { showHidden = Settings.current.showHidden }
        let wanted = Reveal(setting: Settings.current.reveal)
        if reveal != wanted { reveal = wanted }
    }

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

    var filterSummary: String { summary(sayingSide: false) }

    /// `filterSummary`, and with `sayingSide`, the Players search's default side as well, for a line that would
    /// otherwise say there are no filters while one side is left out.
    func summary(sayingSide: Bool) -> String {
        listIsStaff ? activeStaffFilter.describe()
            : activePlayerFilter.describe(clubSignsWomen: session?.clubSignsWomen, sayingSide: sayingSide)
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

    /// `automatic` for a read the player didn't ask for, which says it failed on the status line rather than in an alert.
    func loadSave(automatic: Bool = false) {
        guard !loading else { return }
        loading = true
        readIfMovedOn = false
        status = "Connecting to Football Manager..."
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let (database, engine) = try GameReader.connect(status: { text in
                    Task { @MainActor in self?.status = text }
                }, log: AppLog.write)
                let data = NewData(database)
                await self?.finished(data, engine, automatic: automatic)
            } catch {
                await self?.failed("\(error)", automatic: automatic)
            }
        }
    }

    func finished(_ data: NewData, _ engine: RulesEngine?, automatic: Bool = false) {
        loading = false
        if automatic, playerIsBusy {
            heldRead = (data, engine)
            status = Self.heldReadNote
            return
        }
        GameRules.engine = engine
        install(data, automatic: automatic)
        let database = data.database, club = session?.club.name ?? ""
        if let developmentStore { DispatchQueue.global(qos: .utility).async { developmentStore.save(db: database, club: club) } }
        if let engine { loadSeasonStats(database, engine) }
    }

    func failed(_ message: String, automatic: Bool = false) {
        loading = false
        status = message
        if !automatic { alert = message }
    }

    static let heldReadNote = "Your save has been read again. It shows once you've closed what you have open."

    /// Installs the read held for the player, once they're done with what they had open, and not in the middle of
    /// another read, which would show the older one and leave the newer reading alongside.
    @discardableResult
    func useHeldRead() -> Bool {
        guard let heldRead, heldReadReady else { return false }
        finished(heldRead.data, heldRead.engine, automatic: true)
        return true
    }

    private var heldReadReady: Bool { heldRead != nil && !playerIsBusy && !loading }

    /// Everything that follows new data, wherever it came from. `automatic` for a read the player didn't ask for.
    func install(_ data: NewData, automatic: Bool = false) {
        let database = data.database
        heldRead = nil
        readOnShowFor = nil
        readIfMovedOn = false
        quietSelfCheck = nil
        seasonToken?.cancel()
        readingSeasonStats = false
        seasonStatsAvailable = true
        laterChecks = LaterChecks()
        saveMovedOn = nil
        lastDaySeen = nil

        RulesState.shared.reset()
        RulesState.shared.fill(database)
        Units.setCurrencies(database.currencies)
        Units.apply()
        reloadColumns()

        self.database = database
        playersByUID = Dictionary(database.players.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        staffByUID = Dictionary(database.staff.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        playerOptions = data.playerOptions
        staffOptions = data.staffOptions
        for keyPath in [\AppModel.playerFilter, \.squadPlayerFilter, \.listPlayerFilter] { self[keyPath: keyPath].fill(playerOptions) }
        for keyPath in [\AppModel.staffFilter, \.squadStaffFilter, \.listStaffFilter] { self[keyPath: keyPath].fill(staffOptions) }

        session = AnalysisSession(db: database, club: chosenClub(in: database), display: displayOptions, library: FMData.library)
        squadCatalogue = session.map { OpenSquad(session: $0, choices: data.squads) }
        analysisVersion += 1
        openShortlist = nil
        selection = []
        search()
        if let problems = database.checkProblems {
            let message = "FM Starship's self-checks failed on this save (\(problems)), so the numbers on screen may be wrong. If FM has just been patched, see Help > Compatibility."
            if automatic {
                quietSelfCheck = message
                if !searching { status = message }
            } else {
                alert = message
            }
        }
    }

    /// Every 2 s. A read held for the player is installed after the poll's own cost is measured, since that's a search
    /// and more, and has its own. The plugin logs both. `checkGame` has dropped it if FM has closed.
    func pollGame() {
        checkGameCost.measure {
            followSettingsFile()
            checkGame()
        }
        if heldReadReady { heldReadCost.measure { useHeldRead() } }
    }

    /// The rules read addresses that only mean something in the game they came from. When that game
    /// closes they go, and what was loaded stays on screen as plain data.
    private func checkGame() {
        gameState = GameLauncher.state
        guard let engine = GameRules.engine as? RulesEngine else { return }
        guard GameProcess.runningPID() != engine.pid else {
            // A held read about to be installed: the date is looked at again against it.
            if !heldReadReady { followSaveDate(engine, byPoll: true) }
            return
        }
        seasonToken?.cancel()
        GameRules.engine = nil
        RulesState.shared.reset()
        heldRead = nil
        saveMovedOn = nil
        lastDaySeen = nil
        status = "Football Manager closed. Showing what was last loaded."
        cellsVersion += 1
    }

    /// Looks at FM's game date where the read found it: two small reads, where reading everything again takes seconds,
    /// so it's done on the poll and the save is only read again when the window is shown or Load Save is pressed.
    /// Inside FM they're reads of FM's own memory, on its main thread as before. Outside it they're round trips to the
    /// agent, which would hold up the app's window if FM stopped answering, so they're made off the main thread.
    private func followSaveDate(_ engine: RulesEngine, byPoll: Bool) {
        guard !loading, !lookingAtDate, let database else { return }
        let game = engine.game
        guard !Self.isInsideGame else {
            let (now, time) = Self.look { GameReader.gameDate(of: database, in: game) }
            dateLooked(now, at: time, byPoll: byPoll)
            return
        }
        lookingAtDate = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (now, time) = Self.look { GameReader.gameDate(of: database, in: game) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lookingAtDate = false
                    // A read started or finished meanwhile, or FM closed: what was looked at belongs to the save before.
                    guard !self.loading, self.database === database, GameRules.engine === engine else {
                        self.readIfMovedOn = false
                        return
                    }
                    self.dateLooked(now, at: time, byPoll: byPoll)
                }
            }
        }
    }

    /// A look at FM's date, timed when it's made rather than when its answer arrives, so a slow round trip to the
    /// agent doesn't count as FM staying on its day.
    nonisolated static func look(_ read: () -> Date?) -> (date: Date?, time: TimeInterval) {
        let time = ProcessInfo.processInfo.systemUptime
        return (read(), time)
    }

    func dateLooked(_ now: Date?, at time: TimeInterval = ProcessInfo.processInfo.systemUptime, byPoll: Bool) {
        saveDateSeen(now, at: time, byPoll: byPoll)
        readIfShown(at: time)
    }

    /// Starts the read the window's showing asked for, if `takeReadOnShow` agrees. If all it's waiting for is FM to
    /// stay on its day, the poll's next looks ask again, for up to `showWait` after the window was shown.
    private func readIfShown(at time: TimeInterval) {
        guard readIfMovedOn else { return }
        if time > readIfMovedOnUntil {
            readIfMovedOn = false
        } else if takeReadOnShow() {
            readIfMovedOn = false
            readOnItsOwn(self)
        } else if !readOnShowWanted {
            readIfMovedOn = false
        }
    }

    /// FM's game date as it is now, nil when it can't be told, as once FM has let go of the save that was read. Only
    /// the poll's looks tell how long FM has stayed on a day; the window's own look can only see that it hasn't. Nor
    /// can a poll look that comes more than `pollGap` after the last, so the day's time starts over from it.
    func saveDateSeen(_ now: Date?, at time: TimeInterval = ProcessInfo.processInfo.systemUptime, byPoll: Bool = true) {
        if now != lastDaySeen || (byPoll && time - daySeen.last > Self.pollGap) {
            daySeen = (time, time)
        } else if byPoll {
            daySeen.last = time
        }
        lastDaySeen = now
        let progress = SaveProgress(readOn: database?.gameDate, now: now)
        if progress != saveMovedOn { saveMovedOn = progress }
    }

    /// Over a list the game couldn't narrow by who would join.
    var joinWarning: String { SaveProgress.joinWarning(saveMovedOn, canReload: GameRules.engine != nil) }

    /// FM Starship's window has been hidden or closed, or the app has gone to the back: a read it was waiting to start
    /// for being shown isn't wanted any more.
    package func windowHidden() {
        readIfMovedOn = false
    }

    /// FM Starship's window has been shown, or the app has come to the front. If the save has moved on since it was
    /// read, it's read again, once the date has been looked at and FM has stayed on its day, if that's within
    /// `showWait`.
    package func windowShown(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        readIfMovedOn = true
        readIfMovedOnUntil = time + Self.showWait
        if let engine = GameRules.engine as? RulesEngine, GameProcess.runningPID() == engine.pid { followSaveDate(engine, byPoll: false) }
        // A look still going on starts the read when it's done.
        if !lookingAtDate { readIfShown(at: time) }
    }

    /// Whether showing the window should start a read: once for each save and day it has moved on to, so a read that
    /// fails, or a window shown again and again, doesn't start one after another. Not while FM is still pressing on
    /// through days, nor while the player is in the middle of something.
    func takeReadOnShow() -> Bool {
        guard readOnShowWanted, daySettled else { return false }
        readOnShowFor = saveMovedOn
        return true
    }

    /// Everything a read on showing the window needs but FM staying on its day.
    private var readOnShowWanted: Bool {
        guard let saveMovedOn, !loading, !playerIsBusy, saveMovedOn != readOnShowFor else { return false }
        return true
    }

    /// FM has stayed on the day the last look saw for `settleTime`, by the poll's looks.
    var daySettled: Bool { lastDaySeen != nil && daySeen.last - daySeen.first >= Self.settleTime }

    /// The player is in the middle of something a read would throw away: the filter or columns sheet, another sheet,
    /// or a shortlist, which a read closes.
    var playerIsBusy: Bool {
        editingFilter || editingColumns || (screen == .shortlists && openShortlist != nil) || sheetShown()
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
        // The Players search keeps the chosen club's side, so its rows follow the club.
        search()
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
        return DisplayOptions(reveal: reveal, showHidden: showHidden, units: units, insideGame: Self.isInsideGame)
    }

    private func tellFilters() {
        for keyPath in [\AppModel.playerFilter, \.squadPlayerFilter, \.listPlayerFilter] {
            self[keyPath: keyPath].showHidden = showHidden
            self[keyPath: keyPath].showAbility = showsAbility
        }
        for keyPath in [\AppModel.staffFilter, \.squadStaffFilter, \.listStaffFilter] {
            self[keyPath: keyPath].showHidden = showHidden
            self[keyPath: keyPath].showAbility = showsAbility
        }
    }

    private func visibilityChanged() {
        if !following { persist() }
        tellFilters()
        rebuildShownColumns()
        if !following { captureColumns() }
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

    /// A filter typed in a column that Hidden attributes or Ability no longer allows does nothing.
    func parsedFilters(_ columns: [Col], _ texts: [String: String]) -> [(col: Col, filter: ColumnFilter)] {
        columns.compactMap { col in
            guard Columns.allowed(col, showHidden: showHidden, showAbility: showsAbility),
                  let text = texts[col.name], let filter = ColumnFilter.parse(text, numeric: col.numeric) else { return nil }
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
        let clubSignsWomen = session?.clubSignsWomen
        return PeopleSearch(people: database.players, match: { filter.criteria(clubSignsWomen: clubSignsWomen).filter($0) },
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

    /// The list's usual line, after what the player should still see: a read held for them, and self-checks that
    /// failed on a read nobody asked for.
    func idleStatus() -> String {
        let notes = [heldRead == nil ? nil : Self.heldReadNote, quietSelfCheck].compactMap { $0 }
        return (notes + [listStatus()]).joined(separator: "  ·  ")
    }

    private func listStatus() -> String {
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
        var removal: [MenuEntry] = []
        if screen == .shortlists, let open = openShortlist, open.isStaff == isStaff {
            let onIt = people.filter { open.uids.contains($0.uid) }
            removal = [MenuEntry("Remove \(who) from \"\(open.name)\"", enabled: !onIt.isEmpty) { [weak self] in
                self?.removeFromOpenShortlist(onIt)
            }]
        }
        return [
            MenuEntry(people.count == 1 ? "Open \(first.name)'s profile" : "Open \(first.name)'s profile (first selected)") { [weak self] in
                self?.openProfile(first)
            },
            MenuEntry(comparable ? "Compare these \(people.count)" : "Compare (select 2 or 3 rows)", enabled: comparable) { [weak self] in
                self?.compare(people)
            },
            .separator,
            MenuEntry("Add \(who) to shortlist", submenu: { [weak self] in self?.shortlistEntries(people, isStaff: isStaff) ?? [] }),
        ] + removal + [
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
        // Nothing open: its rows go too, so the list's menus can't act on a shortlist that's gone.
        if shortlist == nil, screen == .shortlists {
            selection = []
            players = []
            staff = []
        }
        // The original starts from a clean filter too: a shortlist should show everyone on it.
        if shortlist?.isStaff == true {
            listStaffFilter = StaffFilter(showHidden: showHidden, showAbility: showsAbility)
            listStaffFilter.job = "Any job"
            listStaffFilter.rank = StaffFilter.noRanking
            listStaffFilter.markDefaults()
        } else {
            listPlayerFilter = PlayerFilter(showHidden: showHidden, showAbility: showsAbility)
        }
        if screen == .shortlists { search() }
    }

    func shortlistsChanged() { shortlistsVersion += 1 }

    /// The open shortlist's file changed: show who's on it now, keeping the filters the player has on it.
    func refreshOpenShortlist(_ url: URL, uids: [UInt32]) {
        guard let open = openShortlist, open.url == url else { return }
        openShortlist = OpenShortlist(url: url, name: open.name, isStaff: open.isStaff, uids: uids)
        if screen == .shortlists { search() }
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
