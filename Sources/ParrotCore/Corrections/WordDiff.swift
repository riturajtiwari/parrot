import Foundation

/// One change between the text Parrot pasted and the text the user kept:
/// the words that were there and the words that replaced them (ADR-006).
///
/// Holds a few words, never the sentence around them.
struct WordChange: Equatable, Sendable {
    /// What the model wrote, one word per element.
    var heard: [String]
    /// What the user wrote instead.
    var corrected: [String]
    /// The change starts a sentence, where a capital letter says nothing
    /// about the word.
    var atSentenceStart: Bool = false

    var heardText: String { heard.joined(separator: " ") }
    var correctedText: String { corrected.joined(separator: " ") }
    /// Only the letter case differs.
    var isCaseOnly: Bool {
        heard.count == corrected.count
            && heardText.caseInsensitiveCompare(correctedText) == .orderedSame
            && heardText != correctedText
    }
}

/// Finds the word changes between two versions of a text. Pure.
///
/// - Words are compared ignoring case and the punctuation around them, so
///   "fix," and "Fix" are one word; a change of case alone is still a change.
/// - Consecutive changed words form one change. Changes with an empty side
///   (a word only added or only removed) are dropped, and so are changes of
///   more than `maxWords` words on either side.
/// - When the user kept less than `minKept` of the pasted words, the edit is
///   a rewrite, not a correction, and there are no changes.
enum WordDiff {
    static let maxWords = 3
    static let minKept = 0.6

    static func changes(from pasted: String, to edited: String) -> [WordChange] {
        let a = words(pasted)
        let b = words(edited)
        guard !a.isEmpty, !b.isEmpty else { return [] }
        let keyA = a.map(\.key)
        let keyB = b.map(\.key)
        let lcs = longestCommonSubsequence(keyA, keyB)
        guard Double(lcs.count) / Double(a.count) >= minKept else { return [] }

        var result: [WordChange] = []
        var i = 0
        var j = 0
        for (matchA, matchB) in lcs + [(a.count, b.count)] {
            // A gap before this match: words the user replaced.
            if i < matchA, j < matchB {
                let heard = a[i..<matchA].map(\.text)
                let corrected = b[j..<matchB].map(\.text)
                if heard.count <= maxWords, corrected.count <= maxWords {
                    result.append(WordChange(heard: heard, corrected: corrected, atSentenceStart: a[i].startsSentence))
                }
            }
            // The match itself: the same word, but maybe another case.
            if matchA < a.count, matchB < b.count, a[matchA].text != b[matchB].text {
                result.append(WordChange(
                    heard: [a[matchA].text], corrected: [b[matchB].text], atSentenceStart: a[matchA].startsSentence
                ))
            }
            i = matchA + 1
            j = matchB + 1
        }
        return result
    }

    /// The share of `pasted`'s words that `edited` kept, in order.
    static func keptShare(from pasted: String, to edited: String) -> Double {
        let a = words(pasted).map(\.key)
        guard !a.isEmpty else { return 1 }
        return Double(longestCommonSubsequence(a, words(edited).map(\.key)).count) / Double(a.count)
    }

    /// A word as it appears (`text`, edge punctuation removed) and as it is
    /// compared (`key`, lowercased).
    struct Word: Equatable {
        var text: String
        var key: String
        var startsSentence: Bool
    }

    /// The words of `text`: runs of non-space characters with the
    /// punctuation at their edges removed. Inner punctuation stays, so
    /// "CA-15", "v2.1" and "can't" are one word each. Markup tags such as
    /// `<li>` are removed first.
    static func words(_ text: String) -> [Word] {
        let plain = text
            .replacingOccurrences(of: #"<[^>\n]{1,40}>"#, with: " ", options: .regularExpression)
            // A line break ends a sentence too: a lone "." marks it.
            .replacingOccurrences(of: "\n", with: " . ")
        var result: [Word] = []
        var sentenceEnded = true
        for raw in plain.split(whereSeparator: { $0.isWhitespace }) {
            // Invisible format characters (a stray U+FEFF, a zero-width
            // space) are not part of any word.
            let visible = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.properties.generalCategory != .format }))
            let trimmed = visible.trimmingCharacters(in: edgePunctuation)
            defer { sentenceEnded = raw.last.map { ".!?".contains($0) } ?? false }
            guard !trimmed.isEmpty else { continue }
            result.append(Word(text: trimmed, key: trimmed.lowercased(), startsSentence: sentenceEnded))
        }
        return result
    }

    private static let edgePunctuation = CharacterSet.punctuationCharacters
        .union(.symbols)
        .union(.whitespacesAndNewlines)

    /// Index pairs of one longest common subsequence, in order.
    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count
        let m = b.count
        // lengths[i][j]: LCS length of a[i...] and b[j...].
        var lengths = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
