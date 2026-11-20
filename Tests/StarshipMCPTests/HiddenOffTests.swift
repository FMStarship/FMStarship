import StarshipCore
@testable import StarshipMCP
import StarshipSearch
import XCTest

/// With Hidden attributes off nothing hidden goes out of any tool: no CA or PA, no hidden attribute, no personality
/// number, nothing worked out from them, and no order by them. Off means gone, so not even the names come back. With
/// Ability off, CA and PA go the same way.
final class HiddenOffTests: XCTestCase {
    override func tearDown() {
        GameRules.engine = nil
        super.tearDown()
    }

    /// Every tool, with arguments that bring out what it can show.
    private static let calls: [(String, JSON)] = [
        ("game_status", [:]), ("squad", [:]), ("squad", ["squad": "all"]), ("squad", ["club": "Rivals FC"]), ("staff", [:]),
        ("person", ["uid": 13]), ("person", ["uid": 21]), ("person", ["uid": 12]), ("person", ["uid": 500]), ("person", ["uid": 502]),
        ("search_players", [:]), ("search_players", ["club": "Testing", "sort": "Age"]), ("search_players", ["clause_max": 5_000_000]),
        ("search_staff", [:]), ("search_staff", ["rank_by": "Fitness"]),
        ("shortlists", [:]), ("shortlist", ["name": "Targets"]), ("shortlist", ["name": "Coaches"]),
        ("club_overview", [:]), ("staff_overview", [:]), ("compare", ["uids": [1, 12, 21]]), ("compare", ["uids": [500, 502]]),
        ("recommend_signings", ["upgrades_only": false]), ("recommend_signings", ["mode": "young", "upgrades_only": false]),
        ("recommend_signings", ["mode": "budget", "upgrades_only": false]),
        ("find_bargains", ["kind": "contracts_ending", "only_join": false]), ("find_bargains", ["kind": "free_agents"]),
        ("find_bargains", ["kind": "release_clauses", "only_join": false]), ("find_bargains", ["kind": "transfer_listed"]),
        ("find_bargains", ["kind": "wonderkids", "only_join": false]),
    ]

    private static let abilityNames = ["CA", "PA", "Growth room", "Current ability", "Potential ability", "Likely peak",
                                       "Room to grow", "vs your best", "vs best", "Best eleven"]
    /// The names of what's hidden, except a member of staff's Adaptability, which FM shows. Some of the hidden ones in a staff
    /// record share a name with something shown, such as a player's Marking, so names are looked for where values are named.
    private static let hiddenNames = Names.hidden + Names.personality.filter { !Names.staffShownPersonality.contains($0) }
        + Array(StaffFilter.hiddenRuleAttributes).filter { !Names.staffShownPersonality.contains($0) } + ["Drive (hidden)"]

    /// Every name a value goes out under: an object's keys, a list's column names, and the labels of compare's rows.
    private static func valueNames(_ value: JSON, staffOnly: Bool) -> Set<String> {
        var names = Set<String>()
        func walk(_ value: JSON, kind: String?) {
            switch value {
            case .object(let pairs):
                let kind = pairs.first { $0.0 == "kind" }?.1.string ?? kind
                for (key, item) in pairs {
                    if kind != "player" || !staffOnly { names.insert(key) }
                    if key == "columns" { names.formUnion(item.array?.compactMap(\.string) ?? []) }
                    // A row with only a label is a section's heading, which names no value.
                    if key == "rows" { names.formUnion(item.array?.compactMap { row in (row.array?.count ?? 0) > 1 ? row.array?.first?.string : nil } ?? []) }
                    walk(item, kind: kind)
                }
            case .array(let items): items.forEach { walk($0, kind: kind) }
            default: break
            }
        }
        walk(value, kind: nil)
        return names
    }

    private func harness(_ hidden: Bool, _ reveal: Reveal) throws -> Harness {
        let harness = Harness(hidden: hidden, reveal: reveal)
        try harness.saveShortlist("Targets", isStaff: false, uids: [12, 21])
        try harness.saveShortlist("Coaches", isStaff: true, uids: [501, 502])
        return harness
    }

    private func assertNothing(_ names: [String], numbers: String, in harness: Harness, file: StaticString = #filePath, line: UInt = #line) {
        for (tool, arguments) in Self.calls {
            guard let result = harness.toolbox.call(tool, arguments: arguments) else { return XCTFail(tool, file: file, line: line) }
            let what = "\(tool) \(arguments.text)"
            XCTAssertFalse(result.isError, "\(what): \(result.text)", file: file, line: line)
            // Staff are the only ones with a hidden Marking or Coaching, and players and staff are never in one answer but compare's.
            let answer = (try? JSON.parse(result.text)) ?? .null
            let staff = ["staff", "search_staff"].contains(tool) || answer["kind"] == "staff"
                || (tool == "shortlist" && answer["kind"] == "staff") || (tool == "compare" && arguments.text.contains("500"))
            let sent = Self.valueNames(answer, staffOnly: false)
            for name in names where sent.contains(name) {
                let staffName = StaffFilter.hiddenRuleAttributes.contains(name) && !Names.hidden.contains(name) && !Names.personality.contains(name)
                if staffName, !staff { continue }
                XCTFail("\(what) sends \(name): \(result.text)", file: file, line: line)
            }
            XCTAssertNil(result.text.range(of: numbers, options: .regularExpression), "\(what) sends a hidden number: \(result.text)",
                         file: file, line: line)
        }
    }

