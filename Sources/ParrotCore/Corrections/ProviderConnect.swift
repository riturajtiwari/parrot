import CryptoKit
import Foundation

/// How a provider connects from Settings → Corrections (ADR-006).
///
/// Claude, OpenAI and Gemini let no other app sign in for the user, so
/// Parrot opens the page where the user makes a key, and takes the key from
/// the clipboard when the user copies it. OpenRouter has a sign-in (OAuth
/// with PKCE) that gives Parrot a key of its own. Ollama and LM Studio run
/// on this Mac and need no key.
enum ConnectMethod: Equatable {
    /// The user makes a key on `page` and copies it.
    case keyPage(URL)
    /// OpenRouter's sign-in, which returns a key.
    case openRouterSignIn
    /// A server on this Mac; `download` gets it.
    case localServer(download: URL)
    /// A base URL, an optional key and a model, by hand.
    case manual
}

extension LLMProvider {
    /// The providers the Settings screen shows, in order.
    static let connectable: [LLMProvider] = [.claude, .openai, .gemini, .openrouter, .ollama, .lmstudio, .custom]

    /// The name under the provider's logo.
    var shortName: String {
        switch self {
        case .none: return "None"
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .openrouter: return "OpenRouter"
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        case .custom: return "Other"
        }
    }

    var connectMethod: ConnectMethod {
        switch self {
        case .claude: return .keyPage(URL(string: "https://platform.claude.com/settings/keys")!)
        case .openai: return .keyPage(URL(string: "https://platform.openai.com/api-keys")!)
        case .gemini: return .keyPage(URL(string: "https://aistudio.google.com/apikey")!)
        case .openrouter: return .openRouterSignIn
        case .ollama: return .localServer(download: URL(string: "https://ollama.com/download")!)
        case .lmstudio: return .localServer(download: URL(string: "https://lmstudio.ai")!)
        case .none, .custom: return .manual
        }
    }

    /// Where the user sees and deletes the keys of this provider.
    var keysPage: URL? {
        switch connectMethod {
        case .keyPage(let page): return page
        case .openRouterSignIn: return URL(string: "https://openrouter.ai/settings/keys")
        case .localServer, .manual: return nil
        }
    }

    /// The name of the page that makes keys, for the button that opens it.
    var keyPageName: String {
        switch self {
        case .claude: return "Claude Console"
        case .openai: return "OpenAI Platform"
        case .gemini: return "Google AI Studio"
        default: return "\(displayName) keys"
        }
    }

