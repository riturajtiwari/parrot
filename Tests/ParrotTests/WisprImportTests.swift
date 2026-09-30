import SQLite3
import XCTest
@testable import ParrotCore

// Synthetic rows only: the real ones hold names of people and companies.

final class WisprImportTests: XCTestCase {
    private let judge = LocalJudge(common: FixedCommonWords(words: ["link", "blink", "deck", "dev", "send", "file", "team"]))

    private func run(
        _ dictionary: [WisprDatabase.DictionaryRow],
        _ dictations: [WisprDatabase.Dictation] = [],
        decided: LearnedPairs = LearnedPairs()
    ) -> WisprImport {
        WisprImport(dictionary: dictionary, dictations: dictations, judge: judge, decided: decided)
    }

    private func row(_ phrase: String, observed: String? = nil, replacement: String? = nil,
                     manual: Bool = false, snippet: Bool = false, uses: Int = 1) -> WisprDatabase.DictionaryRow {
        WisprDatabase.DictionaryRow(phrase: phrase, observed: observed, replacement: replacement, manual: manual, snippet: snippet, uses: uses)
    }

    private func candidate(_ result: WisprImport, _ word: String, heard: String? = nil) -> WisprImport.Candidate? {
        result.candidates.first { $0.change.correctedText == word && (heard == nil || $0.change.heardText == heard) }
    }

    func testALearnedWordWithACommonHeardFormIsNeverReplaced() throws {
        let result = run([row("Zorblink", observed: "Link", uses: 40)])
        let c = try XCTUnwrap(candidate(result, "Zorblink"))
        XCTAssertEqual(c.verdict.rules, [.casing, .prompt])
        XCTAssertEqual(c.evidence.seen, 40)
    }

    func testEditsAddEvidenceToTheSamePair() throws {
        let edits = (0..<3).map { _ in WisprDatabase.Dictation(pasted: "ping the kwilbo team", edited: "ping the Qwilbo team") }
        let result = run([row("Qwilbo", observed: "Kwilbo", uses: 2)], edits)
        // A heard form in another case is the same pair: 2 uses plus 3 edits.
        XCTAssertEqual(result.candidates.filter { $0.change.correctedText == "Qwilbo" }.count, 1)
        XCTAssertEqual(try XCTUnwrap(candidate(result, "Qwilbo")).evidence.seen, 5)
        XCTAssertEqual(result.summary.edited, 3)
    }

    func testAHeardFormInKeptTextIsNotReplaced() throws {
        let kept = WisprDatabase.Dictation(pasted: "the kwilbo stays here", edited: nil)
        let result = run([row("Qwilbo", observed: "Kwilbo", uses: 5)], [kept])
        let c = try XCTUnwrap(candidate(result, "Qwilbo"))
        XCTAssertEqual(c.evidence.keptHeard, 1)
        XCTAssertFalse(c.verdict.rules.contains(.replace))
    }

    func testManualWordsReplacementsAndSnippets() throws {
        let result = run([
            row("Zorbex Labs", manual: true),
            row("zbx", replacement: "Zorbex", manual: true),
            row("my address", replacement: "1 Long Road, Springfield", snippet: true),
        ])
        XCTAssertEqual(try XCTUnwrap(candidate(result, "Zorbex Labs")).verdict.rules, [.casing, .prompt])
        XCTAssertNotNil(candidate(result, "Zorbex", heard: "zbx"))
        XCTAssertEqual(result.summary.snippets, 1)
        XCTAssertNil(candidate(result, "1 Long Road, Springfield"))
    }

