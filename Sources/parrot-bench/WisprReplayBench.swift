import Foundation
import ParrotCore

/// Flags for `parrot-bench wispr-replay`.
struct WisprReplayOptions {
    var database: String?
    var model: String?
    var limit: Int?
    var save: Bool
}

/// `parrot-bench wispr-replay`: Wispr Flow's recorded dictations through
/// Parrot's model, with and without the dictionary (ADR-006). Prints counts,
/// rates and word pairs, never a sentence.
enum WisprReplayBench {
    static func run(_ options: WisprReplayOptions) throws {
        guard let model = options.model.map(ModelRegistry.find) ?? ModelRegistry.recommended() else {
            print("unknown model: \(options.model ?? "")")
            throw SilentExit(1)
        }
        guard WhisperKitTranscriber.isCached(model) else {
            print("\(model.id) is not downloaded; run: parrot models download \(model.id)")
            throw SilentExit(1)
        }
        let database = options.database.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let dictionary = LayeredDictionary()
        let terms = try database.map { try WisprReplay.defaultTerms(database: $0, dictionary: dictionary) }
            ?? WisprReplay.defaultTerms(dictionary: dictionary)

        let language = DictionaryContext.language(of: model, setting: nil)
        let withPrompt = DictionaryContext(store: dictionary, language: language, examples: DictionaryContext.savedExamples()).context()
        var withoutPrompt = withPrompt
        withoutPrompt.prompt = nil
        withoutPrompt.examples = [:]
        let usesPrompt = withPrompt.prompt != nil || !withPrompt.examples.isEmpty
        let contexts = (with: withPrompt, without: withoutPrompt)

        let transcriber = WhisperKitTranscriber(model: model, tuning: .standard)
        try blocking { try await transcriber.warmUp() }
        print("model \(model.id) · \(terms.count) terms · example sentence \(usesPrompt ? "on" : "none")")

        let started = Date()
        let report = try WisprReplay.run(
            database: database ?? Paths.wisprDatabase,
            limit: options.limit,
            terms: terms,
            usesPrompt: usesPrompt,
            transcribe: { samples, prompt in
                try blocking { try await transcriber.transcribe(samples, context: prompt ? contexts.with : contexts.without).text }
            },
            replace: { dictionary.apply(to: $0) },
            progress: { done in if done % 25 == 0 { print("  \(done) clips…") } }
        )

        print(String(format: "\n%d clips in %.0f s (%d skipped: not 16 kHz mono PCM)", report.clips, Date().timeIntervalSince(started), report.skipped))
        guard report.referenceWords > 0 else { return }
        func percent(_ part: Int, _ whole: Int) -> String { whole == 0 ? "–" : String(format: "%.1f%%", 100 * Double(part) / Double(whole)) }
        print("                        without dictionary   with dictionary")
        print("WER (vs kept text)      \(percent(report.errorsWithout, report.referenceWords).padding(toLength: 21, withPad: " ", startingAt: 0))\(percent(report.errorsWith, report.referenceWords))")
        print("term recall, exact      \(percent(report.termHitsWithout, report.termOccurrences).padding(toLength: 21, withPad: " ", startingAt: 0))\(percent(report.termHitsWith, report.termOccurrences))   (\(report.termOccurrences) terms in kept text)")
        print("false terms             \(String(report.falseTermsWithout).padding(toLength: 21, withPad: " ", startingAt: 0))\(report.falseTermsWith)")
        print("\nWhat the model wrote where you kept a term (\(report.mishearings.count) pairs):")
        for m in report.mishearings.prefix(40) {
            print("  \(String(m.count).padding(toLength: 5, withPad: " ", startingAt: 0))\(m.word.padding(toLength: 24, withPad: " ", startingAt: 0)) ← \(m.heard)")
        }
        if options.save {
            let saved = try WisprReplay.save(report)
            print("\nSaved \(saved) pairs to corrections.json. `parrot import wispr` now judges them too.")
        } else if !report.mishearings.isEmpty {
            print("\nAdd --save to give these pairs to `parrot import wispr`.")
        }
    }

    /// Runs `body` to completion from synchronous command code.
    private static func blocking<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>?
        Task.detached {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result!.get()
    }
}
