import Foundation

/// One request to a language model for JSON that fits a schema.
struct LLMRequest: Sendable {
    var system: String
    var user: String
    var schemaName: String
    /// The JSON schema, as JSON text.
    var schema: String
    var maxTokens = 4000
    var timeout: TimeInterval = 60
}

enum LLMError: Error, Equatable, CustomStringConvertible {
    case notConfigured(String)
    /// The HTTP status, and the provider's short message, never the request.
    case http(Int, String)
    /// The model's safety checks declined the request.
    case refused
    /// The answer stopped at the token limit.
    case incomplete
    case malformed(String)
    case network(String)

    var description: String {
        switch self {
        case .notConfigured(let what): return "not set up: \(what)"
        case .http(let status, let message): return "HTTP \(status)\(message.isEmpty ? "" : ": \(message)")"
        case .refused: return "the model declined"
        case .incomplete: return "the answer was cut off"
        case .malformed(let what): return "unexpected answer: \(what)"
        case .network(let what): return "network: \(what)"
        }
    }

    /// Worth another try: rate limits, server errors and network trouble.
    var isTransient: Bool {
        switch self {
        case .http(let status, _): return status == 429 || status == 408 || status == 529 || status >= 500
        case .network: return true
        default: return false
        }
    }
}

/// A language model behind HTTP (ADR-006). Requests and answers are never
/// logged: they hold the user's words.
protocol LLMClient: Sendable {
    /// The JSON text of the model's answer.
    func complete(_ request: LLMRequest) async throws -> Data
    /// The model ids the provider offers.
    func models() async throws -> [String]
}

enum LLMClients {
    /// The client for `settings`, with its key from the Keychain, or an
    /// error that says what is missing.
    static func make(_ settings: CorrectionSettings, credentials: CredentialStore = CredentialStore(),
                     session: URLSession = LLMHTTP.session) throws -> LLMClient {
        guard settings.provider != .none else { throw LLMError.notConfigured("no provider") }
        guard let base = settings.resolvedBaseURL else { throw LLMError.notConfigured("no base URL") }
        let key = try credentials.key(for: settings.provider) ?? ""
        if settings.provider.needsKey, key.isEmpty { throw LLMError.notConfigured("no API key") }
        let model = settings.resolvedModel ?? ""
        if settings.provider == .claude {
            return AnthropicClient(baseURL: base, key: key, model: model, session: session)
        }
        return OpenAICompatibleClient(baseURL: base, key: key, model: model, session: session)
    }
}

/// Shared HTTP plumbing: an ephemeral session (no cache on disk) and a
/// retry for transient failures.
enum LLMHTTP {
    /// Scales the waits between retries; tests set it to 0.
    nonisolated(unsafe) static var delayScale = 1.0

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// Sends `request`, retrying twice after a transient failure. Returns
    /// the body of a 2xx answer.
    static func send(_ request: URLRequest, session: URLSession, retries: Int = 2) async throws -> Data {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await sendOnce(request, session: session)
                guard let http = response as? HTTPURLResponse else { throw LLMError.malformed("not HTTP") }
                guard (200..<300).contains(http.statusCode) else {
                    let error = LLMError.http(http.statusCode, providerMessage(data))
                    if error.isTransient, attempt < retries {
                        attempt += 1
                        try await Task.sleep(nanoseconds: UInt64(delay(http, attempt: attempt) * delayScale * 1_000_000_000))
                        continue
                    }
                    throw error
                }
                return data
            } catch let error as LLMError {
                throw error
            } catch {
                let failure = LLMError.network((error as? URLError).map { "\($0.code.rawValue)" } ?? "\(type(of: error))")
                if attempt < retries {
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(Double(attempt * attempt) * delayScale * 1_000_000_000))
                    continue
                }
                throw failure
            }
        }
    }

    private static func sendOnce(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    /// `retry-after`, capped at 10 s, else 1 s then 4 s.
    private static func delay(_ response: HTTPURLResponse, attempt: Int) -> Double {
        if let header = response.value(forHTTPHeaderField: "retry-after"), let seconds = Double(header) {
            return min(max(seconds, 0), 10)
        }
        return Double(attempt * attempt)
    }

    /// The provider's error message, short, from `{"error": {"message": …}}`.
    static func providerMessage(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let error = json["error"]
        let message = (error as? [String: Any])?["message"] as? String ?? error as? String ?? json["message"] as? String ?? ""
        return String(message.prefix(200))
    }

    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func schema(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }
}

/// Claude through the Messages API, with structured output (ADR-006).
/// Swift has no official Anthropic SDK, so this is raw HTTP.
struct AnthropicClient: LLMClient {
    let baseURL: URL
    let key: String
    let model: String
    let session: URLSession