    func testRewritesAreCountedAndLearnNothing() {
        let result = run([], [WisprDatabase.Dictation(pasted: "can you send the file today", edited: "Reply...")])
        XCTAssertEqual(result.summary.rewrites, 1)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testADecidedPairIsMarked() throws {
        var decided = LearnedPairs()
        decided.record(LearnedPair(word: "Qwilbo", heard: "Kwilbo", rules: [.replace], status: .pending, sources: [.wisprDictionary],
                                   seen: 1, firstSeen: Date(), lastSeen: Date()))
        decided.decide(word: "Qwilbo", heard: "Kwilbo", status: .rejected, rules: [], target: nil)
        let result = run([row("Qwilbo", observed: "Kwilbo")], decided: decided)
        XCTAssertEqual(try XCTUnwrap(candidate(result, "Qwilbo")).decided, .rejected)
    }

    func testProposalsComeFirstThenByEvidence() {
        let result = run([row("Qwilbo", observed: "Kwilbo", uses: 2), row("Zorblink", observed: "Link", uses: 9), row("dev", observed: "deck", uses: 1)])
        XCTAssertEqual(result.candidates.map(\.change.correctedText), ["Zorblink", "Qwilbo", "dev"])
    }
}

/// A real SQLite file in Wispr Flow's shape, read the way `parrot import
/// wispr` reads the real one.
final class WisprDatabaseTests: XCTestCase {
    private var dir: TemporaryDirectory!

    override func setUpWithError() throws {
        dir = try TemporaryDirectory()
    }

    override func tearDown() {
        dir = nil
    }

    private func makeDatabase(wal: Bool) throws -> URL {
        let file = dir.url.appendingPathComponent("flow.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            \(wal ? "PRAGMA journal_mode=WAL;" : "")
            CREATE TABLE Dictionary (id TEXT, phrase TEXT, replacement TEXT, teamDictionaryId TEXT DEFAULT '00000000-0000-0000-0000-000000000000',
              frequencyUsed INTEGER DEFAULT 0, manualEntry INTEGER DEFAULT 0, isDeleted INTEGER DEFAULT 0, source TEXT,
              isSnippet INTEGER DEFAULT 0, observedSource TEXT);
            INSERT INTO Dictionary (id, phrase, observedSource, frequencyUsed, source) VALUES ('1', 'Qwilbo', 'Kwilbo', 4, 'user_edits');
            INSERT INTO Dictionary (id, phrase, source, isDeleted) VALUES ('2', 'Gone', 'manual', 1);
            INSERT INTO Dictionary (id, phrase, source, teamDictionaryId) VALUES ('3', 'TeamWord', 'manual', 'abc');
            CREATE TABLE History (transcriptEntityId TEXT, formattedText TEXT, pastedText TEXT, editedText TEXT, audio BLOB, timestamp DATETIME);
            INSERT INTO History VALUES ('a', 'ping the kwilbo team', 'ping the kwilbo team', 'ping the Qwilbo team', NULL, '2026-01-01');
            INSERT INTO History VALUES ('b', 'no edit here', '', NULL, x'52494646000000005741564500000000000000000000000000000000000000000000000000000000000000000000', '2026-01-02');
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        return file
    }

    func testReadsTheDictionaryDictationsAndClips() throws {
        let file = try makeDatabase(wal: false)
        let before = try Data(contentsOf: file)
        let db = try WisprDatabase(file: file)
        XCTAssertEqual(try db.dictionary().map(\.phrase), ["Qwilbo"])
        XCTAssertEqual(try db.dictionary().first?.observed, "Kwilbo")
        let dictations = try db.dictations()
        XCTAssertEqual(dictations.count, 2)
        XCTAssertEqual(dictations[0].edited, "ping the Qwilbo team")
        XCTAssertEqual(dictations[1].pasted, "no edit here", "an empty pastedText falls back to formattedText")
        var clips = 0
        try db.forEachClip { wav, kept in
            clips += 1
            XCTAssertEqual(kept, "no edit here")
            XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        }
        XCTAssertEqual(clips, 1)
        XCTAssertEqual(try Data(contentsOf: file), before, "reading never writes the file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + "-wal"))
    }

    func testReadsALiveDatabaseWhileAWriterHasItOpen() throws {
        let file = try makeDatabase(wal: true)
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "INSERT INTO Dictionary (id, phrase, source) VALUES ('4', 'Zorblink', 'manual');", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + "-wal"))

        let db = try WisprDatabase(file: file)
        XCTAssertEqual(Set(try db.dictionary().map(\.phrase)), ["Qwilbo", "Zorblink"])
    }

