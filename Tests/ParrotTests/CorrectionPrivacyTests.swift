import XCTest
@testable import ParrotCore

/// Rule 1 and ADR-006: a learned word may reach `corrections.json` and a
/// dictionary, but never a log line, and the sentence around it never
/// reaches disk at all. A canary word proves it.
@MainActor
final class CorrectionPrivacyTests: XCTestCase {
    private let canary = "Zqxcanary"
    private let sentenceWord = "Plumbusfleeb"

    /// Everything written to stderr while `body` runs.
    private func stderr(_ body: () async throws -> Void) async rethrows -> String {
        let pipe = Pipe()
        let saved = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        do {
            try await body()
        } catch {
            dup2(saved, STDERR_FILENO)
            close(saved)
            throw error
        }
        dup2(saved, STDERR_FILENO)
        close(saved)
        pipe.fileHandleForWriting.closeFile()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func testTheLearnerNeverLogsAWordAndStoresNoSentence() async throws {
        let dir = try TemporaryDirectory()
        let actions = CorrectionActions(
            dictionary: dir.url.appendingPathComponent("dictionary"),
            overlay: dir.url.appendingPathComponent("learned-dictionary"),
            lock: dir.url.appendingPathComponent("dictionary.lock"),
            store: LearnedStore(file: dir.url.appendingPathComponent("corrections.json"))
        )
        var settings = CorrectionSettings()
        settings.learning = .hybrid
        // Open the gate, so the learner writes to the overlay and logs it.
        try actions.store.update { pairs in
            for i in 0..<20 {
                pairs.record(LearnedPair(word: "Word\(i)", heard: "Heard\(i)", rules: [.replace], status: .pending,
                                         sources: [.wisprEdits], seen: 1, firstSeen: Date(), lastSeen: Date()))
                pairs.decide(word: "Word\(i)", heard: "Heard\(i)", status: .added, rules: [.replace], target: .dictionary)
            }
        }
        let learner = EditLearner(settings: { settings }, actions: actions)
        learner.local = LocalJudge(common: FixedCommonWords(words: []))

        // What the watcher would find in "the \(sentenceWord) is at \(canary)".
        var watch = EditWatch(pasted: "the \(sentenceWord) is at zqxcanery", expected: 0, at: 0)
        _ = watch.step(FieldState(text: "the \(sentenceWord) is at zqxcanery"), at: 0.3)
        _ = watch.step(FieldState(text: "the \(sentenceWord) is at \(canary)"), at: 1)
        _ = watch.step(FieldState(text: "the \(sentenceWord) is at \(canary)"), at: 1.5)
        guard case .ended(_, let changes) = watch.finish(.nextDictation) else { return XCTFail("the watch did not end") }
        XCTAssertEqual(changes.map(\.correctedText), [canary])

        let log = try await stderr {
            await learner.learn(changes)
            await learner.learn(changes)
            try actions.undo(try XCTUnwrap(try actions.added().first { $0.word == canary }))
        }
        XCTAssertFalse(log.isEmpty, "the learner logs what it did")
        XCTAssertFalse(log.contains(canary), log)
        XCTAssertFalse(log.lowercased().contains("zqxcanery"), log)

        for file in ["corrections.json", "learned-dictionary"] {
            let text = (try? String(contentsOf: dir.url.appendingPathComponent(file), encoding: .utf8)) ?? ""
            XCTAssertFalse(text.contains(sentenceWord), "\(file) holds no word from around the pair")
        }
    }
}
