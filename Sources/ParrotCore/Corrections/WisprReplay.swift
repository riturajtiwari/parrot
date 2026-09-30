import Foundation

/// Replays the dictations that Wispr Flow still has audio for through
/// Parrot's own model (ADR-006). It shows two things: what Whisper itself
/// mishears in the user's voice, which Wispr's learned words can't tell,
/// because Wispr's models hear differently; and whether the dictionary
/// helps. Text stays in memory. The report holds counts and word pairs.
package enum WisprReplay {
    package struct Report {
        package var clips = 0
        package var skipped = 0
        package var referenceWords = 0
        /// Word errors without the dictionary, and with it (example
        /// sentence and replacement pass), ignoring case and punctuation.
        package var errorsWithout = 0
        package var errorsWith = 0
        /// Occurrences of the user's terms in what they kept, and how many
        /// the model wrote exactly, case included.
        package var termOccurrences = 0
        package var termHitsWithout = 0
        package var termHitsWith = 0
        /// Terms the model wrote where the user had none.
        package var falseTermsWithout = 0
        package var falseTermsWith = 0
        /// What Whisper wrote where the user kept a term, by count.
        package var mishearings: [(heard: String, word: String, count: Int)] = []
    }

    /// - Parameters:
    ///   - terms: words to score; each is matched with its case.
    ///   - usesPrompt: whether `transcribe` gives a different result with
    ///     the example sentence. When not, one transcription serves both.
    ///   - transcribe: the model's text for 16 kHz mono samples, with the
    ///     example sentence or without it.
    package static func run(
        database: URL = Paths.wisprDatabase,
        limit: Int? = nil,
        terms: [String],
        usesPrompt: Bool,
        transcribe: (_ samples: [Float], _ withPrompt: Bool) throws -> String,
        replace: (String) -> String,
        progress: (Int) -> Void = { _ in }
    ) throws -> Report {
        var report = Report()
        var pairs: [String: (heard: String, word: String, count: Int)] = [:]
        let termWords = terms.map { WordDiff.words($0).map(\.text) }.filter { !$0.isEmpty }
        let db = try WisprDatabase(file: database)
        try db.forEachClip { wav, kept in
            if let limit, report.clips >= limit { return }
            guard let samples = decodeWAV(wav) else {
                report.skipped += 1
                return
            }
            let without = try transcribe(samples, false)
            let with = replace(usesPrompt ? try transcribe(samples, true) : without)
            let reference = WordDiff.words(kept)
            report.clips += 1
            report.referenceWords += reference.count
            report.errorsWithout += wordErrors(reference.map(\.key), WordDiff.words(without).map(\.key))
            report.errorsWith += wordErrors(reference.map(\.key), WordDiff.words(with).map(\.key))

            let keptText = reference.map(\.text)
            let withoutText = WordDiff.words(without).map(\.text)
            let withText = WordDiff.words(with).map(\.text)
            for term in termWords {
                let inKept = count(term, in: keptText)
                let inWithout = count(term, in: withoutText)
                let inWith = count(term, in: withText)
                report.termOccurrences += inKept
                report.termHitsWithout += min(inKept, inWithout)
                report.termHitsWith += min(inKept, inWith)
                report.falseTermsWithout += max(inWithout - inKept, 0)
                report.falseTermsWith += max(inWith - inKept, 0)
            }
            // Where the user kept a term and the model wrote something
            // else: Whisper's own mishearing of that term.
            for change in WordDiff.changes(from: without, to: kept) where termWords.contains(change.corrected) {
                let key = change.heardText.lowercased() + "\u{1F}" + change.correctedText
                pairs[key, default: (change.heardText.lowercased(), change.correctedText, 0)].count += 1
            }
            progress(report.clips)
        }
        report.mishearings = pairs.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.word < $1.word }
        return report
    }

    /// The words to score: Wispr Flow's dictionary (without snippets or
    /// replacements) and every word in Parrot's dictionaries.
    package static func defaultTerms(database: URL = Paths.wisprDatabase, dictionary: LayeredDictionary = LayeredDictionary()) throws -> [String] {
        let wispr = try WisprDatabase(file: database).dictionary()
            .filter { !$0.snippet && $0.replacement == nil && !$0.phrase.contains("@") }
            .map(\.phrase)
        var seen = Set<String>()
        return (wispr + dictionary.words).filter { seen.insert($0).inserted }
    }

    /// Records the mishearings in `corrections.json` as pending pairs from
    /// Whisper, so `parrot import wispr` judges and proposes them.
    package static func save(_ report: Report, store: URL = Paths.correctionsFile) throws -> Int {
        let now = Date()
        let storable = report.mishearings.filter { LearnedPair.isStorable($0.heard) && LearnedPair.isStorable($0.word) }
        try LearnedStore(file: store).update { learned in
            for m in storable {
                learned.record(LearnedPair(word: m.word, heard: m.heard, rules: [], status: .pending, sources: [.whisper],
                                           seen: m.count, firstSeen: now, lastSeen: now))
            }
        }
        return storable.count
    }

    /// 16-bit PCM WAV at 16 kHz, one channel, as samples from -1 to 1.
    /// Nil for any other format.
    static func decodeWAV(_ data: Data) -> [Float]? {
        let bytes = [UInt8](data)
        guard bytes.count > 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x41, 0x56, 0x45] else { return nil }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var offset = 12
        var pcm16Mono16k = false
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt ", body + 16 <= bytes.count {
                pcm16Mono16k = u16(body) == 1 && u16(body + 2) == 1 && u32(body + 4) == 16_000 && u16(body + 14) == 16
            } else if id == "data" {
                guard pcm16Mono16k else { return nil }
                let end = min(body + size, bytes.count)
                var samples = [Float]()
                samples.reserveCapacity((end - body) / 2)
                var i = body
                while i + 1 < end {
                    samples.append(Float(Int16(bitPattern: UInt16(u16(i)))) / 32_768)
                    i += 2
                }
                return samples
            }
            offset = body + size + (size & 1)
        }
        return nil
    }

    /// Word-level edit distance.
    static func wordErrors(_ reference: [String], _ hypothesis: [String]) -> Int {
        if reference.isEmpty { return hypothesis.count }
        if hypothesis.isEmpty { return reference.count }
        var previous = Array(0...hypothesis.count)
        for i in 1...reference.count {
            var current = [i] + Array(repeating: 0, count: hypothesis.count)
            for j in 1...hypothesis.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[hypothesis.count]
    }

    /// Occurrences of the word sequence `term` in `words`, case included.
    static func count(_ term: [String], in words: [String]) -> Int {
        guard !term.isEmpty, words.count >= term.count else { return 0 }
        return (0...(words.count - term.count)).filter { Array(words[$0..<($0 + term.count)]) == term }.count
    }
}