    func testAMissingDatabaseSaysSo() {
        XCTAssertThrowsError(try WisprDatabase(file: dir.url.appendingPathComponent("none.sqlite")))
    }
}

final class LearnedStoreTests: XCTestCase {
    private var dir: TemporaryDirectory!

    override func setUpWithError() throws {
        dir = try TemporaryDirectory()
    }

    override func tearDown() {
        dir = nil
    }

    private func pair(_ word: String, _ heard: String?) -> LearnedPair {
        LearnedPair(word: word, heard: heard, rules: [.casing], status: .pending, sources: [.wisprEdits], seen: 1,
                    firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 0))
    }

    func testRecordsDecidesAndSavesOwnerOnly() throws {
        let store = LearnedStore(file: dir.url.appendingPathComponent("corrections.json"))
        try store.update { $0.record(pair("Qwilbo", "Kwilbo")) }
        try store.update { $0.decide(word: "qwilbo", heard: "kwilbo", status: .added, rules: [.replace, .casing], target: .dictionary, createdRow: true) }
        let saved = try XCTUnwrap(try store.load().pair(word: "Qwilbo", heard: "Kwilbo"))
        XCTAssertEqual(saved.status, .added)
        XCTAssertEqual(saved.rules, [.replace, .casing])
        XCTAssertEqual(saved.createdRow, true)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRefusesASentence() {
        let store = LearnedStore(file: dir.url.appendingPathComponent("corrections.json"))
        XCTAssertThrowsError(try store.update { $0.record(pair("this is a whole sentence", nil)) }) {
            XCTAssertEqual($0 as? LearnedStoreError, .notStorable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
    }

    func testRecordingAgainKeepsTheDecision() throws {
        var pairs = LearnedPairs()
        pairs.record(pair("Qwilbo", "Kwilbo"))
        pairs.decide(word: "Qwilbo", heard: "Kwilbo", status: .rejected, rules: [], target: nil)
        var again = pair("Qwilbo", "Kwilbo")
        again.seen = 5
        pairs.record(again)
        XCTAssertEqual(pairs.pairs.count, 1)
        XCTAssertEqual(pairs.pairs[0].status, .rejected)
        XCTAssertEqual(pairs.pairs[0].seen, 5)
    }

    func testUndoRemovesOnlyWhatParrotWrote() {
        var created = pair("Qwilbo", "Kwilbo")
        created.rules = [.replace, .casing]
        created.createdRow = true
        XCTAssertEqual(CorrectionActions.undoEdits(for: created), [.remove(word: "Qwilbo", replaces: [])])
        created.createdRow = false
        XCTAssertEqual(CorrectionActions.undoEdits(for: created), [.remove(word: "Qwilbo", replaces: ["Kwilbo"])])
    }
}

final class LayeredDictionaryTests: XCTestCase {
    func testTheUsersRowsWin() {
        let mine = UserDictionary(terms: ["Zorblink", "Link"], replacements: [.init(from: ["zor blink"], to: "Zorblink")])
        let learned = UserDictionary(
            terms: ["link", "Qwilbo", "Zorbex"],
            replacements: [.init(from: ["Link"], to: "Zorbex"), .init(from: ["Kwilbo"], to: "Qwilbo"), .init(from: ["zor blink"], to: "Qwilbo")]
        )
        let merged = LayeredDictionary.merged(mine, learned)
        XCTAssertEqual(merged.terms, ["Zorblink", "Link", "Qwilbo", "Zorbex"])
        XCTAssertEqual(merged.replacements, [
            .init(from: ["zor blink"], to: "Zorblink"),
            .init(from: ["Kwilbo"], to: "Qwilbo"),
        ])
        XCTAssertEqual(DictionaryReplacer(merged).apply(to: "the link to kwilbo"), "the Link to Qwilbo")
    }
}
