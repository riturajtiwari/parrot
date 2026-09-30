import Foundation

/// Judges pairs with a language model, inside the local rules (ADR-006).
///
/// The local rules run first. The model sees each pair, the local features
/// and the rules the local vetoes allow; it can drop or narrow a proposal,
/// but never add a rule a veto blocks. When a request fails, the pairs in it
/// keep their local verdict, so the judge never blocks learning.
struct LLMJudge {
    let client: LLMClient
    let local: LocalJudge
    /// Pairs per request.
    var batch = 20
    var timeout: TimeInterval = 60

    struct Item {
        var change: WordChange
        var evidence: CorrectionEvidence
        /// A few words before and after the pair, sent only when the user
        /// turns on `sendContext`.
        var context: (before: String, after: String)?
    }

    struct Outcome {
        /// One verdict per item, in order.
        var verdicts: [CorrectionVerdict]
        /// Requests that failed; their items kept the local verdict.
        var failures: [LLMError]
    }

    func judge(_ items: [Item], known: Set<String> = []) async -> Outcome {
        var verdicts = items.map { local.judge($0.change, evidence: $0.evidence, known: known) }
        var failures: [LLMError] = []
        // Only pairs that could learn something go to the model.
        let asked = verdicts.indices.filter { !Self.allowed(verdicts[$0]).subtracting([.prompt]).isEmpty || verdicts[$0].learns }
        for start in stride(from: 0, to: asked.count, by: batch) {
            let chunk = Array(asked[start..<min(start + batch, asked.count)])
            do {
                let request = try Self.request(chunk.map { (id: $0, item: items[$0], local: verdicts[$0]) }, timeout: timeout)
                let answers = try Self.decode(try await client.complete(request))
                for answer in answers where chunk.contains(answer.id) {
                    verdicts[answer.id] = Self.merge(verdicts[answer.id], answer)
                }
            } catch let error as LLMError {
                failures.append(error)
            } catch {
                failures.append(.malformed("\(type(of: error))"))
            }
        }
        return Outcome(verdicts: verdicts, failures: failures)
    }

    /// What the local vetoes allow: the local proposal, plus `prompt`, which
    /// costs only a few milliseconds and never changes text.
    static func allowed(_ local: CorrectionVerdict) -> Set<CorrectionRule> {
        local.rules.union([.prompt])
    }

    /// The model's verdict, narrowed to what the vetoes allow.
    static func merge(_ local: CorrectionVerdict, _ answer: Answer) -> CorrectionVerdict {
        var verdict = local
        verdict.confidence = answer.confidence
        verdict.reasons = local.reasons + ["model: \(answer.reason)"]
        verdict.kind = answer.kind.localKind
        verdict.rules = answer.learn ? Set(answer.rules.compactMap(CorrectionRule.init(rawValue:))).intersection(allowed(local)) : []
        return verdict
    }

    // MARK: - The request

    struct Answer: Decodable, Equatable {
        enum Kind: String, Decodable {
            case name, brand, acronym, term, join, casing, rewording, content, noise

            var localKind: CorrectionKind {
                switch self {
                case .name, .brand: return .properNoun
                case .acronym: return .acronym
                case .term: return .term
                case .join: return .join
                case .casing: return .casing
                case .rewording: return .rewording
                case .content: return .content
                case .noise: return .noise
                }
            }
        }

        var id: Int
        var learn: Bool
        var kind: Kind
        var rules: [String]
        var confidence: Double
        var reason: String
    }

    private struct Answers: Decodable {
        var verdicts: [Answer]
    }

    static func decode(_ data: Data) throws -> [Answer] {
        do {
            return try JSONDecoder().decode(Answers.self, from: data).verdicts
        } catch {
            throw LLMError.malformed("the verdicts don't fit the schema")
        }
    }

    static func request(_ items: [(id: Int, item: Item, local: CorrectionVerdict)], timeout: TimeInterval) throws -> LLMRequest {
        let pairs: [[String: Any]] = items.map { entry in
            let change = entry.item.change
            var pair: [String: Any] = [
                "id": entry.id,
                "heard": change.heardText,
                "corrected": change.correctedText,
                "features": [
                    "shape": LocalJudge.shapeName(change.correctedText, atSentenceStart: change.atSentenceStart),
                    "soundsAlike": (entry.local.similarity * 100).rounded() / 100,
                    "heardIsCommon": !change.heard.isEmpty && EmbeddingCommonWords.shared.isCommon(change.heardText),
                    "keptCount": entry.item.evidence.keptHeard,
                    "seen": entry.item.evidence.seen,
                ] as [String: Any],
                "allowedRules": allowed(entry.local).sorted().map(\.rawValue),
            ]
            if let context = entry.item.context {
                pair["before"] = context.before
                pair["after"] = context.after
            }
            return pair
        }
        let user = String(decoding: try LLMHTTP.json(["pairs": pairs]), as: UTF8.self)
        return LLMRequest(system: system, user: user, schemaName: "verdicts", schema: schema, timeout: timeout)
    }

    static let schema = """
        {"type":"object","additionalProperties":false,"required":["verdicts"],"properties":{"verdicts":{"type":"array","items":\
        {"type":"object","additionalProperties":false,"required":["id","learn","kind","rules","confidence","reason"],"properties":{\
        "id":{"type":"integer"},"learn":{"type":"boolean"},\
        "kind":{"type":"string","enum":["name","brand","acronym","term","join","casing","rewording","content","noise"]},\
        "rules":{"type":"array","items":{"type":"string","enum":["replace","case","prompt"]}},\
        "confidence":{"type":"number"},"reason":{"type":"string"}}}}}}
        """

    static let system = """
        You review corrections that a person made to text that a speech-to-text model wrote. Each pair has \
        `heard`, the words the model wrote, and `corrected`, the words the person wrote instead. Decide whether \
        the pair teaches the spelling of a word the model mishears: the name of a person or a company, a product \
        or brand, an acronym, a technical term, or the joining or capitalization of such a word. Rewording, \
        grammar, a change of meaning, numbers and half-typed fragments are not spellings: for those, set learn to false.

        Rules for a pair that teaches a spelling:
        - replace: from now on, every occurrence of `heard` becomes `corrected`, in everything the person dictates. \
        Only when `heard` is not an ordinary word or phrase that the person may also mean literally.
        - case: always write `corrected` with exactly this capitalization. Only for a distinct spelling, never for an everyday word.
        - prompt: add `corrected` to a sentence that primes the speech model, for a word the model hears as ordinary \
        words, where replace is unsafe.
        Choose rules only from `allowedRules`; local checks block the others.

        Each pair has local features: `shape` of the corrected words, `soundsAlike` from 0 to 1, `heardIsCommon`, \
        `keptCount` (how often the person kept `heard` in other text), and `seen` (how often the pair occurred). \
        Some pairs also have `before` and `after`: the words around the correction.

        Made-up examples:
        - heard "Kwilbo", corrected "Qwilbo": learn, kind brand, rules replace and case.
        - heard "Link", corrected "Zorblink": learn, kind brand, rules case and prompt, because "Link" is an ordinary word.
        - heard "post hog", corrected "PostHog": learn, kind join, rules replace and case.
        - heard "Elsie", corrected "LC": learn, kind name, rules case and prompt, because the person may also mean someone called Elsie.
        - heard "those", corrected "these": do not learn, kind rewording.
        - heard "weekend", corrected "week": do not learn, kind content.

        Give one verdict for each id, with a confidence from 0 to 1 and a reason of at most 12 words.
        """
}
