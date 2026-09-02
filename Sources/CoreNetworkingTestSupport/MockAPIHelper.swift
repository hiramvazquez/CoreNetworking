import Foundation
import CoreNetworking

/// Convenience helpers over `MockURLProtocol.register`.
///
/// All methods are synchronous and deterministic: when they return, the mock
/// is already visible to the next request.
public enum MockAPIHelper {
    /// Registers a mock response for `method` + `url`.
    public static func setupMock(
        for url: URL,
        method: HTTPMethod = .get,
        statusCode: Int = 200,
        data: Data? = nil,
        headers: [String: String] = [:]
    ) {
        MockURLProtocol.register(
            MockNetworkExchange(
                method: method,
                url: url,
                response: MockResponse(statusCode: statusCode, data: data, headers: headers)
            )
        )
    }

    /// Registers a mock JSON response for `method` + `url`.
    public static func setupMockJSON(
        for url: URL,
        method: HTTPMethod = .get,
        json: String,
        statusCode: Int = 200
    ) {
        setupMock(for: url, method: method, statusCode: statusCode, data: Data(json.utf8))
    }

    /// Registers a transport-level error (e.g. timeout) for `method` + `url`.
    public static func setupMockError(
        for url: URL,
        method: HTTPMethod = .get,
        error: URLError
    ) {
        MockURLProtocol.register(
            MockNetworkExchange(
                method: method,
                url: url,
                response: MockResponse(statusCode: 500),
                error: error
            )
        )
    }

    /// Registers a sequence of responses for `method` + `url`, consumed in
    /// order; the last one repeats once exhausted. Use it to simulate a
    /// "fails then succeeds" scenario (e.g. 500, 500, 200) through the real
    /// URL loading system — for unit tests, prefer `InMemoryTransport`.
    public static func setupMockSequence(
        for url: URL,
        method: HTTPMethod = .get,
        responses: [MockResponse]
    ) {
        MockURLProtocol.register(
            MockNetworkExchange(method: method, url: url, responses: responses)
        )
    }

    /// Removes all registered mocks and recorded requests.
    /// Call it between tests.
    public static func removeAllMocks() {
        MockURLProtocol.removeAll()
    }
}
