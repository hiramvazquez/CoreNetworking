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
/// ## Example
/// ```swift
/// let policy = RetryPolicy(maxAttempts: 3)          // hasta 3 requests
/// let none = RetryPolicy.noRetry                    // exactamente 1 request
/// ```
public struct RetryPolicy: Sendable {
    /// Maximum TOTAL number of requests (including the first). Always ≥ 1.
    public let maxAttempts: Int

    /// Base delay before the first retry (in seconds).
    public let initialDelay: TimeInterval

    /// Cap for the computed delay (in seconds).
    public let maxDelay: TimeInterval

    /// Multiplier for exponential backoff.
    public let multiplier: Double

    /// Custom logic to decide whether a failure should be retried.
    ///
    /// Receives the error and the number of attempts already made
    /// (1 = the first request just failed).
    public let shouldRetry: @Sendable (Error, Int) -> Bool

    /// Creates a retry policy with exponential backoff + jitter.
    ///
    /// - Parameters:
    ///   - maxAttempts: Total requests allowed (default: 3). Values < 1 are
    ///     clamped to 1 — "cero requests" no es un estado representable.
    ///   - initialDelay: Base delay in seconds (default: 0.5)
    ///   - maxDelay: Delay cap in seconds (default: 16.0)
    ///   - multiplier: Backoff multiplier (default: 2.0)
    ///   - shouldRetry: Custom retry predicate (default: `APIError.isRetryable`)
    public init(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 0.5,
        maxDelay: TimeInterval = 16.0,
        multiplier: Double = 2.0,
        shouldRetry: @escaping @Sendable (Error, Int) -> Bool = Self.defaultShouldRetry
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
    public func baseDelay(for attempt: Int) -> TimeInterval {
        min(initialDelay * pow(multiplier, Double(attempt)), maxDelay)
    }

    /// Backoff with equal jitter: `base/2 + random(0 ... base/2)`.
    ///
    /// Evita que N clientes que fallaron a la vez reintenten sincronizados.
    public func jitteredDelay(
        for attempt: Int,
        using generator: inout some RandomNumberGenerator
    ) -> TimeInterval {
        let base = baseDelay(for: attempt)
        guard base > 0 else { return 0 }
        return base / 2 + TimeInterval.random(in: 0...(base / 2), using: &generator)
    }

    /// Backoff with equal jitter using the system RNG.
    public func jitteredDelay(for attempt: Int) -> TimeInterval {
        var generator = SystemRandomNumberGenerator()
        return jitteredDelay(for: attempt, using: &generator)
    }

    /// Default retry predicate: retry only when `APIError.isRetryable`.
    public static func defaultShouldRetry(_ error: Error, _ attempt: Int) -> Bool {
        (error as? APIError)?.isRetryable ?? false
    }

    // MARK: - Predefined Policies

    /// Exactly one request, no retries.
    public static let noRetry = RetryPolicy(maxAttempts: 1)

    /// Aggressive: up to 5 total requests, longer delays.
    public static let aggressive = RetryPolicy(
        maxAttempts: 5,
        initialDelay: 1.0,
        maxDelay: 30.0,
        multiplier: 2.0
    )

    /// Conservative: up to 2 total requests, short delays.
    public static let conservative = RetryPolicy(
        maxAttempts: 2,
        initialDelay: 0.25,
        maxDelay: 2.0,
        multiplier: 2.0
    )
}

// MARK: - Equatable

extension RetryPolicy: Equatable {
    /// Equality over the numeric configuration; `shouldRetry` (a closure)
    /// deliberately cannot participate.
    public static func == (lhs: RetryPolicy, rhs: RetryPolicy) -> Bool {
        lhs.maxAttempts == rhs.maxAttempts &&
        lhs.initialDelay == rhs.initialDelay &&
        lhs.maxDelay == rhs.maxDelay &&
        lhs.multiplier == rhs.multiplier
    }
}
