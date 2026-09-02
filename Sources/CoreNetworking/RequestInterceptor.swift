import Foundation
import os

/// Identity + timing for ONE attempt through the pipeline.
///
/// The SAME `RequestContext` flows through `willSend` → `didReceive`/`didFail`
/// for that attempt — `id` correlates the three calls in logs even when
/// several requests race. A retry builds a NEW context (new `id`,
/// `attempt + 1`, fresh `startedAt`); it never reuses the failed attempt's.
public struct RequestContext: Sendable {
    /// Unique per attempt. Two different attempts of the SAME logical
    /// request (a retry) get two different `id`s — correlate them with
    /// `attempt`, not `id`.
    public let id: UUID

    /// The request as built for this attempt, before any interceptor's
    /// `willSend` mutates it. Each interceptor in the chain still receives
    /// the progressively-mutated request as its own `request:` parameter;
    /// this is the starting point for the WHOLE attempt.
    public let request: URLRequest

    /// 1-based: the first try is `1`, the first retry is `2`, and so on.
    public let attempt: Int

    /// When this attempt started (`ContinuousClock`, monotonic — not a wall
    /// clock `Date`). `LoggingInterceptor` and any custom metrics interceptor
    /// measure duration against it.
    public let startedAt: ContinuousClock.Instant

    public init(
        id: UUID = UUID(),
        request: URLRequest,
        attempt: Int,
        startedAt: ContinuousClock.Instant = ContinuousClock.now
    ) {
        self.id = id
        self.request = request
        self.attempt = attempt
        self.startedAt = startedAt
    }
}

/// Protocol for intercepting and modifying network requests and responses.
///
/// Interceptors inspect, modify, or ABORT requests as they flow through the
/// pipeline, and observe the response (or failure) that comes back.
///
/// ## Common Use Cases
/// - Request/Response logging (`LoggingInterceptor`, included)
/// - Authentication token injection (`BearerTokenInterceptor`, included —
///   see `Auth/TokenRefresher.swift` for the matching retry side)
/// - Aborting a request before it is sent (missing credential, disabled
///   feature flag) via `willSend` throwing
/// - Error tracking / metrics, correlated by `context.id`
///
/// ## Example — auth token interceptor that can abort
/// ```swift
/// struct AuthInterceptor: RequestInterceptor {
///     let tokenProvider: @Sendable () async -> String?
///
///     func willSend(_ request: URLRequest, context: RequestContext) async throws(APIError) -> URLRequest {
///         guard let token = await tokenProvider() else {
///             throw APIError(code: .interceptor, request: .init(request), underlying: MissingTokenError())
///         }
///         var modified = request
///         modified.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
///         return modified
///     }
/// }
/// ```
public protocol RequestInterceptor: Sendable {
    /// Called before a request is sent — return a modified request, the
    /// original, or THROW to abort it.
    ///
    /// A throw aborts the attempt before the transport ever sees the
    /// request: `APIService` wraps whatever is thrown in
    /// `APIError(code: .interceptor, underlying: <what you threw>)`, calls
    /// `didFail` exactly once with it, and — same as any other failure —
    /// offers it to `retriers` / `RetryPolicy` before it reaches the caller.
    ///
    /// - Parameters:
    ///   - request: The URLRequest about to be sent (already mutated by any
    ///     earlier interceptor in the chain).
    ///   - context: Identity/timing for this attempt. The same value across
    ///     every interceptor's `willSend` for this attempt, and later passed
    ///     to `didReceive`/`didFail`.
    /// - Returns: The URLRequest to actually send (can be modified).
    func willSend(_ request: URLRequest, context: RequestContext) async throws(APIError) -> URLRequest

    /// Called after receiving a response — any status code, 2xx included.
    /// Not called when the transport failed or the response isn't a valid
    /// `HTTPURLResponse` (those go straight to `didFail`).
    ///
    /// - Parameters:
    ///   - response: The HTTP response received.
    ///   - data: The response body, exactly as received.
    ///   - context: Same value `willSend` received for this attempt.
    func didReceive(_ response: HTTPURLResponse, data: Data, context: RequestContext) async

