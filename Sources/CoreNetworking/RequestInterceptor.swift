import Foundation
import os

/// Protocol for intercepting and modifying network requests and responses.
///
/// Interceptors allow you to inspect, modify, or log requests/responses
/// as they flow through the networking layer.
///
/// ## Common Use Cases
/// - Request/Response logging
/// - Authentication token injection
/// - Error tracking
/// - Custom headers based on environment
///
/// ## Example - Auth Token Interceptor
/// ```swift
/// struct AuthInterceptor: RequestInterceptor {
///     let tokenProvider: @Sendable () async -> String?
///
///     func willSend(_ request: URLRequest) async -> URLRequest {
///         var modified = request
///         if let token = await tokenProvider() {
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

    /// Called after receiving a response (any status code).
    ///
    /// - Parameters:
    ///   - response: The URLResponse received
    ///   - data: The response data
    func didReceive(_ response: URLResponse, data: Data) async

    /// Called when a request fails — transport errors, invalid responses AND
    /// non-2xx statuses (the mapped `APIError`).
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

// MARK: - Built-in Logging Interceptor

/// Logs requests and responses through `os.Logger` (subsystem "CoreNetworking",
/// category "network").
///
/// Privacy rules (not configurable):
/// - Sensitive headers (Authorization, Cookie, Set-Cookie, api keys, tokens…)
///   are ALWAYS redacted before logging — there is no opt-out.
/// - URLs are logged with `.private` privacy: visible while debugging,
///   redacted in sysdiagnose/console of release builds.
/// - Bodies are only ever logged in DEBUG builds, and only when opted in.
///
/// ## Example
/// ```swift
/// let service = APIService(configuration: config, interceptors: [LoggingInterceptor()])
/// ```
public struct LoggingInterceptor: RequestInterceptor {
    private let includeHeaders: Bool
    private let includeBody: Bool

    /// - Parameters:
    ///   - includeHeaders: Log request headers (redacted). Default: `false`.
    ///   - includeBody: Log bodies (DEBUG builds only). Default: `false`.
    public init(includeHeaders: Bool = false, includeBody: Bool = false) {
        self.includeHeaders = includeHeaders
        self.includeBody = includeBody
    }

    public func willSend(_ request: URLRequest) async -> URLRequest {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "<no url>"
        NetLog.network.debug("→ \(method, privacy: .public) \(url, privacy: .private)")

        if includeHeaders, let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            let redacted = HeaderRedactor.redact(headers)
            NetLog.network.debug("   headers: \(redacted, privacy: .private)")
        }

        #if DEBUG
        if includeBody, let body = request.httpBody,
           let text = String(data: body, encoding: .utf8) {
            NetLog.network.debug("   body: \(text, privacy: .private)")
        }
        #endif

        return request
    }

    public func didReceive(_ response: URLResponse, data: Data) async {
        guard let http = response as? HTTPURLResponse else { return }
        let url = http.url?.absoluteString ?? "<no url>"
        NetLog.network.debug("← \(http.statusCode, privacy: .public) \(url, privacy: .private)")

        #if DEBUG
        if includeBody, let text = String(data: data, encoding: .utf8) {
            NetLog.network.debug("   body: \(text, privacy: .private)")
        }
        #endif
    }

    public func didFail(_ request: URLRequest, error: Error) async {
        let url = request.url?.absoluteString ?? "<no url>"
        NetLog.network.error("✗ \(url, privacy: .private) — \(String(describing: error), privacy: .public)")
    }
}

// NOTA (decisión documentada): el PerformanceInterceptor anterior se ELIMINÓ en
// vez de arreglarse. Su contrato (didReceive solo recibe URLResponse + Data) no
// da identidad de request, así que solo podía correlacionar por URL: dos
// requests concurrentes a la misma URL se pisaban las mediciones, y su limpieza
// solo compilaba en DEBUG (leak del diccionario en Release). Medir bien exige
// cambiar el contrato del interceptor (identidad por request) — rediseño que es
// decisión del owner. Mientras tanto: Instruments (Network) o un interceptor
// propio en la app con el contrato que necesite.
