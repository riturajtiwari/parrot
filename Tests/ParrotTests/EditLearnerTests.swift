import XCTest
@testable import ParrotCore

@MainActor
final class EditLearnerTests: XCTestCase {
    private var dir: TemporaryDirectory!
    private var actions: CorrectionActions!
    private var settings = CorrectionSettings()

    override func setUp() async throws {
        dir = try TemporaryDirectory()
        actions = CorrectionActions(
            dictionary: dir.url.appendingPathComponent("dictionary"),
            overlay: dir.url.appendingPathComponent("learned-dictionary"),
            lock: dir.url.appendingPathComponent("dictionary.lock"),
            store: LearnedStore(file: dir.url.appendingPathComponent("corrections.json"))
        )
        settings = CorrectionSettings()
    }

    private func learner() -> EditLearner {
        let learner = EditLearner(settings: { [unowned self] in self.settings }, actions: actions)
        learner.local = LocalJudge(common: FixedCommonWords(words: ["link"]))
        return learner
    }

    private let change = WordChange(heard: ["Kwilbo"], corrected: ["Qwilbo"])

    private func decided(_ count: Int, accepted: Int) throws {
        try actions.store.update { pairs in
            for i in 0..<count {
                let word = "Word\(i)"
                pairs.record(LearnedPair(word: word, heard: "Heard\(i)", rules: [.replace, .casing], status: .pending,
                                         sources: [.wisprEdits], seen: 1, firstSeen: Date(), lastSeen: Date()))
                if i < accepted {
                    pairs.decide(word: word, heard: "Heard\(i)", status: .added, rules: [.replace, .casing], target: .dictionary)
                } else {
                    pairs.decide(word: word, heard: "Heard\(i)", status: .rejected, rules: [], target: nil)
                }
            }
        }
    }

    func testReviewModeQueuesAndWritesNoRow() async throws {
        await learner().learn([change])
        XCTAssertEqual(try actions.store.load().pair(word: "Qwilbo", heard: "Kwilbo")?.status, .pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: actions.overlay.path))
    }

    func testHybridWaitsForTheGate() async throws {
        settings.learning = .hybrid
        try decided(20, accepted: 18)
        XCTAssertFalse(HybridGate.status(try actions.store.load().pairs).isOpen)
        let l = learner()
        await l.learn([change])
        await l.learn([change])
        XCTAssertEqual(try actions.store.load().pair(word: "Qwilbo", heard: "Kwilbo")?.status, .pending)
    }

    func testHybridAddsAClearFixToTheOverlayOnceTheGateIsOpen() async throws {
        settings.learning = .hybrid
        try decided(20, accepted: 20)
        var learned: [String] = []
        let l = learner()
        l.onOutcomes = { outcomes in
            for case .added(let pair) in outcomes { learned.append(pair.word) }
        }
        // Seen once: queued. Seen twice with the local rules: added.
        await l.learn([change])
        XCTAssertEqual(learned, [])
        await l.learn([change])
        XCTAssertEqual(learned, ["Qwilbo"])
        let overlay = try String(contentsOf: actions.overlay, encoding: .utf8)
        XCTAssertTrue(overlay.contains("Qwilbo") && overlay.contains("Kwilbo"), overlay)
        XCTAssertFalse(FileManager.default.fileExists(atPath: actions.dictionary.path), "never the user's own file")
        XCTAssertEqual(try actions.store.load().pair(word: "Qwilbo", heard: "Kwilbo")?.target, .overlay)
    }

    func testRevertingALearnedRuleMarksItSuspect() async throws {
        try actions.accept(change, rules: [.replace, .casing], source: .watched, target: .overlay)
        await learner().learn([WordChange(heard: ["Qwilbo"], corrected: ["Kwilbo"])])
        let pairs = try actions.store.load()
        XCTAssertEqual(pairs.pair(word: "Qwilbo", heard: "Kwilbo")?.status, .suspect)
        XCTAssertNil(pairs.pair(word: "Kwilbo", heard: "Qwilbo"), "the reverse is never learned")
        XCTAssertEqual(try actions.pending().first?.pair.status, .suspect)
    }

    func testEachEditReportsWhatItDid() async throws {
        var outcomes: [EditLearner.Outcome] = []
        let l = learner()
        l.onOutcomes = { outcomes += $0 }
        await l.learn([change, WordChange(heard: ["zorb"], corrected: ["zorp"])])
        XCTAssertEqual(outcomes.count, 2)
        guard case .proposed(let pair) = outcomes.first else { return XCTFail("\(outcomes)") }
        XCTAssertEqual(pair.word, "Qwilbo")
        XCTAssertEqual(outcomes.last, .notLearned(reason: "a lowercase word"))
    }

    func testARevertIsReported() async throws {
        try actions.accept(change, rules: [.replace, .casing], source: .watched, target: .overlay)
        var outcomes: [EditLearner.Outcome] = []
        let l = learner()
        l.onOutcomes = { outcomes += $0 }
        await l.learn([WordChange(heard: ["Qwilbo"], corrected: ["Kwilbo"])])
        guard case .reverted(let pair) = outcomes.first else { return XCTFail("\(outcomes)") }
        XCTAssertEqual(pair.word, "Qwilbo")
    }

    func testAPairDecidedBeforeStaysQuiet() async throws {
        try actions.store.update {
            $0.record(LearnedPair(word: "Qwilbo", heard: "Kwilbo", rules: [.casing], status: .pending, sources: [.watched],
                                  seen: 1, firstSeen: Date(), lastSeen: Date()))
        }
        try actions.reject(word: "Qwilbo", heard: "Kwilbo")
        var outcomes: [EditLearner.Outcome] = []
        let l = learner()
        l.onOutcomes = { outcomes += $0 }
        await l.learn([change])
        XCTAssertTrue(outcomes.isEmpty)
    }

    func testOffLearnsNothing() async throws {
        settings.learning = .off
        await learner().learn([change])
        XCTAssertTrue(try actions.store.load().pairs.isEmpty)
    }
}

final class HybridGateTests: XCTestCase {
    private func pair(_ i: Int, _ status: LearnedPair.Status, proposed: [CorrectionRule], rules: [CorrectionRule]) -> LearnedPair {
        var p = LearnedPair(word: "W\(i)", heard: "H\(i)", rules: rules, status: status, sources: [.wisprEdits], seen: 1,
                            firstSeen: Date(), lastSeen: Date())
        p.proposed = proposed
        return p
    }

    func testCountsOnlyDecidedReplaceProposals() {
        var pairs = (0..<19).map { pair($0, .added, proposed: [.replace], rules: [.replace]) }
        pairs.append(pair(19, .rejected, proposed: [.replace], rules: []))
        pairs.append(pair(20, .pending, proposed: [.replace], rules: [.replace]))
        pairs.append(pair(21, .added, proposed: [.casing, .prompt], rules: [.casing]))
        let status = HybridGate.status(pairs)
        XCTAssertEqual(status.decisions, 20)
        XCTAssertEqual(status.accepted, 19)
        XCTAssertTrue(status.isOpen)
    }

    func testAcceptedWithoutReplaceCountsAsWrong() {
        let pairs = (0..<20).map { pair($0, .added, proposed: [.replace], rules: $0 < 2 ? [.casing] : [.replace]) }
        XCTAssertEqual(HybridGate.status(pairs).accepted, 18)
        XCTAssertFalse(HybridGate.status(pairs).isOpen)
    }
}
