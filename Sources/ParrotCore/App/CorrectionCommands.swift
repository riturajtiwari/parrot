import Foundation

/// Behind `parrot import wispr` and `parrot corrections …` (ADR-006).
///
/// Prints word pairs, never sentences. Writes a dictionary row only after
/// the user accepts it at the prompt.
public enum CorrectionCommands {
    /// Reads Wispr Flow's database and prints what it would learn. With
    /// `apply`, asks about each proposal and writes the accepted rows.
    public static func importWispr(database: String?, apply: Bool, all: Bool) throws {
        let file = database.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? Paths.wisprDatabase
        let store = LearnedStore()
        let known = Set(LayeredDictionary().current().dictionary.terms.map { $0.lowercased() })
        let result: WisprImport
        do {
            let db = try WisprDatabase(file: file)
            result = WisprImport(
                dictionary: try db.dictionary(),
                dictations: try db.dictations(),
                judge: LocalJudge(),
                known: known,
                decided: try store.load()
            )
        } catch let error as WisprError {
            print(error)
            throw SilentExit(1)
        }

        let s = result.summary
        print("Wispr Flow: \(s.dictionaryRows) dictionary rows (\(s.snippets) snippets skipped), \(s.dictations) dictations, \(s.edited) edited, \(s.rewrites) rewrites.")
        let open = result.candidates.filter { $0.decided == nil }
        let proposed = open.filter(\.verdict.learns)
        let declined = open.filter { !$0.verdict.learns }
        let decided = result.candidates.count - open.count
        print("\nProposed (\(proposed.count))\(decided > 0 ? ", \(decided) already decided" : ""):")
        printTable(proposed)
        var kinds: [String: Int] = [:]
        for candidate in declined { kinds[candidate.verdict.kind.rawValue, default: 0] += 1 }
        let summary = kinds.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        print("\nNot learned (\(declined.count)): \(summary.isEmpty ? "none" : summary).\(all ? "" : " Add --all to list them.")")
        if all { printTable(declined) }

        guard apply else {
            print("\nNothing was written. Run again with --apply to review each proposal.")
            return
        }
        guard isatty(STDIN_FILENO) != 0 else {
            print("--apply asks about each proposal, so it needs a terminal.")
            throw SilentExit(1)
        }
        try store.update { pairs in
            for candidate in proposed { pairs.record(pending(candidate)) }
        }
        try review(proposed, store: store)
    }

    /// Lists every learned pair with its status.
    public static func list() throws {
        let pairs = try LearnedStore().load().pairs
        guard !pairs.isEmpty else {
            print("No learned corrections yet.")
            return
        }
        for status in [LearnedPair.Status.added, .pending, .suspect, .rejected] {
            let group = pairs.filter { $0.status == status }
            guard !group.isEmpty else { continue }
            print("\n\(status.rawValue.capitalized) (\(group.count)):")
            for pair in group.sorted(by: { $0.seen > $1.seen }) {
                let rules = pair.rules.map(\.rawValue).joined(separator: ", ")
                print("  " + pad(pair.word, 24) + pad(pair.heard ?? "–", 24) + pad(String(pair.seen), 6) + rules)
            }
        }
    }

    /// Removes the rows written for `word`, and marks its pairs rejected so
    /// that Parrot doesn't propose them again.
    public static func undo(word: String) throws {
        let store = LearnedStore()
        let matches = try store.load().pairs.filter { $0.word.caseInsensitiveCompare(word) == .orderedSame && $0.status == .added }
        guard !matches.isEmpty else {
            print("No added correction for \(word).")
            throw SilentExit(1)
        }
        for pair in matches {
            try write(undoEdits(for: pair), to: pair.target ?? .dictionary)
            try store.update { $0.decide(word: pair.word, heard: pair.heard, status: .rejected, rules: [], target: nil) }
            print("Removed \(pair.word)\(pair.heard.map { " ← \($0)" } ?? "").")
        }
    }

    // MARK: - Review

