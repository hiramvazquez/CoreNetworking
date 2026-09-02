import Foundation

/// Configuration for automatic request retry behavior.
///
/// `maxAttempts` counts TOTAL requests, including the first one:
/// `maxAttempts: 3` means at most 3 requests hit the network.
///
/// Only idempotent HTTP methods are retried by default; non-idempotent
/// requests (POST/PATCH) must opt in per-request via
/// `BaseRequest.allowsNonIdempotentRetry`.
///
/// Backoff is exponential with equal jitter, and a server-provided
/// `Retry-After` (seconds or HTTP-date) takes precedence over the computed
/// delay.
///
/// Delays are `Duration`, not `TimeInterval`: `APIService` sleeps them
/// through an injectable `Clock<Duration>` (`ContinuousClock` in production,
/// `ManualClock` in tests) instead of `Task.sleep` on the real clock — see
/// [Retry](../../README.md#retry) and `CoreNetworkingTestSupport.ManualClock`.
///
/// ## Example
/// ```swift
/// let policy = RetryPolicy(maxAttempts: 3)          // hasta 3 requests
/// let none = RetryPolicy.noRetry                    // exactamente 1 request
/// ```
public struct RetryPolicy: Sendable {
    /// Maximum TOTAL number of requests (including the first). Always ≥ 1.
    public let maxAttempts: Int

    /// Base delay before the first retry.
    public let initialDelay: Duration

    /// Cap for the computed delay.
    public let maxDelay: Duration

    /// Multiplier for exponential backoff.
    public let multiplier: Double

    /// Custom logic to decide whether a failure should be retried.
    ///
    /// Receives the `APIError` and the number of attempts already made
    /// (1 = the first request just failed). Typed on purpose: the predicate
    /// can inspect `code`, `statusCode`, `urlError` or the server body without
    /// casting.
    public let shouldRetry: @Sendable (APIError, Int) -> Bool

    /// Creates a retry policy with exponential backoff + jitter.
    ///
    /// - Parameters:
    ///   - maxAttempts: Total requests allowed (default: 3). Values < 1 are
    ///     clamped to 1 — "cero requests" no es un estado representable.
    ///   - initialDelay: Base delay (default: 500 ms)
    ///   - maxDelay: Delay cap (default: 16 s)
    ///   - multiplier: Backoff multiplier (default: 2.0)
    ///   - shouldRetry: Custom retry predicate (default: `APIError.isRetryable`)
    public init(
        maxAttempts: Int = 3,
        initialDelay: Duration = .milliseconds(500),
        maxDelay: Duration = .seconds(16),
        multiplier: Double = 2.0,
        shouldRetry: @escaping @Sendable (APIError, Int) -> Bool = Self.defaultShouldRetry
    ) {
        self.maxAttempts = Swift.max(1, maxAttempts)
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.shouldRetry = shouldRetry
    }

    /// Deterministic exponential backoff: `min(initialDelay * multiplier^attempt, maxDelay)`.
    ///
    /// - Parameter attempt: 0-based retry index (0 = delay before the 1st retry)
    public func baseDelay(for attempt: Int) -> Duration {
        let scaledSeconds = initialDelay.timeInterval * pow(multiplier, Double(attempt))
        return .seconds(min(scaledSeconds, maxDelay.timeInterval))
    }

    /// Backoff with equal jitter: `base/2 + random(0 ... base/2)`.
    ///
    /// Evita que N clientes que fallaron a la vez reintenten sincronizados.
    public func jitteredDelay(
        for attempt: Int,
        using generator: inout some RandomNumberGenerator
    ) -> Duration {
        let base = baseDelay(for: attempt)
        guard base > .zero else { return .zero }
        let baseSeconds = base.timeInterval
        let half = baseSeconds / 2
        return .seconds(half + TimeInterval.random(in: 0...half, using: &generator))
    }

    /// Backoff with equal jitter using the system RNG.
    public func jitteredDelay(for attempt: Int) -> Duration {
        var generator = SystemRandomNumberGenerator()
        return jitteredDelay(for: attempt, using: &generator)
    }

    /// Default retry predicate: retry only when `APIError.isRetryable`.
    public static func defaultShouldRetry(_ error: APIError, _ attempt: Int) -> Bool {
        error.isRetryable
    }

    // MARK: - Predefined Policies

    /// Exactly one request, no retries.
    public static let noRetry = RetryPolicy(maxAttempts: 1)

    /// Aggressive: up to 5 total requests, longer delays.
    public static let aggressive = RetryPolicy(
        maxAttempts: 5,
        initialDelay: .seconds(1),
        maxDelay: .seconds(30),
        multiplier: 2.0
    )

    /// Conservative: up to 2 total requests, short delays.
    public static let conservative = RetryPolicy(
        maxAttempts: 2,
        initialDelay: .milliseconds(250),
        maxDelay: .seconds(2),
        multiplier: 2.0
    )
}

// NOTA: RetryPolicy NO es Equatable a propósito. `shouldRetry` es un closure y
// no puede compararse; un `==` que lo ignorase declararía iguales dos políticas
// con predicados distintos. Compara los campos numéricos si lo necesitas.
