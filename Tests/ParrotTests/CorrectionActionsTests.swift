import XCTest
@testable import ParrotCore

final class CorrectionActionsTests: XCTestCase {
    private var dir: TemporaryDirectory!
    private var actions: CorrectionActions!

    override func setUpWithError() throws {
        dir = try TemporaryDirectory()
        actions = CorrectionActions(
            dictionary: dir.url.appendingPathComponent("dictionary"),
            overlay: dir.url.appendingPathComponent("learned-dictionary"),
            lock: dir.url.appendingPathComponent("dictionary.lock"),
            store: LearnedStore(file: dir.url.appendingPathComponent("corrections.json"))
        )
    }

    override func tearDown() {
        actions = nil
        dir = nil
    }

    private var dictionaryText: String {
        (try? String(contentsOf: actions.dictionary, encoding: .utf8)) ?? ""
    }

    private let change = WordChange(heard: ["Kwilbo"], corrected: ["Qwilbo"])

    func testAcceptWritesTheRowAndUndoRemovesIt() throws {
        try "# mine\nVercel  Versailles\n".write(to: actions.dictionary, atomically: true, encoding: .utf8)
        try actions.accept(change, rules: [.replace, .casing], source: .fixWord)
        XCTAssertTrue(dictionaryText.contains("Qwilbo  Kwilbo"), dictionaryText)
        let added = try XCTUnwrap(try actions.added().first)
        XCTAssertEqual(added.createdRow, true)
        XCTAssertEqual(added.sources, [.fixWord])

        try actions.undo(added)
        XCTAssertFalse(dictionaryText.contains("Qwilbo"), dictionaryText)
        XCTAssertTrue(dictionaryText.hasPrefix("# mine\nVercel  Versailles\n"))
        XCTAssertEqual(try actions.store.load().pair(word: "Qwilbo", heard: "Kwilbo")?.status, .rejected)
    }

    func testUndoOnTheUsersOwnRowRemovesOnlyTheItem() throws {
        try "Qwilbo  Qilbo\n".write(to: actions.dictionary, atomically: true, encoding: .utf8)
        try actions.accept(change, rules: [.replace, .casing], source: .fixWord)
        XCTAssertEqual(dictionaryText, "Qwilbo  Qilbo, Kwilbo\n")
        try actions.undo(try XCTUnwrap(try actions.added().first))
        XCTAssertEqual(dictionaryText, "Qwilbo  Qilbo\n")
    }

    func testAPromptAloneWritesNoRow() throws {
        try actions.accept(WordChange(heard: ["Link"], corrected: ["Zorblink"]), rules: [.prompt], source: .wisprDictionary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: actions.dictionary.path))
        XCTAssertEqual(try actions.added().first?.rules, [.prompt])
    }

    func testPendingPairsAreJudgedAgainAndRejectedOnesLeave() throws {
        try actions.store.update { pairs in
            pairs.record(LearnedPair(word: "Qwilbo", heard: "Kwilbo", rules: [], status: .pending, sources: [.whisper],
                                     seen: 3, firstSeen: Date(), lastSeen: Date()))
        }
        XCTAssertEqual(try actions.pendingCount(), 1)
        let review = try XCTUnwrap(try actions.pending(judge: LocalJudge(common: FixedCommonWords(words: []))).first)
        XCTAssertEqual(review.verdict.rules, [.replace, .casing])
        try actions.reject(word: "Qwilbo", heard: "Kwilbo")
        XCTAssertEqual(try actions.pendingCount(), 0)
    }

    func testWarningsNameWhatARuleWouldChange() {
        let common = FixedCommonWords(words: ["link", "dev"])
        XCTAssertEqual(CorrectionActions.warnings(WordChange(heard: ["Link"], corrected: ["Zorblink"]), rules: [.replace], common: common),
                       ["every \"Link\" in every dictation becomes \"Zorblink\""])
        XCTAssertEqual(CorrectionActions.warnings(WordChange(heard: ["deck"], corrected: ["dev"]), rules: [.casing], common: common),
                       ["every \"dev\" in any case becomes \"dev\""])
        XCTAssertEqual(CorrectionActions.warnings(change, rules: [.replace, .casing], common: common), [])
    }
}
