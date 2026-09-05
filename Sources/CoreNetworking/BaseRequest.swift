import Foundation

/// HTTP method. Lowercase cases, `rawValue` in uppercase — la convención de
/// Swift (y de `HTTPTypes` de Apple), no la del wire format.
public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"

    /// Whether the method is idempotent per RFC 9110 (safe to retry).
    ///
    /// POST and PATCH are not: retrying them can duplicate effects, so they
    /// only retry when the request opts in (`allowsNonIdempotentRetry`).
    public var isIdempotent: Bool {
        switch self {
        case .get, .head, .put, .delete, .options: true
        case .post, .patch: false
        }
    }
}

/// A network endpoint as a complete, self-describing type: what to ask
/// (`path`, `method`, `body`, `queryItems`) and what to expect back
/// (`Response`). No boilerplate `typealias` for a marker protocol on every
/// GET, and no ambiguity at the call site about what `execute` returns.
///
/// ## Example — GET, no body, no response to decode
/// ```swift
/// struct GetGames: BaseRequest {
///     let path = "/games"
///     let method = HTTPMethod.get
/// }
/// // execute(GetGames()) -> Empty
/// ```
///
/// ## Example — GET with a typed response
/// ```swift
/// struct GetGames: BaseRequest {
///     struct Response: Decodable, Sendable { let games: [Game] }
///     let path = "/games"
///     let method = HTTPMethod.get
/// }
/// // execute(GetGames()) -> GetGames.Response
/// ```
///
/// ## Example — POST with a typed body and response
/// ```swift
/// struct CreateGame: BaseRequest {
///     struct Body: Encodable, Sendable { let title: String }
///     struct Response: Decodable, Sendable { let id: String }
///
///     let path = "/games"
///     let method = HTTPMethod.post
///     let body: Body?
///
///     init(title: String) { self.body = Body(title: title) }
/// }
/// ```
/// How authentication interceptors should treat one request.
///
/// Surfaced on `RequestContext.authenticationPolicy` — not just read by
/// `BearerTokenInterceptor`, but available to ANY interceptor in the chain,
/// so a custom API-key or multi-tenant credential interceptor can honor the
/// same declaration instead of inventing its own.
public enum RequestAuthenticationPolicy: Sendable, Equatable {
    /// Default: an authentication interceptor MAY attach its credential to
    /// this request, but must never overwrite an `Authorization` header
    /// (or similar) this specific request declared EXPLICITLY via
    /// `BaseRequest.headers` — see `BearerTokenInterceptor.willSend` and
    /// `RequestContext.explicitHeaderFields`. It DOES overwrite one that
    /// only got there because `NetworkingConfiguration.defaultHeaders` set
    /// it: that value is AMBIENT (a static placeholder captured once, when
    /// the configuration was built), not a per-endpoint decision, and an
    /// authentication interceptor's whole job is to supply the credential
    /// that changes — a team pairing a `defaultHeaders` placeholder with a
    /// real `BearerTokenInterceptor` gets the live token, not the
    /// placeholder. Exactly the behavior every `BaseRequest` had before this
    /// property existed, minus the bug where an explicit `Authorization`
    /// got clobbered anyway.
    case automatic

    /// No AMBIENT credential reaches this request, regardless of whether
    /// one is available. "Ambient" means anything applied to every request
    /// without this one asking for it: `NetworkingConfiguration
    /// .defaultHeaders` (a fixed API key or bearer token set once, globally)
    /// and whatever an authentication interceptor would otherwise attach —
    /// both are stripped/skipped for a small, fixed set of credential
    /// header names (`Authorization`, `Proxy-Authorization`, `Cookie`,
    /// `X-Api-Key` — see `APIService.ambientCredentialHeaderNames`).
    ///
    /// An `Authorization` (or other credential header) THIS request set
    /// itself, via its own `headers`, is NOT ambient — it's what whoever
    /// wrote this specific endpoint declared on purpose (e.g. a partner's
    /// API key for a third-party host) — and survives untouched.
    ///
    /// For:
    /// - A login/signup endpoint — the stale token from a previous session
    ///   has no business being sent to it.
    /// - The token-refresh endpoint itself — sending the very token being
    ///   replaced (already expired, or the reason for the 401) is pointless
    ///   and can itself trigger the failure it's meant to fix.
    /// - A request to a third-party or partner host — leaking the app's own
    ///   `Authorization` there is a credential leak, not a convenience. This
    ///   is exactly the case a fixed API key in `defaultHeaders` would
    ///   otherwise leak through, since `defaultHeaders` applies to every
    ///   request regardless of host.
    case none
}

