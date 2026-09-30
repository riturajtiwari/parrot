import Foundation

/// What happens to the corrections the edit watcher sees (ADR-006).
///
/// - The judge from Settings, or the local rules, decides the rules.
/// - In hybrid mode, with the gate open, a clear `replace` fix goes to the
///   overlay at once and the menu offers Undo. Everything else waits for
///   review.
/// - A correction that reverts what a learned rule wrote marks that rule
///   suspect, and is never learned the other way round.
@MainActor
final class EditLearner {
    private let actions: CorrectionActions
    private let settings: () -> CorrectionSettings
    /// A word was added to the overlay.
    var onLearned: ((String) -> Void)?
    /// The review queue changed.
    var onQueued: (() -> Void)?

    /// The confidence the LLM judge must give an automatic add.
    static let minConfidence = 0.8

    init(settings: @escaping () -> CorrectionSettings, actions: CorrectionActions = CorrectionActions()) {
        self.settings = settings
        self.actions = actions
    }

    func learn(_ changes: [WordChange]) async {
        let settings = self.settings()
        guard settings.learning != .off, !changes.isEmpty else { return }
        let pairs = (try? actions.store.load()) ?? LearnedPairs()
        let known = Set(CorrectionActions.words(in: actions.dictionary).map { $0.lowercased() })

        var items: [LLMJudge.Item] = []
        for change in changes {
            if markReverted(change, pairs) { continue }
            let existing = pairs.pair(word: change.correctedText, heard: change.heardText)
            if existing?.status == .rejected || existing?.status == .added { continue }
            items.append(LLMJudge.Item(change: change, evidence: CorrectionEvidence(seen: (existing?.seen ?? 0) + 1)))
        }
        guard !items.isEmpty else { return }

        let verdicts: [CorrectionVerdict]
        if settings.provider != .none, let client = try? makeClient(settings) {
            let judge = LLMJudge(client: client, local: local, batch: settings.maxPerDictation, timeout: 20)
            verdicts = await judge.judge(items, known: known).verdicts
        } else {
            verdicts = items.map { local.judge($0.change, evidence: $0.evidence, known: known) }
        }
        let gate = HybridGate.status((try? actions.store.load().pairs) ?? [])
        for (item, verdict) in zip(items, verdicts) where verdict.learns {
            apply(item, verdict, automatic: settings.learning == .hybrid && gate.isOpen)
        }
    }

    /// The local rules; tests give a fixed word list.
    var local = LocalJudge()
    /// The LLM client for the settings; tests give a stub.
    var makeClient: (CorrectionSettings) throws -> LLMClient = { try LLMClients.make($0) }

    private func apply(_ item: LLMJudge.Item, _ verdict: CorrectionVerdict, automatic: Bool) {
        let clear = verdict.rules.contains(.replace)
            && (verdict.confidence.map { $0 >= Self.minConfidence } ?? (item.evidence.seen >= 2))
        do {
            if automatic, clear {
                try actions.accept(item.change, rules: verdict.rules, source: .watched, seen: item.evidence.seen, target: .overlay)
                Log.info("learned: added \(verdict.rules.count) rule(s) to the overlay")
                onLearned?(item.change.correctedText)
            } else {
                let now = Date()
                try actions.store.update {
                    $0.record(LearnedPair(word: item.change.correctedText, heard: item.change.heardText, rules: verdict.rules.sorted(),
                                          status: .pending, sources: [.watched], seen: item.evidence.seen, firstSeen: now, lastSeen: now))
                }
                onQueued?()
            }
        } catch {
            Log.warning("learned correction not saved: \(error)")
        }
    }

    /// A correction back to what a learned rule replaced: the rule is wrong
    /// at least sometimes. Marks it suspect; returns true when it did.
    private func markReverted(_ change: WordChange, _ pairs: LearnedPairs) -> Bool {
        guard let rule = pairs.pairs.first(where: {
            $0.status == .added && $0.word.caseInsensitiveCompare(change.heardText) == .orderedSame
                && $0.heard?.caseInsensitiveCompare(change.correctedText) == .orderedSame
        }) else { return false }
        do {
            try actions.store.update {
                $0.decide(word: rule.word, heard: rule.heard, status: .suspect, rules: rule.rules, target: rule.target)
            }
            Log.info("learned: a rule was reverted; marked suspect")
            onQueued?()
        } catch {
            Log.warning("couldn't mark a reverted rule: \(error)")
        }
        return true
    }
}