    /// Whether `text` has the shape of this provider's API key: the right
    /// prefix, no spaces, and a plausible length. The clipboard watcher
    /// takes nothing else.
    func looksLikeKey(_ text: String) -> Bool {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count <= 400, !key.contains(where: \.isWhitespace) else { return false }
        func matches(_ pattern: String) -> Bool {
            key.range(of: pattern, options: .regularExpression) != nil
        }
        switch self {
        case .claude:
            return matches(#"^sk-ant-api\d{2}-[A-Za-z0-9_-]{32,}$"#)
        case .openai:
            // Project, service-account and older user keys. Not Claude's or
            // OpenRouter's, which start with sk- too, and not admin keys,
            // which can't make requests.
            return matches(#"^sk-[A-Za-z0-9_-]{20,}$"#)
                && !["sk-ant-", "sk-or-", "sk-admin-"].contains(where: key.hasPrefix)
        case .gemini:
            return matches(#"^AIza[0-9A-Za-z_-]{35}$"#)
        case .openrouter:
            return matches(#"^sk-or-v1-[0-9a-f]{64}$"#)
        case .none, .ollama, .lmstudio, .custom:
            return false
        }
    }
}

/// Connecting a provider: checks a key, finds local models, picks a model.
enum ProviderConnect {
    /// Lists the provider's models with `key`. A wrong key fails here, and
    /// listing costs nothing. (OpenRouter lists its models to anyone.)
    static func check(_ key: String, for provider: LLMProvider, baseURL: URL? = nil,
                      session: URLSession = LLMHTTP.session) async throws -> [String] {
        guard let base = baseURL ?? provider.baseURL else { throw LLMError.notConfigured("no base URL") }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .claude {
            return try await AnthropicClient(baseURL: base, key: trimmed, model: "", session: session).models()
        }
        return try await OpenAICompatibleClient(baseURL: base, key: trimmed, model: "", session: session).models()
    }

    /// The models of a server on this Mac, or nil when none answers. One
    /// quick try, with no retries: a server that is off refuses at once.
    static func localModels(_ provider: LLMProvider, session: URLSession = LLMHTTP.session) async -> [String]? {
        guard let base = provider.baseURL else { return nil }
        var request = URLRequest(url: base.appendingPathComponent("models"), timeoutInterval: 3)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        guard let data = try? await LLMHTTP.send(request, session: session, retries: 0) else { return nil }
        return try? OpenAICompatibleClient.modelIDs(data)
    }

    /// Checks that `client` can judge: two made-up pairs, as Test Connection
    /// and `parrot llm test` send. Returns the first failure, or nil.
    static func test(_ client: LLMClient) async -> LLMError? {
        let items = [
            WordChange(heard: ["Kwilbo"], corrected: ["Qwilbo"]),
            WordChange(heard: ["weekend"], corrected: ["week"]),
        ].map { LLMJudge.Item(change: $0, evidence: CorrectionEvidence(seen: 3)) }
        return await LLMJudge(client: client, local: LocalJudge(), timeout: 30).judge(items).failures.first
    }

    /// A model to start with, from the ids the provider lists: a current,
    /// general model, the smallest where there is a choice, since the judge
    /// only sorts word pairs. The user can choose another.
    static func suggestModel(for provider: LLMProvider, from ids: [String]) -> String? {
        switch provider {
        case .claude:
            let claude = ids.filter { $0.hasPrefix("claude-") }
            guard !claude.isEmpty else { return provider.defaultModel }
            return ["haiku", "sonnet", "opus"].lazy.compactMap { family in newest(claude.filter { $0.contains(family) }) }.first
                ?? newest(claude)
        case .openai:
            return pickOpenAI(ids)
        case .gemini:
            return pickGemini(ids.map(withoutModelsPrefix))
        case .openrouter:
            // OpenAI's and Google's models there take a JSON schema.
            let openai = ids.filter { $0.hasPrefix("openai/") }.map { String($0.dropFirst("openai/".count)) }
            if let model = pickOpenAI(openai) { return "openai/" + model }
            let google = ids.filter { $0.hasPrefix("google/") }.map { String($0.dropFirst("google/".count)) }
            if let model = pickGemini(google) { return "google/" + model }
            return ids.first
        case .ollama, .lmstudio, .custom:
            return ids.first { !$0.localizedCaseInsensitiveContains("embed") } ?? ids.first
        case .none:
            return nil
        }
    }

    /// The models to offer when the user chooses, the suggested one first,
    /// then the newest. Models for other tasks are left out, and on
    /// OpenRouter only the families that take a JSON schema.
    static func choices(for provider: LLMProvider, from ids: [String]) -> [String] {
        var list: [String]
        switch provider {
        case .claude:
            list = ids.filter { $0.hasPrefix("claude-") }
        case .openai:
            list = general(ids, stable: false).filter { $0.hasPrefix("gpt-") || $0.range(of: #"^o\d"#, options: .regularExpression) != nil }
        case .gemini:
            list = general(ids.map(withoutModelsPrefix), stable: false).filter { $0.hasPrefix("gemini-") }
        case .openrouter:
            list = general(ids, stable: false).filter { id in ["openai/", "anthropic/", "google/"].contains(where: id.hasPrefix) }
        case .ollama, .lmstudio, .custom:
            list = ids.filter { !$0.localizedCaseInsensitiveContains("embed") }
        case .none:
            return []
        }
        var seen = Set<String>()
        list = list.filter { seen.insert($0).inserted }.sorted { a, b in
            rank(a) != rank(b) ? rank(a) > rank(b) : a < b
        }
        if let suggested = suggestModel(for: provider, from: ids) {
            list.removeAll { $0 == suggested }
            list.insert(suggested, at: 0)
        }
        return list
    }

    /// One line on what size of model to pick, under the model menu.
    static func modelHint(for provider: LLMProvider) -> String {
        switch provider {
        case .claude: return "Haiku is the fastest and costs least. Sonnet and Opus cost more and add little for word pairs."
        case .openai: return "A mini model is fast and costs little. Larger models add little for word pairs."
        case .gemini: return "A Flash model is fast and costs little. Pro models add little for word pairs."
        case .openrouter: return "A small model, such as a GPT mini or a Gemini Flash, is enough for word pairs."
        case .ollama, .lmstudio: return "A small model answers fastest. The model must give JSON answers."
        case .custom, .none: return "A small model is enough: the judge only sorts word pairs."
        }
    }

    /// Words in model ids that mark a model for another task.
    private static let special = ["audio", "realtime", "transcribe", "tts", "search", "image", "embed", "moderation",
                                  "instruct", "codex", "vision", "live", "computer-use", "deep-research"]
    /// Previews and experiments: offered, but never suggested.
    private static let unstable = ["preview", "exp", "thinking"]

    private static func general(_ ids: [String], stable: Bool = true) -> [String] {
        let excluded = stable ? special + unstable : special
        return ids.filter { id in !excluded.contains { id.localizedCaseInsensitiveContains($0) } }
    }

    /// Gemini lists its models as `models/gemini-…`; requests take the bare id.
    private static func withoutModelsPrefix(_ id: String) -> String {
        id.hasPrefix("models/") ? String(id.dropFirst("models/".count)) : id
    }

    /// GPT models: the newest mini, else the newest of any size.
    private static func pickOpenAI(_ ids: [String]) -> String? {
        let gpt = general(ids).filter { $0.hasPrefix("gpt-") && !$0.contains("nano") }
        return newest(gpt.filter { $0.contains("mini") }) ?? newest(gpt)
    }

    /// Gemini models: the newest Flash that isn't Lite, else the newest.
    private static func pickGemini(_ ids: [String]) -> String? {
        let gemini = general(ids).filter { $0.hasPrefix("gemini-") }
        return newest(gemini.filter { $0.contains("flash") && !$0.contains("lite") }) ?? newest(gemini)
    }

    /// The id with the highest version number, preferring an alias with no
    /// date over a dated snapshot of the same model.
    static func newest(_ ids: [String]) -> String? {
        ids.max { a, b in rank(a) < rank(b) }
    }

    private static func rank(_ id: String) -> (Double, Int, Int) {
        let dated = id.range(of: #"\d{4}-\d{2}-\d{2}|\d{8}|-\d{4}$"#, options: .regularExpression) != nil
        var version = 0.0
        if let range = id.range(of: #"\d+([.-]\d)?"#, options: .regularExpression) {
            version = Double(id[range].replacingOccurrences(of: "-", with: ".")) ?? 0
        }
        // A shorter id is the plain model; a longer one adds a variant.
        return (version, dated ? 0 : 1, -id.count)
    }
}

/// PKCE (RFC 7636) for the OpenRouter sign-in.
enum PKCE {
    /// 32 random bytes, base64url: 43 characters.
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no random bytes")
        return base64url(Data(bytes))
    }

    /// S256: base64url of the SHA-256 of the verifier.
    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// OpenRouter's sign-in: the user approves Parrot in the browser, and
/// OpenRouter sends a code to Parrot's loopback address, which Parrot trades
/// for a key. The key is the user's to see and delete on openrouter.ai.
enum OpenRouterSignIn {
    static let authorize = URL(string: "https://openrouter.ai/auth")!
    static let exchange = URL(string: "https://openrouter.ai/api/v1/auth/keys")!

    static func authorizeURL(callback: URL, challenge: String) -> URL {
        var components = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: callback.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "key_label", value: "Parrot"),
        ]
        return components.url!
    }

    /// Trades the code from the redirect for a key.
    static func key(code: String, verifier: String, session: URLSession = LLMHTTP.session) async throws -> String {
        var request = URLRequest(url: exchange, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try LLMHTTP.json(["code": code, "code_verifier": verifier, "code_challenge_method": "S256"])
        let data = try await LLMHTTP.send(request, session: session, retries: 1)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["key"] as? String, !key.isEmpty else { throw LLMError.malformed("no key in the answer") }
        return key
    }
}