    func testHiddenAttributesOffSendsNothingHiddenFromAnyTool() throws {
        for reveal in Reveal.allCases {
            let harness = try harness(false, reveal)
            assertNothing(Self.abilityNames + Self.hiddenNames, numbers: World.hiddenNumbers, in: harness)
        }
    }

    func testAbilityOffSendsNoCAOrPAFromAnyTool() throws {
        let harness = try harness(true, .hidden)
        assertNothing(Self.abilityNames, numbers: #"\b(171|183|137|197|139|177)\b"#, in: harness)
    }

    func testTheSameCallsDoShowThemWhenOn() throws {
        let harness = try harness(true, .exact)
        let person = try harness.answer("person", ["uid": 13])
        XCTAssertNotNil(person["Ability"]?["CA"])
        XCTAssertNotNil(person["Hidden"]?["Consistency"])
        XCTAssertNotNil(person["Personality"]?["Ambition"])
        XCTAssertNotNil(person["Personality"]?["Adaptability"])
    }

    func testEachCallFollowsTheSettingAsTheUserLastSetIt() throws {
        let harness = try harness(true, .exact)
        XCTAssertTrue(try harness.answer("squad").columnNames.contains("CA"))
        harness.settings = World.settings(hidden: false, reveal: .exact)
        XCTAssertFalse(try harness.answer("squad").columnNames.contains("CA"))
        XCTAssertNil(try harness.answer("person", ["uid": 1])["Hidden"])
        harness.settings = World.settings(hidden: true, reveal: .stars)
        XCTAssertEqual(try harness.answer("squad").rowsByName.first?["CA"], "4.5★")
        XCTAssertEqual(harness.source.reads, 1, "a setting changes what's sent, not what's read")
    }

    func testOffMeansGoneNotEmpty() throws {
        let harness = try harness(false, .exact)
        let person = try harness.answer("person", ["uid": 13])
        XCTAssertNil(person["Ability"])
        XCTAssertNil(person["Hidden"])
        XCTAssertNil(person["Personality"]?["Ambition"])
        XCTAssertNil(person["Personality"]?["Adaptability"], "a player's Adaptability is hidden")
        XCTAssertEqual(person["Personality"]?["Personality"], "Resolute", "FM shows the personality's name")
        XCTAssertEqual(person["Personality"]?["Media handling"], "Reserved")
        XCTAssertFalse(try harness.answer("squad").columnNames.contains("CA"))

        let coach = try harness.answer("person", ["uid": 502])
        XCTAssertEqual(coach["Attributes"]?["Adaptability"], 12, "FM shows a member of staff's Adaptability")
    }

    func testHiddenFiltersAndOrdersAreRefusedNotIgnored() throws {
        let harness = try harness(false, .exact)
        let refusals: [(String, JSON, String)] = [
            ("search_players", ["rules": [["attribute": "Consistency", "at_least": 10]]], "Consistency"),
            ("search_players", ["rules": [["attribute": "Ambition", "at_least": 10]]], "Ambition"),
            ("search_players", ["ca_min": 100], "CA"),
            ("search_players", ["pa_max": 150], "PA"),
            ("search_players", ["sort": "CA"], "CA"),
            ("search_players", ["sort": "Growth room"], "Growth room"),
            ("search_players", ["sort": "Injury Proneness"], "Injury Proneness"),
            ("search_staff", ["rules": [["attribute": "Eccentricity", "at_most": 10]]], "Eccentricity"),
            ("search_staff", ["sort": "PA"], "PA"),
            ("find_bargains", ["min_ca": 120], "CA"),
        ]
        for (tool, arguments, name) in refusals {
            let sentence = try harness.refusal(tool, arguments)
            XCTAssertTrue(sentence.hasPrefix(name), sentence)
            XCTAssertTrue(sentence.contains("Hidden attributes is off"), sentence)
        }
        // The order that would have come from CA comes from value instead.
        let search = try harness.answer("search_players", ["club": "Testing", "limit": 2])
        XCTAssertEqual(search["order"], "Value")
        XCTAssertEqual(search.rowsByName.map { $0["uid"] }, [13, 12])
    }

    func testAbilityOffRefusesCAAndPAButNotHiddenAttributes() throws {
        let harness = try harness(true, .hidden)
        XCTAssertTrue(try harness.refusal("search_players", ["ca_min": 100]).contains("Ability is Off"))
        XCTAssertTrue(try harness.refusal("search_players", ["sort": "PA"]).contains("Ability is Off"))
        XCTAssertEqual(try harness.answer("search_players", ["rules": [["attribute": "Consistency", "at_least": 19]]])["found"], 25)
    }
}
