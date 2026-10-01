import XCTest
@testable import ParrotCore

// Made-up words only.

final class LearningNoticePlanTests: XCTestCase {
    private func pair(_ word: String, _ heard: String?) -> LearnedPair {
        LearnedPair(word: word, heard: heard, rules: [.replace, .casing], status: .pending, sources: [.watched],
                    seen: 1, firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 0))
    }

    func testAnAddComesFirstAndTheRestWaitInReview() {
        let plan = LearningNoticePlan.plan([
            .notLearned(reason: "a rewording"), .proposed(pair("Zorblink", "zor blink")), .added(pair("Qwilbo", "Kwilbo")),
        ])
        XCTAssertEqual(plan?.kind, .added)
        XCTAssertEqual(plan?.text, "Added “Qwilbo” to your dictionary · 1 more in Review")
        XCTAssertEqual(plan?.duration, 4)
    }

    func testAQuestionShowsThePair() {
        let plan = LearningNoticePlan.plan([.proposed(pair("Qwilbo", "Kwilbo"))])
        XCTAssertEqual(plan?.kind, .ask)
        XCTAssertEqual(plan?.text, "Learn Kwilbo → Qwilbo?")
        XCTAssertEqual(plan?.pair?.word, "Qwilbo")
        XCTAssertEqual(plan?.duration, 6)
    }

    func testNothingLearnedIsBriefAndNamesNoWord() {
        XCTAssertEqual(LearningNoticePlan.plan([.notLearned(reason: "an everyday word")]),
                       .init(kind: .notLearned, text: "Edit seen: nothing to learn (an everyday word)", duration: 2, pair: nil))
    }

    func testARevertPointsToReview() {
        let plan = LearningNoticePlan.plan([.reverted(pair("Qwilbo", "Kwilbo")), .proposed(pair("Zorblink", "zor blink"))])
        XCTAssertEqual(plan?.kind, .ask, "a question comes before a revert")
        XCTAssertEqual(LearningNoticePlan.plan([.reverted(pair("Qwilbo", "Kwilbo"))])?.text, "You changed back “Qwilbo”. It waits in Review")
    }

    func testNoOutcomeNoNotice() {
        XCTAssertNil(LearningNoticePlan.plan([]))
    }
}

final class NotLearnedReasonTests: XCTestCase {
    private func verdict(_ kind: CorrectionKind, _ reasons: [String]) -> CorrectionVerdict {
        CorrectionVerdict(word: "w", heard: "h", kind: kind, rules: [], similarity: 0, reasons: reasons)
    }

    func testReasonsNameTheKindOfChange() {
        XCTAssertEqual(EditLearner.reason(verdict(.known, [])), "already in your dictionary")
        XCTAssertEqual(EditLearner.reason(verdict(.content, ["lowercase word"])), "a lowercase word")
        XCTAssertEqual(EditLearner.reason(verdict(.rewording, ["common word"])), "an everyday word")
        XCTAssertEqual(EditLearner.reason(verdict(.rewording, ["function words"])), "a rewording")
        XCTAssertEqual(EditLearner.reason(verdict(.content, ["sounds different (0.20)"])), "a change of content")
        XCTAssertEqual(EditLearner.reason(verdict(.noise, ["no letters"])), "not a word or a name")
    }

    func testNoticesAreOnUnlessTurnedOff() throws {
        XCTAssertTrue(try JSONDecoder().decode(CorrectionSettings.self, from: Data("{}".utf8)).showNotices)
        XCTAssertFalse(try JSONDecoder().decode(CorrectionSettings.self, from: Data(#"{"showNotices":false}"#.utf8)).showNotices)
    }
}
