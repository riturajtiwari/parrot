import XCTest
@testable import ParrotCore

/// Answers every request of a session with the next canned response, and
/// keeps each request for the test to inspect. No network.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(status: Int, body: String, headers: [String: String])] = []
    nonisolated(unsafe) static var failures: [URLError.Code] = []
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data)] = []

    static func reset() {
        responses = []
        failures = []
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.requests.append((request, body))
        if !Self.failures.isEmpty {
            client?.urlProtocol(self, didFailWithError: URLError(Self.failures.removeFirst()))
            return
        }
        let next = Self.responses.isEmpty ? (status: 500, body: "{}", headers: [:]) : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class LLMJudgeTests: XCTestCase {
    private let common = FixedCommonWords(words: ["link", "weekend", "week"])
    private var local: LocalJudge { LocalJudge(common: common) }

    override func setUp() {
        StubProtocol.reset()
        LLMHTTP.delayScale = 0
    }

    override func tearDown() {
        LLMHTTP.delayScale = 1
    }

    private func claude(_ model: String = "claude-opus-5-5") -> AnthropicClient {
        AnthropicClient(baseURL: URL(string: "https://api.anthropic.com/v1")!, key: "test-key", model: model, session: StubProtocol.session)
    }

    private func verdicts(_ items: String) -> String {
        #"{"verdicts":[\#(items)]}"#
    }

    /// A Messages API answer: a thinking block, then the text block.
    private func messages(_ text: String, stop: String = "end_turn") -> String {
        let escaped = String(data: try! JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed]), encoding: .utf8)!.dropFirst().dropLast()
        return #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":\#(escaped)}],"stop_reason":"\#(stop)"}"#
    }

    private let items = [
        LLMJudge.Item(change: WordChange(heard: ["Kwilbo"], corrected: ["Qwilbo"]), evidence: CorrectionEvidence(seen: 3)),
        LLMJudge.Item(change: WordChange(heard: ["Link"], corrected: ["Zorblink"]), evidence: CorrectionEvidence(seen: 9)),
    ]

    func testClaudeRequestShapeAndAnswer() async throws {
        StubProtocol.responses = [(200, messages(verdicts("""
            {"id":0,"learn":true,"kind":"brand","rules":["replace","case"],"confidence":0.9,"reason":"a brand"},
            {"id":1,"learn":true,"kind":"brand","rules":["case","prompt"],"confidence":0.8,"reason":"Link is common"}
            """)), [:])]
        let outcome = await LLMJudge(client: claude(), local: local).judge(items)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(outcome.verdicts.map(\.rules), [[.replace, .casing], [.casing, .prompt]])
        XCTAssertEqual(outcome.verdicts[0].confidence, 0.9)

        let sent = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(sent.request.url?.path, "/v1/messages")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertNil(body["thinking"], "thinking is always on for this model; sending it is not needed")
        let output = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "low")
        XCTAssertEqual((output["format"] as? [String: Any])?["type"] as? String, "json_schema")
        let user = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        XCTAssertTrue(user.contains("Qwilbo"))
        XCTAssertFalse(user.contains("\"before\""), "no context unless the user turns it on")
    }

    func testOlderModelsGetNoEffortOrFallbacks() async throws {
        StubProtocol.responses = [(200, messages(verdicts("")), [:])]
        _ = await LLMJudge(client: claude("claude-haiku-4-5"), local: local).judge(items)
        let sent = try XCTUnwrap(StubProtocol.requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertNil(body["fallbacks"])
        XCTAssertNil((body["output_config"] as? [String: Any])?["effort"])
        XCTAssertNil(sent.request.value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testTheModelCanNeverAddABlockedRule() async {
        // The local vetoes block `replace` for the common heard word "Link".
        StubProtocol.responses = [(200, messages(verdicts("""
            {"id":0,"learn":true,"kind":"brand","rules":["replace","case"],"confidence":0.99,"reason":"trust me"}
            """)), [:])]
        let outcome = await LLMJudge(client: claude(), local: local).judge([items[1]])
        XCTAssertEqual(outcome.verdicts.first?.rules, [.casing])
        XCTAssertEqual(outcome.verdicts.first?.confidence, 0.99)
    }

    func testTheModelCanDropAProposal() async {
        StubProtocol.responses = [(200, messages(verdicts("""
            {"id":0,"learn":false,"kind":"content","rules":[],"confidence":0.7,"reason":"a different word"}
            """)), [:])]
        let outcome = await LLMJudge(client: claude(), local: local).judge([items[0]])
        XCTAssertEqual(outcome.verdicts.first?.rules, [])
        XCTAssertEqual(outcome.verdicts.first?.kind, .content)
    }

    func testFailuresKeepTheLocalVerdict() async {
        let expected = items.map { local.judge($0.change, evidence: $0.evidence) }
        for (response, error) in [
            ((200, messages("", stop: "refusal"), [String: String]()), LLMError.refused),
            ((200, messages("{\"verdicts\":", stop: "max_tokens"), [:]), LLMError.incomplete),
            ((200, messages("not json"), [:]), LLMError.malformed("the verdicts don't fit the schema")),
            ((401, #"{"error":{"message":"invalid x-api-key"}}"#, [:]), LLMError.http(401, "invalid x-api-key")),
        ] {
            StubProtocol.reset()
            StubProtocol.responses = [response]
            let outcome = await LLMJudge(client: claude(), local: local).judge(items)
            XCTAssertEqual(outcome.failures, [error])
            XCTAssertEqual(outcome.verdicts, expected)
        }
    }

    func testRetriesARateLimitThenSucceeds() async {
        StubProtocol.responses = [
            (429, #"{"error":{"message":"slow down"}}"#, ["retry-after": "0"]),
            (200, messages(verdicts(#"{"id":0,"learn":true,"kind":"brand","rules":["replace"],"confidence":0.8,"reason":"ok"}"#)), [:]),
        ]
        let outcome = await LLMJudge(client: claude(), local: local).judge([items[0]])
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testNetworkFailuresRetryThenGiveUp() async {
        StubProtocol.failures = [.timedOut, .timedOut, .timedOut]
        let outcome = await LLMJudge(client: claude(), local: local).judge([items[0]])
        XCTAssertEqual(StubProtocol.requests.count, 3)
        XCTAssertEqual(outcome.failures.count, 1)
    }

    func testOpenAICompatibleFallsBackToAnyJSON() async throws {
        let answer = verdicts(#"{"id":0,"learn":true,"kind":"brand","rules":["replace","case"],"confidence":0.9,"reason":"ok"}"#)
        let encoded = String(data: try JSONSerialization.data(withJSONObject: [answer], options: []), encoding: .utf8)!.dropFirst().dropLast()
        StubProtocol.responses = [
            (400, #"{"error":{"message":"response_format json_schema is not supported"}}"#, [:]),
            (200, #"{"choices":[{"message":{"content":\#(encoded)},"finish_reason":"stop"}]}"#, [:]),
        ]
        let client = OpenAICompatibleClient(baseURL: URL(string: "http://localhost:11434/v1")!, key: "", model: "local-model", session: StubProtocol.session)
        let outcome = await LLMJudge(client: client, local: local).judge([items[0]])
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(outcome.verdicts.first?.rules, [.replace, .casing])

        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: StubProtocol.requests[0].body) as? [String: Any])
        XCTAssertEqual((first["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: StubProtocol.requests[1].body) as? [String: Any])
        XCTAssertEqual((second["response_format"] as? [String: Any])?["type"] as? String, "json_object")
        XCTAssertEqual(StubProtocol.requests[0].request.url?.path, "/v1/chat/completions")
        XCTAssertNil(StubProtocol.requests[0].request.value(forHTTPHeaderField: "Authorization"), "a local server gets no key")
    }

    func testModelLists() async throws {
        StubProtocol.responses = [(200, #"{"data":[{"id":"b-model"},{"id":"a-model"}]}"#, [:])]
        let ids = try await claude().models()
        XCTAssertEqual(ids, ["a-model", "b-model"])
    }
}

final class CorrectionSettingsTests: XCTestCase {
    func testDefaultsAndUnknownValues() throws {
        let empty = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).corrections
        XCTAssertEqual(empty, CorrectionSettings())
        XCTAssertEqual(empty.learning, .review)
        XCTAssertEqual(empty.provider, LLMProvider.none)

        let odd = try JSONDecoder().decode(CorrectionSettings.self, from: Data(#"{"provider":"nobody","learning":"sometimes","model":"m"}"#.utf8))
        XCTAssertEqual(odd.provider, LLMProvider.none)
        XCTAssertEqual(odd.learning, .review)
        XCTAssertEqual(odd.model, "m")
    }

    func testTheKeyIsNeverInTheSettings() throws {
        var settings = CorrectionSettings()
        settings.provider = .claude
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("key\""), json)
    }

    func testResolvedModelAndBaseURL() {
        var settings = CorrectionSettings()
        settings.provider = .claude
        XCTAssertEqual(settings.resolvedModel, "claude-opus-5-5")
        XCTAssertEqual(settings.resolvedBaseURL?.absoluteString, "https://api.anthropic.com/v1")
        settings.provider = .custom
        XCTAssertNil(settings.resolvedModel)
        XCTAssertNil(settings.resolvedBaseURL)
        settings.baseURL = "http://example.local/v1"
        XCTAssertEqual(settings.resolvedBaseURL?.host, "example.local")
    }
}
