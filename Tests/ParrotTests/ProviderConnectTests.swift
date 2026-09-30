import XCTest
@testable import ParrotCore

// Made-up keys only: each has the shape of a real key and nothing more.

final class ProviderConnectTests: XCTestCase {
    private let claudeKey = "sk-ant-api03-" + String(repeating: "Ab3_-", count: 19) + "AA"
    private let openAIProjectKey = "sk-proj-" + String(repeating: "xY9", count: 50)
    private let openAIUserKey = "sk-" + String(repeating: "a1B2", count: 12)
    private let openRouterKey = "sk-or-v1-" + String(repeating: "0a1b", count: 16)
    private let geminiKey = "AIza" + String(repeating: "Sy_1-", count: 7)

    override func setUp() {
        StubProtocol.reset()
        LLMHTTP.delayScale = 0
    }

    override func tearDown() {
        LLMHTTP.delayScale = 1
    }

    // MARK: - Key shapes

    func testEachProviderTakesOnlyItsOwnKeys() {
        let keys: [LLMProvider: String] = [.claude: claudeKey, .openai: openAIProjectKey, .openrouter: openRouterKey, .gemini: geminiKey]
        for (owner, key) in keys {
            for provider in LLMProvider.allCases {
                XCTAssertEqual(provider.looksLikeKey(key), provider == owner, "\(provider) and the \(owner) key")
            }
        }
        XCTAssertTrue(LLMProvider.openai.looksLikeKey(openAIUserKey))
    }

    func testKeyShapesTrimTheEdgesButRefuseInnerSpaceAndAdminKeys() {
        XCTAssertTrue(LLMProvider.claude.looksLikeKey("  \(claudeKey)\n"))
        XCTAssertFalse(LLMProvider.claude.looksLikeKey("sk-ant-api03-abc def" + String(repeating: "x", count: 40)))
        XCTAssertFalse(LLMProvider.claude.looksLikeKey("sk-ant-admin01-" + String(repeating: "x", count: 60)))
        XCTAssertFalse(LLMProvider.openai.looksLikeKey("sk-admin-" + String(repeating: "x", count: 60)))
        XCTAssertFalse(LLMProvider.openai.looksLikeKey("sk-short"))
        XCTAssertFalse(LLMProvider.gemini.looksLikeKey("AIza-too-short"))
        XCTAssertFalse(LLMProvider.claude.looksLikeKey("Here is my key: \(claudeKey)"))
    }

    func testLocalServersAndOtherTakeNoKeyFromTheClipboard() {
        for provider in [LLMProvider.ollama, .lmstudio, .custom, .none] {
            XCTAssertFalse(provider.looksLikeKey(openAIProjectKey))
        }
    }

    func testConnectMethods() {
        XCTAssertEqual(LLMProvider.claude.connectMethod, .keyPage(URL(string: "https://platform.claude.com/settings/keys")!))
        XCTAssertEqual(LLMProvider.openrouter.connectMethod, .openRouterSignIn)
        XCTAssertEqual(LLMProvider.ollama.connectMethod, .localServer(download: URL(string: "https://ollama.com/download")!))
        XCTAssertEqual(LLMProvider.custom.connectMethod, .manual)
        XCTAssertEqual(LLMProvider.connectable.count, 7)
        XCTAssertFalse(LLMProvider.connectable.contains(.none))
    }

    // MARK: - PKCE and the OpenRouter sign-in

    func testPKCEMatchesTheRFCExample() {
        // RFC 7636, appendix B.
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = PKCE.verifier()
        XCTAssertEqual(verifier.count, 43)
        XCTAssertNil(verifier.range(of: #"[^A-Za-z0-9_-]"#, options: .regularExpression))
        XCTAssertNotEqual(verifier, PKCE.verifier())
    }

    func testTheSignInAddressCarriesTheCallbackAndTheChallenge() throws {
        let url = OpenRouterSignIn.authorizeURL(callback: URL(string: "http://localhost:51423/callback")!, challenge: "abc")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "openrouter.ai")
        XCTAssertEqual(url.path, "/auth")
        XCTAssertEqual(query["callback_url"], "http://localhost:51423/callback")
        XCTAssertEqual(query["code_challenge"], "abc")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["key_label"], "Parrot")
    }

