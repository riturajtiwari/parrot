import Foundation

/// What can happen to a learned pair, shared by the CLI, Fix Word and the
/// review window (ADR-006). Each action writes the dictionary first and then
/// records the decision, so a failed write leaves the pair as it was.
struct CorrectionActions {
    var dictionary: URL = Paths.dictionaryFile
    var overlay: URL = Paths.learnedDictionaryFile
    var lock: URL = Paths.dictionaryLock
    var store = LearnedStore()

    /// A pending pair, judged again for display.
    struct Review: Identifiable {
        var pair: LearnedPair
        var change: WordChange
        var verdict: CorrectionVerdict

        var id: String { pair.key }
    }

    /// Writes the rows for `rules` and records the pair as added. With no
    /// rules that write a row (`prompt` alone), only records the decision.
    func accept(
        _ change: WordChange, rules: Set<CorrectionRule>, source: LearnedPair.Source,
        seen: Int = 1, target: LearnedPair.Target = .dictionary
    ) throws {
        let file = target == .dictionary ? dictionary : overlay
        let edits = Self.edits(change, rules: rules)
        let hadRow = Self.words(in: file).contains(change.correctedText)
        if !edits.isEmpty {
            try DictionaryWriter(file: file, lock: lock).apply(edits)
        }
        let heard = change.heard.isEmpty ? nil : change.heardText
        try store.update { pairs in
            if pairs.pair(word: change.correctedText, heard: heard) == nil {
                let now = Date()
                pairs.record(LearnedPair(word: change.correctedText, heard: heard, rules: rules.sorted(), status: .pending,
                                         sources: [source], seen: seen, firstSeen: now, lastSeen: now))
            }
            pairs.decide(word: change.correctedText, heard: heard, status: .added, rules: rules.sorted(),
                         target: target, createdRow: !hadRow && !edits.isEmpty)
        }
    }

    /// Keeps a suspect pair: its rows stay, and it is added again.
    func keep(_ pair: LearnedPair) throws {
        try store.update { $0.decide(word: pair.word, heard: pair.heard, status: .added, rules: pair.rules, target: pair.target) }
    }

    /// Records that the user said no. Parrot never proposes the pair again.
    func reject(word: String, heard: String?) throws {
        try store.update { $0.decide(word: word, heard: heard, status: .rejected, rules: [], target: nil) }
    }

    /// Removes what an added pair wrote and marks it rejected.
    func undo(_ pair: LearnedPair) throws {
        let edits = Self.undoEdits(for: pair)
        if !edits.isEmpty {
            try DictionaryWriter(file: pair.target == .overlay ? overlay : dictionary, lock: lock).apply(edits)
        }
        try reject(word: pair.word, heard: pair.heard)
    }

    /// The pending pairs, most seen first, each judged again, and the added
    /// pairs the user reverted since (suspect), first.
    ///
    /// A pending pair shows the rules recorded with it, when it has any:
    /// they came from evidence that is not all stored, such as context, and
    /// from the LLM judge. The local rules still apply, so a rule that they
    /// block now drops out; only `prompt` may come from the judge alone.
    func pending(judge: LocalJudge = LocalJudge()) throws -> [Review] {
        let known = Set(Self.words(in: dictionary).map { $0.lowercased() })
        return try store.load().pairs
            .filter { $0.status == .pending || $0.status == .suspect }
            .sorted { ($0.status == .suspect ? 1 : 0, $0.seen) > ($1.status == .suspect ? 1 : 0, $1.seen) }
            .map { pair in
                let change = WordChange(heard: pair.heard.map { WordDiff.words($0).map(\.text) } ?? [],
                                        corrected: WordDiff.words(pair.word).map(\.text))
                var verdict = judge.judge(change, evidence: pair.evidence, known: known)
                if pair.status == .suspect {
                    verdict.rules = Set(pair.rules)
                    verdict.reasons.insert("you reverted what this rule wrote; Reject removes it", at: 0)
                } else if !pair.rules.isEmpty {
                    verdict.rules = Set(pair.rules).intersection(LLMJudge.allowed(verdict))
                }
                return Review(pair: pair, change: change, verdict: verdict)
            }
    }

    /// How many pairs wait for review, without judging them.
    func pendingCount() throws -> Int {
        try store.load().pairs.filter { $0.status == .pending || $0.status == .suspect }.count
    }

    /// Added pairs, newest first.
    func added() throws -> [LearnedPair] {
        try store.load().pairs.filter { $0.status == .added }.sorted { ($0.decided ?? .distantPast) > ($1.decided ?? .distantPast) }
    }

    // MARK: - Rows

    /// The dictionary edits for `rules`. Every row is also a case rule, so a
    /// `replace` row covers `case`.
    static func edits(_ change: WordChange, rules: Set<CorrectionRule>) -> [DictionaryEdit] {
        if rules.contains(.replace), !change.heard.isEmpty {
            return [.add(word: change.correctedText, replaces: [change.heardText])]
        }
        if rules.contains(.casing) {
            return [.add(word: change.correctedText, replaces: [])]
        }
        return []
    }

    /// Removes what the pair wrote: the whole row when Parrot created it,
    /// else only the heard form it added to the user's row.
    static func undoEdits(for pair: LearnedPair) -> [DictionaryEdit] {
        if pair.createdRow == true { return [.remove(word: pair.word, replaces: [])] }
        if pair.rules.contains(.replace), let heard = pair.heard { return [.remove(word: pair.word, replaces: [heard])] }
        return []
    }

    /// What the rows would change beyond the word itself.
    static func warnings(_ change: WordChange, rules: Set<CorrectionRule>, common: CommonWords = EmbeddingCommonWords.shared) -> [String] {
        var result: [String] = []
        if rules.contains(.replace), change.heard.count == 1, common.isCommon(change.heardText) {
            result.append("every \"\(change.heardText)\" in every dictation becomes \"\(change.correctedText)\"")
        }
        let writesRow = !edits(change, rules: rules).isEmpty
        if writesRow, common.isCommon(change.correctedText) {
            result.append("every \"\(change.correctedText.lowercased())\" in any case becomes \"\(change.correctedText)\"")
        } else if writesRow, !LocalJudge.hasShape(change.correctedText) {
            result.append("every capitalized \"\(change.correctedText.capitalized)\" becomes \"\(change.correctedText)\", even at a sentence start")
        }
        return result
    }

    /// The words of the dictionary file, or none when it is missing or
    /// doesn't parse.
    static func words(in file: URL) -> [String] {
        guard let data = try? Data(contentsOf: file), let dictionary = try? UserDictionary.parse(data) else { return [] }
        return dictionary.terms
    }
}
