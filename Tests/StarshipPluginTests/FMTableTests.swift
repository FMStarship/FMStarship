@testable import StarshipPlugin
import StarshipAnalysis
import StarshipCore
import XCTest

/// FM's own tables need the game, but which of FM Starship's columns go into them, under which headings, and how a
/// click on their headings sorts the list, don't.
@MainActor
final class FMTableTests: XCTestCase {
    private func person(_ index: UInt32) -> Person {
        let person = Person()
        person.index = index
        return person
    }

    /// Four signings as the engine shows them with Hidden attributes on: two share a CA, one has no PA.
    private func signings() -> (table: AnalysisTable, people: [Person]) {
        let people = (1...4).map { person(UInt32($0)) }
        let columns = ["Name", "CA", "PA", "Would join on", "vs your best"].map { TableColumn($0, 5) }
        let cells = [["Abel", "140", "150", "Transfer", "+4 (GK)"],
                     ["Berg", "153", "160", "Transfer or loan", "+15 (GK)"],
                     ["Carr", "141", "", "Loan", "-2 (ST)"],
                     ["Dahl", "153", "155", "Transfer", "+15 (DC)"]]
        return (AnalysisTable(columns: columns, rows: zip(cells, people).map { TableRow(cells: $0, person: $1) }), people)
    }

    private func names(_ people: [Person]) -> [UInt32] { people.map(\.index) }

    private func extra(_ title: String) -> FMTable.Extra {
        let extras = FMTable.extras(from: signings().table, titles: ["CA", "PA", "Would join on", "vs your best"])
        return extras.first { ($0.title ?? $0.host) == title }!
    }

    func testCAAndPAGoInFMsOwnColumnsForThemAndTheRestUnderTheEnginesHeadings() {
        let extras = FMTable.extras(from: signings().table, titles: ["CA", "PA", "Would join on", "vs your best"])
        XCTAssertEqual(extras.map(\.host).prefix(2), ["hidden-current-ability", "hidden-potential-ability"])
        // FM's own headings stay on CA and PA; the rest are the engine's, with FM's word for whether a player would join.
        XCTAssertEqual(extras.map(\.title), [nil, nil, "Interest", "vs your best"])
        XCTAssertEqual(Set(extras.map(\.host)).count, 4, "Each in a column of its own")
        XCTAssertEqual(extras[0].values[2], "153")
        XCTAssertEqual(extras[2].values[2], "Transfer or loan")
    }

    func testWithHiddenAttributesOffTheEngineHasNoCAAndFMsScoutsKeepTheirColumns() {
        // The engine leaves out CA, PA and what's worked out from them while Hidden attributes is off.
        var table = signings().table
        table.columns = [TableColumn("Name", 5), TableColumn("Would join on", 5)]
        table.rows = table.rows.map { TableRow(cells: [$0.cells[0], $0.cells[3]], person: $0.person) }
        let extras = FMTable.extras(from: table, titles: ["CA", "PA", "Would join on", "vs your best"])
        XCTAssertEqual(extras.map(\.title), ["Interest"])
        let columns = FMTable.columns(["name", "scout-opinion-current-ability", "scout-opinion-potential-ability"], with: extras)
        XCTAssertEqual(columns.prefix(3), ["name", "scout-opinion-current-ability", "scout-opinion-potential-ability"])
        XCTAssertFalse(columns.contains("hidden-current-ability"))
    }

    func testOurCAAndPATakeTheScoutsPlacesAndTheRestGoAtTheEnd() {
        let extras = FMTable.extras(from: signings().table, titles: ["CA", "PA", "Would join on", "vs your best"])
        let columns = FMTable.columns(["name", "scout-opinion-current-ability", "scout-opinion-potential-ability", "wage"], with: extras)
        XCTAssertEqual(columns.prefix(4), ["name", "hidden-current-ability", "hidden-potential-ability", "wage"])
        XCTAssertEqual(columns.count, 6)
        XCTAssertEqual(Array(columns.suffix(2)), extras.suffix(2).map(\.host))
    }

    func testSortingByANumberPutsTheHighestFirstAndKeepsTiesInTheEnginesOrder() {
        let people = signings().people
        XCTAssertEqual(names(FMTable.sorted(people, by: extra("hidden-current-ability"), descending: true)), [2, 4, 3, 1])
        XCTAssertEqual(names(FMTable.sorted(people, by: extra("hidden-current-ability"), descending: false)), [1, 3, 2, 4])
    }

    func testSortingBySignedNumbersReadsTheSign() {
        XCTAssertEqual(names(FMTable.sorted(signings().people, by: extra("vs your best"), descending: true)), [2, 4, 1, 3])
    }

    func testPlayersWithoutAValueGoLastEitherWay() {
        let people = signings().people
        XCTAssertEqual(names(FMTable.sorted(people, by: extra("hidden-potential-ability"), descending: true)), [2, 4, 1, 3])
        XCTAssertEqual(names(FMTable.sorted(people, by: extra("hidden-potential-ability"), descending: false)), [1, 4, 2, 3])
    }

