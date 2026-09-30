import Foundation

/// The example sentence for the `prompt` rule (ADR-006). Whisper reads it
/// before each dictation, so it biases the model toward the terms in it.
/// It lives in `settings.json` under `dictionary.examples`, keyed by
/// language, the same key `parrot import wispr --apply` writes.
enum ExampleSentence {
    static let language = "en"
    /// More words cost more than they help: each adds about 4 ms to every
    /// dictation on whisper-base.en.
    static let suggestedMaxWords = 12

    /// The terms of accepted `prompt` rules, newest first, without repeats.
    static func terms(_ added: [LearnedPair]) -> [String] {
        var seen = Set<String>()
        return added.filter { $0.rules.contains(.prompt) }.map(\.word).filter { seen.insert($0.lowercased()).inserted }
    }

    /// The `terms` that `sentence` does not hold yet, as whole words in any
    /// case, in their order.
    static func missing(_ terms: [String], in sentence: String) -> [String] {
        let words = WordDiff.words(sentence).map(\.key)
        return terms.filter { term in
            let target = WordDiff.words(term).map(\.key)
            guard !target.isEmpty, target.count <= words.count else { return true }
            return !(0...(words.count - target.count)).contains { Array(words[$0..<($0 + target.count)]) == target }
        }
    }

    static func wordCount(_ sentence: String) -> Int {
        sentence.split(whereSeparator: \.isWhitespace).count
    }
}
