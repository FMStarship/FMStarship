@testable import StarshipAnalysis
import StarshipCore
import XCTest

final class DevelopmentCurveTests: XCTestCase {
    private func player(age: Int, ca: Int, pa: Int) -> Player {
        let player = Player()
        player.age = age
        player.ca = ca
        player.pa = pa
        return player
    }

    /// A world of PA 150 players, spread around one line at each age.
    private let world: [Player] = {
        var people: [Player] = []
        for (age, share) in [(18, 0.70), (20, 0.80), (24, 0.90), (28, 0.95)] {
            for offset in [-0.04, -0.02, 0, 0.02, 0.04] {
                for _ in 0..<4 {
                    let player = Player()
                    player.age = age
                    player.pa = 150
                    player.ca = Int(150 * (share + offset))
                    people.append(player)
                }
            }
        }
        return people
    }()

    func testSomeoneOnTheMiddleLineStaysOnIt() {
        let curve = DevelopmentCurve(players: world, usesHidden: true)
        let teenager = player(age: 18, ca: 105, pa: 150)
        XCTAssertEqual(curve.expected(teenager, atAge: 20), 120)
        XCTAssertEqual(curve.peak(teenager), 142)
    }

    func testSomeoneAheadOfTheirAgeIsProjectedToStayAhead() {
        let curve = DevelopmentCurve(players: world, usesHidden: true)
        XCTAssertGreaterThan(curve.peak(player(age: 18, ca: 111, pa: 150)), curve.peak(player(age: 18, ca: 105, pa: 150)))
    }

    func testNoOneIsProjectedPastTheirPotentialOrBelowTheirAbility() {
        let curve = DevelopmentCurve(players: world, usesHidden: true)
        XCTAssertLessThanOrEqual(curve.peak(player(age: 18, ca: 140, pa: 150)), 150)
        XCTAssertEqual(curve.expected(player(age: 18, ca: 140, pa: 150), atAge: 19), 140)
        XCTAssertEqual(curve.peak(player(age: 30, ca: 120, pa: 150)), 120)
    }

    func testAProspectIsYoungWithRoomToGrow() {
        let curve = DevelopmentCurve(players: world, usesHidden: true)
        XCTAssertTrue(curve.isProspect(player(age: 18, ca: 105, pa: 150)))
        XCTAssertFalse(curve.isProspect(player(age: 25, ca: 105, pa: 150)))
        XCTAssertFalse(curve.isProspect(player(age: 20, ca: 148, pa: 150)))
    }

    private func prime(pa: Int, ca: Int, mentality value: Int) -> Player {
        let player = player(age: 26, ca: ca, pa: pa)
        player.raw[Names.playerIndex["Determination"]!] = UInt8(value * 5)
        player.pers[Names.personalityIndex["Professionalism"]!] = UInt8(value)
        player.pers[Names.personalityIndex["Ambition"]!] = UInt8(value)
        return player
    }

    /// Strong minds got to 95% of their potential and weak ones to 80%, as a save might show.
    private var mixedWorld: [Player] {
        world.filter { $0.age < 25 } + (0..<20).map { _ in prime(pa: 150, ca: 142, mentality: 16) } + (0..<20).map { _ in prime(pa: 150, ca: 120, mentality: 8) }
    }

    private func young(mentality: Int) -> Player {
        let player = prime(pa: 150, ca: 105, mentality: mentality)
        player.age = 18
        return player
    }

    func testTheOddsComeFromHowPlayersLikeThisTurnedOut() {
        let curve = DevelopmentCurve(players: mixedWorld, usesHidden: true)
        XCTAssertEqual(curve.talent(young(mentality: 16))?.verdict, .likely)
        XCTAssertEqual(curve.talent(young(mentality: 8))?.verdict, .unlikely)
    }

    func testSomeoneAlreadyCloseHasLittleLeftToGoWrong() {
        let curve = DevelopmentCurve(players: mixedWorld, usesHidden: true)
        let nearlyThere = young(mentality: 8)
        nearlyThere.ca = 135
        XCTAssertEqual(curve.talent(nearlyThere)?.verdict, .likely)
    }

    func testMentalityMovesTheLikelyPeak() {
        let curve = DevelopmentCurve(players: mixedWorld, usesHidden: true)
        XCTAssertGreaterThan(curve.peak(young(mentality: 16)), curve.peak(young(mentality: 8)))
    }

    func testHiddenStatsStayOutWhenTheUserHidesThem() {
        let curve = DevelopmentCurve(players: mixedWorld, usesHidden: false)
        XCTAssertNil(curve.talent(young(mentality: 16)))
        XCTAssertEqual(curve.peak(young(mentality: 16)), curve.peak(young(mentality: 8)))
    }

    func testOddsReadTheWayPeopleSayThem() {
        let talent = DevelopmentCurve.Talent(determination: 14, professionalism: 13, ambition: 15, injuryProneness: 6, chance: 68)
        XCTAssertEqual(talent.odds, "7 in 10")
        XCTAssertEqual(talent.mentality, "Pro 13, Det 14, Amb 15")
        XCTAssertFalse(talent.injuryProne)
    }

    func testAnEmptyWorldPromisesNothing() {
        let curve = DevelopmentCurve(players: [], usesHidden: true)
        XCTAssertEqual(curve.peak(player(age: 18, ca: 105, pa: 150)), 105)
        XCTAssertFalse(curve.isProspect(player(age: 18, ca: 105, pa: 150)))
    }
}
