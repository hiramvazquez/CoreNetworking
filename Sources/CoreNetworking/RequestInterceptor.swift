import Foundation

/// Protocol for intercepting and modifying network requests and responses.
///
/// Interceptors allow you to inspect, modify, or log requests/responses
/// as they flow through the networking layer.
///
/// ## Common Use Cases
/// - Request/Response logging
/// - Authentication token injection
/// - Performance monitoring
/// - Error tracking
/// - Custom headers based on environment
///
/// ## Example - Logging Interceptor
/// ```swift
/// struct LoggingInterceptor: RequestInterceptor {
///     func willSend(_ request: URLRequest) async -> URLRequest {
///         print("📤 \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")")
///         return request
///     }
///
///     func didReceive(_ response: URLResponse, data: Data) async {
///         if let http = response as? HTTPURLResponse {
///             print("📥 Status: \(http.statusCode)")
///         }
///     }
/// }
/// ```
///
/// ## Example - Auth Token Interceptor
/// ```swift
/// struct AuthInterceptor: RequestInterceptor {
///     let tokenProvider: () -> String?
///
///     func willSend(_ request: URLRequest) async -> URLRequest {
///         var modified = request
///         if let token = tokenProvider() {
///             modified.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
///         }
///         return modified
///     }
/// }
/// ```
public protocol RequestInterceptor: Sendable {
    /// Called before a request is sent. Return a modified request or the original.
    ///
    /// - Parameter request: The URLRequest about to be sent
    /// - Returns: The URLRequest to actually send (can be modified)
    func willSend(_ request: URLRequest) async -> URLRequest

    /// Called after receiving a response (both success and failure).
    ///
    /// - Parameters:
    ///   - response: The URLResponse received
    ///   - data: The response data
    func didReceive(_ response: URLResponse, data: Data) async

    /// Called when a request fails with an error.
    ///
    /// - Parameters:
    ///   - request: The original request
    ///   - error: The error that occurred
    func didFail(_ request: URLRequest, error: Error) async
}

// MARK: - Default Implementations

public extension RequestInterceptor {
    func willSend(_ request: URLRequest) async -> URLRequest {
        request
    }

    func didReceive(_ response: URLResponse, data: Data) async {
        // Default: no-op
    }

    func didFail(_ request: URLRequest, error: Error) async {
        // Default: no-op
    }
}

// MARK: - Built-in Interceptors

/// Logs all requests and responses to console (DEBUG only).
///
/// ## Example
/// ```swift
/// let service = APIService(interceptors: [LoggingInterceptor()])
/// ```
public struct LoggingInterceptor: RequestInterceptor {
    private let includeHeaders: Bool
    private let includeBody: Bool

    public init(includeHeaders: Bool = true, includeBody: Bool = false) {
        self.includeHeaders = includeHeaders
        self.includeBody = includeBody
    }

    public func willSend(_ request: URLRequest) async -> URLRequest {
        #if DEBUG
        print("📤 [REQUEST] \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")")

        if includeHeaders, let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            print("   Headers: \(headers)")
        }

        if includeBody, let body = request.httpBody, let json = try? JSONSerialization.jsonObject(with: body) {
            print("   Body: \(json)")
        }
        #endif

        return request
    }

    public func didReceive(_ response: URLResponse, data: Data) async {
        #if DEBUG
        if let http = response as? HTTPURLResponse {
            let emoji = (200..<300).contains(http.statusCode) ? "✅" : "❌"
            print("\(emoji) [RESPONSE] \(http.statusCode) - \(http.url?.absoluteString ?? "")")

            if includeBody, let json = try? JSONSerialization.jsonObject(with: data) {
                print("   Body: \(json)")
            }
        }
        #endif
    }

    public func didFail(_ request: URLRequest, error: Error) async {
        #if DEBUG
        print("❌ [ERROR] \(request.url?.absoluteString ?? "") - \(error.localizedDescription)")
        #endif
    }
}

/// Measures and logs request duration (DEBUG only).
///
/// ## Example
/// ```swift
/// let service = APIService(interceptors: [PerformanceInterceptor()])
/// ```
public actor PerformanceInterceptor: RequestInterceptor {
    private var requestStartTimes: [URL: Date] = [:]

    public init() {}

    public func willSend(_ request: URLRequest) async -> URLRequest {
        if let url = request.url {
            requestStartTimes[url] = Date()
        }
        return request
    }

    public func didReceive(_ response: URLResponse, data: Data) async {
        #if DEBUG
        if let url = response.url, let startTime = requestStartTimes[url] {
            let duration = Date().timeIntervalSince(startTime)
            print("⏱️ [PERF] \(url.absoluteString) - \(String(format: "%.3f", duration))s")
            requestStartTimes[url] = nil
        }
        #endif
    }

    public func didFail(_ request: URLRequest, error: Error) async {
        #if DEBUG
        if let url = request.url, let startTime = requestStartTimes[url] {
            let duration = Date().timeIntervalSince(startTime)
            print("⏱️ [PERF] \(url.absoluteString) - Failed after \(String(format: "%.3f", duration))s")
            requestStartTimes[url] = nil
        }
        #endif
    }
}
