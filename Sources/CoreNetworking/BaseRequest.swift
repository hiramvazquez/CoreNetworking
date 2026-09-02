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
    var timeout: Duration { get }

    /// Opt-in to retry non-idempotent methods (POST/PATCH).
    ///
    /// Default `false`: retrying a non-idempotent request can duplicate its
    /// effect (double charge, double insert). Set `true` ONLY when the
    /// endpoint is safe to repeat (e.g. idempotency keys server-side).
    var allowsNonIdempotentRetry: Bool { get }
}

// MARK: - Default Implementations

public extension BaseRequest {
    var headers: [String: String] { [:] }
    var body: Body? { nil }
    var queryItems: [URLQueryItem] { [] }
    var timeout: Duration { .seconds(30) }
    var allowsNonIdempotentRetry: Bool { false }
}

// MARK: - Empty

/// Decoded response for a request that doesn't declare one: `Response`'s
/// default. Also what `execute` returns for a 204/205 (or any 2xx with an
/// empty body) when the request's declared `Response` IS `Empty` — a request
/// that declares a real `Response` and gets an empty body back is a decoding
/// error, not `Empty()`.
public struct Empty: Decodable, Sendable {
    public init() {}
}