    func complete(_ request: LLMRequest) async throws -> Data {
        var outputConfig: [String: Any] = ["format": ["type": "json_schema", "schema": try LLMHTTP.schema(request.schema)]]
        if Self.supportsEffort(model) { outputConfig["effort"] = "low" }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": request.maxTokens,
            "system": request.system,
            "messages": [["role": "user", "content": request.user]],
            "output_config": outputConfig,
        ]
        var http = URLRequest(url: baseURL.appendingPathComponent("messages"), timeoutInterval: request.timeout)
        http.httpMethod = "POST"
        headers(&http)
        if Self.supportsFallbacks(model) {
            // On a refusal, the API reruns the request on the model it
            // recommends for that kind of refusal.
            body["fallbacks"] = "default"
            http.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        http.httpBody = try LLMHTTP.json(body)
        let data = try await LLMHTTP.send(http, session: session)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.malformed("not JSON") }
        switch json["stop_reason"] as? String {
        case "refusal": throw LLMError.refused
        case "max_tokens": throw LLMError.incomplete
        default: break
        }
        // Thinking blocks come first; the answer is the text block.
        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw LLMError.malformed("no text block")
        }
        return Data(text.utf8)
    }

    func models() async throws -> [String] {
        var http = URLRequest(url: baseURL.appendingPathComponent("models"), timeoutInterval: 20)
        headers(&http)
        return try OpenAICompatibleClient.modelIDs(try await LLMHTTP.send(http, session: session))
    }

    private func headers(_ http: inout URLRequest) {
        http.setValue(key, forHTTPHeaderField: "x-api-key")
        http.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        http.setValue("application/json", forHTTPHeaderField: "content-type")
    }

    /// `output_config.effort` exists on current models; older Haiku and
    /// Sonnet 4.5 reject it.
    static func supportsEffort(_ model: String) -> Bool {
        !(model.contains("haiku") || model.contains("sonnet-4-5") || model.hasPrefix("claude-3"))
    }

    /// Server-side fallbacks, for the models whose safety checks can decline.
    static func supportsFallbacks(_ model: String) -> Bool {
        ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"].contains(model)
    }
}

/// Any provider that serves the OpenAI chat-completions format: OpenAI,
/// Gemini, OpenRouter, Ollama, LM Studio (ADR-006). Claude's own
/// compatibility layer ignores `response_format`, so Claude uses
/// `AnthropicClient` instead.
struct OpenAICompatibleClient: LLMClient {
    let baseURL: URL
    let key: String
    let model: String
    let session: URLSession

    func complete(_ request: LLMRequest) async throws -> Data {
        do {
            return try await complete(request, strict: true)
        } catch LLMError.http(400, let message) where message.localizedCaseInsensitiveContains("response_format")
            || message.localizedCaseInsensitiveContains("json_schema") || message.localizedCaseInsensitiveContains("schema") {
            // A provider without JSON-schema output: ask for any JSON, and
            // the judge checks the shape.
            return try await complete(request, strict: false)
        }
    }

    private func complete(_ request: LLMRequest, strict: Bool) async throws -> Data {
        let format: [String: Any] = strict
            ? ["type": "json_schema", "json_schema": ["name": request.schemaName, "strict": true, "schema": try LLMHTTP.schema(request.schema)]]
            : ["type": "json_object"]
        let system = strict ? request.system : request.system + "\n\nAnswer with one JSON object that fits this schema:\n" + request.schema
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": request.user]],
            "response_format": format,
        ]
        var http = URLRequest(url: baseURL.appendingPathComponent("chat/completions"), timeoutInterval: request.timeout)
        http.httpMethod = "POST"
        headers(&http)
        http.httpBody = try LLMHTTP.json(body)
        let data = try await LLMHTTP.send(http, session: session)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else { throw LLMError.malformed("no choices") }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw LLMError.refused }
        if choice["finish_reason"] as? String == "length" { throw LLMError.incomplete }
        guard let content = message["content"] as? String else { throw LLMError.malformed("no content") }
        return Data(content.utf8)
    }

    func models() async throws -> [String] {
        var http = URLRequest(url: baseURL.appendingPathComponent("models"), timeoutInterval: 20)
        headers(&http)
        return try Self.modelIDs(try await LLMHTTP.send(http, session: session))
    }

    private func headers(_ http: inout URLRequest) {
        if !key.isEmpty { http.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        http.setValue("application/json", forHTTPHeaderField: "content-type")
    }

    /// `{"data": [{"id": …}]}`, sorted.
    static func modelIDs(_ data: Data) throws -> [String] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { throw LLMError.malformed("no model list") }
        return list.compactMap { $0["id"] as? String }.sorted()
    }
}
