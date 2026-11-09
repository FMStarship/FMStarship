import AppKit
import Combine
import FMStarshipUI
import Foundation
@preconcurrency import StarshipAnalysis
@preconcurrency import StarshipCore
import StarshipFiles

/// FM Starship inside FM's own interface: a tab in FM's navigation bar, and screens made of FM's elements, under
/// subtabs of their own, where FM shows its own. Going to any of FM's screens puts the game's back.
@MainActor
final class FMInterface {
    static let shared = FMInterface()

    private typealias Pointer = IL2CPP.Pointer

    private var model: AppModel?
    private var timer: Timer?
    private var watching: AnyCancellable?

    /// Our elements and FM's, held through GC handles: FM's collector can't see Swift's memory.
    private var tab: IL2CPP.Handle?
    private var tabButton: IL2CPP.Handle?
    /// FM's tab that was lit when ours went up, dark while ours is.
    private var fmTab: IL2CPP.Handle?
    private static let litClasses = ["navigation-tab-portal-default-active-true", "buttongroup__button--active"]
    private var screen: IL2CPP.Handle?
    private var menuBody: IL2CPP.Handle?
    /// FM's layer of report cards over its screens, such as the player database.
    private var reportBody: IL2CPP.Handle?
    /// What our screen is in: within FM's own screen, or FM's screen area when there's no screen of FM's showing.
    private var screenHost: IL2CPP.Handle?

    /// Where our screen goes. Within the binding scope of FM's screen, FM's elements in ours, like its tables, find
    /// what FM's screens give them: the game, the manager, the team. The developer command `host` changes it.
    private enum Host: String { case scope, panel, body }
    private var hostIn = Host.scope
    /// FM's screens we hid, with the inline display each had before.
    private var hidden: [(handle: IL2CPP.Handle, display: (Int32, Int32))] = []
    /// What FM's screen area held when ours went up, so we notice FM going somewhere else.
    private var fmState: [String] = []

    /// Our subtab row, in place of FM's while our screen is up.
    private var subtabs: IL2CPP.Handle?
    private var subtabButtons: [Pointer] = []

    /// The FM table last made for a screen of ours, for the developer's `table` commands.
    private var lastTable: IL2CPP.Handle?

    private var current: StarshipScreen = .dashboard
    /// Each screen's content, and the analysis it was made from.
    private var contents: [StarshipScreen: MadeScreen<ScreenContent>] = [:]
    private var running: Set<StarshipScreen> = []
    /// The analysis and search each screen's work last came back empty for.
    private var cameBackEmpty: [StarshipScreen: WorkFor] = [:]
    /// Which of the model's reads the screens may be made from: none from before FM loaded another save.
    private var saveWatch = SaveWatch()
    /// FM's memory, for the clubs' names in `saveNow`.
    private lazy var game: GameProcess? = try? GameProcess.insideGame()
    /// The Recommended signings and Bargains searches, as last applied, set up again for each read of the save.
    private var signingSearch: SigningSearch?
    private var bargainSearch: BargainSearch?
    private weak var searchSession: AnalysisSession?
    private var searchRevision = -1
    /// Goes up each time a screen's search changes, so what a search started before then finds isn't shown.
    private var searchVersions: [StarshipScreen: Int] = [:]
    /// The search being changed on its screen's Edit Search page, until Apply or Cancel.
    private var editing: (screen: StarshipScreen, draft: any ScreenSearch)?
    /// The Edit Search page's switches, which FM's switch changes itself when clicked, so they're read back.
    private var editToggles: [(id: String, element: Pointer)] = []
    /// An open dropdown list on the Edit Search page, and the layer behind it.
    private var openList: [Pointer] = []
    private var shown = ""
    private var look: TileLook?
    private var lastProblem = ""
    /// What our timers cost FM's main thread, written to the log once a minute.
    private let tickCost = TimerCost(), rowsCost = TimerCost()
    private var costsWritten = Date()

