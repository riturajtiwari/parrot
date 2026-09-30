import Foundation

/// How alike two words sound, for the `replace` rule (ADR-006): a model
/// mishears a word as something that sounds like it ("Kwilbo" for
/// "Qwilbo"), while a rewrite ("those" for "these") or a content change
/// ("week" for "weekend") need not sound alike at all. Pure.
enum Phonetic {
    /// Similarity from 0 (nothing alike) to 1 (the same key). Compares the
    /// words' keys with spaces removed, and also with each all-capital word
    /// read out as letters, so "our QX" and "RQX" match, and "Elsie" and "LC".
    static func similarity(_ a: String, _ b: String) -> Double {
        var best = 0.0
        for x in variants(a) {
            for y in variants(b) {
                let longest = max(x.count, y.count)
                guard longest > 0 else { continue }
                best = max(best, 1 - Double(levenshtein(x, y)) / Double(longest))
            }
        }
        return best
    }

    /// The keys of `text` as written and as spelled out letter by letter.
    static func variants(_ text: String) -> Set<String> {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let plain = key(words.map(spellDigits).joined())
        let spelled = key(words.map { isAcronym($0) ? $0.map { letterNames[$0] ?? String($0) }.joined() : spellDigits($0) }.joined())
        return [plain, spelled]
    }

    /// A word of two to five capital letters, which people say letter by letter.
    static func isAcronym(_ word: String) -> Bool {
        (2...5).contains(word.count) && word.allSatisfy { $0.isUppercase && $0.isASCII }
    }

    /// A simplified Metaphone key: the consonant sounds of `word`, with the
    /// first vowel kept.
    static func key(_ word: String) -> String {
        let s = Array(word.uppercased().filter { $0.isASCII && $0.isLetter })
        guard !s.isEmpty else { return "" }
        func at(_ i: Int) -> Character? { i >= 0 && i < s.count ? s[i] : nil }
        func isVowel(_ c: Character?) -> Bool { c.map { "AEIOU".contains($0) } ?? false }

        var out = ""
        var i = 0
        // Silent first letters.
        if let first = at(0), let second = at(1) {
            switch (first, second) {
            case ("A", "E"), ("G", "N"), ("K", "N"), ("P", "N"), ("W", "R"): i = 1
            case ("X", _): out = "S"; i = 1
            case ("W", "H"): out = "W"; i = 2
            default: break
            }
        }
        while i < s.count {
            let c = s[i]
            defer { i += 1 }
            // Double letters sound as one, except C ("accent").
            if c != "C", i > 0, at(i - 1) == c { continue }
            let next = at(i + 1)
            switch c {
            case "A", "E", "I", "O", "U":
                // Any first vowel is one sound here: "our" and "R" ("ar") match.
                if i == 0 { out.append("A") }
            case "B":
                if !(at(i - 1) == "M" && i == s.count - 1) { out.append("B") }
            case "C":
                if next == "I", at(i + 2) == "A" { out.append("X") }
                else if next == "H" { out.append(at(i - 1) == "S" ? "K" : "X"); i += 1 }
                else if let n = next, "IEY".contains(n) { out.append("S") }
                else { out.append("K") }
            case "D":
                if next == "G", let n = at(i + 2), "IEY".contains(n) { out.append("J") } else { out.append("T") }
            case "G":
                if next == "H", !isVowel(at(i + 2)), i + 2 < s.count { continue }
                if next == "N" { continue }
                if let n = next, "IEY".contains(n), at(i - 1) != "G" { out.append("J") } else { out.append("K") }
            case "H":
                if isVowel(next), !(at(i - 1).map { "CSPTG".contains($0) } ?? false) { out.append("H") }
            case "K":
                if at(i - 1) != "C" { out.append("K") }
            case "P":
                if next == "H" { out.append("F"); i += 1 } else { out.append("P") }
            case "Q":
                out.append("K")
            case "S":
                if next == "H" { out.append("X"); i += 1 }
                else if next == "I", let n = at(i + 2), "OA".contains(n) { out.append("X") }
                else { out.append("S") }
            case "T":
                if next == "I", let n = at(i + 2), "OA".contains(n) { out.append("X") }
                else if next == "H" { out.append("0"); i += 1 }
                else if !(next == "C" && at(i + 2) == "H") { out.append("T") }
            case "V":
                out.append("F")
            case "W", "Y":
                if isVowel(next) { out.append(c) }
            case "X":
                out.append("KS")
            case "Z":
                out.append("S")
            default:
                out.append(c)
            }
        }
        return out
    }

    /// How letters sound when spoken one by one.
    private static let letterNames: [Character: String] = [
        "A": "AY", "B": "BEE", "C": "SEE", "D": "DEE", "E": "EE", "F": "EF", "G": "JEE", "H": "AYCH",
        "I": "EYE", "J": "JAY", "K": "KAY", "L": "EL", "M": "EM", "N": "EN", "O": "OH", "P": "PEE",
        "Q": "KYOO", "R": "AR", "S": "ES", "T": "TEE", "U": "YOO", "V": "VEE", "W": "DUBELYOO",
        "X": "EKS", "Y": "WY", "Z": "ZEE",
    ]

    private static let digitNames = ["ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE"]

    /// "QX7" reads as "QXSEVEN".
    private static func spellDigits(_ word: String) -> String {
        String(word.flatMap { c -> String in
            guard let digit = c.wholeNumberValue, c.isASCII else { return String(c) }
            return digitNames[digit]
        })
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a)
        let y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count]
    }
}
