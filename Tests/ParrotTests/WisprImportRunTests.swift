import SQLite3
import XCTest
@testable import ParrotCore

// Synthetic rows only.

/// A judge that gives the same answer to every request.
private struct FixedAnswerClient: LLMClient {
    let answer: String
    func complete(_ request: LLMRequest) async throws -> Data { Data(answer.utf8) }
    func models() async throws -> [String] { [] }
}

final class WisprImportRunTests: XCTestCase {
    private var dir: TemporaryDirectory!
    private var run: WisprImportRun!
    private let local = LocalJudge(common: FixedCommonWords(words: ["team", "ping"]))

    override func setUpWithError() throws {
        dir = try TemporaryDirectory()
        run = WisprImportRun(
            database: dir.url.appendingPathComponent("flow.sqlite"),
            actions: CorrectionActions(
                dictionary: dir.url.appendingPathComponent("dictionary"),
                overlay: dir.url.appendingPathComponent("learned-dictionary"),
                lock: dir.url.appendingPathComponent("dictionary.lock"),
                store: LearnedStore(file: dir.url.appendingPathComponent("corrections.json"))
            ),
            judge: local
        )
    }

    override func tearDown() {
        run = nil
        dir = nil
    }

    /// One learned word, Qwilbo for "Kwilbo", used 5 times, and dictations
    /// that keep "kwilbo" as it is `kept` times.
    private func makeDatabase(kept: Int = 0) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(run.database.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var sql = """
            CREATE TABLE Dictionary (id TEXT, phrase TEXT, replacement TEXT, teamDictionaryId TEXT DEFAULT '00000000-0000-0000-0000-000000000000',
              frequencyUsed INTEGER DEFAULT 0, manualEntry INTEGER DEFAULT 0, isDeleted INTEGER DEFAULT 0, source TEXT,
              isSnippet INTEGER DEFAULT 0, observedSource TEXT);
            INSERT INTO Dictionary (id, phrase, observedSource, frequencyUsed, source) VALUES ('1', 'Qwilbo', 'Kwilbo', 5, 'user_edits');
            CREATE TABLE History (transcriptEntityId TEXT, formattedText TEXT, pastedText TEXT, editedText TEXT, audio BLOB, timestamp DATETIME);
            """
        for index in 0..<kept {
            sql += "INSERT INTO History VALUES ('k\(index)', 'the kwilbo stays', 'the kwilbo stays', NULL, NULL, '2026-01-01');\n"
        }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    private func stored() throws -> LearnedPair {
        try XCTUnwrap(try run.actions.store.load().pair(word: "Qwilbo", heard: "Kwilbo"))
    }

    func testTheImportRecordsProposalsWithTheirEvidence() async throws {
        try makeDatabase(kept: 2)
        let report = try await run.run(settings: CorrectionSettings(), known: [])
        XCTAssertEqual(report, WisprImportRun.Report(proposed: 1, declined: 0, decided: 0, judge: nil, failures: []))
        let pair = try stored()
        XCTAssertEqual(pair.status, .pending)
        XCTAssertEqual(pair.seen, 5)
        XCTAssertEqual(pair.keptHeard, 2)
        XCTAssertEqual(pair.sources, [.wisprDictionary])
        // "Kwilbo" is a word the user keeps, so it is never replaced.
        XCTAssertFalse(pair.rules.contains(.replace))
        XCTAssertFalse(try XCTUnwrap(try run.actions.pending(judge: local).first).verdict.rules.contains(.replace))
    }

    func testASecondImportKeepsTheUsersDecision() async throws {
        try makeDatabase()
        _ = try await run.run(settings: CorrectionSettings(), known: [])
        try run.actions.reject(word: "Qwilbo", heard: "Kwilbo")
        let again = try await run.run(settings: CorrectionSettings(), known: [])
        XCTAssertEqual(again.proposed, 0)
        XCTAssertEqual(again.decided, 1)
        XCTAssertEqual(try stored().status, .rejected)
    }

    func testTheJudgesNarrowerRulesReachReview() async throws {
        try makeDatabase()
        var settings = CorrectionSettings()
        settings.provider = .claude
        let answer = #"{"verdicts":[{"id":0,"learn":true,"kind":"brand","rules":["case"],"confidence":0.9,"reason":"spell it only"}]}"#
        let report = try await run.run(settings: settings, known: [], makeClient: { _ in FixedAnswerClient(answer: answer) })
        XCTAssertEqual(report.judge, .claude)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(try stored().rules, [.casing])
        // The local rules alone would propose a replace row; the window
        // shows what the judge left.
        XCTAssertTrue(local.judge(WordChange(heard: ["Kwilbo"], corrected: ["Qwilbo"]), evidence: CorrectionEvidence(seen: 5)).rules.contains(.replace))
        XCTAssertEqual(try XCTUnwrap(try run.actions.pending(judge: local).first).verdict.rules, [.casing])
    }

    func testAJudgeWithoutAKeyLeavesTheLocalRules() async throws {
        try makeDatabase()
        var settings = CorrectionSettings()
        settings.provider = .openai
        let report = try await run.run(settings: settings, known: [], makeClient: { _ in throw LLMError.notConfigured("no API key") })
        XCTAssertNil(report.judge)
        XCTAssertEqual(report.failures, [.notConfigured("no API key")])
        XCTAssertEqual(report.proposed, 1)
        XCTAssertTrue(try stored().rules.contains(.replace))
    }

    func testAMissingDatabaseIsAnError() async {
        XCTAssertFalse(WisprImportRun.isAvailable(at: run.database))
        do {
            _ = try await run.run(settings: CorrectionSettings(), known: [])
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is WisprError, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.database.path), "the import must not create Wispr's file")
    }

