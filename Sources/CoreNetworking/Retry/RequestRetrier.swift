import Foundation

/// What `APIService` does after a `RequestRetrier` looks at a failed attempt.
///
/// `.retryAfter` OVERRIDES both `RetryPolicy`'s computed backoff and a
/// server `Retry-After` header — it is the retrier's explicit answer to
/// "wait this long", not a suggestion layered under the usual precedence.
public enum RetryDecision: Sendable, Equatable {
    /// This retrier has no opinion about `error` — ask the next retrier, or
    /// fall back to `RetryPolicy` if none is left.
    case doNotRetry
    /// Retry using the usual delay: the server's `Retry-After` if present,
    /// otherwise `RetryPolicy`'s jittered backoff.
    case retry
    /// Retry after EXACTLY `Duration` — ignores `RetryPolicy` and any
    /// server `Retry-After`.
    case retryAfter(Duration)
}

/// Consulted BEFORE `RetryPolicy`, once per failed attempt, in the order
/// `APIService.init(retriers:)` lists them.
///
/// The first retrier whose `retry(_:context:)` does not answer
/// `.doNotRetry` decides — its decision is used as-is, no other retrier and
/// no `RetryPolicy` is consulted for that failure. If every retrier answers
/// `.doNotRetry` (or there are none), `RetryPolicy.shouldRetry` decides
/// instead, same as before `RequestRetrier` existed. Either path is bounded
/// by `RetryPolicy.maxAttempts` — TOTAL requests, retriers included.
///
/// A `.retry`/`.retryAfter` decision sends the exact SAME `BaseRequest`
/// through the pipeline again, starting from `willSend`: an interceptor that
/// reads a token fresh on every call (`BearerTokenInterceptor`) picks up
/// whatever changed since the attempt that failed — e.g. the token
/// `TokenRefreshRetrier` just refreshed.
///
/// ## Example — retry once per new attempt, never on the first
/// ```swift
/// struct SkipFirstRetrier: RequestRetrier {
///     func retry(_ error: APIError, context: RequestContext) async -> RetryDecision {
///         context.attempt == 1 ? .doNotRetry : .retry
///     }
/// }
/// ```
public protocol RequestRetrier: Sendable {
    /// Decides whether to retry after `error`.
    ///
    /// - Parameters:
    ///   - error: The mapped `APIError` for the attempt that just failed.
    ///   - context: Identity/timing for the attempt that failed —
    ///     `context.attempt` is 1-based (the first request is `1`).
    func retry(_ error: APIError, context: RequestContext) async -> RetryDecision
}