    func testTextSortsAlphabetically() {
        XCTAssertEqual(names(FMTable.sorted(signings().people, by: extra("Interest"), descending: false)), [3, 1, 4, 2])
    }

    func testATacticsPlacesSortFromTheGoalkeeperUpNotAlphabetically() {
        // The squad planner's first team, as it is inside FM.
        let people = (1...5).map { person(UInt32($0)) }
        let columns = [TableColumn("Position", 5, order: .place), TableColumn("Player", 5)]
        let rows = zip(["ST", "DC (L)", "GK", "DC (R)", "AMR"], people).map { TableRow(cells: [$0, "Abel"], person: $1) }
        let position = FMTable.extras(from: AnalysisTable(columns: columns, rows: rows), titles: ["Position"])[0]
        XCTAssertEqual(position.order, .place)
        XCTAssertEqual(names(FMTable.sorted(people, by: position, descending: false)), [3, 4, 2, 5, 1])
        XCTAssertEqual(names(FMTable.sorted(people, by: position, descending: true)), [1, 5, 2, 4, 3])
    }

    func testPlayersSortByThePositionTheyreRatedBestAt() {
        func player(_ index: UInt32, _ ratings: [String: UInt8]) -> Player {
            let player = Player()
            player.index = index
            for (name, rating) in ratings { player.pos[Names.positions.firstIndex(of: name)!] = rating }
            return player
        }
        // A striker who can play in midfield, and a full-back as good on either side, whom FM puts on the right.
        let people: [Person] = [player(1, ["ST": 20, "MC": 18]), player(2, ["DL": 20, "DR": 20]), player(3, ["GK": 20]), person(4)]
        let columns = [TableColumn("Position", 5, order: .playerPosition)]
        let rows = zip(["MC, ST", "DL, DR", "GK", "DC"], people).map { TableRow(cells: [$0], person: $1) }
        let position = FMTable.extras(from: AnalysisTable(columns: columns, rows: rows), titles: ["Position"])[0]
        XCTAssertEqual(names(FMTable.sorted(people, by: position, descending: false)), [3, 2, 4, 1])
    }

    func testOurColumnsAreWideEnoughForTheirLongestValue() {
        XCTAssertGreaterThan(extra("Interest").width, extra("vs your best").width)
        XCTAssertLessThanOrEqual(extra("Interest").width, 220)
    }

    func testOurColumnsHaveIDsOfTheirOwnThatFMsDontUse() {
        XCTAssertEqual(extra("Interest").host, "fmstarship-interest")
        XCTAssertEqual(extra("vs your best").host, "fmstarship-vs-your-best")
        XCTAssertFalse(FMTable.ownID("Now → peak").contains(" "))
    }

    func testARowsToneColoursOnlyTheColumnItsFor() {
        // As the Dashboard's young talent: the outlook is coloured, the rest of the row isn't.
        let people = (1...2).map { person(UInt32($0)) }
        let columns = ["Name", "Now → peak", "Outlook"].map { TableColumn($0, 5) }
        let rows = [TableRow(cells: ["Abel", "120 → 150", "Likely star"], person: people[0], tone: .star, toneColumn: 2),
                    TableRow(cells: ["Berg", "110 → 118", "Steady"], person: people[1])]
        let extras = FMTable.extras(from: AnalysisTable(columns: columns, rows: rows), titles: ["Now → peak", "Outlook"])
        XCTAssertEqual(extras[0].tones, [:])
        XCTAssertEqual(extras[1].tones, [1: .star])
        XCTAssertEqual(extras[1].values[2], "Steady")
    }

    func testAWholeTableKeepsTheEnginesOrderWithFMsColumnsWhereFMHasThem() {
        // The squad planner's signings: FM's name, age and club, the engine's CA and PA in FM's columns for them.
        let table = AnalysisTable(columns: ["For", "Name", "Age", "Club", "CA", "PA", "Value", "vs best"].map { TableColumn($0, 5) })
        let layout = FMTable.layout(of: table, fm: ["Name": "name", "Age": "age", "Club": "club"])
        XCTAssertEqual(layout.columns, ["fmstarship-for", "name", "age", "club", "hidden-current-ability", "hidden-potential-ability",
                                        "fmstarship-value", "fmstarship-vs-best"])
        XCTAssertEqual(layout.extras, ["For", "CA", "PA", "Value", "vs best"])
        XCTAssertEqual(FMTable.columns(layout.columns, with: FMTable.extras(from: table, titles: layout.extras)), layout.columns)
    }

