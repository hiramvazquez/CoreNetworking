#if canImport(XCTest) || DEBUG
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Thread-Safe Mock Storage

/// Thread-safe actor for storing mock network exchanges.
///
/// This actor ensures that mock requests can be safely accessed from multiple threads
/// without data races, making it compatible with Swift 6 strict concurrency.
actor MockStorage {
    private var mockRequests: Set<MockNetworkExchange> = []

    func insert(_ mock: MockNetworkExchange) {
        mockRequests.insert(mock)
    }

    func remove(for url: URL) -> MockNetworkExchange? {
        guard let index = mockRequests.firstIndex(where: { $0.urlRequest.url == url }) else {
            return nil
        }
        return mockRequests.remove(at: index)
    }

    func contains(url: URL) -> Bool {
        mockRequests.contains(where: { $0.urlRequest.url == url })
    }

    func removeAll() {
        mockRequests.removeAll()
    }

    func count() -> Int {
        mockRequests.count
    }
}

// MARK: - MockURLProtocol

/// URLProtocol subclass for intercepting and mocking network requests in tests.
///
/// This protocol allows you to inject mock responses for testing without
/// hitting real network endpoints.
///
/// ## Thread Safety
/// Uses an actor-based storage system to ensure thread-safe access to mock data,
/// compatible with Swift 6 strict concurrency.
///
/// ## Example
/// ```swift
/// // Setup mock response
/// let mockData = """
/// {"id": 1, "title": "Test Game"}
/// """.data(using: .utf8)!
///
/// let url = URL(string: "https://api.example.com/games")!
/// MockAPIHelper.setupMock(for: url, data: mockData)
///
/// // Configure URLSession to use mock
/// let config = URLSessionConfiguration.ephemeral
/// config.protocolClasses = [MockURLProtocol.self]
/// let session = URLSession(configuration: config)
///
/// // Requests will now return mock data
/// let (data, response) = try await session.data(from: url)
/// ```
public final class MockURLProtocol: URLProtocol {
    /// Thread-safe storage for mock requests
    nonisolated(unsafe) private static let storage = MockStorage()

    /// Legacy property for backward compatibility (deprecated).
    ///
    /// **Warning**: This property is not thread-safe. Use `MockAPIHelper.setupMock()`
    /// instead, which uses the thread-safe actor storage.
    @available(*, deprecated, message: "Use MockAPIHelper.setupMock() for thread-safe mock injection")
    public static var mockRequests: Set<MockNetworkExchange> {
        get {
            // Note: This is unsafe and only provided for backward compatibility
            []
        }
        set {
            // Note: This is unsafe and only provided for backward compatibility
            // New code should use MockAPIHelper.setupMock()
        }
    }

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

        // Fetch mock from thread-safe storage
        Task {
            guard let mock = await Self.storage.remove(for: url) else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }

            // Process the response
            if let error = mock.error {
                client?.urlProtocol(self, didFailWithError: error)
            } else {
                client?.urlProtocol(self, didReceive: mock.urlResponse, cacheStoragePolicy: .notAllowed)
                if let data = mock.response.data {
                    client?.urlProtocol(self, didLoad: data)
                }
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    public override func stopLoading() {}

    // MARK: - Internal Methods (for MockAPIHelper)

    /// Inserts a mock into thread-safe storage.
    internal static func insertMock(_ mock: MockNetworkExchange) async {
        await storage.insert(mock)
    }

    /// Checks if a mock exists for the given URL.
    internal static func containsMock(for url: URL) async -> Bool {
        await storage.contains(url: url)
    }

    /// Removes all mocks from storage.
    internal static func removeAllMocks() async {
        await storage.removeAll()
    }
}

// MARK: - MockResponse

/// Represents a mock HTTP response.
public struct MockResponse: Hashable, Sendable {
    public let statusCode: Int
    public let data: Data?

    public init(statusCode: Int, data: Data? = nil) {
        self.statusCode = statusCode
        self.data = data
    }
}

// MARK: - MockNetworkExchange

/// Represents a complete mock network exchange (request + response + error).
public struct MockNetworkExchange: Hashable, Sendable {
    public static func == (lhs: MockNetworkExchange, rhs: MockNetworkExchange) -> Bool {
        lhs.urlRequest.url == rhs.urlRequest.url &&
        lhs.response.data == rhs.response.data &&
        lhs.response.statusCode == rhs.response.statusCode
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(urlRequest.url)
        hasher.combine(response.statusCode)
        if let data = response.data { hasher.combine(data) }
    }

    public let urlRequest: URLRequest
    public let response: MockResponse
    public let error: Error?

    public init(urlRequest: URLRequest, response: MockResponse, error: Error? = nil) {
        self.urlRequest = urlRequest
        self.response = response
        self.error = error
    }

    public var urlResponse: HTTPURLResponse {
        HTTPURLResponse(
            url: urlRequest.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}

// MARK: - TestCodeChecker (Deprecated)

/// Deprecated test utility. Use MockAPIHelper instead.
@available(*, deprecated, message: "Use MockAPIHelper for setting up mocks")
public enum TestCodeChecker {
    public enum TestApiCode: Int {
        case success = 200
        case error = 400
    }

    public static let code: TestApiCode = .success
}
#endif