    private static func review(_ proposed: [WisprImport.Candidate], store: LearnedStore) throws {
        var promptTerms: [String] = []
        print("\nFor each proposal: a = accept, r = reject, e = choose the rules, s = skip, q = quit.")
        for (index, candidate) in proposed.enumerated() {
            let change = candidate.change
            print("\n[\(index + 1)/\(proposed.count)] \(line(candidate))")
            for warning in warnings(change, rules: candidate.verdict.rules) { print("  ! \(warning)") }
            var rules = candidate.verdict.rules
            answer: while true {
                print("> ", terminator: "")
                switch readLine()?.trimmingCharacters(in: .whitespaces).lowercased() {
                case "a":
                    break answer
                case "r":
                    try store.update { $0.decide(word: change.correctedText, heard: heard(change), status: .rejected, rules: [], target: nil) }
                    rules = []
                    break answer
                case "e":
                    print("Rules, comma-separated (replace, case, prompt), or none: ", terminator: "")
                    let chosen = (readLine() ?? "").split(separator: ",").compactMap { CorrectionRule(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
                    rules = Set(chosen)
                    let risks = warnings(change, rules: rules)
                    guard !risks.isEmpty else { break answer }
                    for risk in risks { print("  ! \(risk)") }
                    print("Write it anyway? [y/N] ", terminator: "")
                    if readLine()?.lowercased() == "y" { break answer }
                    rules = candidate.verdict.rules
                    print("Kept the proposal's rules. Choose again.")
                case "s", "":
                    rules = []
                    break answer
                case "q", nil:
                    try finish(promptTerms)
                    return
                default:
                    print("a, r, e, s or q.")
                }
            }
            guard !rules.isEmpty else { continue }
            let hadRow = DictionaryStore(file: Paths.dictionaryFile).current().dictionary.terms.contains(change.correctedText)
            try write(edits(change, rules: rules), to: .dictionary)
            try store.update {
                $0.decide(word: change.correctedText, heard: heard(change), status: .added, rules: Array(rules),
                          target: .dictionary, createdRow: !hadRow && !edits(change, rules: rules).isEmpty)
            }
            if rules.contains(.prompt) { promptTerms.append(change.correctedText) }
            print("  added")
        }
        try finish(promptTerms)
    }

    /// Asks for an example sentence when there are terms for one.
    private static func finish(_ terms: [String]) throws {
        guard !terms.isEmpty else { return }
        print("""

            These words need the example sentence, because the model hears them as common words:
              \(terms.joined(separator: ", "))
            Write one sentence of 12 words or fewer that uses some of them, the way you speak.
            Whisper reads it before each dictation. Press Return to skip.
            """)
        print("> ", terminator: "")
        guard let sentence = readLine()?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty else { return }
        let count = sentence.split(whereSeparator: \.isWhitespace).count
        if count > 12 { print("  That has \(count) words. Each word adds about 4 ms to every dictation on whisper-base.en.") }
        MainActor.assumeIsolated {
            let settings = SettingsStore()
            settings.update { $0.dictionary.examples["en"] = sentence }
        }
        print("  saved as the English example sentence in settings.json")
    }

    // MARK: - Rows

    private static func heard(_ change: WordChange) -> String? {
        change.heard.isEmpty ? nil : change.heardText
    }

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

    private static func write(_ edits: [DictionaryEdit], to target: LearnedPair.Target) throws {
        guard !edits.isEmpty else { return }
        let file = target == .dictionary ? Paths.dictionaryFile : Paths.learnedDictionaryFile
        do {
            try DictionaryWriter(file: file).apply(edits)
        } catch let error as DictionaryWriteError {
            print("  not written: \(error)")
            throw SilentExit(1)
        }
    }

    /// What a row would change beyond the word itself.
    private static func warnings(_ change: WordChange, rules: Set<CorrectionRule>) -> [String] {
        let common = EmbeddingCommonWords.shared
        var result: [String] = []
        if rules.contains(.replace), change.heard.count == 1, common.isCommon(change.heardText) {
            result.append("every \"\(change.heardText)\" in every dictation would become \"\(change.correctedText)\"")
        }
        if !edits(change, rules: rules).isEmpty, common.isCommon(change.correctedText) {
            result.append("every \"\(change.correctedText.lowercased())\" in any case would become \"\(change.correctedText)\"")
        }
        return result
    }

    private static func pending(_ candidate: WisprImport.Candidate) -> LearnedPair {
        let now = Date()
        return LearnedPair(
            word: candidate.change.correctedText,
            heard: heard(candidate.change),
            rules: candidate.verdict.rules.sorted(),
            status: .pending,
            sources: candidate.sources.sorted(),
            seen: candidate.evidence.seen,
            firstSeen: now,
            lastSeen: now
        )
    }

    // MARK: - Printing

    private static func printTable(_ candidates: [WisprImport.Candidate]) {
        guard !candidates.isEmpty else { return }
        print("  " + pad("WORD", 24) + pad("HEARD", 24) + pad("SEEN", 6) + pad("KEPT", 6) + pad("SOUND", 7) + pad("RULES", 22) + "WHY")
        for candidate in candidates {
            print("  " + row(candidate))
        }
    }

    private static func row(_ c: WisprImport.Candidate) -> String {
        let rules = c.verdict.rules.sorted().map(\.rawValue).joined(separator: ", ")
        let sound = c.change.heard.isEmpty || c.change.isCaseOnly ? "–" : String(format: "%.2f", c.verdict.similarity)
        return pad(c.change.correctedText, 24) + pad(c.change.heard.isEmpty ? "–" : c.change.heardText, 24)
            + pad(String(c.evidence.seen), 6) + pad(c.change.heard.isEmpty ? "–" : String(c.evidence.keptHeard), 6)
            + pad(sound, 7) + pad(rules.isEmpty ? "none" : rules, 22) + c.verdict.reasons.joined(separator: "; ")
    }

    private static func line(_ c: WisprImport.Candidate) -> String {
        let heard = c.change.heard.isEmpty ? "" : " ← \(c.change.heardText)"
        let rules = c.verdict.rules.sorted().map(\.rawValue).joined(separator: ", ")
        let why = c.verdict.reasons.isEmpty ? "" : " · \(c.verdict.reasons.joined(separator: "; "))"
        return "\(c.change.correctedText)\(heard) · seen \(c.evidence.seen) · rules: \(rules)\(why)"
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width - 1 ? String(text.prefix(width - 2)) + "… " : text.padding(toLength: width, withPad: " ", startingAt: 0)
    }
}
