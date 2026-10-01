import Foundation

/// One Wispr Flow import (ADR-006), shared by `parrot import wispr` and the
/// Import button in Settings → Corrections. It reads Wispr's database
/// read-only, judges every pair with the local rules and, when one is set,
/// the LLM judge, and records the open proposals as pending pairs for
/// Review Corrections. A second run adds only new pairs: a pair that the
/// user accepted or rejected keeps its decision.
struct WisprImportRun {
    var database: URL = Paths.wisprDatabase
    var actions = CorrectionActions()
    var judge = LocalJudge()

    /// What one run did, as counts.
    struct Report: Equatable, Sendable {
        /// Proposals now waiting in Review Corrections.
        var proposed = 0
        /// Pairs that teach nothing: rewording, common words, fragments.
        var declined = 0
        /// Pairs the user decided before.
        var decided = 0
        /// The provider that checked the proposals, if one did.
        var judge: LLMProvider?
        /// Failed judge requests. Their pairs kept the local verdict.
        var failures: [LLMError] = []
    }

    /// Whether Wispr Flow's database is on this Mac.
    static func isAvailable(at database: URL = Paths.wisprDatabase) -> Bool {
        FileManager.default.fileExists(atPath: database.path)
    }

    /// The words of the user's dictionary and of the overlay, lowercased.
    static func knownWords() -> Set<String> {
        Set(LayeredDictionary().current().dictionary.terms.map { $0.lowercased() })
    }

    /// Reads Wispr's rows and judges each pair with the local rules. Writes
    /// nothing.
    func analyze(known: Set<String>) throws -> WisprImport {
        let learned = try actions.store.load()
        // What Parrot's own model wrote for the user's terms, saved by
        // `parrot-bench wispr-replay --save`.
        let whisper = learned.pairs
            .filter { $0.status == .pending && $0.sources.contains(.whisper) }
            .compactMap { pair -> (change: WordChange, seen: Int)? in
                guard let heard = pair.heard else { return nil }
                return (WordChange(heard: WordDiff.words(heard).map(\.text), corrected: WordDiff.words(pair.word).map(\.text)), pair.seen)
            }
        let db = try WisprDatabase(file: database)
        return WisprImport(
            dictionary: try db.dictionary(),
            dictations: try db.dictations(),
            whisper: whisper,
            judge: judge,
            known: known,
            decided: learned
        )
    }

    /// Lets `client` check the open candidates, in batches. A failed request
    /// leaves its pairs with the local verdict.
    func review(_ result: inout WisprImport, client: LLMClient, known: Set<String>) async -> [LLMError] {
        let open = result.candidates.indices.filter { result.candidates[$0].decided == nil }
        let items = open.map { LLMJudge.Item(change: result.candidates[$0].change, evidence: result.candidates[$0].evidence) }
        let outcome = await LLMJudge(client: client, local: judge).judge(items, known: known)
        for (index, verdict) in zip(open, outcome.verdicts) {
            result.candidates[index].verdict = verdict
        }
        return outcome.failures
    }

    /// Records each open proposal as a pending pair, with its evidence
    /// counts. A pair that already waits, such as one from the Whisper
    /// replay, gets this run's verdict and evidence even when it now teaches
    /// nothing; with no rules, it stays out of Review. Returns how many
    /// proposals it recorded.
    @discardableResult
    func record(_ result: WisprImport) throws -> Int {
        let storable = { (pair: LearnedPair) in
            LearnedPair.isStorable(pair.word) && (pair.heard.map(LearnedPair.isStorable) ?? true)
        }
        let proposals = result.proposed.map { $0.pendingPair() }.filter(storable)
        let updates = result.declined.map { $0.pendingPair() }.filter(storable)
        try actions.store.update { stored in
            for pair in proposals { stored.record(pair) }
            for pair in updates where stored.pair(word: pair.word, heard: pair.heard)?.status == .pending {
                stored.record(pair)
            }
        }
        return proposals.count
    }

    /// The whole import, for the Settings button: read, let the provider in
    /// `settings` check the pairs when there is one, and record.
    func run(
        settings: CorrectionSettings,
        known: Set<String>? = nil,
        makeClient: (CorrectionSettings) throws -> LLMClient = { try LLMClients.make($0) },
        progress: (String) -> Void = { _ in }
    ) async throws -> Report {
        progress("Reading Wispr Flow…")
        let known = known ?? Self.knownWords()
        var result = try analyze(known: known)
        var report = Report()
        if settings.provider != .none {
            do {
                let client = try makeClient(settings)
                progress("Asking \(settings.provider.displayName) about \(result.open.count) pairs…")
                report.failures = await review(&result, client: client, known: known)
                report.judge = settings.provider
            } catch {
                report.failures = [error as? LLMError ?? .notConfigured("\(error)")]
            }
        }
        report.proposed = try record(result)
        report.declined = result.declined.count
        report.decided = result.candidates.count - result.open.count
        return report
    }
}

extension WisprImport {
    /// The candidates the user has not decided yet.
    var open: [Candidate] { candidates.filter { $0.decided == nil } }
    /// Open candidates that teach something.
    var proposed: [Candidate] { open.filter(\.verdict.learns) }
    /// Open candidates that teach nothing.
    var declined: [Candidate] { open.filter { !$0.verdict.learns } }
}

extension WisprImport.Candidate {
    /// The pending pair for Review Corrections: the pair, its proposed rules
    /// and its evidence counts. No text beyond the pair.
    func pendingPair(at date: Date = Date()) -> LearnedPair {
        LearnedPair(
            word: change.correctedText,
            heard: change.heard.isEmpty ? nil : change.heardText,
            rules: verdict.rules.sorted(),
            status: .pending,
            sources: sources.sorted(),
            seen: evidence.seen,
            firstSeen: date,
            lastSeen: date,
            keptHeard: change.heard.isEmpty ? nil : evidence.keptHeard,
            manual: evidence.manual ? true : nil
        )
    }
}
