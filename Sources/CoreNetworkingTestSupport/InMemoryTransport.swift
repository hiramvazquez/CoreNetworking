import CoreNetworking
import Foundation

/// In-memory `HTTPTransport`: no `URLSession`, no global registry, no
/// `URLProtocol` — the primary way to unit-test `APIService`.
///
/// Unlike `MockURLProtocol` (a static, process-wide registry that fights
/// Swift Testing's parallel execution), each `InMemoryTransport` is a fresh
/// instance owned by one test: no cross-test contamination, no "one host per
/// test" discipline needed. It also supports SEQUENCES of responses per
/// request (500 → 500 → 200), which `MockURLProtocol` cannot — the exact gap
/// that used to make "retry that eventually succeeds" untestable.
///
/// `actor`, not a lock-guarded class: the state (registered exchanges,
/// recorded requests) is genuinely shared mutable state between the test and
/// the pipeline running concurrently, and every method is already `async`.
///
/// ## Example — retry that ends in success
/// ```swift
/// let transport = InMemoryTransport()
/// await transport.register(InMemoryTransport.Exchange(
///     url: URL(string: "https://unit.test/games")!,
///     responses: [.response(status: 500), .response(status: 500), .response(status: 200, body: json)]
/// ))
/// let service = APIService(configuration: configuration, transport: transport, clock: ManualClock())
/// ```
public actor InMemoryTransport: HTTPTransport {
    /// A registered mock: request matcher (method + URL) plus the sequence
    /// of outcomes to hand back, one per request.
    public struct Exchange: Sendable {
        public let method: HTTPMethod
        public let url: URL
        /// Consumed in order, one per matching request; the last one repeats
        /// once exhausted (so a single-element sequence behaves like a
        /// reusable mock, same as `MockURLProtocol`).
        public let responses: [Outcome]

        public init(method: HTTPMethod = .get, url: URL, responses: [Outcome]) {
            self.method = method
            self.url = url
            self.responses = responses
        }

        /// Convenience for the common case: a single, reusable outcome.
        public init(method: HTTPMethod = .get, url: URL, response: Outcome) {
            self.init(method: method, url: url, responses: [response])
        }
    }

    /// One simulated outcome of `HTTPTransport.send`.
    public enum Outcome: Sendable {
        case response(status: Int, headers: [String: String] = [:], body: Data = Data(), latency: Duration? = nil)
        case failure(any Error)

        /// Convenience: simulates exactly what `URLSessionTransport` throws
        /// when its per-task `TaskDelegate` cancelled a server-trust
        /// challenge because pinning rejected the certificate —
        /// `URLError(.cancelled)` with `pinningFailed == true`, translated to
        /// `PinningFailure`. Lets a unit test exercise `APIService`'s
        /// `.untrustedServer` mapping without a real TLS handshake.
        public static func pinningFailure(host: String) -> Outcome {
            .failure(PinningFailure(host: host))
        }
    }

    private struct MatchKey: Hashable {
        let method: String
        let url: URL
    }

    private var exchanges: [MatchKey: [Outcome]] = [:]
    private var cursors: [MatchKey: Int] = [:]
    private var recordedRequests: [URLRequest] = []

    public init() {}

    /// Registers a mock. Overwrites any previous registration for the same
    /// method + URL and resets its cursor.
    public func register(_ exchange: Exchange) {
        let key = MatchKey(method: exchange.method.rawValue, url: exchange.url)
        exchanges[key] = exchange.responses
        cursors[key] = 0
    }

    /// Every request this transport handled, in order. The body is exactly
    /// what `APIService` built (`URLRequest.httpBody`) — always plain `Data`,
    /// never a stream: nothing here goes through the real URL loading system.
    public var recorded: [URLRequest] { recordedRequests }

    public func send(_ request: URLRequest, progress: TransferProgress?) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)

        guard let url = request.url else { throw URLError(.badURL) }
        let method = request.httpMethod ?? HTTPMethod.get.rawValue
        let key = MatchKey(method: method, url: url)

        guard let outcomes = exchanges[key], !outcomes.isEmpty else {
            throw URLError(.resourceUnavailable)
        }
        let index = cursors[key] ?? 0
        cursors[key] = index + 1
        let outcome = outcomes[min(index, outcomes.count - 1)]

        switch outcome {
        case .failure(let error):
            throw error
        case .response(let status, let headers, let body, let latency):
            if let latency {
                try await Task.sleep(for: latency)
            }
            guard
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )
            else {
                throw URLError(.badServerResponse)
            }
            progress?.onUpload?(1.0)
            progress?.onDownload?(1.0)
            return (body, response)
        }
    }

    /// Same matching/sequencing as `send`, but writes the body to
    /// `destination` instead of returning it — every outcome (including
    /// `.pinningFailure`, latency and response sequences) behaves exactly
    /// the same for `download` as for `send`.
    public func download(
        _ request: URLRequest,
        to destination: URL,
        progress: TransferProgress?
    ) async throws -> HTTPURLResponse {
        let (data, response) = try await send(request, progress: progress)
        try data.write(to: destination, options: .atomic)
        return response
    }
}