    func start(model: AppModel) {
        self.model = model
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                FMInterface.shared.tickCost.measure { FMInterface.shared.tick() }
                FMInterface.shared.writeCosts()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        watching = model.objectWillChange.sink { _ in
            // objectWillChange comes before the change, so look once it's made.
            DispatchQueue.main.async { MainActor.assumeIsolated { FMInterface.shared.modelChanged() } }
        }
        #if STARSHIP_DEVELOPER
        TableDump.shared.startWatchingIfAsked()
        #endif
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated { FMInterface.shared.mouseDown(event) }
            return event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FMInterface.shared.stop() }
        }
    }

    /// FM is quitting. Unity may shut IL2CPP down before the run loop turns again, so no timer of ours fires after this,
    /// and nothing else calls into FM: `IL2CPP.shared` is nil from now on.
    private func stop() {
        IL2CPP.stop()
        timer?.invalidate()
        timer = nil
        rowsTimer?.invalidate()
        rowsTimer = nil
        #if STARSHIP_DEVELOPER
        TableDump.shared.stop()
        #endif
        PluginLog.write("FM is quitting, so FM Starship stops")
    }

    /// A click on FM's own navigation goes back to FM: its tabs, as moving between FM's tabs does, its bookmarks and
    /// its Back button. That includes the tab or bookmark of the screen under ours, which FM itself leaves as it is.
    /// A tab's dropdown arrow only opens FM's menu, and choosing from that changes FM's screen, which `followFM`
    /// notices.
    private func mouseDown(_ event: NSEvent) {
        // A click in FM Starship's own windows over FM isn't one on FM's interface, wherever it lands.
        guard let window = event.window, !Plugin.shared.owns(window), let view = window.contentView, view.bounds.width > 0,
              view.bounds.height > 0, let il2cpp = IL2CPP.shared, let ui = FMElements(il2cpp) else { return }
        il2cpp.withoutCollection {
            guard let root = try? ui.mainRoot(), let panel = ui.layout(root) else { return }
            // FM's interface fills the window, in its own units, from the top left.
            let point = view.convert(event.locationInWindow, from: nil)
            let x = Float(point.x / view.bounds.width) * panel.width
            let y = Float((view.isFlipped ? point.y : view.bounds.height - point.y) / view.bounds.height) * panel.height
            guard let element = screen.flatMap(ui.il2cpp.target) else {
                // With ours closed by a click in it, FM's Back to the screen that was under it brings ours back.
                if comeBack != nil, let back = ui.query(root, "BackButton"), ui.contains(back, x: x, y: y) {
                    comeBackUntil = Date().addingTimeInterval(4)
                } else if comeBack != nil, y < 110 {
                    comeBack = nil
                }
                return
            }
            if ui.contains(element, x: x, y: y) { clickedInside = Date() }
            if let clicked = ((try? fmTabs(ui)) ?? []).first(where: { ui.contains($0.tab, x: x, y: y) }) {
                if let arrow = ui.query(clicked.tab, "NavTabDropdown"), ui.contains(arrow, x: x, y: y) { return }
                PluginLog.write("FM's \(ui.name(of: clicked.tab)) clicked, so its screen comes back")
                return leave(ui)
            }
            // FM's bookmarks sit at the end of the row our subtabs are in; its Back button at the start of its bar.
            let bookmarks = ui.query(root, "SecondaryNavigationBarTabs").flatMap(ui.parent(of:)).flatMap { ui.children(of: $0).last }
            for element in [bookmarks, ui.query(root, "BackButton")].compactMap({ $0 }) where ui.contains(element, x: x, y: y) {
                PluginLog.write("FM's \(ui.name(of: element).isEmpty ? "bookmarks" : ui.name(of: element)) clicked, so FM's screen comes back")
                return leave(ui)
            }
        }
    }

    /// The last click inside our screen, such as on a player's name, which can take FM to a screen of its own.
    private var clickedInside: Date?
    /// FM's screens that were under ours when a click in ours took FM elsewhere: FM's Back to them brings ours back,
    /// as Back from a player's profile returns to FM's own list. Until when Back's return is waited for.
    private var comeBack: [String]?
    private var comeBackUntil: Date?
    /// When ours last came back with FM's Back.
    private var cameBack: Date?
    /// FM's screens showing, in its screen area and its report cards, as which elements they are.
    private var underState: [String] = []

    private func visibleState(_ ui: FMElements) -> [String] {
        guard let root = try? ui.mainRoot() else { return [] }
        let ours = screen.flatMap(ui.il2cpp.target)
        return ["MenuBody", "ReportBody"].compactMap { ui.query(root, $0) }.flatMap { ui.children(of: $0) }
            .filter { $0 != ours && ui.hasClass($0, "panel--visible") }.map { "\($0)" }
    }

    private func waitToComeBack(_ ui: FMElements) {
        guard screen == nil, let state = comeBack, let until = comeBackUntil else { return }
        if Date() > until {
            comeBack = nil
            comeBackUntil = nil
        } else if visibleState(ui) == state {
            comeBack = nil
            comeBackUntil = nil
            PluginLog.write("FM went back to the screen under ours, so ours comes back")
            cameBack = Date()
            do { try show(ui) } catch { report(error) }
        }
    }

    /// Twice a second: keep our tab in FM's bar, which FM builds again now and then, and notice FM moving on.
    private func tick() {
        // Until FM's IL2CPP is up, or if this build lacks something it needs: the next tick tries again.
        guard let il2cpp = IL2CPP.shared, let ui = FMElements(il2cpp) else { return }
        il2cpp.withoutCollection {
            do {
                try keepTab(ui)
                watchSave(ui)
                #if STARSHIP_DEVELOPER
                runCommand(ui)
                #endif
                waitToComeBack(ui)
                if screen != nil { followFM(ui) }
                if screen != nil { watchFMTab(ui) }
                lastProblem = ""
            } catch {
                report(error)
            }
        }
    }

    private func writeCosts() {
        guard Date().timeIntervalSince(costsWritten) >= 60 else { return }
        costsWritten = Date()
        let costs = [("tick", tickCost), ("refreshRows", rowsCost), ("checkGame", model?.checkGameCost)]
            .compactMap { name, cost in cost?.take().map { "\(name) \($0)" } }
        if !costs.isEmpty { PluginLog.write("FM's main thread, last minute: " + costs.joined(separator: "; ")) }
    }

    private func report(_ error: Error) {
        let problem = "\(error)"
        if problem != lastProblem { PluginLog.write("FM Starship in FM: \(problem)") }
        lastProblem = problem
    }

    // MARK: The save

    /// The model's analysis, unless it was read before FM loaded another save, or may have.
    private var analysis: AnalysisSession? {
        guard let session = model?.analysis, saveWatch.usable(session.db) else { return nil }
        return session
    }

    /// Notices FM's save no longer being the one read: another date in FM's bar, or the clubs gone from where the read
    /// found them in FM's memory, as after Load Save.
    private func watchSave(_ ui: FMElements) {
        guard let model else { return }
        let session = model.analysis
        switch saveWatch.follow(read: session?.db, loading: model.readingSave, now: { self.saveNow(ui, session) }) {
        case .none:
            break
        case .saveChanged:
            saveChanged("FM's date or club isn't what it was when your save was read", ui)
        case .readWasStale:
            PluginLog.write("The read going on when FM's save changed is done, and is stale too")
            if screen != nil { model.loadSaveAgain() }
        }
    }

    /// The save as FM shows it now. A snapshot's clubs were found in another run of FM, so they can't be looked for.
    private func saveNow(_ ui: FMElements, _ session: AnalysisSession?) -> SaveIdentity {
        guard let session, !session.db.source.hasPrefix("snapshot") else { return SaveIdentity() }
        let widget = (try? ui.mainRoot()).flatMap { ui.query($0, "CurrentDayWidget") }
        let date = widget.flatMap { ui.query($0, "Month") }.flatMap(ui.shownText)
        let clubs = game.flatMap { game in
            session.db.humanClubs.isEmpty ? nil : session.db.humanClubs.map { GameReader.clubName(team: $0.team, in: game) }.joined(separator: ", ")
        }
        return SaveIdentity(date: date, clubs: clubs)
    }

    /// FM has loaded another save, or may have. Nothing made from what was read before is shown again: the save is read
    /// again when FM Starship's screen next opens, which says it's reading until then.
    private func saveChanged(_ why: String, _ ui: FMElements) {
        PluginLog.write("\(why), so your save is read again when FM Starship's screen opens")
        saveWatch.saveChanged(read: model?.analysis?.db, loading: model?.readingSave ?? false)
        if screen != nil { leave(ui) }
        contents = [:]
        stopTables()
        signingSearch = nil
        bargainSearch = nil
        searchSession = nil
        searchRevision = -1
        editing = nil
        shown = ""
    }

    /// Reads the save if there's none to show: the first time, or once FM may have loaded another.
    func loadSaveIfNeeded() {
        guard let model else { return }
        if let il2cpp = IL2CPP.shared, let ui = FMElements(il2cpp) { il2cpp.withoutCollection { watchSave(ui) } }
        if saveWatch.needsReading(model.analysis?.db, loading: model.readingSave) { model.loadSaveAgain() }
    }

    // MARK: The tab

    private func keepTab(_ ui: FMElements) throws {
        guard let root = try ui.mainRoot(), let group = ui.query(root, "ManagingClubButtons") else { return }
        if let element = tab.flatMap(ui.il2cpp.target), ui.parent(of: element) == group { return }
        // FM built its bar again, or this is the first time we've seen it with a career loaded.
        if screen != nil { leave(ui) }
        // FM builds it again on loading a save, and after a match.
        if tab != nil { saveChanged("FM built its bar again", ui) }
        release(&tab)
        release(&tabButton)
        let (element, button) = try makeTab(ui)
        let children = ui.children(of: group)
        let last = children.lastIndex { ui.name(of: $0).hasSuffix("Button") } ?? (children.count - 1)
        try ui.insert(element, into: group, at: last + 1)
        tab = ui.il2cpp.pin(element)
        tabButton = ui.il2cpp.pin(button)
        PluginLog.write("FM Starship tab added to FM's navigation bar")
    }

    /// The same elements and classes as FM's own tabs, so FM's style sheets draw it like them.
    private func makeTab(_ ui: FMElements) throws -> (tab: Pointer, button: Pointer) {
        let tab = try ui.box(name: "FMStarshipButton")
        let button = try ui.box(["sibutton", "navigatable", "navigation-tab-portal-default-active-false", "margin-horizontal-global-gap-none",
                                 "buttongroup__button"], name: "buttons-button-navigation-default")
        let face = try ui.box(["thematic-md", "justify-content-center"])
        let frame = try ui.box(["row-direction-normal", "padding-bottom-global-padding-none", "padding-left-global-padding-none",
                                "padding-top-global-padding-none", "padding-right-global-padding-large", "align-items-center"], name: "MainFrame")
        let textFrame = try ui.box(name: "TextVisible")
        let text = try ui.text("FM STARSHIP", ["portal-text", "margin-right-global-gap-none", "sitext-hover-cursor", "margin-right-global-gap-small",
                                              "thematic-md"], name: "text")
        let chipFrame = try ui.box(["align-self-centre", "margin-right-global-gap-small", "navigation-chip-container", "width-100-percent"],
                                   name: "NavigationChip")
        let chip = try ui.box(["navigation-chip", "flex-grow-class", "align-self-centre"], name: "Chip")
        // FM's tab templates fill the bar's height, so the face's centring puts the text in the middle like theirs.
        // The button and face grow down the tab's height; the tab keeps its own width, as FM's do.
        try ui.style(tab) { try $0.number("flexShrink", 0) }
        for element in [button, face] {
            try ui.style(element) { style in
                try style.number("flexGrow", 1)
                try style.number("flexShrink", 0)
            }
        }
        try ui.add(chip, to: chipFrame)
        try ui.add(text, to: textFrame)
        try ui.add(chipFrame, to: textFrame)
        try ui.add(textFrame, to: frame)
        try ui.add(frame, to: face)
        try ui.add(face, to: button)
        try ui.add(button, to: tab)
        try ui.onClick(button) { FMInterface.shared.tabClicked() }
        return (tab, button)
    }

    private func setTabActive(_ active: Bool, _ ui: FMElements) {
        guard let button = tabButton.flatMap(ui.il2cpp.target) else { return }
        try? ui.removeClass(button, "navigation-tab-portal-default-active-\(!active)")
        try? ui.addClass(button, "navigation-tab-portal-default-active-\(active)")
    }

    /// FM's tabs, each with its button, as FM's bar holds them now. Ours isn't one of them.
    private func fmTabs(_ ui: FMElements) throws -> [(tab: Pointer, button: Pointer)] {
        guard let root = try ui.mainRoot(), let group = ui.query(root, "ManagingClubButtons") else { return [] }
        return ui.children(of: group).compactMap { tab in
            let name = ui.name(of: tab)
            guard name.hasSuffix("Button"), name != "FMStarshipButton",
                  let button = ui.query(tab, "buttons-button-navigation-default") else { return nil }
            return (tab, button)
        }
    }

    /// FM's lit tab goes dark while ours is up, as when FM moves from one of its tabs to another.
    private func darkenFMTab(_ ui: FMElements) throws {
        guard let lit = try fmTabs(ui).first(where: { ui.hasClass($0.button, Self.litClasses[0]) }) else { return }
        for name in Self.litClasses { try ui.removeClass(lit.button, name) }
        fmTab = ui.il2cpp.pin(lit.button)
    }

    /// FM lights its tab again when it's clicked, even with its screen already under ours: that's the way back to it.
    /// Just after ours came back with FM's Back, FM lights it again as it finishes going back, which isn't a click, so
    /// it goes dark again. A click on it then is still seen by `mouseDown`.
    private func watchFMTab(_ ui: FMElements) {
        guard let button = fmTab.flatMap(ui.il2cpp.target), ui.hasClass(button, Self.litClasses[0]) else { return }
        if let back = cameBack, Date().timeIntervalSince(back) < 3 {
            for name in Self.litClasses { try? ui.removeClass(button, name) }
            return
        }
        PluginLog.write("FM lit its tab again, so its screen comes back")
        leave(ui)
    }

    /// Lights FM's tab again on leaving, unless FM has lit one itself by going somewhere else.
    private func relightFMTab(_ ui: FMElements) {
        defer { release(&fmTab) }
        guard let button = fmTab.flatMap(ui.il2cpp.target), let tabs = try? fmTabs(ui),
              !tabs.contains(where: { ui.hasClass($0.button, Self.litClasses[0]) }) else { return }
        for name in Self.litClasses { try? ui.addClass(button, name) }
    }

    private func tabClicked() {
        guard let ui = FMElements(IL2CPP.shared) else { return }
        PluginLog.write("FM Starship tab clicked")
        if screen != nil {
            // FM's style for a lit tab takes no clicks, ours included, so this is only for a click that gets through:
            // the tab's first screen. FM's own tabs are the way back to FM.
            select(.dashboard)
        } else {
            do { try show(ui) } catch { report(error) }
        }
    }

    // MARK: The screen

    /// Puts our screen up. If any of that fails, whatever was done is undone first, so FM's own screen isn't left hidden.
    private func show(_ ui: FMElements) throws {
        do {
            try putUp(ui)
        } catch {
            leave(ui)
            throw error
        }
    }

    private func putUp(_ ui: FMElements) throws {
        guard let root = try ui.mainRoot(), let body = ui.query(root, "MenuBody") else { throw IL2CPP.Failure("No screen area in FM") }
        // Before ours is up, so that FM's save having changed only means reading it again.
        loadSaveIfNeeded()
        let fmScreens = ui.children(of: body)
        if look == nil { look = TileLook.copied(from: fmScreens, ui) }
        if !FMTable.ready(.players) || !FMTable.ready(.staff) {
            // From one of FM's own player tables, if a screen of FM's has one, or from the last start's.
            FMTable.lookForAssets(below: [body] + [ui.query(root, "ReportBody")].compactMap { $0 }, ui)
            FMTable.loadAssets(ui)
        }
        // Hide FM's screens under ours, as FM does with its own, and remember how each was so it goes back the same.
        // Ours goes within FM's own screen when one is showing, with everything of FM's around it hidden.
        let panel = hostIn == .body ? nil : fmScreens.first { ui.hasClass($0, "panel--visible") }
        let host = panel.map { hostIn == .scope ? scope(in: $0, ui) ?? $0 : $0 } ?? body
        for element in fmScreens where element != (panel ?? body) { try hide(element, ui) }
        if let panel {
            var inner = host
            for element in ui.children(of: host) { try hide(element, ui) }
            while inner != panel, let outer = ui.parent(of: inner) {
                for element in ui.children(of: outer) where element != inner { try hide(element, ui) }
                inner = outer
            }
        }
        // A report card of FM's over its screen, such as the player database, makes way for ours, and comes back after.
        let reports = ui.query(root, "ReportBody")
        for element in reports.map({ ui.children(of: $0) }) ?? [] where ui.hasClass(element, "panel--visible") { try hide(element, ui) }
        reportBody = reports.flatMap { ui.il2cpp.pin($0) }
        fmState = state(of: body, ui)
        underState = visibleState(ui)
        // Our subtabs where FM's are, with our name where FM shows the tab's, for as long as our screen is up.
        if let fmTabs = ui.query(root, "SecondaryNavigationBarTabs"), let row = ui.parent(of: fmTabs),
           let index = ui.children(of: row).firstIndex(of: fmTabs) {
            let siblings = ui.children(of: row)
            if index > 0 { try hide(siblings[index - 1], ui) }
            try hide(fmTabs, ui)
            let bar = try ui.box(["row-direction-normal", "align-items-center", "flex-grow-class"], name: "FMStarshipSubtabs")
            // FM's subtabs stretch across the row, which keeps its bookmarks over on the right.
            try ui.style(bar) { try $0.number("flexGrow", 1) }
            try ui.insert(bar, into: row, at: max(0, index - 1))
            subtabs = ui.il2cpp.pin(bar)
        }
        let element = try ui.box(["flex-grow-class"], name: "FMStarshipScreen")
        try ui.style(element) { style in
            try style.keyword("position", 1)
            for side in ["left", "top", "right", "bottom"] { try style.length(side, 0) }
        }
        try ui.add(element, to: host)
        screen = ui.il2cpp.pin(element)
        menuBody = ui.il2cpp.pin(body)
        screenHost = ui.il2cpp.pin(host)
        PluginLog.write("FM Starship screen in \(panel.map { "FM's \(ui.name(of: $0)), in its \(ui.il2cpp.name(of: ui.il2cpp.classOf(host)))" } ?? "FM's screen area")")
        setTabActive(true, ui)
        try darkenFMTab(ui)
        shown = ""
        startWork()
        if let staff = current.listsStaff { model?.showListInsideGame(staff: staff) }
        try fillOrSay(ui)
        PluginLog.write("FM Starship screen shown")
    }

    /// Where FM's screen holds its content: down from the panel through the elements that fill it, such as the
    /// Portal's binding scope or the Squad screen's safe area, to the last before FM's grid of tiles, which places
    /// whatever is in it. There, FM's elements in ours find what the screen gives its own, wherever FM sets it.
    private func scope(in panel: Pointer, _ ui: FMElements) -> Pointer? {
        guard let size = ui.layout(panel), size.width > 0, size.height > 0 else { return nil }
        var host = panel
        for _ in 0..<12 {
            let filling = ui.children(of: host).first { child in
                guard let child = ui.layout(child) else { return false }
                return child.width >= size.width * 0.95 && child.height >= size.height * 0.95
            }
            guard let next = filling else { break }
            let kind = ui.il2cpp.name(of: ui.il2cpp.classOf(next))
            if kind.contains("Grid") || kind.contains("ScrollView") || kind.contains("Layout") { break }
            host = next
        }
        return host == panel ? nil : host
    }

    private func hide(_ element: Pointer, _ ui: FMElements) throws {
        let before = try ui.inlineEnum(element, "display")
        try ui.style(element) { try $0.keyword("display", 1) }
        if let handle = ui.il2cpp.pin(element) { hidden.append((handle, before)) }
    }

    /// Puts FM's screens and subtabs back as they were and takes ours away.
    private func leave(_ ui: FMElements) {
        for (handle, display) in hidden {
            if let element = ui.il2cpp.target(of: handle) { try? ui.style(element) { try $0.setEnum("display", display) } }
            ui.il2cpp.unpin(handle)
        }
        hidden = []
        for handle in [screen, subtabs].compactMap({ $0 }) {
            if let element = ui.il2cpp.target(of: handle) { try? ui.remove(element) }
        }
        release(&screen)
        release(&subtabs)
        release(&menuBody)
        release(&screenHost)
        release(&reportBody)
        stopTables()
        forgetSubtabClicks()
        forgetListClicks()
        setTabActive(false, ui)
        relightFMTab(ui)
        PluginLog.write("FM Starship screen closed")
    }

    /// FM opening another screen changes what its screen area holds, or which of it is visible, and so does FM
    /// opening a report card over its screens.
    private func followFM(_ ui: FMElements) {
        // FM putting away a screen it has already hidden, such as the profile Back has just left, isn't FM moving on.
        if let body = menuBody.flatMap(ui.il2cpp.target) {
            let now = state(of: body, ui)
            if now != fmState, Self.visible(now) == Self.visible(fmState) { fmState = now }
        }
        guard let body = menuBody.flatMap(ui.il2cpp.target), let host = screenHost.flatMap(ui.il2cpp.target),
              let element = screen.flatMap(ui.il2cpp.target), ui.parent(of: element) == host, state(of: body, ui) == fmState else {
            // A click in ours, such as on a player's name, took FM to a screen of its own: Back can bring ours back.
            if let clicked = clickedInside, Date().timeIntervalSince(clicked) < 3 { comeBack = underState }
            leave(ui)
            return
        }
    }

    private func state(of body: Pointer, _ ui: FMElements) -> [String] {
        let ours = screen.flatMap(ui.il2cpp.target)
        let reports = reportBody.flatMap(ui.il2cpp.target).map { ui.children(of: $0) } ?? []
        return (ui.children(of: body) + reports).filter { $0 != ours }.map { "\($0) \(ui.hasClass($0, "panel--visible"))" }
    }

    /// Of a state, the screens FM shows.
    nonisolated static func visible(_ state: [String]) -> [String] { state.filter { $0.hasSuffix(" true") } }

    /// The chosen screen, or, where it can't be built on this FM build, a note saying so in its place. Throws only if
    /// even that can't be shown.
    private func fillOrSay(_ ui: FMElements) throws {
        do {
            try fill(ui)
        } catch {
            report(error)
            guard let element = screen.flatMap(ui.il2cpp.target) else { throw error }
            // What was built of it goes, with any of FM's tables in it.
            stopTables()
            for child in ui.children(of: element) { try ui.remove(child) }
            let page = NativePage(ui: ui, look: look ?? .fallback)
            try page.message(Self.cantBuild("\(error)"), title: current.title, in: try page.body(in: element))
        }
    }

    /// What a screen that can't be built says, with the first line of what went wrong. FM's exceptions bring their
    /// stack with them, which is for the log.
    nonisolated static func cantBuild(_ problem: String) -> String {
        let first = problem.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? problem
        return "FM Starship couldn't build this screen on this build of FM, so it's off until FM Starship is updated for it. "
            + "FM's own screens work as usual. What went wrong: \(first.trimmingCharacters(in: .whitespaces))"
    }

    /// The subtabs and the chosen screen's content: what it found, or what's happening until then.
    private func fill(_ ui: FMElements) throws {
        guard let element = screen.flatMap(ui.il2cpp.target) else { return }
        let content = shownContent
        let status = statusLine
        // The app's Players and Staff searches: drawn again when one finishes, and while one runs, as it goes.
        let list = current.listsStaff.flatMap { model?.listInsideGame(staff: $0) }
        let listState = list.map { $0.searching ? "searching \(model?.statusLine ?? "")" : "\($0.version) \($0.filter)" } ?? ""
        if let session = analysis, let revision = model?.analysisRevision { updateSearches(session, revision: revision) }
        let searchState = editing.map { $0.screen == current ? "editing \($0.draft.key)" : "" } ?? search(for: current)?.key ?? ""
        // Drawn again once FM's own tables are known, in place of plain rows.
        let known = FMTable.Kind.allCases.map { FMTable.ready($0) ? "1" : "0" }.joined()
        let key = "\(current) \(content?.revision ?? -1) \(status) \(chosenShortlist?.path ?? "") \(listState) \(searchState) \(known)"
        guard key != shown else { return }
        // The tables of what was showing go with it, and so do its clickable entries.
        stopTables()
        forgetListClicks()
        try fillSubtabs(ui)
        for child in ui.children(of: element) { try ui.remove(child) }
        let page = NativePage(ui: ui, look: look ?? .fallback)
        if let editing, editing.screen == current, analysis != nil {
            try fillEditSearch(editing.draft, in: element, page: page, ui)
            shown = key
            return
        }
        if let staff = current.listsStaff, analysis != nil {
            try fillList(staff: staff, list, in: element, page: page, ui)
            shown = key
            return
        }
        switch content?.content {
        case .dashboard(let dashboard):
            let tables = FMTable.ready
            // The hint goes over the first tile only: once is enough on one screen.
            var hinted = false
            try NativeDashboard(page: page).build(into: try page.body(in: element), dashboard: dashboard) { section, columns, tile, rows in
                if tables {
                    try self.addFMTable(section, columns: columns, in: tile, rows: min(rows, NativePage.rowLimit), ui)
                } else {
                    if !hinted { try page.hint(NativePage.tableHint(section.kind), in: tile) }
                    hinted = true
                    try page.rows(of: section, in: tile)
                }
            }
        case .tables(let sections):
            if sections.count == 1, let section = sections.first, let columns = section.fmColumns, FMTable.ready(section.kind) {
                try fmTableScreen(section, columns: columns, in: element, page: page, ui)
            } else {
                let body = try page.body(in: element)
                if let buttons = try searchButtons(page) {
                    let row = try ui.box(["row-direction-normal", "justify-content-end"])
                    try ui.add(buttons, to: row)
                    try ui.add(try page.spaced(row, bottom: 12), to: body)
                }
                for section in sections {
                    if let columns = section.fmColumns, FMTable.ready(section.kind) {
                        try fmTableTile(section, columns: columns, in: body, page: page, ui)
                    } else {
                        try page.table(section, in: body, hint: Self.fallsBack(section, ready: FMTable.ready) ? NativePage.tableHint(section.kind) : nil)
                    }
                }
            }
        case .shortlists(let lists):
            let tables = FMTable.ready
            listButtons = try NativeShortlists(page: page).build(
                into: try page.fixedBody(in: element), lists: lists, chosen: chosenShortlist, columns: Self.playerColumns,
                table: { section, tile in
                    if tables {
                        try self.addFMTable(section, columns: section.fmColumns ?? Self.playerColumns, in: tile, rows: nil, ui)
                    } else {
                        try page.hint(NativePage.tableHint(section.kind), in: tile)
                        try page.rows(of: section, in: tile)
                    }
                },
                choose: { FMInterface.shared.chooseShortlist($0) })
        case nil:
            try page.message(status, title: current.title, in: try page.body(in: element))
        }
        shown = key
    }

    /// The app's Players or Staff search, in FM's own table, with a button for the app's filters.
    private func fillList(staff: Bool, _ list: (people: [Person], searching: Bool, filter: String, version: Int)?, in element: Pointer,
                          page: NativePage, _ ui: FMElements) throws {
        guard let model, let session = analysis else { return }
        guard let list else {
            try page.message("FM Starship's own window is on another screen. Choose \(current.title) here again to search.",
                             title: current.title, in: try page.body(in: element))
            return
        }
        let view = PeopleListView(people: list.people, staff: staff, filter: list.filter, display: session.display)
        let kind: FMTable.Kind = staff ? .staff : .players
        let tables = FMTable.ready(kind)
        let searching = list.searching ? (model.statusLine.isEmpty ? current.working : model.statusLine) : nil
        let button = try NativeSearch(page: page).build(
            into: try page.fixedBody(in: element), list: view, searching: searching,
            table: { section, tile in
                if tables {
                    try self.addFMTable(section, columns: section.fmColumns ?? [], in: tile, rows: nil, ui)
                } else {
                    // FM's tables are taken from one of FM's own, the first time a screen of FM's with one is open.
                    try page.hint(NativePage.tableHint(kind), in: tile)
                    try page.rows(of: section, in: tile)
                }
            },
            editFilters: { FMInterface.shared.model?.editFiltersInsideGame(staff: staff) })
        listButtons = [button]
    }

    // MARK: Edit Search

    /// The search of a screen that has one, as last applied.
    private func search(for screen: StarshipScreen) -> (any ScreenSearch)? {
        switch screen {
        case .signings: return signingSearch
        case .bargains: return bargainSearch
        default: return nil
        }
    }

    private func setSearch(_ search: any ScreenSearch, for screen: StarshipScreen) {
        switch screen {
        case .signings: if let search = search as? SigningSearch { signingSearch = search }
        case .bargains: if let search = search as? BargainSearch { bargainSearch = search }
        default: return
        }
        searchVersions[screen, default: 0] += 1
        contents[screen] = nil
        PluginLog.write("\(screen.title) searches again: \(search.key)")
        startWork()
    }

    /// The searches for this read of the save. As in the app, Bargains' max fee goes back to the transfer budget
    /// each time the save is read; the rest is kept.
    private func updateSearches(_ session: AnalysisSession, revision: Int) {
        guard revision != searchRevision else { return }
        searchRevision = revision
        let newSave = searchSession !== session
        searchSession = session
        let display = session.display
        let budget = BargainFinder(session: session).startingMaxFee
        signingSearch = SigningSearch(options: signingSearch?.options ?? RecommendOptions(), units: display.units, budget: budget)
        bargainSearch = BargainSearch(keeping: bargainSearch?.options, newSave: newSave, startingMaxFee: budget,
                                      units: display.units, showsAbility: display.showsAbility,
                                      canCheckInterest: session.checks.canCheckInterest)
        if var draft = editing?.draft {
            // The page being changed keeps what's on it, in the save's new terms.
            let position = draft.position
            let criteria = draft.criteria
            draft = search(for: editing?.screen ?? current) ?? draft
            draft.position = position
            for criterion in draft.criteria {
                guard let was = criteria.first(where: { $0.id == criterion.id }) else { continue }
                switch (was.control, criterion.control) {
                case (.choice(let choices, let selected), .choice(let now, _)):
                    if choices.indices.contains(selected), let index = now.firstIndex(of: choices[selected]) { draft.choose(criterion.id, index) }
                case (.toggle(let on, _), .toggle(let now, _)):
                    if on != now { draft.toggle(criterion.id) }
                default: break
                }
            }
            editing?.draft = draft
        }
    }

    /// FM's player database's buttons over its list, for a screen with a search: Clear and Edit Search.
    private func searchButtons(_ page: NativePage) throws -> Pointer? {
        guard let search = search(for: current) else { return nil }
        let buttons = try NativeEditSearch(page: page).searchButtons(search, clear: { FMInterface.shared.clearSearch() },
                                                                     edit: { FMInterface.shared.editSearch() })
        listButtons += buttons.clickable
        return buttons.row
    }

    private func fillEditSearch(_ draft: any ScreenSearch, in element: Pointer, page: NativePage, _ ui: FMElements) throws {
        let built = try NativeEditSearch(page: page).build(into: element, search: draft, actions: EditSearchActions(
            open: { id, dropdown in FMInterface.shared.openDropdown(id, dropdown) },
            toggled: { id, _ in FMInterface.shared.toggled(id) },
            position: { FMInterface.shared.changeDraft { $0.position = $1 }($0) },
            clearAll: { FMInterface.shared.changeDraft { draft, _ in draft.clear() }(0) },
            cancel: { FMInterface.shared.cancelEdit() },
            apply: { FMInterface.shared.applySearch() }))
        listButtons += built.clickable
        editToggles = built.toggles
    }

    private func editSearch() {
        guard let search = search(for: current) else { return }
        PluginLog.write("Edit Search: \(current.title)")
        editing = (current, search)
        refreshLater()
    }

    private func clearSearch() {
        guard var search = search(for: current) else { return }
        search.clear()
        setSearch(search, for: current)
        refreshLater()
    }

    /// A change to the search being edited, which the page then shows.
    private func changeDraft(_ change: @escaping (inout any ScreenSearch, Int) -> Void) -> (Int) -> Void {
        { value in
            let interface = FMInterface.shared
            interface.readToggles()
            guard var draft = interface.editing?.draft else { return }
            change(&draft, value)
            interface.editing?.draft = draft
            interface.refreshLater()
        }
    }

    /// FM's switch changes itself when clicked, and this follows it; the page is then made again from the search.
    /// If the switch didn't change itself, `readToggles` would put that right before anything else is done.
    private func toggled(_ id: String) {
        guard var draft = editing?.draft else { return }
        draft.toggle(id)
        editing?.draft = draft
        refreshLater()
    }

    /// The search being edited, as its switches show it.
    private func readToggles() {
        guard var draft = editing?.draft, let ui = FMElements(IL2CPP.shared) else { return }
        for (id, element) in editToggles {
            guard let on = ui.toggleValue(element), let criterion = draft.criteria.first(where: { $0.id == id }),
                  case .toggle(let was, true) = criterion.control, on != was else { continue }
            draft.toggle(id)
        }
        editing?.draft = draft
    }

    private func openDropdown(_ id: String, _ dropdown: Pointer) {
        readToggles()
        guard openList.isEmpty, let criterion = editing?.draft.criteria.first(where: { $0.id == id }),
              case .choice(let choices, let selected) = criterion.control else { return }
        // Once FM has finished with the click.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let interface = FMInterface.shared
                guard let il2cpp = IL2CPP.shared, let ui = FMElements(il2cpp), let element = interface.screen.flatMap(il2cpp.target) else { return }
                il2cpp.withoutCollection {
                    do {
                        let page = NativePage(ui: ui, look: interface.look ?? .fallback)
                        let list = try NativeEditSearch(page: page).list(
                            choices, selected: selected, under: dropdown, in: element,
                            choose: { index in
                                interface.closeList()
                                interface.changeDraft { draft, index in draft.choose(id, index) }(index)
                            },
                            close: { interface.closeList() })
                        interface.openList = list.elements
                        interface.listButtons += list.clickable
                    } catch {
                        interface.report(error)
                    }
                }
            }
        }
    }

    private func closeList() {
        let elements = openList
        openList = []
        guard !elements.isEmpty else { return }
        // Once FM has finished with the click, which came from the list or the layer behind it.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let ui = FMElements(IL2CPP.shared) else { return }
                for element in elements { try? ui.remove(element) }
            }
        }
    }

    private func cancelEdit() {
        editing = nil
        refreshLater()
    }

    private func applySearch() {
        readToggles()
        guard let editing else { return }
        self.editing = nil
        if search(for: editing.screen)?.key != editing.draft.key { setSearch(editing.draft, for: editing.screen) }
        refreshLater()
    }

    /// Draws the screen again once FM has finished with the click that changed it, which may have come from an
    /// element the screen is about to lose.
    private func refreshLater() {
        DispatchQueue.main.async { MainActor.assumeIsolated { FMInterface.shared.refresh() } }
    }

    /// Whether a list that goes in FM's own table is in plain rows instead, because FM's table of its kind isn't known
    /// yet. The engine's own tables, such as the squad's places, are always in plain rows.
    nonisolated static func fallsBack(_ section: TableSection, ready: (FMTable.Kind) -> Bool) -> Bool {
        section.fmColumns != nil && !ready(section.kind)
    }

    /// One list in FM's own player table, filling the screen as FM's lists do, with the engine's line below it.
    private func fmTableScreen(_ section: TableSection, columns: [String], in element: Pointer, page: NativePage, _ ui: FMElements) throws {
        let body = try page.fixedBody(in: element)
        let tile = try page.tile()
        try ui.style(tile) { try $0.number("flexGrow", 1) }
        if let buttons = try searchButtons(page) {
            // FM's table grows to fill the tile, and would squeeze the row above it.
            let top = try ui.box(["row-direction-normal", "align-items-start"])
            try ui.style(top) { try $0.number("flexShrink", 0) }
            let heading = try ui.box()
            try ui.style(heading) { try $0.number("flexGrow", 1) }
            try page.heading(section.title, note: section.table.head, in: heading)
            try ui.add(heading, to: top)
            try ui.add(buttons, to: top)
            try ui.add(top, to: tile)
        } else {
            try page.heading(section.title, note: section.table.head, in: tile)
        }
        try ui.add(tile, to: body)
        try addFMTable(section, columns: columns, in: tile, rows: nil, ui)
        try linesBelow(section, in: tile, page: page, ui)
    }

    /// One list in FM's own player table, in a tile of its own on a page with others, as tall as its rows.
    private func fmTableTile(_ section: TableSection, columns: [String], in body: Pointer, page: NativePage, _ ui: FMElements) throws {
        let tile = try page.tile()
        try page.heading(section.title, note: section.table.head, in: tile)
        try ui.add(tile, to: body)
        let people = section.table.rows.filter { $0.person != nil }.count
        if people > 0 { try addFMTable(section, columns: columns, in: tile, rows: min(people, NativePage.rowLimit), ui) }
        try linesBelow(section, in: tile, page: page, ui)
    }

    /// What goes under one of FM's tables: the engine's rows that are about nobody, such as a gap no player fills,
    /// as lines of text, then its status line and notes.
    private func linesBelow(_ section: TableSection, in tile: Pointer, page: NativePage, _ ui: FMElements) throws {
        for row in section.table.rows where row.person == nil {
            let text = row.cells.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
            let line = try ui.text(text, ["body-sm", "global-text-secondary"])
            if let tone = row.tone { try page.colour(line, tone) }
            try ui.add(try page.spaced(line, top: 6), to: tile)
        }
        let status = NativePage.withoutAppHints(section.table.status)
        for line in [status] + section.notes where !line.isEmpty {
            try ui.add(try page.spaced(try ui.text(line, ["body-sm", "global-text-secondary"]), top: 8), to: tile)
        }
    }

    /// One of FM's player tables with the section's people, in `container`, which must be in FM's tree: tall enough
    /// for `rows` rows, or filling the container. FM's columns, then the engine's own, as `section.fmExtras` names them.
    @discardableResult
    func addFMTable(_ section: TableSection, columns: [String], in container: IL2CPP.Pointer, rows: Int?, _ ui: FMElements) throws -> IL2CPP.Pointer {
        let fmTable = FMTable(ui: ui, kind: section.kind)
        let table = try fmTable.make(name: "FMStarship-\(current)-\(liveTables.count)")
        try ui.style(table) { style in
            if let rows {
                try style.length("height", 26 + Float(rows) * FMTable.rowHeight)
                try style.number("flexShrink", 0)
            } else {
                try style.number("flexGrow", 1)
            }
        }
        try ui.add(FMTable.wrapInRoot ? try fmTable.wrap(table) : table, to: container)
        if let old = lastTable { ui.il2cpp.unpin(old) }
        lastTable = ui.il2cpp.pin(table)
        // Bound before its rows go in, so each row gets its key under the table's, as in FM's own tables.
        if FMTable.bindIfIdle, !fmTable.isBound(table) { _ = fmTable.call(table, "BindToData") }
        let people = section.table.rows.compactMap(\.person)
        // The engine's CA and PA, as the Ability setting shows them, in FM's columns for them, and its own columns.
        let extras = FMTable.extras(from: section.table, titles: section.fmExtras)
        let chosen = FMTable.columnOverride ?? FMTable.columns(columns, with: extras)
        // FM can't sort by our values, so its sorting is off for our columns; clicking their headings sorts here.
        let own = Dictionary(extras.filter { $0.title != nil || !FMTable.abilitySortable }.map { ($0.host, $0.width) },
                             uniquingKeysWith: { first, _ in first })
        try fmTable.fill(table, people: people, columns: chosen, own: own, extras: extras)
        PluginLog.write("FM's table for \(current.title): \(fmTable.report(table))")
        keepRows(table, extras, people: people)
        checkLater(table, kind: section.kind, people: people, columns: chosen, own: own, extras: extras, attempt: 1)
        return table
    }

    /// One of FM's tables on our screen: kept fitted to its height, holding the engine's values as FM draws its rows,
    /// and sorted by our columns when their headings are clicked.
    private final class LiveTable {
        let handle: IL2CPP.Handle
        let extras: [FMTable.Extra]
        let people: [Person]
        /// Whether its values were made with Hidden attributes on: with it on, they can be CA and PA.
        let showsAbility: Bool
        let shown = FMTable.Shown()
        var sort: FMTable.Sort?

        init(handle: IL2CPP.Handle, extras: [FMTable.Extra], people: [Person], showsAbility: Bool) {
            self.handle = handle
            self.extras = extras
            self.people = people
            self.showsAbility = showsAbility
        }
    }

    private var liveTables: [LiveTable] = []
    private var rowsTimer: Timer?

    private func keepRows(_ table: Pointer, _ extras: [FMTable.Extra], people: [Person]) {
        guard let handle = IL2CPP.shared?.pin(table) else { return }
        liveTables.append(LiveTable(handle: handle, extras: extras, people: people, showsAbility: analysis?.display.showsAbility ?? false))
        guard rowsTimer == nil else { return }
        // Often enough that a row FM reuses while scrolling or sorting shows its new person's values at once.
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { FMInterface.shared.rowsCost.measure { FMInterface.shared.refreshRows() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        rowsTimer = timer
    }

    private func refreshRows() {
        guard let il2cpp = IL2CPP.shared, let ui = FMElements(il2cpp) else { return }
        il2cpp.withoutCollection {
            guard screen != nil else { return stopTables() }
            // Values made with Hidden attributes on aren't written again once it's off: the screen is made again.
            let showsAbility = analysis?.display.showsAbility
            if liveTables.contains(where: { !MadeScreen<Void>.fits(madeWith: $0.showsAbility, now: showsAbility) }) {
                stopTables()
                shown = ""
                return refreshLater()
            }
            let fmTable = FMTable(ui: ui)
            for live in liveTables {
                guard let table = il2cpp.target(of: live.handle), ui.parent(of: table) != nil else { continue }
                // Sorting by one of FM's own columns takes over from ours.
                if live.sort != nil, fmTable.sortedByFM(table, besides: live.extras) { live.sort = nil }
                fmTable.refreshRows(table, live.extras, shown: live.shown, sort: live.sort) { [weak live] host in
                    // Sorting rebuilds the table, so it waits until FM has finished with the click on its heading.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { if let live { FMInterface.shared.sort(live, by: host) } }
                    }
                }
            }
        }
    }

    /// A click on one of our columns' headings: highest first, then the other way on the next click, as FM's do.
    private func sort(_ live: LiveTable, by host: String) {
        guard let il2cpp = IL2CPP.shared, let ui = FMElements(il2cpp), let extra = live.extras.first(where: { $0.host == host }) else { return }
        let descending = live.sort?.host == host ? !(live.sort?.descending ?? true) : true
        il2cpp.withoutCollection {
            guard let table = il2cpp.target(of: live.handle) else { return }
            do {
                try FMTable(ui: ui).setRows(table, FMTable.sorted(live.people, by: extra, descending: descending))
                live.sort = FMTable.Sort(host: host, descending: descending)
                PluginLog.write("FM's table sorted by \(extra.title ?? host), \(descending ? "highest" : "lowest") first")
            } catch {
                report(error)
            }
        }
    }

    /// Lets go of the tables of a screen that's gone.
    private func stopTables() {
        rowsTimer?.invalidate()
        rowsTimer = nil
        for live in liveTables {
            live.shown.forget(IL2CPP.shared)
            IL2CPP.shared?.unpin(live.handle)
        }
        liveTables = []
    }

    /// The table loads FM's column factory once it's in the tree. A moment later, this says what it made of it, and
    /// puts the columns and rows in again if it has none yet.
    private func checkLater(_ table: Pointer, kind: FMTable.Kind, people: [Person], columns: [String], own: [String: Float], extras: [FMTable.Extra],
                            attempt: Int) {
        guard let handle = IL2CPP.shared?.pin(table) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                guard let il2cpp = IL2CPP.shared, let ui = FMElements(il2cpp) else { return }
                defer { il2cpp.unpin(handle) }
                il2cpp.withoutCollection {
                    // A table of a screen that's gone still has a parent, so it's looked for among the tables up now.
                    guard let table = il2cpp.target(of: handle),
                          FMInterface.shared.liveTables.contains(where: { il2cpp.target(of: $0.handle) == table }) else { return }
                    let fmTable = FMTable(ui: ui, kind: kind)
                    PluginLog.write("FM's table, check \(attempt): \(fmTable.report(table))")
                    guard fmTable.columnCount(table) == 0, attempt < 3 else { return }
                    if FMTable.bindIfIdle, !fmTable.isBound(table) {
                        PluginLog.write("FM's table still isn't bound, so it's asked again: \(fmTable.call(table, "BindToData"))")
                    }
                    do {
                        try fmTable.fill(table, people: people, columns: columns, own: own, extras: extras)
                    } catch {
                        FMInterface.shared.report(error)
                    }
                    FMInterface.shared.checkLater(table, kind: kind, people: people, columns: columns, own: own, extras: extras, attempt: attempt + 1)
                }
            }
        }
    }

    /// What's happening while the chosen screen has nothing to show yet.
    private var statusLine: String {
        guard let model else { return "" }
        if analysis == nil { return model.statusLine.isEmpty ? "Reading your save..." : model.statusLine }
        return shownContent == nil && current.listsStaff == nil ? current.working : ""
    }

    /// The chosen screen as last made, if it was made with Hidden attributes as it is now. Until it's made again, the
    /// screen says it's working.
    private var shownContent: MadeScreen<ScreenContent>? {
        contents[current].flatMap { $0.fits(showsAbility: analysis?.display.showsAbility) ? $0 : nil }
    }

    // MARK: The subtabs

    /// FM's subtab row, made again for FM Starship's screens: the name on the left, then a tab per screen.
    private func fillSubtabs(_ ui: FMElements) throws {
        guard let bar = subtabs.flatMap(ui.il2cpp.target) else { return }
        forgetSubtabClicks()
        for child in ui.children(of: bar) { try ui.remove(child) }

        let label = try ui.box(["row-direction-normal", "main-nav-secondary-bar", "align-items-center", "justify-content-end"])
        try ui.style(label) { style in
            try style.length("width", 144)
            try style.length("height", 24)
        }
        try ui.add(try ui.text("FM Starship", ["thematic-xs"]), to: label)
        let divider = try ui.box(["layout-layout-divider-solid-vertical"])
        try ui.style(divider) { style in
            try style.length("height", 24)
            try style.length("marginLeft", 8)
        }
        try ui.add(divider, to: label)
        try ui.add(label, to: bar)

        let tabs = try ui.box(["row-direction-normal", "main-nav-secondary-bar", "padding-left-global-padding-extra-small"])
        for screen in StarshipScreen.allCases {
            let active = screen == current
            let item = try ui.box(["navigation-secondary-text-portal-default-active-\(active)"])
            let button = try ui.box(["sibutton", "navigatable", "sitext-hover-cursor", "navigation-_navigation-dropdown-menu_item_base-default",
                                     "margin-horizontal-global-gap-none", "align-items-center", "secondary-navigation-padding-box"])
            try ui.add(try ui.text(screen.title, ["body-md", "secondary-navigation-tab-text", "sitext-hover-cursor",
                                                  "padding-top-global-padding-extra-small"]), to: button)
            // FM draws its underline with a gradient element of its own, so ours is sized and coloured here.
            let underline = try ui.box()
            try ui.style(underline) { style in
                try style.length("height", 2)
                try style.percent("width", 100)
                try style.length("marginTop", 2)
                try style.number("flexShrink", 0)
                try style.color("backgroundColor", active ? (0.95, 0.95, 0.98, 1) : (0, 0, 0, 0))
            }
            try ui.add(underline, to: button)
            try ui.add(button, to: item)
            try ui.add(item, to: tabs)
            try ui.onClick(button) { FMInterface.shared.select(screen) }
            subtabButtons.append(button)
        }
        try ui.add(tabs, to: bar)
    }

    /// The open shortlist, by its file. The newest until one is chosen.
    private var chosenShortlist: URL?
    /// The shortlists' entries on the left of their screen, which can be clicked.
    private var listButtons: [Pointer] = []

    /// Opens another shortlist, once FM has finished with the click on its entry, which goes when the screen is
    /// rebuilt.
    private func chooseShortlist(_ url: URL) {
        guard url != chosenShortlist else { return }
        PluginLog.write("Shortlist chosen: \(url.deletingPathExtension().lastPathComponent)")
        chosenShortlist = url
        DispatchQueue.main.async { MainActor.assumeIsolated { FMInterface.shared.refresh() } }
    }

    private func forgetSubtabClicks() {
        for button in subtabButtons { ClickActions.actions[button] = nil }
        subtabButtons = []
    }

    /// The screen's own clickable entries, its switches and an open dropdown, which go with what's showing.
    private func forgetListClicks() {
        for entry in listButtons { ClickActions.actions[entry] = nil }
        listButtons = []
        editToggles = []
        openList = []
    }

    /// Changing screens rebuilds the row the click came from, so it waits until FM has finished with the click.
    private func select(_ screen: StarshipScreen) {
        // FM's own tables may be found by now, in one of FM's screens under ours, which can still be loading when ours
        // opens. The screen is drawn again with them.
        if FMTable.Kind.allCases.contains(where: { !FMTable.ready($0) }), let ui = FMElements(IL2CPP.shared) {
            FMTable.lookForAssets(below: [menuBody, reportBody].compactMap { $0.flatMap(ui.il2cpp.target) }, ui)
            if screen == current { refreshLater() }
        }
        guard screen != current else { return }
        PluginLog.write("Subtab chosen: \(screen.title)")
        current = screen
        // Edit Search is a page of its own, which choosing another screen leaves without applying it.
        editing = nil
        // Shortlist files change while FM runs, whenever one is saved, so they're read again each time.
        if screen == .shortlists { contents[.shortlists] = nil }
        if let staff = screen.listsStaff { model?.showListInsideGame(staff: staff) }
        startWork()
        DispatchQueue.main.async { MainActor.assumeIsolated { FMInterface.shared.refresh() } }
    }

    // MARK: The work

    private func modelChanged() {
        startWork()
        refresh()
    }

    /// Works out the chosen screen in the background, once per analysis, as the app's screens do.
    private func startWork() {
        // The app runs its own searches for the Players and Staff screens.
        guard screen != nil, current.listsStaff == nil, let model, let session = analysis else { return }
        let revision = model.analysisRevision
        let showsAbility = session.display.showsAbility
        let chosen = current
        let version = searchVersions[chosen, default: 0]
        guard Self.needsWork(made: contents[chosen]?.revision, empty: cameBackEmpty[chosen], running: running.contains(chosen),
                             now: WorkFor(revision: revision, version: version)) else { return }
        updateSearches(session, revision: revision)
        let signings = signingSearch?.options ?? RecommendOptions()
        let bargains = bargainSearch?.options
        running.insert(chosen)
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let content = Self.work(chosen, session: session, signings: signings, bargains: bargains)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let interface = FMInterface.shared
                    let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                    PluginLog.write("\(chosen.title) \(content == nil ? "came back empty" : "ready") in \(seconds) s")
                    interface.running.remove(chosen)
                    // A search changed since this started is made again, below.
                    // Nor is what was made from a read FM's save has changed under.
                    if let content, version == interface.searchVersions[chosen, default: 0], session === interface.analysis {
                        interface.contents[chosen] = MadeScreen(revision: revision, showsAbility: showsAbility, content: content)
                    }
                    if content == nil { interface.cameBackEmpty[chosen] = WorkFor(revision: revision, version: version) }
                    interface.refresh()
                    // In case the save was read again while this was being made.
                    interface.startWork()
                }
            }
        }
    }

    /// What a screen's work is done for: the analysis, and the screen's search.
    struct WorkFor: Equatable {
        let revision: Int
        let version: Int
    }

    /// Whether a screen's work starts: not while it's running, nor for the analysis it was last made from, nor again
    /// for an analysis and search it came back empty for, since it would come back empty again, over and over.
    nonisolated static func needsWork(made: Int?, empty: WorkFor?, running: Bool, now: WorkFor) -> Bool {
        !running && made != now.revision && empty != now
    }

    /// The same engine calls as the app's screens, with the searches set on their Edit Search pages: at first, the
    /// app's own starting options.
    nonisolated private static func work(_ screen: StarshipScreen, session: AnalysisSession, signings: RecommendOptions,
                                         bargains: BargainOptions?) -> ScreenContent? {
        switch screen {
        case .dashboard:
            return .dashboard(ClubDashboard(session: session))
        case .signings:
            guard let table = SigningRecommender(session: session).find(signings) else { return nil }
            return .tables([TableSection(title: "Recommended signings", table: table, fmColumns: playerColumns,
                                         fmExtras: ["CA", "PA", "Would join on", "vs your best"])])
        case .planner:
            let lines = SquadPlanner.analyse(session)
            let squad = SquadPlanner.squadView(lines, session: session)
            let start = SquadPlanner.startingBudget(session)
            var sections = [Self.fmSection("Your first team", squad.table, fm: ["Player": "name", "Best": "name"])]
            if let plan = SquadPlanner.plan(session, lines: lines, budget: start.budget, wageRoom: start.wageRoom, includeLoans: false) {
                sections.append(Self.fmSection("Signings for the plan", plan.table, fm: ["Name": "name", "Age": "age", "Club": "club"]))
            }
            return .tables(sections)
        case .bargains:
            let finder = BargainFinder(session: session)
            var options = bargains ?? BargainOptions()
            // The app's max fee starts at the transfer budget.
            if bargains == nil { options.maxFee = finder.startingMaxFee }
            guard let table = finder.find(options) else { return nil }
            return .tables([TableSection(title: "Bargains", table: table, fmColumns: bargainColumns, fmExtras: ["CA", "PA", "Would join on"])])
        case .shortlists:
            let players = Dictionary(session.db.players.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
            // Only FM's own folders, under Library: looking in Documents, where the Windows game keeps them, would make
            // macOS ask the player whether FM may, which FM never does itself.
            let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path + "/"
            var roots = ShortlistFile.gameRoots().filter { $0.standardizedFileURL.path.hasPrefix(library) }
            #if STARSHIP_DEVELOPER
            roots += [testShortlistRoot].compactMap { $0 }
            #endif
            return .shortlists(ShortlistFile.list(isStaff: false, roots: roots).map { entry in
                ShortlistView(url: entry.url, name: entry.shortlist.name, modified: entry.modified, uids: entry.shortlist.uids,
                              players: players, club: session.club.name, display: session.display)
            })
        case .players, .staff:
            // The app's own searches, which the app runs.
            return nil
        }
    }

    /// A whole engine table in FM's own player table: FM's columns where `fm` names them for the engine's, and the
    /// engine's own for the rest, in the engine's order.
    nonisolated private static func fmSection(_ title: String, _ table: AnalysisTable, fm: [String: String]) -> TableSection {
        let layout = FMTable.layout(of: table, fm: fm)
        return TableSection(title: title, table: table, fmColumns: layout.columns, fmExtras: layout.extras)
    }

    /// FM's own columns for a list of players to sign, by their IDs in FM's PlayerTableFactory, as FM's recruitment
    /// and squad tables use them. FM fills them with what it shows of each player.
    nonisolated private static let playerColumns = ["name", "age", "nation", "club", "scouted-best-position-and-role", "transfer-value",
                                                    "wage", "scout-opinion-current-ability", "scout-opinion-potential-ability"]
    /// Bargains are about contracts running out, so FM's contract column goes next to the value.
    nonisolated private static let bargainColumns = ["name", "age", "nation", "club", "scouted-best-position-and-role", "contract-expiry-date",
                                                     "transfer-value", "wage", "scout-opinion-current-ability", "scout-opinion-potential-ability"]

    private func refresh() {
        guard screen != nil, let il2cpp = IL2CPP.shared, let ui = FMElements(il2cpp) else { return }
        il2cpp.withoutCollection {
            do {
                try fillOrSay(ui)
            } catch {
                // Not even the note could go up, so FM's own screen comes back.
                report(error)
                leave(ui)
            }
        }
    }

    // MARK: Development

    #if STARSHIP_DEVELOPER
    /// For checking these screens without a hand on FM, which ignores clicks while it isn't the front app: a command
    /// written to this file, which is then removed, opens, switches or closes FM Starship's screen, or writes out FM's
    /// interface or its tables. Nothing in it changes the game's own screens or data. Only in developer builds
    /// (`Scripts/install-plugin.sh --developer`), because any program running as the player could write the file.
    static let commandFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FMStarship/Plugin/command")

    private func runCommand(_ ui: FMElements) {
        guard let data = try? Data(contentsOf: Self.commandFile) else { return }
        try? FileManager.default.removeItem(at: Self.commandFile)
        let words = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
        PluginLog.write("Command: \(words.joined(separator: " "))")
        switch words.first {
        case "open":
            if screen == nil { do { try show(ui) } catch { report(error) } }
        case "close":
            if screen != nil { leave(ui) }
        case "screen":
            guard let name = words.dropFirst().first, let chosen = StarshipScreen.allCases.first(where: { "\($0)" == name }) else {
                PluginLog.write("Screens: \(StarshipScreen.allCases.map { "\($0)" }.joined(separator: ", "))")
                return
            }
            if screen == nil { do { try show(ui) } catch { report(error) } }
            select(chosen)
        case "dump":
            InterfaceDump.shared.write()
        case "tables":
            TableDump.shared.write()
        case "host":
            hostIn = words.dropFirst().first.flatMap(Host.init(rawValue:)) ?? .scope
            PluginLog.write("FM Starship's screen goes in FM's \(hostIn.rawValue) from the next time it opens")
        case "refs":
            referencesCommand(ui)
        case "table":
            tableCommand(Array(words.dropFirst()), ui)
        case "methods":
            InterfaceDump.shared.writeMethodMap()
        case "uids":
            // Who's in the screen's tables, by FM's unique IDs, for making test files such as a shortlist.
            for live in liveTables { PluginLog.write(live.people.map { "\($0.uid) \($0.name)" }.joined(separator: "; ")) }
        case "shortlists":
            // A folder with a "shortlists" folder in it, read as well as FM's own, for trying the Shortlists screen.
            Self.testShortlistRoot = words.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            contents[.shortlists] = nil
            PluginLog.write("Shortlists are read from FM's folders\(Self.testShortlistRoot.map { " and \($0.path)" } ?? "")")
            startWork()
        default:
            PluginLog.write("Commands: open, close, screen <name>, dump, tables, methods, host panel|body, table ..., uids, shortlists <folder>")
        }
    }

    /// The `shortlists` command's folder.
    nonisolated(unsafe) private static var testShortlistRoot: URL?

    /// Trying out how FM's table starts, on the one last made: calling one of its methods that takes nothing, or
    /// changing how the next one is made, which choosing its subtab again does.
    private func tableCommand(_ words: [String], _ ui: FMElements) {
        let fmTable = FMTable(ui: ui)
        let table = lastTable.flatMap(ui.il2cpp.target)
        switch (words.first, words.dropFirst().first) {
        case ("call", let method?):
            guard let table else { return PluginLog.write("No FM table made yet") }
            PluginLog.write(fmTable.call(table, method))
            PluginLog.write("FM's table now: \(fmTable.report(table))")
        case ("report", _):
            guard let table else { return PluginLog.write("No FM table made yet") }
            PluginLog.write("FM's table: \(fmTable.report(table))")
        case ("root", let value?):
            FMTable.wrapInRoot = value == "on"
            PluginLog.write("FM's table gets a BindingRoot of its own: \(FMTable.wrapInRoot)")
        case ("bind", let value?):
            FMTable.bindIfIdle = value == "on"
            PluginLog.write("FM's table is asked to bind itself: \(FMTable.bindIfIdle)")
        case ("refs", let value?):
            FMTable.withUID = value == "uid"
            PluginLog.write("FM's table rows carry the unique ID: \(FMTable.withUID)")
        case ("height", let value?):
            FMTable.rowHeight = Float(value) ?? FMTable.rowHeight
            PluginLog.write("FM's table rows are \(FMTable.rowHeight) high from the next table")
        case ("widths", let value?):
            FMTable.widths = FMTable.Widths(rawValue: value) ?? .min
            PluginLog.write("Our columns' widths go to FM as: \(FMTable.widths.rawValue)")
        case ("casort", let value?):
            FMTable.abilitySortable = value == "on"
            PluginLog.write("CA and PA sort by FM's own columns for them: \(FMTable.abilitySortable)")
        case ("columns", let value?):
            FMTable.columnOverride = value == "default" ? nil : value.split(separator: ",").map(String.init)
            PluginLog.write("FM's table columns from the next table: \(FMTable.columnOverride?.joined(separator: ", ") ?? "the screen's own")")
        default:
            PluginLog.write("Table commands: call <Method>, report, root on|off, bind on|off, refs index|uid, height <n>, columns <id,...>|default, casort on|off, widths none|min|width|both")
        }
        // Made again with the change, as choosing the subtab again would.
        if ["height", "columns", "refs", "root", "casort", "widths"].contains(words.first ?? "") {
            shown = ""
            refresh()
        }
    }

    /// The references in our FM table's first rows beside those in FM's own tables on screen, to compare.
    private func referencesCommand(_ ui: FMElements) {
        let fmTable = FMTable(ui: ui)
        if let table = lastTable.flatMap(ui.il2cpp.target) {
            PluginLog.write("Our table's references:\n" + fmTable.describeReferences(in: table).joined(separator: "\n"))
        }
        guard let tableClass = ui.il2cpp.findClass("SI.Bindable", "StreamedTable"), let root = try? ui.mainRoot() else { return }
        var queue = ["MenuBody", "ReportBody"].compactMap { ui.query(root, $0) }
        var looked = 0
        while !queue.isEmpty, looked < 40_000 {
            let element = queue.removeFirst()
            looked += 1
            if ui.il2cpp.isSubclass(ui.il2cpp.classOf(element), of: tableClass) {
                if !ui.name(of: element).hasPrefix("FMStarship") {
                    PluginLog.write("FM's \(ui.name(of: element)) table's references:\n" + fmTable.describeReferences(in: element).joined(separator: "\n"))
                }
                continue
            }
            queue += ui.children(of: element)
        }
    }
    #endif

    private func release(_ handle: inout IL2CPP.Handle?) {
        if let value = handle { IL2CPP.shared?.unpin(value) }
        handle = nil
    }
}

/// How FM draws a tile: its background, border and corners, copied from one of FM's own on screen when there is one.
struct TileLook {
    var background: (Float, Float, Float, Float)
    var border: (Float, Float, Float, Float)
    var borderWidth: Float
    var radius: Float

    /// Close to FM's dark tiles, for when there's none to copy.
    static let fallback = TileLook(background: (0.075, 0.082, 0.118, 1), border: (0.22, 0.23, 0.29, 1), borderWidth: 1, radius: 4)

    @MainActor
    static func copied(from screens: [IL2CPP.Pointer], _ ui: FMElements) -> TileLook? {
        var queue = screens
        var looked = 0
        while !queue.isEmpty, looked < 4000 {
            let element = queue.removeFirst()
            looked += 1
            if let size = ui.layout(element), size.width > 150, size.height > 80,
               let background = ui.resolvedColor(element, "backgroundColor"), background.3 > 0.5,
               ["si-tile", "tile", "block", "card"].contains(where: { word in ui.classes(of: element).contains { $0.contains(word) } }) {
                let width = ui.resolvedNumber(element, "borderTopWidth") ?? 0
                let look = TileLook(background: background, border: ui.resolvedColor(element, "borderTopColor") ?? fallback.border,
                                    borderWidth: width, radius: ui.resolvedNumber(element, "borderTopLeftRadius") ?? 0)
                PluginLog.write("Tile look copied from FM's \(ui.name(of: element)) (\(ui.classes(of: element).joined(separator: " ")))")
                return look
            }
            queue += ui.children(of: element)
        }
        PluginLog.write("No tile of FM's to copy, using the fallback look")
        return nil
    }
}
