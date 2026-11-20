import Foundation
import StarshipAnalysis
import StarshipCore
import StarshipSearch

/// What may go out on this call, from the user's settings as they are now: the same switch as the eye in the app's
/// toolbar and FM Starship's tab inside FM. CA and PA are hidden in FM too, so Hidden attributes off takes Ability with it.
struct Visibility: Equatable {
    let showHidden: Bool
    let reveal: Reveal

    init(_ settings: Settings) {
        showHidden = settings.showHidden
        reveal = settings.showHidden ? Reveal(setting: settings.reveal) : .hidden
    }

    var showsAbility: Bool { reveal != .hidden }

    var display: DisplayOptions {
        let ability: AbilityReveal
        switch reveal {
        case .exact: ability = .numbers
        case .stars: ability = .stars
        case .hidden: ability = .hidden
        }
        let wages: MoneyUnits.WagePeriod
        switch Units.wages {
        case .week: wages = .week
        case .month: wages = .month
        case .year: wages = .year
        }
        let units = MoneyUnits(symbol: Units.money.symbol, perPound: Units.money.perPound, wagePeriod: wages,
                               feetAndInches: Units.height == .feetInches)
        return DisplayOptions(reveal: ability, showHidden: showHidden, units: units)
    }

    /// Whether a column may go out at all. The one test for every person value this server sends.
    func allows(_ col: Col) -> Bool { Columns.allowed(col, showHidden: showHidden, showAbility: showsAbility) }

    var abilityText: String {
        switch reveal {
        case .exact: return "exact"
        case .stars: return "stars"
        case .hidden: return "off"
        }
    }

    /// Why a hidden thing can't be asked for, so the agent knows its filter or order wasn't used.
    static func hiddenSentence(_ name: String) -> String {
        "\(name) is hidden in FM, and Hidden attributes is off in FM Starship, so it can't be used. The user can switch "
            + "Hidden attributes on in FM Starship's toolbar or in FM Starship's tab inside FM."
    }

    static func abilitySentence(_ name: String, showHidden: Bool) -> String {
        showHidden
            ? "\(name) can't be used while Ability is Off in FM Starship. The user can set Ability to Exact or Stars."
            : hiddenSentence(name)
    }
}
