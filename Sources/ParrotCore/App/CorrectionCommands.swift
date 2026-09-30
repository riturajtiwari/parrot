import Foundation

/// Behind `parrot import wispr` and `parrot corrections …` (ADR-006).
///
/// Prints word pairs, never sentences. Writes a dictionary row only after
/// the user accepts it at the prompt.
public enum CorrectionCommands {
    /// Reads Wispr Flow's database and prints what it would learn. With
    /// `apply`, asks about each proposal and writes the accepted rows. With
    /// `llm`, the LLM judge set in Settings reviews the proposals first.
    public static func importWispr(database: String?, apply: Bool, all: Bool, llm: Bool = false) throws {
        let file = database.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? Paths.wisprDatabase
        let actions = CorrectionActions()
        let known = Set(LayeredDictionary().current().dictionary.terms.map { $0.lowercased() })
        var result: WisprImport
        do {
            let learned = try actions.store.load()
            // What Parrot's own model wrote for the user's terms, saved by
            // `parrot-bench wispr-replay --save`.
            let whisper = learned.pairs
                .filter { $0.status == .pending && $0.sources.contains(.whisper) }
                .compactMap { pair -> (change: WordChange, seen: Int)? in
                    guard let heard = pair.heard else { return nil }
                    return (WordChange(heard: WordDiff.words(heard).map(\.text), corrected: WordDiff.words(pair.word).map(\.text)), pair.seen)
                }
            let db = try WisprDatabase(file: file)
            result = WisprImport(
                dictionary: try db.dictionary(),
                dictations: try db.dictations(),
                whisper: whisper,
                judge: LocalJudge(),
                known: known,
                decided: learned
            )
        } catch let error as WisprError {
            print(error)
            throw SilentExit(1)
        }
        if llm { try judgeWithLLM(&result, known: known) }

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
        try actions.store.update { pairs in
            for candidate in proposed { pairs.record(pending(candidate)) }
        }
        try review(proposed, actions: actions)
    }

    /// Lets the LLM judge in Settings review the open candidates, in batches.
    private static func judgeWithLLM(_ result: inout WisprImport, known: Set<String>) throws {
        let settings = CorrectionSettings.saved()
        let client: LLMClient
        do {
            client = try LLMClients.make(settings)
        } catch {
            print("LLM judge: \(error). Set a provider in Settings → Corrections, or `parrot llm set-key`.")
            throw SilentExit(1)
        }
        let open = result.candidates.indices.filter { result.candidates[$0].decided == nil }
        let items = open.map { LLMJudge.Item(change: result.candidates[$0].change, evidence: result.candidates[$0].evidence) }
        print("LLM judge: \(settings.provider.displayName), \(settings.resolvedModel ?? "?"), \(items.count) pairs…")
        let judge = LLMJudge(client: client, local: LocalJudge())
        let started = Date()
        let outcome = blocking { await judge.judge(items, known: known) }
        for (index, verdict) in zip(open, outcome.verdicts) {
            result.candidates[index].verdict = verdict
        }
        print(String(format: "LLM judge: done in %.0f s%@", Date().timeIntervalSince(started),
                     outcome.failures.isEmpty ? "" : ", \(outcome.failures.count) failed request(s) kept the local verdict: \(outcome.failures.map(\.description).joined(separator: "; "))"))
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
        let actions = CorrectionActions()
        let matches = try actions.added().filter { $0.word.caseInsensitiveCompare(word) == .orderedSame }
        guard !matches.isEmpty else {
            print("No added correction for \(word).")
            throw SilentExit(1)
        }
        for pair in matches {
            try writing { try actions.undo(pair) }
            print("Removed \(pair.word)\(pair.heard.map { " ← \($0)" } ?? "").")
        }
    }

    // MARK: - Review

    private static func review(_ proposed: [WisprImport.Candidate], actions: CorrectionActions) throws {
        var promptTerms: [String] = []
        print("\nFor each proposal: a = accept, r = reject, e = choose the rules, s = skip, q = quit.")
        for (index, candidate) in proposed.enumerated() {
            let change = candidate.change
            let heard = change.heard.isEmpty ? nil : change.heardText
            print("\n[\(index + 1)/\(proposed.count)] \(line(candidate))")
            for warning in CorrectionActions.warnings(change, rules: candidate.verdict.rules) { print("  ! \(warning)") }
            var rules: Set<CorrectionRule>? = candidate.verdict.rules
            answer: while true {
                print("> ", terminator: "")
                switch readLine()?.trimmingCharacters(in: .whitespaces).lowercased() {
                case "a":
                    break answer
                case "r":
                    try actions.reject(word: change.correctedText, heard: heard)
                    rules = nil
                    break answer
                case "e":
                    print("Rules, comma-separated (replace, case, prompt), or none: ", terminator: "")
                    let chosen = Set((readLine() ?? "").split(separator: ",").compactMap { CorrectionRule(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
                    let risks = CorrectionActions.warnings(change, rules: chosen)
                    guard !risks.isEmpty else {
                        rules = chosen
                        break answer
                    }
                    for risk in risks { print("  ! \(risk)") }
                    print("Write it anyway? [y/N] ", terminator: "")
                    if readLine()?.lowercased() == "y" {
                        rules = chosen
                        break answer
                    }
                    print("Kept the proposal's rules. Choose again.")
                case "s", "":
                    rules = nil
                    break answer
                case "q", nil:
                    try finish(promptTerms)
                    return
                default:
                    print("a, r, e, s or q.")
                }
            }
            guard let rules, !rules.isEmpty else { continue }
            try writing { try actions.accept(change, rules: rules, source: candidate.sources.sorted().first ?? .wisprEdits, seen: candidate.evidence.seen) }
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

    /// Runs `body` to completion from synchronous command code.
    static func blocking<T>(_ body: @escaping @Sendable () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: T?
        Task.detached {
            result = await body()
            sem.signal()
        }
        sem.wait()
        return result!
    }

    /// Prints a refused write and exits, instead of a stack of errors.
    private static func writing(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as DictionaryWriteError {
            print("  not written: \(error)")
            throw SilentExit(1)
        }
    }

    private static func pending(_ candidate: WisprImport.Candidate) -> LearnedPair {
        let now = Date()
        return LearnedPair(
            word: candidate.change.correctedText,
            heard: candidate.change.heard.isEmpty ? nil : candidate.change.heardText,
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
