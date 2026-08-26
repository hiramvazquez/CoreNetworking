#if canImport(XCTest) || DEBUG
import Foundation

/// Helper utilities for setting up mock network responses in tests.
///
/// This helper provides a convenient API for injecting mock responses
/// without dealing with URLProtocol internals.
///
/// ## Thread Safety
/// All methods use the thread-safe actor-based storage from `MockURLProtocol`,
/// ensuring compatibility with Swift 6 strict concurrency.
///
/// ## Example - Success Response
/// ```swift
/// let mockData = """
/// {"id": 1, "title": "Test Game"}
/// """.data(using: .utf8)!
///
/// let url = URL(string: "https://api.example.com/games")!
/// MockAPIHelper.setupMock(for: url, data: mockData)
/// ```
///
/// ## Example - Error Response
/// ```swift
/// let url = URL(string: "https://api.example.com/games")!
/// MockAPIHelper.setupMock(
///     for: url,
///     statusCode: 404,
///     error: URLError(.notConnectedToInternet)
/// )
/// ```
///
/// ## Example - In Tests
/// ```swift
/// final class MyNetworkTests: XCTestCase {
///     func testFetchGames() async throws {
///         // Setup mock
///         let mockJSON = """
///         [{"id": 1, "title": "Game 1"}]
///         """.data(using: .utf8)!
///
///         MockAPIHelper.setupMock(
///             for: URL(string: "https://api.test.com/games")!,
///             data: mockJSON
///         )
///
///         // Execute request
///         let service = APIService()
///         let games: [Game] = try await service.execute(request: GetGamesRequest())
///
///         // Verify
///         XCTAssertEqual(games.count, 1)
///     }
/// }
/// ```
public struct MockAPIHelper {
    /// Sets up a mock response for the specified URL.
    ///
    /// - Parameters:
    ///   - url: The URL to intercept
    ///   - statusCode: HTTP status code (default: 200)
    ///   - data: Response body data
    ///   - error: Optional error to return instead of success
    public static func setupMock(
        for url: URL,
        statusCode: Int = 200,
        data: Data? = nil,
        error: Error? = nil
    ) {
        let mock = MockNetworkExchange(
            urlRequest: URLRequest(url: url),
            response: MockResponse(statusCode: statusCode, data: data),
            error: error
        )

        Task {
            await MockURLProtocol.insertMock(mock)
        }
    }

    /// Sets up a mock JSON response for the specified URL.
    ///
    /// - Parameters:
    ///   - url: The URL to intercept
    ///   - json: JSON string to return as response
    ///   - statusCode: HTTP status code (default: 200)
    public static func setupMockJSON(
        for url: URL,
        json: String,
        statusCode: Int = 200
    ) {
        let data = json.data(using: .utf8)
        setupMock(for: url, statusCode: statusCode, data: data)
    }

    /// Sets up a mock error response for the specified URL.
    ///
    /// - Parameters:
    ///   - url: The URL to intercept
    ///   - error: The error to return
    public static func setupMockError(
        for url: URL,
        error: Error
    ) {
        let mock = MockNetworkExchange(
            urlRequest: URLRequest(url: url),
            response: MockResponse(statusCode: 500),
            error: error
        )

        Task {
            await MockURLProtocol.insertMock(mock)
        }
    }

    /// Checks if a mock exists for the given URL.
    ///
    /// - Parameter url: The URL to check
    /// - Returns: True if a mock is registered for this URL
    public static func hasMock(for url: URL) async -> Bool {
        await MockURLProtocol.containsMock(for: url)
    }

    /// Removes all registered mocks.
    ///
    /// Useful for cleaning up between tests.
    public static func removeAllMocks() async {
        await MockURLProtocol.removeAllMocks()
    }
}
#endif
