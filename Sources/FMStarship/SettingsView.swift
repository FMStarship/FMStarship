import StarshipFiles
import StarshipSearch
import SwiftUI

struct SettingsView<Updates: UpdateChecking>: View {
    let updater: Updates

    var body: some View {
        TabView {
            UnitsSettings()
                .tabItem { Label("Units", systemImage: "ruler") }
            ThemeSettings()
                .tabItem { Label("Theme", systemImage: "paintpalette") }
            if updater.isAvailable {
                UpdateSettings(updater: updater)
                    .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            }
        }
        .frame(width: 500)
    }
}

private struct UpdateSettings<Updates: UpdateChecking>: View {
    @ObservedObject var updater: Updates

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
            } footer: {
                Text("Once a day, FM Starship asks GitHub whether there's a new version. Nothing about your save is sent, and it doesn't check while Football Manager is running.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 150)
    }
}

/// Written straight through to `Settings`, then `AppModel.unitsChanged` rebuilds what depends on them.
private struct UnitsSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var followFM = StarshipSearch.Settings.current.unitsFollowFm
    @State private var height = StarshipSearch.Settings.current.heightUnit
    @State private var wages = StarshipSearch.Settings.current.wagePeriod
    @State private var currency = StarshipSearch.Settings.current.currencyName

    var body: some View {
        Form {
            Toggle("Follow my FM settings", isOn: $followFM)
                .onChange(of: followFM) {
                    StarshipSearch.Settings.current.unitsFollowFm = followFM
                    model.unitsChanged()
                    showResolved()
                }
            Section {
                Picker("Height", selection: $height) {
                    Text("Centimetres").tag("cm")
                    Text("Feet and inches").tag("ft")
                }
                .onChange(of: height) {
                    guard !followFM else { return }
                    StarshipSearch.Settings.current.heightUnit = height
                    model.unitsChanged()
                }
                Picker("Wages", selection: $wages) {
                    Text("Per week").tag("week")
                    Text("Per month").tag("month")
                    Text("Per year").tag("year")
                }
                .onChange(of: wages) {
                    guard !followFM else { return }
                    StarshipSearch.Settings.current.wagePeriod = wages
                    model.unitsChanged()
                }
                Picker("Currency", selection: $currency) {
                    ForEach(Units.currencies, id: \.name) { Text("\($0.name) (\($0.symbol))").tag($0.name) }
                }
                .onChange(of: currency) {
                    guard !followFM else { return }
                    StarshipSearch.Settings.current.currencyName = currency
                    model.unitsChanged()
                }
            } footer: {
                if Units.currencies.count == 1 {
                    Text("Other currencies appear after Load Save.").foregroundStyle(.secondary)
                }
            }
            .disabled(followFM)
        }
        .formStyle(.grouped)
        .onAppear(perform: showResolved)
        .frame(height: 320)
    }

    /// While following FM the pickers show what FM says.
    private func showResolved() {
        guard followFM else { return }
        height = Units.height == .feetInches ? "ft" : "cm"
        switch Units.wages {
        case .week: wages = "week"
        case .month: wages = "month"
        case .year: wages = "year"
        }
        currency = Units.money.name
    }
}

private struct ThemeSettings: View {
    @EnvironmentObject private var model: AppModel
    private static let system = Theme.system
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    private var current: String { model.colors.palette?.name ?? Self.system }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Theme").font(.headline)
                LazyVGrid(columns: columns, spacing: 10) {
                    swatch(name: "System", value: Self.system, palette: nil)
                    ForEach(Theme.all, id: \.name) { palette in
                        swatch(name: palette.name, value: palette.name, palette: palette)
                    }
                }
                Text("System follows your Mac's light or dark appearance. The others have their own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .frame(height: 480)
    }

    private func swatch(name: String, value: String, palette: Theme.Palette?) -> some View {
        Button {
            model.setTheme(value)
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 0) {
                    if let palette {
                        Self.color(palette.back)
                        Self.color(palette.altRow)
                        Self.color(palette.good)
                        Self.color(palette.hidden)
                    } else {
                        Color.white
                        Color.black
                    }
                }
                .frame(height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                Text(name).font(.subheadline)
            }
            .padding(4)
            .background(current == value ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private static func color(_ rgb: Theme.RGB) -> Color { Color(red: rgb.red, green: rgb.green, blue: rgb.blue) }
}
