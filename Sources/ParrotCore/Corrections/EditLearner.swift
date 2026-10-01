import Foundation

/// What happens to the corrections the edit watcher sees (ADR-006).
///
/// - The judge from Settings, or the local rules, decides the rules.
/// - In hybrid mode, with the gate open, a clear `replace` fix goes to the
///   overlay at once, with Undo. Everything else waits for the user's Add
///   or Not this.
/// - A correction that reverts what a learned rule wrote marks that rule
///   suspect, and is never learned the other way round.
/// - Each batch reports what it did, so the learning notice can say so.
@MainActor
final class EditLearner {
    /// What the learner did with one change, for the learning notice.
    enum Outcome: Equatable {
        /// Added at once to the overlay: hybrid, with its gate open.
        case added(LearnedPair)
        /// Recorded as pending: it waits for Add or Not this.
        case proposed(LearnedPair)
        /// Seen, but there is nothing safe to learn. `reason` names the kind
        /// of change, never the words.
        case notLearned(reason: String)
        /// The user changed back what a learned rule wrote; it is suspect now.
        case reverted(LearnedPair)
    }

    private let actions: CorrectionActions
    private let settings: () -> CorrectionSettings
    /// Called after each batch with what it did, in order.
    var onOutcomes: (([Outcome]) -> Void)?

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

        var outcomes: [Outcome] = []
        defer { if !outcomes.isEmpty { onOutcomes?(outcomes) } }
        var items: [LLMJudge.Item] = []
        for change in changes {
            if let reverted = markReverted(change, pairs) {
                outcomes.append(.reverted(reverted))
                continue
            }
            let existing = pairs.pair(word: change.correctedText, heard: change.heardText)
            // The user decided this pair before: stay quiet.
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
        for (item, verdict) in zip(items, verdicts) {
            if verdict.learns {
                if let outcome = apply(item, verdict, automatic: settings.learning == .hybrid && gate.isOpen) {
                    outcomes.append(outcome)
                }
            } else {
                let reason = Self.reason(verdict)
                Log.info("learned: nothing to learn (\(reason))")
                outcomes.append(.notLearned(reason: reason))
            }
        }
    }

    /// Why a seen change teaches nothing, in a few words, without the words
    /// themselves.
    nonisolated static func reason(_ verdict: CorrectionVerdict) -> String {
        if verdict.kind == .known { return "already in your dictionary" }
        // The rules' own reasons say more than the kind they fall back to.
        if verdict.reasons.contains("lowercase word") { return "a lowercase word" }
        if verdict.reasons.contains("common word") { return "an everyday word" }
        switch verdict.kind {
        case .rewording: return "a rewording"
        case .content: return "a change of content"
        case .fragment, .noise: return "not a word or a name"
        default: return "nothing safe to learn"
        }
    }

    /// The local rules; tests give a fixed word list.
    var local = LocalJudge()
    /// The LLM client for the settings; tests give a stub.
    var makeClient: (CorrectionSettings) throws -> LLMClient = { try LLMClients.make($0) }

    private func apply(_ item: LLMJudge.Item, _ verdict: CorrectionVerdict, automatic: Bool) -> Outcome? {
        let clear = verdict.rules.contains(.replace)
            && (verdict.confidence.map { $0 >= Self.minConfidence } ?? (item.evidence.seen >= 2))
        let word = item.change.correctedText
        let heard = item.change.heardText
        do {
            if automatic, clear {
                try actions.accept(item.change, rules: verdict.rules, source: .watched, seen: item.evidence.seen, target: .overlay)
                Log.info("learned: added \(verdict.rules.count) rule(s) to the overlay")
                return try actions.store.load().pair(word: word, heard: heard).map(Outcome.added)
            }
            let now = Date()
            try actions.store.update {
                $0.record(LearnedPair(word: word, heard: heard, rules: verdict.rules.sorted(),
                                      status: .pending, sources: [.watched], seen: item.evidence.seen, firstSeen: now, lastSeen: now))
            }
            return try actions.store.load().pair(word: word, heard: heard).map(Outcome.proposed)
        } catch {
            Log.warning("learned correction not saved: \(error)")
            return nil
        }
    }

    /// A correction back to what a learned rule replaced: the rule is wrong
    /// at least sometimes. Marks it suspect and returns it, or nil when the
    /// change reverts nothing.
    private func markReverted(_ change: WordChange, _ pairs: LearnedPairs) -> LearnedPair? {
        guard let rule = pairs.pairs.first(where: {
            $0.status == .added && $0.word.caseInsensitiveCompare(change.heardText) == .orderedSame
                && $0.heard?.caseInsensitiveCompare(change.correctedText) == .orderedSame
        }) else { return nil }
        do {
            try actions.store.update {
                $0.decide(word: rule.word, heard: rule.heard, status: .suspect, rules: rule.rules, target: rule.target)
            }
            Log.info("learned: a rule was reverted; marked suspect")
        } catch {
            Log.warning("couldn't mark a reverted rule: \(error)")
        }
        return rule
    }
}
