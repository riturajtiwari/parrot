import Foundation

/// What Parrot may do with a learned pair (ADR-006).
enum CorrectionRule: String, Codable, CaseIterable, Sendable, Comparable {
    /// A dictionary row `Word  heard`: the heard form becomes the word in
    /// every dictation.
    case replace
    /// A dictionary row with the word only: any casing becomes the word's.
    case casing = "case"
    /// The word goes into the example sentence, which biases Whisper.
    case prompt

    static func < (a: CorrectionRule, b: CorrectionRule) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// What a pair is, as far as the rules can tell.
enum CorrectionKind: String, Codable, Sendable {
    case acronym, join, casing, properNoun = "proper-noun", term
    case rewording, content, fragment, noise, known
}

/// What Parrot knows about how often a pair happened.
struct CorrectionEvidence: Equatable, Sendable {
    /// Times the pair was seen: edits, Wispr's own count, Whisper replays.
    var seen: Int = 1
    /// Times the heard form occurs in text the user kept. A heard form the
    /// user keeps elsewhere is a real word to them, so it is never replaced.
    var keptHeard: Int = 0
    /// The user added the word by hand, for example in Wispr Flow.
    var manual: Bool = false
}

/// The rules for one pair, and why. `reasons` name features, never text.
struct CorrectionVerdict: Equatable, Sendable {
    var word: String
    var heard: String
    var kind: CorrectionKind
    var rules: Set<CorrectionRule>
    var similarity: Double
    var reasons: [String]

    var learns: Bool { !rules.isEmpty }
}

/// The local rules (ADR-006): what a pair may become, with the vetoes that
/// no judge can override. Pure.
struct LocalJudge: Sendable {
    /// `replace` needs at least this much sound similarity.
    static let minSimilarity = 0.6
    /// A single heard word shorter than this is never replaced: short words
    /// and acronyms ("ID", "PR") collide with everyday text.
    static let minReplacedLength = 4
    /// A word corrected this often may enter the example sentence even when
    /// it has no row.
    static let promptEvidence = 5

    let common: CommonWords

    init(common: CommonWords = EmbeddingCommonWords.shared) {
        self.common = common
    }

    /// The verdict for `change`. `known` holds the dictionary's words, in
    /// any case; a word already there needs nothing new.
    func judge(_ change: WordChange, evidence: CorrectionEvidence = CorrectionEvidence(), known: Set<String> = []) -> CorrectionVerdict {
        let word = change.correctedText
        let heard = change.heardText
        var verdict = CorrectionVerdict(word: word, heard: heard, kind: .term, rules: [], similarity: 0, reasons: [])
        func none(_ kind: CorrectionKind, _ reason: String) -> CorrectionVerdict {
            verdict.kind = kind
            verdict.reasons.append(reason)
            return verdict
        }

        // What is never a spelling.
        guard !change.corrected.isEmpty, change.corrected.count <= WordDiff.maxWords,
              change.heard.count <= WordDiff.maxWords else { return none(.noise, "too many words") }
        guard word.contains(where: \.isLetter) else { return none(.noise, "no letters") }
        guard !word.contains("@"), !word.contains("://") else { return none(.noise, "address") }
        if !change.heard.isEmpty, heard.lowercased().hasPrefix(word.lowercased()), word.count < heard.count, word.count <= 3 {
            return none(.fragment, "part of the heard word")
        }
        let allFunction = { (words: [String]) in words.allSatisfy { FunctionWords.all.contains($0.lowercased()) } }
        if allFunction(change.corrected) || (!change.heard.isEmpty && allFunction(change.heard)) {
            return none(.rewording, "function words")
        }
        if change.isCaseOnly, change.atSentenceStart || !Self.hasShape(word) {
            return none(.rewording, change.atSentenceStart ? "case at a sentence start" : "case of an ordinary word")
        }

        let wordIsCommon = common.isCommon(word)
        let shaped = Self.hasShape(word)
        let alreadyKnown = known.contains(word.lowercased())

        // `case`: a distinct spelling that is not an everyday word.
        if shaped, !wordIsCommon {
            verdict.rules.insert(.casing)
        } else if !shaped {
            verdict.reasons.append("lowercase word")
        } else {
            verdict.reasons.append("common word")
        }

        // `replace`: the heard form sounds like the word and is safe to
        // change everywhere.
        if !change.heard.isEmpty, !change.isCaseOnly {
            verdict.similarity = Phonetic.similarity(heard, word)
            let heardIsCommon = common.isCommon(heard)
            let singleShort = change.heard.count == 1 && heard.count < Self.minReplacedLength
            if change.heard.count == 1, heardIsCommon {
                verdict.reasons.append("heard form is a common word")
            } else if singleShort {
                verdict.reasons.append("heard form is too short")
            } else if evidence.keptHeard > 0 {
                verdict.reasons.append("heard form occurs \(evidence.keptHeard)× in kept text")
            } else if verdict.similarity < Self.minSimilarity {
                verdict.reasons.append(String(format: "sounds different (%.2f)", verdict.similarity))
            } else if change.heard.count > 1, heardIsCommon, verdict.similarity < 0.75 {
                verdict.reasons.append("heard words are common and sound different")
            } else {
                verdict.rules.insert(.replace)
            }
        }

        // `prompt`: an important word that the model hears as another word,
        // when no row can fix it. A fix of case alone needs no bias: the
        // model already hears the word.
        if !verdict.rules.contains(.replace), !change.isCaseOnly,
           verdict.rules.contains(.casing) || evidence.seen >= Self.promptEvidence {
            verdict.rules.insert(.prompt)
        }

        if alreadyKnown { verdict.rules.remove(.casing) }
        verdict.kind = Self.kind(change, shaped: shaped, wordIsCommon: wordIsCommon, learns: !verdict.rules.isEmpty)
        if alreadyKnown, verdict.rules.isEmpty { verdict.kind = .known }
        return verdict
    }

    /// A spelling a reader notices: a capital after the first letter, a
    /// digit, a capitalized word, or inner punctuation such as "CA-15".
    static func hasShape(_ word: String) -> Bool {
        word.split(separator: " ").contains { part in
            let letters = part.filter(\.isLetter)
            guard let first = letters.first else { return part.contains(where: \.isNumber) }
            return first.isUppercase
                || letters.dropFirst().contains(where: \.isUppercase)
                || part.contains(where: \.isNumber)
        }
    }

    private static func kind(_ change: WordChange, shaped: Bool, wordIsCommon: Bool, learns: Bool) -> CorrectionKind {
        let word = change.correctedText
        if change.isCaseOnly { return .casing }
        if change.heard.count > 1, change.corrected.count == 1,
           change.heard.joined().lowercased() == word.lowercased().filter({ $0.isLetter || $0.isNumber }) {
            return .join
        }
        if word.split(separator: " ").contains(where: { Phonetic.isAcronym(String($0)) || $0.contains(where: \.isNumber) }) {
            return .acronym
        }
        if !learns { return wordIsCommon ? .rewording : .content }
        return shaped ? .properNoun : .term
    }
}