public protocol BaseRequest: Sendable {
    /// Request body, encoded with `NetworkingConfiguration.makeEncoder`.
    /// Defaults to `Never`: a request that sends no body simply doesn't
    /// declare one.
    associatedtype Body: Encodable & Sendable = Never

    /// Expected response. Defaults to `Empty`: a request that doesn't
    /// declare one gets `Empty()` back regardless of what the server sends —
    /// see `Empty` for the 204/empty-body handling.
    associatedtype Response: Decodable & Sendable = Empty

    /// Endpoint path, relative to `NetworkingConfiguration.baseURL`.
    var path: String { get }

    /// HTTP method.
    var method: HTTPMethod { get }

    /// Headers specific to this request. Merged over
    /// `NetworkingConfiguration.defaultHeaders` and the package's own
    /// `Accept`/`Content-Type` — this request's value always wins. Default: `[:]`.
    var headers: [String: String] { get }

    /// Request body. `nil` (the default) sends no body and omits
    /// `Content-Type`.
    var body: Body? { get }

    /// Query items appended to `path`. Default: `[]`.
    var queryItems: [URLQueryItem] { get }

    /// Request timeout. Default: 30 seconds.
    ///
    /// This is `URLRequest.timeoutInterval`: an INACTIVITY timeout between packets, not a
    /// ceiling on how long the whole request may take. A server that keeps dribbling bytes
    /// never trips it.
    ///
    /// - Important: with `waitsForConnectivity` enabled — which
    ///   `NetworkingConfiguration.defaultSessionConfiguration()` does — this timeout is
    ///   suppressed entirely against a connected server that simply sends nothing.
    ///   Measured against a real host, not inferred: see `LiveNetworkTests`. The effective
    ///   ceiling in that case is the session's `timeoutIntervalForResource`, which
    ///   `NetworkingConfiguration.enforceSecurityFloor(on:)` pins to 60 seconds — Foundation's
    ///   own default is 7 days.
    var timeout: Duration { get }

    /// Opt-in to retry non-idempotent methods (POST/PATCH).
    ///
    /// Default `false`: retrying a non-idempotent request can duplicate its
    /// effect (double charge, double insert). Set `true` ONLY when the
    /// endpoint is safe to repeat (e.g. idempotency keys server-side).
    var allowsNonIdempotentRetry: Bool { get }

    /// How authentication interceptors should treat this request — see
    /// `RequestAuthenticationPolicy`. Default: `.automatic`, identical to
    /// this package's behavior before this property existed. See
    /// <doc:Authentication> for the full header-precedence rules.
    var authenticationPolicy: RequestAuthenticationPolicy { get }
}

// MARK: - Default Implementations

public extension BaseRequest {
    var headers: [String: String] { [:] }
    var body: Body? { nil }
    var queryItems: [URLQueryItem] { [] }
    var timeout: Duration { .seconds(30) }
    var allowsNonIdempotentRetry: Bool { false }
    var authenticationPolicy: RequestAuthenticationPolicy { .automatic }
}

// MARK: - Empty

/// Decoded response for a request that doesn't declare one: `Response`'s
/// default. Also what `execute` returns for a 204/205 (or any 2xx with an
/// empty body) when the request's declared `Response` IS `Empty` — a request
/// that declares a real `Response` and gets an empty body back is a decoding
/// error, not `Empty()`.
public struct Empty: Decodable, Sendable, Equatable {
    public init() {}
}