    func testTwoOfTheEnginesColumnsForTheSamePlayerAreOneOfFMs() {
        let table = AnalysisTable(columns: ["Position", "Player", "Best"].map { TableColumn($0, 5) })
        XCTAssertEqual(FMTable.layout(of: table, fm: ["Player": "name", "Best": "name"]).columns, ["fmstarship-position", "name"])
    }

    func testANoteColumnIsQuiet() {
        let columns = ["Name", "Status", "What's missing"].map { TableColumn($0, 5) }
        let row = TableRow(cells: ["Abel", "Watch", "Abel is injury-prone"], person: person(1), tone: .fair, toneColumn: 1, quietColumn: 2)
        let extras = FMTable.extras(from: AnalysisTable(columns: columns, rows: [row]), titles: ["Status", "What's missing"])
        XCTAssertEqual(extras.map(\.quiet), [false, true])
        XCTAssertEqual(extras[0].tones, [1: .fair])
    }

    func testTheAppsHintsAboutDoubleClickingAreLeftOut() {
        XCTAssertEqual(NativePage.withoutAppHints("Top 10 who would join Molde FK. Double-click a player for the full profile."),
                       "Top 10 who would join Molde FK.")
        XCTAssertEqual(NativePage.withoutAppHints("Double-click for the full profile; right-click to compare or add to a shortlist."), "")
        XCTAssertEqual(NativePage.withoutAppHints("Nothing found"), "Nothing found")
    }

    func testHeadingsGoOnAgainOnlyWhenFMsHeadersOrTheSortChangeOrASecondHasGone() {
        let shown = FMTable.Shown()
        let first = IL2CPP.Pointer(bitPattern: 0x1000), second = IL2CPP.Pointer(bitPattern: 0x2000)
        let start = Date()
        XCTAssertTrue(shown.needsHeadings([first, second], sort: nil, now: start), "Not put on yet")
        shown.headers = [first, second]
        shown.headedSort = nil
        shown.headedAt = start
        XCTAssertFalse(shown.needsHeadings([first, second], sort: nil, now: start.addingTimeInterval(0.1)))
        XCTAssertFalse(shown.needsHeadings([first, second], sort: nil, now: start.addingTimeInterval(0.9)))
        XCTAssertTrue(shown.needsHeadings([first, second], sort: nil, now: start.addingTimeInterval(1)), "In case FM set its arrows back")
        XCTAssertTrue(shown.needsHeadings([first, nil], sort: nil, now: start.addingTimeInterval(0.1)), "FM made a header again")
        XCTAssertTrue(shown.needsHeadings([second, first], sort: nil, now: start.addingTimeInterval(0.1)))
        let byCA = FMTable.Sort(host: "hidden-current-ability", descending: true)
        XCTAssertTrue(shown.needsHeadings([first, second], sort: byCA, now: start.addingTimeInterval(0.1)), "Sorted by ours")
        shown.headedSort = byCA
        XCTAssertTrue(shown.needsHeadings([first, second], sort: FMTable.Sort(host: "hidden-current-ability", descending: false),
                                          now: start.addingTimeInterval(0.1)), "The other way")
        XCTAssertTrue(shown.needsHeadings([first, second], sort: nil, now: start.addingTimeInterval(0.1)), "Sorted by one of FM's")
        shown.forget(nil)
        XCTAssertTrue(shown.needsHeadings([first, second], sort: byCA, now: start.addingTimeInterval(0.1)), "FM built its columns again")
    }

    func testOnlyASearchsEndRedrawsItsListNotHowItsGoing() {
        // How the search is going isn't part of the list's state: it goes into the line already up.
        XCTAssertEqual(FMInterface.listState(searching: true, version: 3, filter: "Age 16-21"),
                       FMInterface.listState(searching: true, version: 4, filter: "Age 16-21"))
        XCTAssertNotEqual(FMInterface.listState(searching: true, version: 4, filter: "Age 16-21"),
                          FMInterface.listState(searching: false, version: 4, filter: "Age 16-21"), "Its rows once it's done")
        XCTAssertNotEqual(FMInterface.listState(searching: false, version: 4, filter: "Age 16-21"),
                          FMInterface.listState(searching: false, version: 5, filter: "Age 16-21"))
        XCTAssertNotEqual(FMInterface.listState(searching: false, version: 4, filter: "Age 16-21"),
                          FMInterface.listState(searching: false, version: 4, filter: "No filters."))
    }
}

/// Whether FM has moved on from the screen under ours goes by the screens it shows, not by the ones it has hidden.
final class FollowFMTests: XCTestCase {
    func testOnlyTheScreensFMShowsCount() {
        // Back from a player's profile: the profile is hidden at once, and put away a moment later.
        let shown = ["0x1 true", "0x2 false"]
        let tidied = ["0x1 true"]
        XCTAssertEqual(FMInterface.visible(shown), FMInterface.visible(tidied))
        XCTAssertNotEqual(FMInterface.visible(shown), FMInterface.visible(["0x1 false", "0x3 true"]))
    }
}