    /// Called when an attempt fails — transport errors, an invalid response,
    /// a non-2xx status, or an interceptor's own `willSend` throwing. Always
    /// the mapped `APIError`, so implementations read `code`, `statusCode`
    /// or `response` without casting. Called exactly once per failed
    /// attempt, regardless of which stage failed.
    ///
    /// - Parameters:
    ///   - error: The error that occurred.
    ///   - context: Same value `willSend` received for this attempt.
    func didFail(_ error: APIError, context: RequestContext) async
}

// MARK: - Default Implementations

public extension RequestInterceptor {
    func willSend(_ request: URLRequest, context: RequestContext) async throws(APIError) -> URLRequest {
        request
    }

    func didReceive(_ response: HTTPURLResponse, data: Data, context: RequestContext) async {
        // Default: no-op
    }

    func didFail(_ error: APIError, context: RequestContext) async {
        // Default: no-op
    }
}

// MARK: - Built-in Logging Interceptor

/// Logs requests and responses through `os.Logger` (subsystem
/// "<bundle id>.corenetworking", category "network").
///
/// Privacy rules (not configurable):
/// - Sensitive headers (Authorization, Cookie, Set-Cookie, api keys, tokens…)
///   are ALWAYS redacted before logging — there is no opt-out.
/// - URLs are logged with `.private` privacy: visible while debugging,
///   redacted in sysdiagnose/console of release builds.
/// - Bodies are only ever logged in DEBUG builds, and only when opted in.
/// - `context.id`, method, status and elapsed milliseconds are `.public` —
///   `error.description`/`code` too, but NEVER `error.underlying`'s message
///   (a server body can carry PII, e.g. "user john@x.com not found").
///
/// `context.startedAt` (`ContinuousClock`, monotonic) is what measures
/// duration — not a wall-clock `Date` a request-scoped dictionary would have
/// needed to age out by hand.
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

    public func willSend(_ request: URLRequest, context: RequestContext) async throws(APIError) -> URLRequest {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "<no url>"
        NetLog.network.debug(
            "→ [\(context.id.uuidString, privacy: .public)] \(method, privacy: .public) \(url, privacy: .private)"
        )

        if includeHeaders, let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            let redacted = HeaderRedactor.redact(headers)
            NetLog.network.debug("   headers: \(redacted, privacy: .private)")
        }

        #if DEBUG
        if includeBody, let body = request.httpBody,
            let text = String(data: body, encoding: .utf8)
        {
            NetLog.network.debug("   body: \(text, privacy: .private)")
        }
        #endif

        return request
    }

    public func didReceive(_ response: HTTPURLResponse, data: Data, context: RequestContext) async {
        let url = response.url?.absoluteString ?? "<no url>"
        let elapsedMS = Self.elapsedMilliseconds(since: context.startedAt)
        NetLog.network.debug(
            "← [\(context.id.uuidString, privacy: .public)] \(response.statusCode, privacy: .public) \(elapsedMS, privacy: .public)ms \(url, privacy: .private)"
        )

        #if DEBUG
        if includeBody, let text = String(data: data, encoding: .utf8) {
            NetLog.network.debug("   body: \(text, privacy: .private)")
        }
        #endif
    }

    public func didFail(_ error: APIError, context: RequestContext) async {
        // Solo `code` y `statusCode` son públicos: ni el body ni `underlying`
        // salen con `.public` (pueden llevar texto del servidor o del error).
        let status = error.statusCode.map(String.init) ?? "-"
        let elapsedMS = Self.elapsedMilliseconds(since: context.startedAt)
        NetLog.network.error(
            "✗ [\(context.id.uuidString, privacy: .public)] code: \(error.code.rawValue, privacy: .public) status: \(status, privacy: .public) \(elapsedMS, privacy: .public)ms"
        )
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int((elapsed.timeInterval * 1000).rounded())
    }
}
