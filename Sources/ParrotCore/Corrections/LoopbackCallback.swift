import Foundation
import Network

/// A one-shot HTTP listener on this Mac's loopback interface, for the
/// redirect at the end of a browser sign-in (ADR-006). It takes the first
/// request for `path`, answers it with a short page, and stops. Nothing
/// outside this Mac can reach it, and it holds nothing but the query.
final class LoopbackCallback: @unchecked Sendable {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case couldNotListen(String)
        case timedOut
        case cancelled

        var description: String {
            switch self {
            case .couldNotListen(let why): return "couldn't listen for the sign-in: \(why)"
            case .timedOut: return "the sign-in took too long"
            case .cancelled: return "cancelled"
            }
        }
    }

    let path: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "parrot.loopback-callback")
    // Guarded by `queue`.
    private var waiter: CheckedContinuation<[URLQueryItem], Error>?
    private var outcome: Result<[URLQueryItem], Error>?

    init(path: String = "/callback") throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            throw Failure.couldNotListen("\(error)")
        }
        self.path = path
    }

    /// Starts listening and returns the address to redirect to.
    func start() async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: Failure.couldNotListen("\(error)"))
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: Failure.cancelled)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
        guard port != 0 else { throw Failure.couldNotListen("no port") }
        return URL(string: "http://localhost:\(port)\(path)")!
    }

    /// Waits for the redirect and returns its query items.
    func wait(timeout: TimeInterval) async throws -> [URLQueryItem] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let outcome = self.outcome {
                    continuation.resume(with: outcome)
                    return
                }
                self.waiter = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(Failure.timedOut)) }
            }
        }
    }

    /// Stops listening. A wait still open ends as cancelled.
    func stop() {
        queue.async { self.finish(.failure(Failure.cancelled)) }
    }

    // MARK: - On `queue`

    private func finish(_ result: Result<[URLQueryItem], Error>) {
        guard outcome == nil else { return }
        outcome = result
        listener.cancel()
        waiter?.resume(with: result)
        waiter = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            let target = data.flatMap { Self.target(of: $0) }
            let components = target.flatMap { URLComponents(string: "http://localhost\($0)") }
            let isCallback = components?.path == self.path && self.outcome == nil
            let page = isCallback ? Self.donePage : "Not found"
            let status = isCallback ? "200 OK" : "404 Not Found"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isCallback { self.finish(.success(components?.queryItems ?? [])) }
        }
    }

    /// The path and query of the request line: `GET /callback?code=… HTTP/1.1`.
    static func target(of request: Data) -> String? {
        guard let text = String(data: request.prefix(8_192), encoding: .utf8),
              let line = text.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/") else { return nil }
        return String(parts[1])
    }

    private static let donePage = """
        <!doctype html><html><head><meta charset="utf-8"><title>Parrot</title></head>\
        <body style="font: 15px -apple-system, sans-serif; text-align: center; margin-top: 18vh">\
        <h2>Parrot received the sign-in</h2><p>You can close this tab and go back to Parrot.</p></body></html>
        """
}
