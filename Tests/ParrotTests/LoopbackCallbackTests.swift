import XCTest
@testable import ParrotCore

/// The one-shot listener for the OpenRouter sign-in, over real loopback
/// connections. Nothing leaves this Mac.
final class LoopbackCallbackTests: XCTestCase {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    private func get(_ url: URL) async throws -> (status: Int, body: String) {
        let (data, response) = try await session.data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    func testTheRedirectHandsOverItsQuery() async throws {
        let callback = try LoopbackCallback()
        let address = try await callback.start()
        XCTAssertEqual(address.host, "localhost")
        XCTAssertEqual(address.path, "/callback")

        let answer = try await get(URL(string: address.absoluteString + "?code=abc123")!)
        XCTAssertEqual(answer.status, 200)
        XCTAssertTrue(answer.body.contains("Parrot received the sign-in"))
        let query = try await callback.wait(timeout: 5)
        XCTAssertEqual(query.first { $0.name == "code" }?.value, "abc123")
    }

    func testOtherPathsGetNotFoundAndTheWaitGoesOn() async throws {
        let callback = try LoopbackCallback()
        let address = try await callback.start()
        var other = URLComponents(url: address, resolvingAgainstBaseURL: false)!
        other.path = "/favicon.ico"
        let answer = try await get(other.url!)
        XCTAssertEqual(answer.status, 404)

        _ = try await get(URL(string: address.absoluteString + "?code=later")!)
        let query = try await callback.wait(timeout: 5)
        XCTAssertEqual(query.first { $0.name == "code" }?.value, "later")
    }

    func testTheWaitTimesOut() async throws {
        let callback = try LoopbackCallback()
        _ = try await callback.start()
        do {
            _ = try await callback.wait(timeout: 0.2)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? LoopbackCallback.Failure, .timedOut)
        }
    }

    func testStopEndsTheWait() async throws {
        let callback = try LoopbackCallback()
        _ = try await callback.start()
        let waiting = Task { try await callback.wait(timeout: 30) }
        callback.stop()
        do {
            _ = try await waiting.value
            XCTFail("expected a cancel")
        } catch {
            XCTAssertEqual(error as? LoopbackCallback.Failure, .cancelled)
        }
    }

    func testTheRequestLineGivesThePathAndQuery() {
        XCTAssertEqual(LoopbackCallback.target(of: Data("GET /callback?code=x HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)), "/callback?code=x")
        XCTAssertNil(LoopbackCallback.target(of: Data("POST /callback HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertNil(LoopbackCallback.target(of: Data("GET http://evil.example/ HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertNil(LoopbackCallback.target(of: Data([0xFF, 0xFE])))
    }
}
