import CoreNetworking
import Foundation
import os

// MARK: - MockResponse

/// A mocked HTTP response.
public struct MockResponse: Sendable, Equatable {
    public let statusCode: Int
    public let data: Data?
    /// Response headers. Include "Content-Length" to exercise download progress.
    public let headers: [String: String]

    public init(statusCode: Int, data: Data? = nil, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
    }
}

// MARK: - MockNetworkExchange

/// A registered mock: request matcher (method + URL) plus the outcome(s).
public struct MockNetworkExchange: Sendable {
    public let method: HTTPMethod
    public let url: URL
    /// Responses consumed in order, one per matching request; the last one
    /// repeats once exhausted (so a single-response registration behaves
    /// exactly like before: the same mock answers any number of requests).
    public let responses: [MockResponse]
    /// Transport-level failure to simulate instead of a response. Applies to
    /// every matching request (not sequenced) — for a mix of failures and
    /// successes, use `responses` with `MockResponse(statusCode: 5xx)`
    /// entries, or `InMemoryTransport` for unit tests.
    public let error: URLError?
    /// Optional artificial latency before delivering — useful to test
    /// cancellation. `stopLoading` cancels a pending delivery.
    public let latency: Duration?

    /// Registers a single, reusable response — the common case.
    public init(
        method: HTTPMethod = .get,
        url: URL,
        response: MockResponse,
        error: URLError? = nil,
        latency: Duration? = nil
    ) {
        self.init(method: method, url: url, responses: [response], error: error, latency: latency)
    }

    /// Registers a sequence of responses consumed in order (e.g. 500, 500,
    /// 200 to test "retry that eventually succeeds" through the real URL
    /// loading system).
    public init(
        method: HTTPMethod = .get,
        url: URL,
        responses: [MockResponse],
        error: URLError? = nil,
        latency: Duration? = nil
    ) {
        self.method = method
        self.url = url
        self.responses = responses
        self.error = error
        self.latency = latency
    }
}

// MARK: - MockURLProtocol

/// Deterministic `URLProtocol` for intercepting requests in tests, through
/// the real URL loading system — for the few integration tests that need
/// that (header merging, redirections, the pinning delegate). For unit tests,
/// prefer `InMemoryTransport`: no static/global registry to fight Swift
/// Testing's parallel execution, no "one host per test" discipline.
///
/// - Registration is synchronous (no fire-and-forget tasks): once `register`
///   returns, the mock is visible to the next request.
/// - Matching is by HTTP method + URL.
/// - Responses are consumed in order (`responses`); the last one repeats
///   once exhausted, so a single-response registration answers any number of
///   requests, same as before — until `removeAll()`.
/// - Every handled request is recorded (`recordedRequests`) so tests can
///   assert exact request counts (retry) and headers.
///
/// ## Example
/// ```swift
/// MockURLProtocol.register(MockNetworkExchange(
///     url: URL(string: "https://unit.test/games")!,
///     response: MockResponse(statusCode: 200, data: json)
/// ))
/// let configuration = NetworkingConfiguration(
///     baseURL: URL(string: "https://unit.test")!,
///     protocolClasses: [MockURLProtocol.self]
/// )
/// ```
public final class MockURLProtocol: URLProtocol {
    private struct MatchKey: Hashable, Sendable {
        let method: String
        let url: URL
    }

    private struct RegistryState: Sendable {
        var exchanges: [MatchKey: MockNetworkExchange] = [:]
        var cursors: [MatchKey: Int] = [:]
        var recorded: [URLRequest] = []
    }

    private static let registry = OSAllocatedUnfairLock(initialState: RegistryState())

    private let pendingDelivery = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    // MARK: Registration API

    /// Registers a mock. Overwrites any previous mock for the same
    /// method+URL and resets its cursor into `responses`.
    public static func register(_ exchange: MockNetworkExchange) {
        let key = MatchKey(method: exchange.method.rawValue, url: exchange.url)
        registry.withLock {
            $0.exchanges[key] = exchange
            $0.cursors[key] = 0
        }
    }

    /// Removes all mocks and recorded requests.
    public static func removeAll() {
        registry.withLock { $0 = RegistryState() }
    }

    /// Every request this protocol handled, in order.
    public static var recordedRequests: [URLRequest] {
        registry.withLock { $0.recorded }
    }

    // MARK: URLProtocol

    public override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let method = request.httpMethod ?? "GET"
        let handledRequest = request

        let matched = Self.registry.withLock { state -> (MockNetworkExchange, MockResponse)? in
            state.recorded.append(handledRequest)
            let key = MatchKey(method: method, url: url)
            guard let exchange = state.exchanges[key] else { return nil }
            let index = state.cursors[key, default: 0]
            state.cursors[key] = index + 1
            let response = exchange.responses[min(index, exchange.responses.count - 1)]
            return (exchange, response)
        }

        guard let (exchange, response) = matched else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        if let latency = exchange.latency {
            // `self` cruza al Task con la conformidad `@unchecked Sendable` de abajo
            // (justificada allí). Un `nonisolated(unsafe) let` local ya no basta: los
            // compiladores más recientes lo tratan como error de `sending`.
            let task = Task {
                try? await Task.sleep(for: latency)
                guard !Task.isCancelled else { return }
                self.deliver(exchange, response: response)
            }
            pendingDelivery.withLock { $0 = task }
        } else {
            deliver(exchange, response: response)
        }
    }

    public override func stopLoading() {
        pendingDelivery.withLock { pending in
            pending?.cancel()
            pending = nil
        }
    }

    // MARK: Delivery

    private func deliver(_ exchange: MockNetworkExchange, response: MockResponse) {
        if let error = exchange.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        guard
            let httpResponse = HTTPURLResponse(
                url: exchange.url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        if let data = response.data {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

// `@unchecked Sendable` JUSTIFICADO: `URLProtocol` no es `Sendable` para el compilador,
// pero el URL loading system mantiene viva la instancia hasta finish/stopLoading y los
// callbacks de `client` son seguros desde cualquier hilo; el único estado mutable propio
// (`pendingDelivery`) va bajo `OSAllocatedUnfairLock`.
extension MockURLProtocol: @unchecked Sendable {}
