@testable import StarshipCore
import XCTest

/// FM's interest rule is asked once per player and team for the life of an engine.
final class InterestAnswersTests: XCTestCase {
    private let interested: InterestAnswers.Answer = (.interested, .doubtful)

    func testAsksOncePerPlayerAndTeam() {
        let answers = InterestAnswers()
        var asked = 0
        for _ in 0..<3 {
            let answer = answers.answer(player: 0x100, team: 1) { asked += 1; return interested }
            XCTAssertEqual(answer?.transfer, .interested)
            XCTAssertEqual(answer?.loan, .doubtful)
        }
        XCTAssertEqual(asked, 1)
    }

    func testAnotherPlayerOrTeamIsAskedItself() {
        let answers = InterestAnswers()
        var asked: [String] = []
        _ = answers.answer(player: 0x100, team: 1) { asked.append("first"); return interested }
        let other = answers.answer(player: 0x200, team: 1) { asked.append("other player"); return (.notInterested, .notInterested) }
        let elsewhere = answers.answer(player: 0x100, team: 2) { asked.append("other team"); return (.persuadable, .notInterested) }
        XCTAssertEqual(asked, ["first", "other player", "other team"])
        XCTAssertEqual(other?.transfer, .notInterested)
        XCTAssertEqual(elsewhere?.transfer, .persuadable)
    }

    /// A call can fail while the game is busy, and the next try has to reach FM again.
    func testAFailureIsntKept() {
        let answers = InterestAnswers()
        var asked = 0
        XCTAssertNil(answers.answer(player: 0x100, team: 1) { asked += 1; return nil })
        XCTAssertEqual(answers.answer(player: 0x100, team: 1) { asked += 1; return interested }?.transfer, .interested)
        XCTAssertEqual(answers.answer(player: 0x100, team: 1) { asked += 1; return nil }?.transfer, .interested)
        XCTAssertEqual(asked, 2)
    }

    func testThreadsCheckingAListAllGetTheAnswer() {
        let answers = InterestAnswers()
        let results = UnsafeMutableBufferPointer<Int>.allocate(capacity: 1000)
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            let player = Int64(0x100 + (i % 50) * 8)
            let answer = answers.answer(player: player, team: 1) { (JoinInterest(score: Int32(i % 50) * 1000), .notInterested) }
            results[i] = answer.map { $0.transfer == JoinInterest(score: Int32(i % 50) * 1000) ? 1 : 0 } ?? 0
        }
        XCTAssertEqual(results.reduce(0, +), 1000)
    }
}
