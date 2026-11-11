@testable import FMStarshipUI
import StarshipAnalysis
@testable import StarshipPlugin
import StarshipSearch
import XCTest

/// Ability in FM Starship's tab inside FM and the picker in FM Starship's window set the same setting, so each shows
/// what the other chose, and the tab's screens are made again for it. Like the picker, it's Off and can't be changed
/// while Hidden attributes is off. None of it needs FM.
@MainActor
final class AbilitySettingTests: XCTestCase {
    private var saved = Settings()

    override func setUp() {
        super.setUp()
        saved = Settings.current
        Settings.current = Settings()
    }

    override func tearDown() {
        Settings.current = saved
        super.tearDown()
    }

    /// The model, as it starts from the saved settings. Settings aren't loaded in tests, so nothing is written.
    private func model(hidden: Bool, reveal: Reveal = .exact) -> AppModel {
        Settings.current.showHidden = hidden
        Settings.current.reveal = reveal.rawValue
        return AppModel()
    }

    func testTheTabOffersThePickersChoicesInItsOrder() {
        XCTAssertEqual(AppModel.abilityChoices.map(\.title), ["Exact", "Stars", "Off"])
        XCTAssertEqual(AppModel.abilityChoices.map(\.ability), [.numbers, .stars, .hidden])
    }

    func testChoosingInTheTabSetsTheSettingThePickerSets() {
        let model = model(hidden: true)
        model.ability = .stars
        XCTAssertEqual(model.reveal, .stars, "The picker in FM Starship's window shows Stars")
        XCTAssertEqual(Settings.current.reveal, Reveal.stars.rawValue, "Saved with the app's settings")
        XCTAssertEqual(model.displayOptions.reveal, .stars, "The screens show stars")
        model.ability = .hidden
        XCTAssertEqual(model.reveal, .hidden)
        XCTAssertEqual(model.displayOptions.reveal, .hidden)
        model.ability = .numbers
        XCTAssertEqual(model.reveal, .exact)
        XCTAssertEqual(Settings.current.reveal, Reveal.exact.rawValue)
    }

    func testWhatThePickerChoosesShowsInTheTab() {
        let model = model(hidden: true)
        var told = 0
        let watching = model.objectWillChange.sink { _ in told += 1 }
        for (setting, ability) in [(Reveal.stars, AbilityReveal.stars), (.hidden, .hidden), (.exact, .numbers)] {
            // As the picker's binding sets it.
            model.reveal = setting
            XCTAssertEqual(model.ability, ability)
        }
        XCTAssertGreaterThan(told, 0, "The tab hears of each change, and draws its row and screen again")
        withExtendedLifetime(watching) {}
    }

    /// CA and PA are hidden in FM, so with Hidden attributes off they're gone whatever Ability was set to.
    func testWithHiddenAttributesOffItsOffAndCantBeChanged() {
        for reveal in Reveal.allCases {
            let model = model(hidden: false, reveal: reveal)
            XCTAssertEqual(model.ability, .hidden, "Off whatever was chosen")
            XCTAssertEqual(model.displayOptions.reveal, .hidden, "No CA or PA on any screen")
            model.ability = .numbers
            XCTAssertEqual(model.reveal, reveal, "Not changed, as the picker can't be")
            XCTAssertEqual(model.ability, .hidden)
            XCTAssertEqual(model.displayOptions.reveal, .hidden)
        }
    }

    func testSwitchingHiddenAttributesOnBringsBackWhatWasChosen() {
        let model = model(hidden: false, reveal: .stars)
        model.hiddenAttributes = true
        XCTAssertEqual(model.ability, .stars)
        model.hiddenAttributes = false
        XCTAssertEqual(model.ability, .hidden)
    }

    func testChoosingWhatsChosenChangesNothing() {
        let model = model(hidden: true, reveal: .stars)
        let revision = model.analysisRevision
        model.ability = .stars
        XCTAssertEqual(model.analysisRevision, revision, "Nothing is made again")
        model.ability = .numbers
        XCTAssertNotEqual(model.analysisRevision, revision, "The screens are made again")
    }

    // MARK: The tab's screens and tables

    /// They're keyed on the settings as the model gives them: a screen or table made with one Ability doesn't stay up
    /// with another, not even until it's made again.
    func testEachAbilityMakesTheScreensAgain() {
        let model = model(hidden: true)
        var made: [ShownAs] = []
        for choice in AppModel.abilityChoices {
            model.ability = choice.ability
            made.append(ShownAs(model.displayOptions))
        }
        for (i, madeWith) in made.enumerated() {
            for (j, now) in made.enumerated() {
                XCTAssertEqual(MadeScreen<Void>.fits(madeWith: madeWith, now: now), i == j, "\(madeWith.reveal) shown with \(now.reveal)")
            }
        }
    }

    func testWithHiddenAttributesOffEveryAbilityIsMadeTheSame() {
        let shown = Reveal.allCases.map { ShownAs(model(hidden: false, reveal: $0).displayOptions) }
        XCTAssertEqual(shown.map(\.reveal), [.hidden, .hidden, .hidden])
        XCTAssertTrue(shown.allSatisfy { $0 == shown[0] })
    }

    // MARK: Its list

    func testTheListOpensUnderTheDropdownButNotAboveTheScreen() {
        // A dropdown on an Edit Search page, in the screen.
        XCTAssertEqual(NativeEditSearch.listTop(under: 300, screenTop: 85), 217)
        // The Ability dropdown, in FM's subtab row just above the screen.
        XCTAssertEqual(NativeEditSearch.listTop(under: 81, screenTop: 85), 0)
    }
}
