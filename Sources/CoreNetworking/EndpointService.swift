/// A convenient template for a `*Service` (`ARQUITECTURA-KIT-2026-09-02.md` §1-2): the
/// architecture's rule is "one `Service` = one API call, with its own `BaseRequest`" — this
/// protocol is that shape written once, not a requirement `Service`s must satisfy. A
/// `Service` that genuinely needs two requests (e.g. paginating internally before handing
/// back one page) is free to skip `EndpointService` and call `api.execute` directly; nothing
/// else in this package or in AppFoundation depends on `EndpointService` existing.
///
/// ## Shape
///
/// ```swift
/// protocol LoginServicing: Sendable {
///     func login(email: String, password: String) async throws(APIError) -> Session
/// }
///
/// struct LoginRequest: BaseRequest {
///     struct Response: Decodable, Sendable { let token: String }
///     let path = "/login"
///     let method = HTTPMethod.post
///     let body: Body?
///
///     struct Body: Encodable, Sendable {
///         let email: String
///         let password: String
///     }
/// }
///
/// struct LoginService: LoginServicing, EndpointService {
///     let api: any APIServiceProtocol
///
///     func login(email: String, password: String) async throws(APIError) -> Session {
///         let response = try await call(LoginRequest(body: .init(email: email, password: password)))
///         return Session(token: response.token)
///     }
/// }
/// ```
///
/// A `Service` holds the ONLY reference to `APIServiceProtocol`/`BaseRequest` in a
/// feature: `Logic` never imports CoreNetworking, it depends on `any LoginServicing`
/// through `init`, exactly the same way it depends on `any XxxStoring` for local
/// persistence (`ARQUITECTURA-KIT-2026-09-02.md` §1, rule 3).
///
/// `Sendable`, like `APIServiceProtocol` itself: a `Service` conformance is typically a
/// `struct` holding just its `api`, so tests substitute `MockAPIService`/`InMemoryTransport`
/// through the SAME `init(api:)` production code uses — no `Service` subclass, no partial
/// mock.
public protocol EndpointService: Sendable {
    /// The single `APIServiceProtocol` every `Service` in the app is built on
    /// (`ARQUITECTURA-KIT-2026-09-02.md` §1: "cada llamada a API es un Service … que usa
    /// el único `APIService`"). Injected through `init`, always as the protocol — never
    /// the concrete `APIService` type.
    var api: any APIServiceProtocol { get }
}

extension EndpointService {
    /// Executes `request` against `api` and returns its decoded `Response` — the one line
    /// an `EndpointService` conformance needs per API call, instead of writing
    /// `try await api.execute(request)` at every call site.
    ///
    /// - Parameter request: The request to execute.
    /// - Returns: `request`'s declared `Response`, decoded.
    /// - Throws: `APIError` if the request fails or the response cannot be decoded.
    public func call<Request: BaseRequest>(
        _ request: Request
    ) async throws(APIError) -> Request.Response {
        try await api.execute(request)
    }
}
