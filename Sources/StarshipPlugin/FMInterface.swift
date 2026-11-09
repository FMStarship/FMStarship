import AppKit
import Combine
import FMStarshipUI
import Foundation
@preconcurrency import StarshipAnalysis
@preconcurrency import StarshipCore

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
    private var contents: [StarshipScreen: (revision: Int, content: ScreenContent)] = [:]
    private var running: Set<StarshipScreen> = []
    private var shown = ""
    private var look: TileLook?
    private var lastProblem = ""

    func start(model: AppModel) {
        self.model = model
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { FMInterface.shared.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        watching = model.objectWillChange.sink { _ in
            // objectWillChange comes before the change, so look once it's made.
            DispatchQueue.main.async { MainActor.assumeIsolated { FMInterface.shared.modelChanged() } }
        }
        TableDump.shared.startWatchingIfAsked()
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated { FMInterface.shared.mouseDown(event) }
            return event
        }
    }

    /// A click on FM's own navigation goes back to FM: its tabs, as moving between FM's tabs does, its bookmarks and
    /// its Back button. That includes the tab or bookmark of the screen under ours, which FM itself leaves as it is.
    /// A tab's dropdown arrow only opens FM's menu, and choosing from that changes FM's screen, which `followFM`
    /// notices.
    private func mouseDown(_ event: NSEvent) {
        guard let view = event.window?.contentView, view.bounds.width > 0, view.bounds.height > 0,
              let il2cpp = IL2CPP.shared, let ui = FMElements(il2cpp) else { return }
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
            do { try show(ui) } catch { report(error) }
        }
    }

    /// Twice a second: keep our tab in FM's bar, which FM builds again now and then, and notice FM moving on.
    private func tick() {
        guard let il2cpp = IL2CPP.shared, let ui = FMElements(il2cpp) else {
            timer?.invalidate()
            return
        }
        il2cpp.withoutCollection {
            do {
                try keepTab(ui)
                runCommand(ui)
                waitToComeBack(ui)
                if screen != nil { followFM(ui) }
                if screen != nil { watchFMTab(ui) }
                lastProblem = ""
            } catch {
                report(error)
            }
        }
    }

    private func report(_ error: Error) {
        let problem = "\(error)"
        if problem != lastProblem { PluginLog.write("FM Starship in FM: \(problem)") }
        lastProblem = problem
    }

    // MARK: The tab

    private func keepTab(_ ui: FMElements) throws {
        guard let root = try ui.mainRoot(), let group = ui.query(root, "ManagingClubButtons") else { return }
        if let element = tab.flatMap(ui.il2cpp.target), ui.parent(of: element) == group { return }
        // FM built its bar again, or this is the first time we've seen it with a career loaded.
        if screen != nil { leave(ui) }
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
    private func watchFMTab(_ ui: FMElements) {
        guard let button = fmTab.flatMap(ui.il2cpp.target), ui.hasClass(button, Self.litClasses[0]) else { return }
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

    private func show(_ ui: FMElements) throws {
        guard let root = try ui.mainRoot(), let body = ui.query(root, "MenuBody") else { throw IL2CPP.Failure("No screen area in FM") }
        let fmScreens = ui.children(of: body)
        if look == nil { look = TileLook.copied(from: fmScreens, ui) }
        if !FMTable.ready {
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
        model?.loadSaveIfEmpty()
        startWork()
        try fill(ui)
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
        stopExtras()
        forgetSubtabClicks()
        setTabActive(false, ui)
        relightFMTab(ui)
        PluginLog.write("FM Starship screen closed")
    }

    /// FM opening another screen changes what its screen area holds, or which of it is visible, and so does FM
    /// opening a report card over its screens.
    private func followFM(_ ui: FMElements) {
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

    /// The subtabs and the chosen screen's content: what it found, or what's happening until then.
    private func fill(_ ui: FMElements) throws {
        guard let element = screen.flatMap(ui.il2cpp.target) else { return }
        let content = contents[current]
        let status = statusLine
        let key = "\(current) \(content?.revision ?? -1) \(status)"
        guard key != shown else { return }
        try fillSubtabs(ui)
        for child in ui.children(of: element) { try ui.remove(child) }
        let page = NativePage(ui: ui, look: look ?? .fallback)
        switch content?.content {
        case .dashboard(let dashboard):
            try NativeDashboard(page: page).build(into: try page.body(in: element), dashboard: dashboard)
        case .tables(let sections):
            if sections.count == 1, let section = sections.first, let columns = section.fmColumns, FMTable.ready {
                try fmTableScreen(section, columns: columns, in: element, page: page, ui)
            } else {
                let body = try page.body(in: element)
                for section in sections { try page.table(section, in: body) }
            }
        case nil:
            try page.message(status, title: current.title, in: try page.body(in: element))
        }
        shown = key
    }

    /// One list in FM's own player table, filling the screen as FM's lists do, with the engine's line below it.
    private func fmTableScreen(_ section: TableSection, columns: [String], in element: Pointer, page: NativePage, _ ui: FMElements) throws {
        let body = try page.fixedBody(in: element)
        let tile = try page.tile()
        try ui.style(tile) { try $0.number("flexGrow", 1) }
        try page.heading(section.title, note: section.table.head, in: tile)
        let fmTable = FMTable(ui: ui)
        let table = try fmTable.make(name: "FMStarship-\(current)")
        try ui.style(table) { try $0.number("flexGrow", 1) }
        try ui.add(FMTable.wrapInRoot ? try fmTable.wrap(table) : table, to: tile)
        if let old = lastTable { ui.il2cpp.unpin(old) }
        lastTable = ui.il2cpp.pin(table)
        let status = NativePage.withoutAppHints(section.table.status)
        for line in [status] + section.notes where !line.isEmpty {
            try ui.add(try page.spaced(try ui.text(line, ["body-sm", "global-text-secondary"]), top: 8), to: tile)
        }
        try ui.add(tile, to: body)
        // Bound before its rows go in, so each row gets its key under the table's, as in FM's own tables.
        if FMTable.bindIfIdle, !fmTable.isBound(table) {
            PluginLog.write("FM's table binds: \(fmTable.call(table, "BindToData")), bound: \(fmTable.isBound(table))")
        }
        let people = section.table.rows.compactMap(\.person)
        // The engine's CA and PA, as the Ability setting shows them, and its own columns, in FM's empty columns.
        let extras = FMTable.extras(from: section.table, titles: section.fmExtras)
        let chosen = FMTable.columnOverride ?? FMTable.columns(columns, with: extras)
        // FM can't sort by our values, so its sorting is off for our columns; clicking their headings sorts here.
        let own = Dictionary(extras.filter { $0.title != nil || !FMTable.abilitySortable }.map { ($0.host, $0.width) },
                             uniquingKeysWith: { first, _ in first })
        try fmTable.fill(table, people: people, columns: chosen, own: own)
        PluginLog.write("FM's table for \(current.title): \(fmTable.report(table))")
        keepRows(table, extras, people: people)
        checkLater(table, people: people, columns: chosen, own: own, attempt: 1)
    }

    /// FM's table's rows, kept fitted to their height and holding the engine's values as FM draws them.
    private var extrasTable: IL2CPP.Handle?
    private var extras: [FMTable.Extra] = []
    private var extrasShown = FMTable.Shown()
    private var extrasTimer: Timer?
    /// The list's people in the engine's order, and how it's sorted by one of our columns, if it is.
    private var tablePeople: [Person] = []
    private var tableSort: FMTable.Sort?

    private func keepRows(_ table: Pointer, _ extras: [FMTable.Extra], people: [Person]) {
        stopExtras()
        guard let handle = IL2CPP.shared?.pin(table) else { return }
        extrasTable = handle
        self.extras = extras
        extrasShown = FMTable.Shown()
        tablePeople = people
        tableSort = nil
        // Often enough that a row FM reuses while scrolling or sorting shows its new person's values at once.
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { FMInterface.shared.refreshRows() } }
        RunLoop.main.add(timer, forMode: .common)
        extrasTimer = timer
    }

    private func refreshRows() {
        guard let il2cpp = IL2CPP.shared, let ui = FMElements(il2cpp), let handle = extrasTable else { return }
        il2cpp.withoutCollection {
            guard screen != nil, let table = il2cpp.target(of: handle), ui.parent(of: table) != nil else { return stopExtras() }
            let fmTable = FMTable(ui: ui)
            // Sorting by one of FM's own columns takes over from ours.
            if tableSort != nil, fmTable.sortedByFM(table, besides: extras) { tableSort = nil }
            fmTable.refreshRows(table, extras, shown: extrasShown, sort: tableSort) { FMInterface.shared.sort(by: $0) }
        }
    }

    /// A click on one of our columns' headings: highest first, then the other way on the next click, as FM's do.
    private func sort(by host: String) {
        guard let il2cpp = IL2CPP.shared, let ui = FMElements(il2cpp), let handle = extrasTable,
              let extra = extras.first(where: { $0.host == host }) else { return }
        let descending = tableSort?.host == host ? !(tableSort?.descending ?? true) : true
        il2cpp.withoutCollection {
            guard let table = il2cpp.target(of: handle) else { return }
            do {
                try FMTable(ui: ui).setRows(table, FMTable.sorted(tablePeople, by: extra, descending: descending))
                tableSort = FMTable.Sort(host: host, descending: descending)
                PluginLog.write("FM's table sorted by \(extra.title ?? host), \(descending ? "highest" : "lowest") first")
            } catch {
                report(error)
            }
        }
    }

    private func stopExtras() {
        extrasTimer?.invalidate()
        extrasTimer = nil
        release(&extrasTable)
        extras = []
    }

    /// The table loads FM's column factory once it's in the tree. A moment later, this says what it made of it, and
    /// puts the columns and rows in again if it has none yet.
    private func checkLater(_ table: Pointer, people: [Person], columns: [String], own: [String: Float], attempt: Int) {
        guard let handle = IL2CPP.shared?.pin(table) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                guard let il2cpp = IL2CPP.shared, let ui = FMElements(il2cpp) else { return }
                defer { il2cpp.unpin(handle) }
                il2cpp.withoutCollection {
                    guard let table = il2cpp.target(of: handle), ui.parent(of: table) != nil else { return }
                    let fmTable = FMTable(ui: ui)
                    PluginLog.write("FM's table, check \(attempt): \(fmTable.report(table))")
                    if FMTable.noteFactory(of: table, il2cpp) {
                        // Now the factory's widths are known, our columns go in those of FM's that fit them.
                        FMInterface.shared.shown = ""
                        DispatchQueue.main.async { MainActor.assumeIsolated { FMInterface.shared.refresh() } }
                        return
                    }
                    guard fmTable.columnCount(table) == 0, attempt < 3 else { return }
                    if FMTable.bindIfIdle, !fmTable.isBound(table) {
                        PluginLog.write("FM's table still isn't bound, so it's asked again: \(fmTable.call(table, "BindToData"))")
                    }
                    do { try fmTable.fill(table, people: people, columns: columns, own: own) } catch { FMInterface.shared.report(error) }
                    FMInterface.shared.checkLater(table, people: people, columns: columns, own: own, attempt: attempt + 1)
                }
            }
        }
    }

    /// What's happening while the chosen screen has nothing to show yet.
    private var statusLine: String {
        guard let model else { return "" }
        if model.analysis == nil { return model.statusLine.isEmpty ? "Reading your save..." : model.statusLine }
        return contents[current] == nil ? current.working : ""
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

    private func forgetSubtabClicks() {
        for button in subtabButtons { ClickActions.actions[button] = nil }
        subtabButtons = []
    }

    /// Changing screens rebuilds the row the click came from, so it waits until FM has finished with the click.
    private func select(_ screen: StarshipScreen) {
        guard screen != current else { return }
        PluginLog.write("Subtab chosen: \(screen.title)")
        current = screen
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
        guard screen != nil, let model, let session = model.analysis else { return }
        let revision = model.analysisRevision
        let chosen = current
        guard contents[chosen]?.revision != revision, !running.contains(chosen) else { return }
        running.insert(chosen)
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let content = Self.work(chosen, session: session)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let interface = FMInterface.shared
                    let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                    PluginLog.write("\(chosen.title) \(content == nil ? "came back empty" : "ready") in \(seconds) s")
                    interface.running.remove(chosen)
                    if let content { interface.contents[chosen] = (revision, content) }
                    interface.refresh()
                    // In case the save was read again while this was being made.
                    interface.startWork()
                }
            }
        }
    }

    /// The same engine calls and starting options as the app's screens.
    nonisolated private static func work(_ screen: StarshipScreen, session: AnalysisSession) -> ScreenContent? {
        switch screen {
        case .dashboard:
            return .dashboard(ClubDashboard(session: session))
        case .signings:
            guard let table = SigningRecommender(session: session).find(RecommendOptions()) else { return nil }
            return .tables([TableSection(title: "Recommended signings", table: table, fmColumns: playerColumns,
                                         fmExtras: ["CA", "PA", "Would join on", "vs your best"])])
        case .planner:
            let lines = SquadPlanner.analyse(session)
            let squad = SquadPlanner.squadView(lines, session: session)
            let start = SquadPlanner.startingBudget(session)
            var sections = [TableSection(title: "Your first team", table: squad.table)]
            if let plan = SquadPlanner.plan(session, lines: lines, budget: start.budget, wageRoom: start.wageRoom, includeLoans: false) {
                sections.append(TableSection(title: "Signings for the plan", table: plan.table))
            }
            return .tables(sections)
        case .bargains:
            let finder = BargainFinder(session: session)
            var options = BargainOptions()
            // The app's max fee starts at the transfer budget.
            options.maxFee = finder.startingMaxFee
            guard let table = finder.find(options) else { return nil }
            return .tables([TableSection(title: "Bargains", table: table, fmColumns: bargainColumns, fmExtras: ["CA", "PA", "Would join on"])])
        }
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
            do { try fill(ui) } catch { report(error) }
        }
    }

    // MARK: Development

    /// For checking these screens without a hand on FM, which ignores clicks while it isn't the front app: a command
    /// written to this file, which is then removed, opens, switches or closes FM Starship's screen, or writes out FM's
    /// interface or its tables. Nothing in it changes the game's own screens or data.
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
        default:
            PluginLog.write("Commands: open, close, screen <name>, dump, tables, methods, host panel|body, table ...")
        }
    }

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
