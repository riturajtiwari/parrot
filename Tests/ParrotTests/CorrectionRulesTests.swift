import XCTest
@testable import ParrotCore

// Every word here is made up or generic. The real pairs a user learns hold
// names of people and companies, so they never go into this public repo.

final class WordDiffTests: XCTestCase {
    func testOneMisheardWord() {
        XCTAssertEqual(
            WordDiff.changes(from: "we deployed to versailles today", to: "we deployed to Vercel today"),
            [WordChange(heard: ["versailles"], corrected: ["Vercel"])]
        )
    }

    func testCaseAloneIsAChange() {
        let changes = WordDiff.changes(from: "open the posthog dashboard", to: "open the PostHog dashboard")
        XCTAssertEqual(changes.map(\.correctedText), ["PostHog"])
        XCTAssertTrue(changes[0].isCaseOnly)
    }

    func testTwoHeardWordsJoinIntoOne() {
        XCTAssertEqual(
            WordDiff.changes(from: "open the post hog page", to: "open the PostHog page"),
            [WordChange(heard: ["post", "hog"], corrected: ["PostHog"])]
        )
    }

    func testARewriteHasNoChanges() {
        XCTAssertEqual(WordDiff.changes(from: "please send the report", to: "thanks, I will review it tomorrow"), [])
    }

    func testAddedOrRemovedWordsAreNotCorrections() {
        XCTAssertEqual(WordDiff.changes(from: "send the file to them", to: "send the new file to them"), [])
        XCTAssertEqual(WordDiff.changes(from: "send the new file to them", to: "send the file to them"), [])
    }

    func testPunctuationAndMarkupAreIgnored() {
        XCTAssertEqual(WordDiff.changes(from: "ship it, then rest.", to: "ship it then rest"), [])
        XCTAssertEqual(WordDiff.changes(from: "<li>one item</li>", to: "one item"), [])
    }

    func testLongReplacementsAreDropped() {
        let changes = WordDiff.changes(
            from: "we met the team on monday and talked a lot about plans",
            to: "we met the whole new product design team on monday and talked a lot about plans"
        )
        XCTAssertEqual(changes, [])
    }

    func testSentenceStartsAreMarked() {
        let changes = WordDiff.changes(from: "Done. Master is green now", to: "Done. master is green now")
        XCTAssertEqual(changes.count, 1)
        XCTAssertTrue(changes[0].atSentenceStart)
        XCTAssertFalse(WordDiff.changes(from: "the posthog page", to: "the PostHog page")[0].atSentenceStart)
    }
}

final class PhoneticTests: XCTestCase {
    func testMishearingsSoundAlike() {
        XCTAssertGreaterThanOrEqual(Phonetic.similarity("Kwilbo", "Qwilbo"), 0.8)
        XCTAssertGreaterThanOrEqual(Phonetic.similarity("versailles", "Vercel"), 0.6)
        XCTAssertGreaterThanOrEqual(Phonetic.similarity("Zor Blink", "Zorblink"), 0.8)
    }

    func testLettersReadAloud() {
        XCTAssertEqual(Phonetic.similarity("our QX", "RQX"), 1)
        XCTAssertEqual(Phonetic.similarity("Elsie", "LC"), 1)
    }

    func testContentChangesSoundDifferent() {
        XCTAssertLessThan(Phonetic.similarity("weekend", "week"), LocalJudge.minSimilarity)
        XCTAssertLessThan(Phonetic.similarity("report", "summary"), LocalJudge.minSimilarity)
    }

    func testKeys() {
        XCTAssertEqual(Phonetic.key("Philips"), "FLPS")
        XCTAssertEqual(Phonetic.key("knock"), "NK")
        XCTAssertEqual(Phonetic.key("thatch"), "0X")
        XCTAssertEqual(Phonetic.levenshtein("kitten", "sitting"), 3)
    }
}

final class LocalJudgeTests: XCTestCase {
    private let judge = LocalJudge(common: FixedCommonWords(words: [
        "link", "deck", "dev", "week", "weekend", "report", "summary", "master", "printer", "blink",
    ]))

    private func verdict(_ heard: String, _ corrected: String, start: Bool = false,
                         evidence: CorrectionEvidence = CorrectionEvidence(), known: Set<String> = []) -> CorrectionVerdict {
        let change = WordChange(
            heard: heard.split(separator: " ").map(String.init),
            corrected: corrected.split(separator: " ").map(String.init),
            atSentenceStart: start
        )
        return judge.judge(change, evidence: evidence, known: known)
    }

    func testARareSoundAlikeWordIsReplacedAndCased() {
        XCTAssertEqual(verdict("Kwilbo", "Qwilbo").rules, [.replace, .casing])
    }

    func testACommonHeardWordIsNeverReplaced() {
        let v = verdict("Link", "Zorblink")
        XCTAssertEqual(v.rules, [.casing, .prompt])
        XCTAssertTrue(v.reasons.contains("heard form is a common word"))
    }

    func testTwoHeardWordsAreReplaced() {
        let v = verdict("Zor Blink", "Zorblink")
        XCTAssertEqual(v.rules, [.replace, .casing])
        XCTAssertEqual(v.kind, .join)
    }

    func testAHeardFormTheUserKeepsIsNeverReplaced() {
        XCTAssertFalse(verdict("Kwilbo", "Qwilbo", evidence: CorrectionEvidence(keptHeard: 3)).rules.contains(.replace))
    }

    func testShortHeardWordsAreNeverReplaced() {
        XCTAssertFalse(verdict("QX", "QXZ").rules.contains(.replace))
    }

    func testALowercaseCommonWordGetsNoRow() {
        XCTAssertEqual(verdict("deck", "dev").rules, [])
        XCTAssertEqual(verdict("deck", "dev", evidence: CorrectionEvidence(seen: 6)).rules, [.prompt])
    }

    func testRewordingAndContentChangesAreNotLearned() {
        XCTAssertEqual(verdict("an", "the").kind, .rewording)
        XCTAssertEqual(verdict("an", "the").rules, [])
        XCTAssertEqual(verdict("weekend", "week").rules, [])
        XCTAssertEqual(verdict("report", "summary").rules, [])
    }

    func testFragmentsAreNotLearned() {
        XCTAssertEqual(verdict("organizing speaking points", "o").kind, .fragment)
    }

    func testCaseAtASentenceStartSaysNothing() {
        XCTAssertEqual(verdict("Master", "master", start: true).rules, [])
    }

    func testACaseOnlyFixOfABrandIsCased() {
        let v = verdict("zorbex", "ZorBex")
        XCTAssertEqual(v.rules, [.casing])
        XCTAssertEqual(v.kind, .casing)
    }

    func testAKnownWordNeedsNoNewCase() {
        XCTAssertEqual(verdict("Kwilbo", "Qwilbo", known: ["qwilbo"]).rules, [.replace])
    }
}
