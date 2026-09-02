import Foundation

/// Refreshes whatever credential the app's `tokenProvider` (e.g. the one
/// `BearerTokenInterceptor` reads) will hand back next.
///
/// Kept as its own protocol — separate from `RequestRetrier` — so an app can
/// swap in its own refresh/deduplication strategy while still using
/// `TokenRefreshRetrier` to wire it into the retry pipeline.
public protocol TokenRefreshing: Sendable {
    /// Refreshes the credential. Throws if the refresh itself fails (expired
    /// refresh token, network error, …) — the caller treats that as "cannot
    /// recover", not as "try again".
    func refreshToken() async throws
}

/// Deduplicates concurrent refreshes: N requests that fail with 401 at the
/// same moment trigger exactly ONE call to the `refresh` closure — every
/// other caller awaits that SAME in-flight attempt instead of starting its
/// own (and a backend refresh token is often single-use: a second concurrent
/// call would invalidate the first).
///
/// `actor` JUSTIFICADO: el estado (¿hay un refresh en vuelo?, a qué `Task`
/// engancharse) se comparte de verdad entre N tasks concurrentes — el caso
/// de uso exacto de un actor, no un lock disfrazado de clase.
///
/// ## Example
/// ```swift
/// let refresher = TokenRefresher {
///     let newToken = try await authClient.refresh()
///     await tokenStore.save(newToken)
/// }
/// let service = APIService(
///     configuration: configuration,
///     interceptors: [BearerTokenInterceptor { await tokenStore.currentToken }],
///     retriers: [TokenRefreshRetrier(refresher: refresher)]
/// )
/// ```
public actor TokenRefresher: TokenRefreshing {
    private let refresh: @Sendable () async throws -> Void
    private var inFlight: Task<Void, any Error>?

    public init(refresh: @escaping @Sendable () async throws -> Void) {
        self.refresh = refresh
    }

    public func refreshToken() async throws {
        if let inFlight {
            try await inFlight.value
            return
        }
        let task = Task { try await refresh() }
        inFlight = task
        defer { inFlight = nil }
        try await task.value
    }
}

/// Adds `Authorization: Bearer <token>` to every request, reading the token
/// FRESH on every `willSend` call — including the one `TokenRefreshRetrier`
/// triggers after a refresh, which is what lets the retried request carry
/// the new token instead of the one that just got a 401.
public struct BearerTokenInterceptor: RequestInterceptor {
    private let tokenProvider: @Sendable () async -> String?

    /// - Parameter tokenProvider: Reads the current token, `nil` when there
    ///   is none (the request goes out without `Authorization`).
    public init(tokenProvider: @escaping @Sendable () async -> String?) {
        self.tokenProvider = tokenProvider
    }

    public func willSend(_ request: URLRequest, context: RequestContext) async throws(APIError) -> URLRequest {
        guard let token = await tokenProvider() else { return request }
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

/// Retries a request once after a 401 by refreshing the token through
/// `refresher` (see `TokenRefresher` for concurrent deduplication).
///
/// Only fires on the FIRST attempt (`context.attempt == 1`): a 401 on a
/// LATER attempt means the just-refreshed token isn't good either, and
/// refreshing again in a loop would never terminate. A refresh failure
/// answers `.doNotRetry` — the original 401 reaches the caller unchanged,
/// with no extra request.
public struct TokenRefreshRetrier: RequestRetrier {
    private let refresher: any TokenRefreshing

    public init(refresher: any TokenRefreshing) {
        self.refresher = refresher
    }

    public func retry(_ error: APIError, context: RequestContext) async -> RetryDecision {
        guard error.statusCode == 401, context.attempt == 1 else { return .doNotRetry }
        do {
            try await refresher.refreshToken()
            return .retry
        } catch {
            return .doNotRetry
        }
    }
}
