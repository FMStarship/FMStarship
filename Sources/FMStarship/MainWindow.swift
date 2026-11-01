import StarshipCore
import StarshipSearch
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appColors) private var colors

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 280)
        } detail: {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        JobOverlay(job: model.fileJob)
                        JobOverlay(job: model.snapshotJob)
                        if model.searching, !model.searchIsQuick {
                            ProgressCard(text: model.status, onCancel: { model.cancelSearch() })
                        }
                    }
                }
                .background(colors.ui.ground)
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.subtitle)
        .toolbar { toolbar }
        .toolbarBackground(colors.ui.ground, for: .windowToolbar)
        .alert("FM Starship", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
        .sheet(isPresented: $model.editingFilter) {
            if model.listIsStaff {
                FilterWindow(filter: Binding(get: { model.activeStaffFilter }, set: { model.activeStaffFilter = $0 }),
                             options: model.staffOptions, onSearch: { model.search() })
            } else {
                FilterWindow(filter: Binding(get: { model.activePlayerFilter }, set: { model.activePlayerFilter = $0 }),
                             options: model.playerOptions, onSearch: { model.search() })
            }
        }
        .sheet(isPresented: $model.editingColumns) {
            ColumnsSheet(staff: model.listIsStaff)
        }
        .onAppear {
            model.openWindow = openWindow
            model.applyAppearance()
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.database == nil {
            WelcomeView()
        } else {
            switch model.screen {
            case .dashboard:
                ClubRequired { DashboardScreen(state: model.dashboard, squad: model.squadOverview, staff: model.staffOverview) }
            case .players:
                PeopleList(isStaff: false).padding(Metric.gutter)
            case .staff:
                PeopleList(isStaff: true).padding(Metric.gutter)
            case .myClub:
                ClubRequired { MyClubScreen(state: model.myClub) }
            case .squadOverview:
                ClubRequired { SquadOverviewScreen(state: model.squadOverview) }
            case .staffOverview:
                ClubRequired { StaffOverviewScreen(state: model.staffOverview) }
            case .squadPlanner:
                ClubRequired { SquadPlannerScreen(state: model.planner) }
            case .signings:
                ClubRequired { RecommendedSigningsScreen(state: model.signings) }
            case .recommendedStaff:
                ClubRequired { RecommendedStaffScreen(state: model.recommendedStaff) }
            case .staffReview:
                ClubRequired { StaffReviewScreen(state: model.staffReview) }
            case .bargains:
                ClubRequired { BargainsScreen(state: model.bargains) }
            case .openSquad:
                OpenSquadScreen()
            case .shortlists:
                ShortlistsScreen()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.database != nil, model.screen.isList {
                Button { model.editingFilter = true } label: { Label("Filters", systemImage: "line.3.horizontal.decrease.circle") }
                    .help("Filter this list")
                Button { model.editingColumns = true } label: { Label("Columns", systemImage: "tablecells") }
                    .help("Choose the columns and their order")
                Button { model.compare(model.selection) } label: { Label("Compare", systemImage: "rectangle.split.3x1") }
                    .disabled(!model.canCompare)
                    .help("Cmd-click two or three rows, then Compare: side by side, the best in each row in green")
                Button { model.exportList() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export this list to CSV, HTML or text")
            }
            HStack(spacing: 6) {
                Text("Ability").font(.callout).foregroundStyle(colors.ui.muted)
                Picker("Ability", selection: $model.reveal) {
                    ForEach([Reveal.exact, .stars, .hidden], id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .help("How to show CA and PA")
            Toggle(isOn: $model.showHidden) {
                Label("Hidden attributes", systemImage: model.showHidden ? "eye" : "eye.slash").labelStyle(.titleAndIcon)
            }
            .help(model.showHidden ? "Hide hidden attributes" : "Show hidden attributes")
            GameButton()
        }
        if model.database != nil, model.screen.isList {
            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(text: Binding(get: { model.searchText }, set: { model.searchText = $0 }), focus: model.focusSearch)
                    .frame(width: 150)
            }
        }
    }
}

/// Launch, or load: the only way in, and the only thing a new user has to find.
private struct GameButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.gameState {
        case .ready:
            Button { model.loadSave() } label: { Label("Load Save", systemImage: "arrow.down.circle").labelStyle(.titleAndIcon) }
                .disabled(model.loading)
        case .notRunning:
            Button { model.launchGame() } label: { Label("Start Football Manager", systemImage: "play.circle").labelStyle(.titleAndIcon) }
        case .runningWithoutAgent:
            Button { model.alert = AppModel.restartHelp } label: { Label("Restart FM needed", systemImage: "exclamationmark.triangle").labelStyle(.titleAndIcon) }
        case .notInstalled:
            Button { model.alert = "Football Manager 27 wasn't found in your Steam library." } label: { Label("FM not found", systemImage: "questionmark.circle").labelStyle(.titleAndIcon) }
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appColors) private var colors

    var body: some View {
        List(selection: Binding(get: { model.screen }, set: { screen in
            if let screen { model.go(to: screen) }
        })) {
            item(.dashboard, "square.grid.2x2")
            Section {
                item(.squadOverview, "person.3")
                item(.staffOverview, "person.2.badge.gearshape")
                item(.squadPlanner, "sportscourt")
                item(.myClub, "doc.text.magnifyingglass")
                item(.staffReview, "checklist")
            } header: {
                heading("Your club")
            }
            Section {
                item(.signings, "person.badge.plus")
                item(.recommendedStaff, "person.crop.rectangle.stack")
                item(.bargains, "tag")
                item(.shortlists, "list.star")
            } header: {
                heading("Market")
            }
            Section {
                item(.players, "figure.soccer")
                item(.staff, "person.text.rectangle")
                item(.openSquad, "building.2")
            } header: {
                heading("Database")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(colors.rail.map { Color(nsColor: $0) } ?? .clear)
        .safeAreaInset(edge: .bottom) { SidebarFooter() }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.medium)).foregroundStyle(colors.ui.muted)
    }

    private func item(_ screen: Screen, _ icon: String) -> some View {
        Label {
            Text(screen.title)
        } icon: {
            // Symbols differ in width; the labels shouldn't.
            Image(systemName: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 15)
        }
        .tag(screen)
        .listItemTint(.monochrome)
    }
}

/// Whose club this is and where the numbers come from, or how far the load has got.
private struct SidebarFooter: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.clubChoices.count > 1 {
                ClubPicker()
            } else if let club = model.session?.club.name, !club.isEmpty {
                Text(club).font(.headline)
            }
            if model.loading {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(model.status)
                }
                .font(.callout)
                .foregroundStyle(colors.ui.muted)
            } else if model.database != nil {
                Text(model.sourceLine)
                    .font(.callout)
                    .foregroundStyle(colors.ui.muted)
                    .help(model.sourceDetail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Network saves have one club per human manager.
private struct ClubPicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.clubChoices, id: \.self) { club in
                Button(club) { model.pickClub(club) }
            }
        } label: {
            Label(model.session?.club.name ?? "Your club", systemImage: "building.columns")
        }
        .help("The club interest and recommendations are worked out for")
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "binoculars").font(.system(size: 42)).foregroundStyle(.secondary)
            Text(title).font(.title)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            GameButton().controlSize(.large).buttonStyle(.borderedProminent)
            Button("Open Snapshot...") { model.openSnapshot() }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch model.gameState {
        case .ready: return "Football Manager is ready"
        case .notRunning: return "Start Football Manager from here"
        case .runningWithoutAgent: return "Football Manager needs a restart"
        case .notInstalled: return "Football Manager 27 wasn't found"
        }
    }

    private var detail: String {
        switch model.gameState {
        case .ready: return "Load your save in the game, then press Load Save."
        case .notRunning: return "macOS only lets FM Starship read the game if FM Starship starts it. Steam stays connected, and no game files are changed."
        case .runningWithoutAgent: return AppModel.restartHelp
        case .notInstalled: return "FM Starship looks in your Steam libraries."
        }
    }
}

/// The screens that are about your club have nothing to show without one.
struct ClubRequired<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        if model.session?.club.name.isEmpty == false {
            content()
        } else {
            ContentUnavailableView("No club to work with", systemImage: "shield.slash",
                                   description: Text("No human-managed club was found in this save."))
        }
    }
}
