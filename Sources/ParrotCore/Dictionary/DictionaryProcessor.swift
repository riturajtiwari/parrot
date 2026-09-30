import Foundation

/// The dictionary's replacement pass, run on every transcript whatever the
/// engine. Reads the current dictionary from the store, so an edit applies to
/// the next dictation.
struct DictionaryProcessor: TranscriptProcessor {
    let store: DictionarySource

    func process(_ transcript: Transcript) -> Transcript {
        Transcript(text: store.current().replacer.apply(to: transcript.text))
    }
}

/// Rewrites a dictionary's `from` variants to their `to` value and its terms to
/// their canonical casing. Pure; built once per loaded dictionary.
///
/// - Matching ignores case and takes whole words only: a match may not touch a
///   letter, digit or underscore in any script (`\p{L}\p{N}_`, plus combining
///   marks), so `api` leaves `rapid` alone and `café` is one word.
/// - Whitespace inside a `from` matches any run of whitespace.
/// - Where several rules match at the same place, the longest wins.
/// - One pass over the input: text a rule inserts is never matched again, so
///   rules cannot chain.
/// - Replacement text is inserted literally; `$` and `\` mean nothing special.
/// - A `from` listed in `replacements` takes precedence over the same word in
///   `terms`, and the first rule listed wins among duplicates.
struct DictionaryReplacer {
    struct Rule: Equatable {
        var from: String
        var to: String
    }

    let rules: [Rule]
    private let regex: NSRegularExpression?

    init(_ dictionary: UserDictionary) {
        var candidates: [Rule] = []
        for replacement in dictionary.replacements {
            let to = replacement.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !to.isEmpty else { continue }
            candidates += replacement.from.map { Rule(from: $0, to: to) }
        }
        candidates += dictionary.terms.map { Rule(from: $0, to: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        self.init(rules: candidates)
    }

    init(rules candidates: [Rule]) {
        // Drop empty sources and later duplicates. Duplicates are found with
        // the same case-insensitive comparison the regex uses.
        var kept: [Rule] = []
        for rule in candidates {
            let from = rule.from.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !from.isEmpty, !rule.to.isEmpty else { continue }
            if kept.contains(where: { $0.from.compare(from, options: .caseInsensitive) == .orderedSame }) { continue }
            kept.append(Rule(from: from, to: rule.to))
        }
        // Longest first: the regex tries alternatives in order at each
        // position, so the first that fits is the longest that fits.
        let ordered = kept.enumerated()
            .sorted { a, b in
                let (la, lb) = (a.element.from.count, b.element.from.count)
                return la != lb ? la > lb : a.offset < b.offset
            }
            .map(\.element)
        self.rules = ordered
        guard !ordered.isEmpty else {
            self.regex = nil
            return
        }
        // One capture group per rule, so the group that matched names the rule
        // without comparing strings outside the regex engine.
        let alternatives = ordered.map { rule in
            "(" + rule.from.split(separator: " ")
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: #"\s+"#) + ")"
        }
        // Combining marks count as part of a word, so a decomposed "é" is not
        // a boundary.
        let word = #"[\p{L}\p{M}\p{N}_]"#
        let pattern = "(?<!\(word))(?:" + alternatives.joined(separator: "|") + ")(?!\(word))"
        self.regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    func apply(to text: String) -> String {
        guard let regex, !text.isEmpty else { return text }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }

        var out = ""
        var cursor = 0
        for match in matches {
            guard let index = (1...rules.count).first(where: { match.range(at: $0).location != NSNotFound }) else {
                continue
            }
            out += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += rules[index - 1].to
            cursor = match.range.location + match.range.length
        }
        out += source.substring(from: cursor)
        return out
    }
}
