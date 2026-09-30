import Foundation

/// What `parrot import wispr` proposes from Wispr Flow's rows (ADR-006).
/// Pure over the rows it gets, so tests need no database.
///
/// Wispr's learned words are hints for its own models, so none is copied
/// as a row. Each word goes through `LocalJudge`, with its evidence: how
/// often Wispr used it, how often the user made the edit, and how often
/// the heard form occurs in text the user kept.
struct WisprImport {
    struct Candidate: Equatable {
        var change: WordChange
        var evidence: CorrectionEvidence
        var sources: Set<LearnedPair.Source>
        var verdict: CorrectionVerdict
        /// The decision already in `corrections.json`, if any.
        var decided: LearnedPair.Status?

        var key: String { LearnedPair.key(word: change.correctedText, heard: change.heard.isEmpty ? nil : change.heardText) }
    }

    struct Summary: Equatable {
        var dictionaryRows = 0
        var snippets = 0
        var dictations = 0
        var edited = 0
        var rewrites = 0
    }

    var candidates: [Candidate] = []
    var summary = Summary()

    init(
        dictionary: [WisprDatabase.DictionaryRow],
        dictations: [WisprDatabase.Dictation],
        judge: LocalJudge,
        known: Set<String> = [],
        decided: LearnedPairs = LearnedPairs()
    ) {
        var found: [String: Candidate] = [:]
        var order: [String] = []
        func add(_ change: WordChange, seen: Int, manual: Bool, source: LearnedPair.Source) {
            guard !change.corrected.isEmpty else { return }
            var candidate = Candidate(
                change: change, evidence: CorrectionEvidence(seen: seen, manual: manual),
                sources: [source], verdict: CorrectionVerdict(word: "", heard: "", kind: .noise, rules: [], similarity: 0, reasons: [])
            )
            if var existing = found[candidate.key] {
                existing.evidence.seen += seen
                existing.evidence.manual = existing.evidence.manual || manual
                existing.sources.insert(source)
                // A change seen once inside a sentence says more than one at its start.
                existing.change.atSentenceStart = existing.change.atSentenceStart && change.atSentenceStart
                candidate = existing
            } else {
                order.append(candidate.key)
            }
            found[candidate.key] = candidate
        }
        let words = { (text: String) in WordDiff.words(text).map(\.text) }

        for row in dictionary {
            summary.dictionaryRows += 1
            if row.snippet {
                summary.snippets += 1
                continue
            }
            if let replacement = row.replacement {
                add(WordChange(heard: words(row.phrase), corrected: words(replacement)), seen: max(row.uses, 1), manual: true, source: .wisprDictionary)
            } else if let observed = row.observed {
                add(WordChange(heard: words(observed), corrected: words(row.phrase)), seen: max(row.uses, 1), manual: row.manual, source: .wisprDictionary)
            } else {
                add(WordChange(heard: [], corrected: words(row.phrase)), seen: max(row.uses, 1), manual: true, source: .wisprDictionary)
            }
        }

        // Kept text: what each field held in the end. Only its word keys
        // stay, in memory, to count heard forms below.
        var kept: [[String]] = []
        for dictation in dictations {
            summary.dictations += 1
            kept.append(WordDiff.words(dictation.edited ?? dictation.pasted).map(\.key))
            guard let edited = dictation.edited, edited != dictation.pasted else { continue }
            summary.edited += 1
            let changes = WordDiff.changes(from: dictation.pasted, to: edited)
            if changes.isEmpty, WordDiff.keptShare(from: dictation.pasted, to: edited) < WordDiff.minKept {
                summary.rewrites += 1
            }
            for change in changes {
                add(change, seen: 1, manual: false, source: .wisprEdits)
            }
        }

        let heardForms = Set(found.values.compactMap { $0.change.heard.isEmpty ? nil : $0.change.heard.map { $0.lowercased() } })
        let counts = Self.occurrences(of: heardForms, in: kept)
        for key in order {
            guard var candidate = found[key] else { continue }
            if !candidate.change.heard.isEmpty {
                candidate.evidence.keptHeard = counts[candidate.change.heard.map { $0.lowercased() }] ?? 0
            }
            candidate.verdict = judge.judge(candidate.change, evidence: candidate.evidence, known: known)
            if let pair = decided.pair(word: candidate.change.correctedText, heard: candidate.change.heard.isEmpty ? nil : candidate.change.heardText),
               pair.status != .pending {
                candidate.decided = pair.status
            }
            candidates.append(candidate)
        }
        candidates.sort { a, b in
            if a.verdict.learns != b.verdict.learns { return a.verdict.learns }
            if a.evidence.seen != b.evidence.seen { return a.evidence.seen > b.evidence.seen }
            return a.change.correctedText.localizedCaseInsensitiveCompare(b.change.correctedText) == .orderedAscending
        }
    }

    /// How often each form, as lowercase words, occurs as whole words in
    /// `texts`.
    static func occurrences(of forms: Set<[String]>, in texts: [[String]]) -> [[String]: Int] {
        guard !forms.isEmpty else { return [:] }
        let lengths = Set(forms.map(\.count))
        var counts: [[String]: Int] = [:]
        for words in texts {
            for n in lengths where n <= words.count {
                for start in 0...(words.count - n) {
                    let window = Array(words[start..<(start + n)])
                    if forms.contains(window) { counts[window, default: 0] += 1 }
                }
            }
        }
        return counts
    }
}