    func testTheSummaryCountsWhatHappened() {
        let report = WisprImportRun.Report(proposed: 3, declined: 7, decided: 2, judge: .claude, failures: [])
        XCTAssertEqual(CorrectionsSection.summary(report),
                       "Added 3 proposals to Review Corrections. Claude checked them. 7 pairs teach nothing, such as rewording or common words. 2 you decided before.")
    }
}

final class LearnedEvidenceTests: XCTestCase {
    private func pair(kept: Int? = nil, manual: Bool? = nil) -> LearnedPair {
        LearnedPair(word: "Qwilbo", heard: "Kwilbo", rules: [.casing], status: .pending, sources: [.wisprDictionary],
                    seen: 2, firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 0),
                    keptHeard: kept, manual: manual)
    }

    func testAnOldFileWithoutEvidenceStillLoads() throws {
        let json = #"{"version":1,"pairs":[{"word":"Qwilbo","heard":"Kwilbo","rules":["case"],"status":"pending","sources":["whisper"],"seen":3,"firstSeen":"2026-09-29T00:00:00Z","lastSeen":"2026-09-29T00:00:00Z"}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pairs = try decoder.decode(LearnedPairs.self, from: Data(json.utf8))
        XCTAssertNil(pairs.pairs[0].keptHeard)
        XCTAssertEqual(pairs.pairs[0].evidence, CorrectionEvidence(seen: 3, keptHeard: 0, manual: false))
    }

    func testRecordingAgainKeepsTheStrongerEvidence() {
        var pairs = LearnedPairs()
        pairs.record(pair(kept: 4, manual: true))
        pairs.record(pair(kept: 1, manual: nil))
        XCTAssertEqual(pairs.pairs.count, 1)
        XCTAssertEqual(pairs.pairs[0].keptHeard, 4)
        XCTAssertEqual(pairs.pairs[0].manual, true)
    }
}

final class ExampleSentenceTests: XCTestCase {
    private func added(_ word: String, _ rules: [CorrectionRule]) -> LearnedPair {
        LearnedPair(word: word, heard: nil, rules: rules, status: .added, sources: [.fixWord], seen: 1, firstSeen: Date(), lastSeen: Date())
    }

    func testTermsComeFromAcceptedPromptRulesOnce() {
        let terms = ExampleSentence.terms([added("Qwilbo", [.prompt]), added("Zorbex Labs", [.casing, .prompt]),
                                           added("Kwarn", [.casing]), added("qwilbo", [.prompt])])
        XCTAssertEqual(terms, ["Qwilbo", "Zorbex Labs"])
    }

    func testMissingTermsAreWholeWordsInAnyCase() {
        let terms = ["Qwilbo", "Zorbex Labs", "Kwarn"]
        XCTAssertEqual(ExampleSentence.missing(terms, in: "Ask qwilbo about Zorbex labs."), ["Kwarn"])
        XCTAssertEqual(ExampleSentence.missing(terms, in: "The Qwilbos and Zorbex met."), terms)
        XCTAssertEqual(ExampleSentence.missing(terms, in: ""), terms)
    }

    func testWordCount() {
        XCTAssertEqual(ExampleSentence.wordCount("  Ask Qwilbo  about Kwarn. "), 4)
    }
}