    func testTheCodeBecomesAKey() async throws {
        StubProtocol.responses = [(200, #"{"key":"\#(openRouterKey)","user_id":"u1"}"#, [:])]
        let key = try await OpenRouterSignIn.key(code: "the-code", verifier: "the-verifier", session: StubProtocol.session)
        XCTAssertEqual(key, openRouterKey)
        let sent = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.url?.absoluteString, "https://openrouter.ai/api/v1/auth/keys")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: String])
        XCTAssertEqual(body, ["code": "the-code", "code_verifier": "the-verifier", "code_challenge_method": "S256"])
    }

    func testAnAnswerWithoutAKeyFails() async {
        StubProtocol.responses = [(200, "{}", [:])]
        do {
            _ = try await OpenRouterSignIn.key(code: "c", verifier: "v", session: StubProtocol.session)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LLMError, .malformed("no key in the answer"))
        }
    }

    // MARK: - Checking a key

    func testAKeyIsCheckedByListingModels() async throws {
        StubProtocol.responses = [(200, #"{"data":[{"id":"claude-opus-5-5"},{"id":"claude-haiku-4-5"}]}"#, [:])]
        let ids = try await ProviderConnect.check(" \(claudeKey) ", for: .claude, session: StubProtocol.session)
        XCTAssertEqual(ids, ["claude-haiku-4-5", "claude-opus-5-5"])
        let request = try XCTUnwrap(StubProtocol.requests.first?.request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), claudeKey)

        StubProtocol.reset()
        StubProtocol.responses = [(200, #"{"data":[{"id":"gpt-5-mini"}]}"#, [:])]
        _ = try await ProviderConnect.check(openAIProjectKey, for: .openai, session: StubProtocol.session)
        XCTAssertEqual(StubProtocol.requests.first?.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(openAIProjectKey)")
    }

    @MainActor
    func testARefusedKeySaysSo() async {
        StubProtocol.responses = [(401, #"{"error":{"message":"invalid x-api-key"}}"#, [:])]
        do {
            _ = try await ProviderConnect.check(claudeKey, for: .claude, session: StubProtocol.session)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(ConnectModel.message(error, provider: .claude), "Claude did not accept the key. Copy it again, or make a new one.")
        }
        XCTAssertEqual(ConnectModel.message(LLMError.http(400, "API key not valid. Please pass a valid API key."), provider: .gemini),
                       "Gemini did not accept the key. Copy it again, or make a new one.")
    }

    func testALocalServerThatIsOffGivesNil() async {
        StubProtocol.failures = [.cannotConnectToHost]
        let ids = await ProviderConnect.localModels(.ollama, session: StubProtocol.session)
        XCTAssertNil(ids)
        XCTAssertEqual(StubProtocol.requests.count, 1, "no retries for a local server")

        StubProtocol.reset()
        StubProtocol.responses = [(200, #"{"data":[{"id":"llama3.2:latest"}]}"#, [:])]
        let found = await ProviderConnect.localModels(.ollama, session: StubProtocol.session)
        XCTAssertEqual(found, ["llama3.2:latest"])
        XCTAssertEqual(StubProtocol.requests.first?.request.url?.absoluteString, "http://localhost:11434/v1/models")
    }

    // MARK: - The model to start with

    func testClaudeKeepsItsDefaultModel() {
        XCTAssertEqual(ProviderConnect.suggestModel(for: .claude, from: ["claude-haiku-4-5", "claude-opus-5-5"]), "claude-opus-5-5")
        XCTAssertEqual(ProviderConnect.suggestModel(for: .claude, from: []), "claude-opus-5-5")
        XCTAssertEqual(ProviderConnect.suggestModel(for: .claude, from: ["claude-opus-4-1-20250805", "claude-opus-5", "claude-sonnet-5-5"]), "claude-opus-5")
    }

    func testOpenAIGetsItsNewestGeneralMini() {
        let ids = ["gpt-4o", "gpt-4o-mini", "gpt-4.1-mini", "gpt-5", "gpt-5-mini", "gpt-5-mini-2025-08-07", "gpt-5-nano",
                   "gpt-realtime", "gpt-4o-audio-preview", "gpt-4o-mini-transcribe", "o3", "text-embedding-3-small", "gpt-image-1"]
        XCTAssertEqual(ProviderConnect.suggestModel(for: .openai, from: ids), "gpt-5-mini")
        XCTAssertEqual(ProviderConnect.suggestModel(for: .openai, from: ["gpt-5", "gpt-4o"]), "gpt-5")
        XCTAssertNil(ProviderConnect.suggestModel(for: .openai, from: ["text-embedding-3-small"]))
    }

    func testGeminiGetsItsNewestFlashWithoutThePrefix() {
        let ids = ["models/gemini-2.0-flash", "models/gemini-2.5-flash", "models/gemini-2.5-flash-lite", "models/gemini-2.5-pro",
                   "models/gemini-2.5-flash-preview-tts", "models/text-embedding-004"]
        XCTAssertEqual(ProviderConnect.suggestModel(for: .gemini, from: ids), "gemini-2.5-flash")
    }

    func testOpenRouterPrefersAModelThatTakesASchema() {
        let ids = ["anthropic/claude-sonnet-4.5", "google/gemini-2.5-flash", "openai/gpt-5", "openai/gpt-5-mini"]
        XCTAssertEqual(ProviderConnect.suggestModel(for: .openrouter, from: ids), "openai/gpt-5-mini")
        XCTAssertEqual(ProviderConnect.suggestModel(for: .openrouter, from: ["anthropic/claude-sonnet-4.5", "google/gemini-2.5-flash"]),
                       "google/gemini-2.5-flash")
    }

    func testALocalServerGetsItsFirstChatModel() {
        XCTAssertEqual(ProviderConnect.suggestModel(for: .ollama, from: ["nomic-embed-text:latest", "llama3.2:latest"]), "llama3.2:latest")
        XCTAssertNil(ProviderConnect.suggestModel(for: .lmstudio, from: []))
        XCTAssertNil(ProviderConnect.suggestModel(for: .none, from: ["x"]))
    }
}
