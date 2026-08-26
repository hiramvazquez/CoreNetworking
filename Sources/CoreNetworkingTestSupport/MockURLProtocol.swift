import Foundation
import CoreNetworking
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

/// A registered mock: request matcher (method + URL) plus the outcome.
public struct MockNetworkExchange: Sendable {
    public let method: HTTPMethod
    public let url: URL
    public let response: MockResponse
    /// Transport-level failure to simulate instead of a response.
    public let error: URLError?
    /// Optional artificial latency before delivering — useful to test
    /// cancellation. `stopLoading` cancels a pending delivery.
    public let latency: Duration?

    public init(
        method: HTTPMethod = .GET,
        url: URL,
        response: MockResponse,
        error: URLError? = nil,
        latency: Duration? = nil
    ) {
        self.method = method
        self.url = url
        self.response = response
        self.error = error
        self.latency = latency
    }
}

// MARK: - MockURLProtocol

/// Deterministic `URLProtocol` for intercepting requests in tests.
///
/// - Registration is synchronous (no fire-and-forget tasks): once `register`
///   returns, the mock is visible to the next request.
/// - Matching is by HTTP method + URL.
/// - Responses are reusable: the same mock answers any number of requests
///   until `removeAll()`.
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
        var recorded: [URLRequest] = []
    }

    private static let registry = OSAllocatedUnfairLock(initialState: RegistryState())

    private let pendingDelivery = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    // MARK: Registration API

    /// Registers a mock. Overwrites any previous mock for the same method+URL.
    public static func register(_ exchange: MockNetworkExchange) {
        let key = MatchKey(method: exchange.method.rawValue, url: exchange.url)
        registry.withLock { $0.exchanges[key] = exchange }
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

        let exchange = Self.registry.withLock { state -> MockNetworkExchange? in
            state.recorded.append(handledRequest)
            return state.exchanges[MatchKey(method: method, url: url)]
        }

        guard let exchange else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        if let latency = exchange.latency {
            // nonisolated(unsafe) JUSTIFICADO: URLProtocol no es Sendable para el
            // compilador, pero el URL loading system mantiene viva la instancia
            // hasta finish/stopLoading y los callbacks de `client` son seguros
            // desde cualquier hilo; el único estado mutable propio
            // (`pendingDelivery`) va bajo lock.
            nonisolated(unsafe) let protocolInstance = self
            let task = Task {
                try? await Task.sleep(for: latency)
                guard !Task.isCancelled else { return }
                protocolInstance.deliver(exchange)
            }
            pendingDelivery.withLock { $0 = task }
        } else {
            deliver(exchange)
        }
    }

    public override func stopLoading() {
        pendingDelivery.withLock { pending in
            pending?.cancel()
            pending = nil
        }
    }

    // MARK: Delivery

    private func deliver(_ exchange: MockNetworkExchange) {
        if let error = exchange.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        guard let httpResponse = HTTPURLResponse(
            url: exchange.url,
            statusCode: exchange.response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: exchange.response.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        if let data = exchange.response.data {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}
