import Foundation

/// Configuration for automatic request retry behavior.
///
/// Retry policies determine when and how failed requests should be retried.
/// By default, only retryable errors (network timeouts, 5xx errors) are retried.
///
/// ## Example - Default Policy
/// ```swift
/// let policy = RetryPolicy(maxAttempts: 3)
/// let service = APIService(retryPolicy: policy)
/// ```
///
/// ## Example - Custom Backoff
/// ```swift
/// let policy = RetryPolicy(
///     maxAttempts: 5,
///     initialDelay: 1.0,
///     maxDelay: 30.0,
///     multiplier: 3.0
/// )
/// ```
///
/// ## Example - No Retry
/// ```swift
/// let policy = RetryPolicy.noRetry
/// ```
public struct RetryPolicy: Sendable {
    /// Maximum number of retry attempts (0 = no retry, 1 = one retry, etc.)
    public let maxAttempts: Int

    /// Initial delay before first retry (in seconds)
    public let initialDelay: TimeInterval

    /// Maximum delay between retries (in seconds)
    public let maxDelay: TimeInterval

    /// Multiplier for exponential backoff (delay *= multiplier after each retry)
    public let multiplier: Double

    /// Custom logic to determine if an error should be retried
    public let shouldRetry: @Sendable (Error, Int) -> Bool

    /// Creates a retry policy with exponential backoff.
    ///
    /// - Parameters:
    ///   - maxAttempts: Maximum retry attempts (default: 3)
    ///   - initialDelay: Initial delay in seconds (default: 0.5)
    ///   - maxDelay: Maximum delay in seconds (default: 16.0)
    ///   - multiplier: Backoff multiplier (default: 2.0)
    ///   - shouldRetry: Custom retry logic (default: retry only APIError.isRetryable)
    public init(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 0.5,
        maxDelay: TimeInterval = 16.0,
        multiplier: Double = 2.0,
        shouldRetry: @escaping @Sendable (Error, Int) -> Bool = Self.defaultShouldRetry
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.shouldRetry = shouldRetry
    }

    /// Calculates the delay before the next retry attempt.
    ///
    /// Uses exponential backoff: delay = min(initialDelay * multiplier^attempt, maxDelay)
    ///
    /// - Parameter attempt: The current attempt number (0-indexed)
    /// - Returns: Delay in seconds before next retry
    public func delay(for attempt: Int) -> TimeInterval {
        let exponentialDelay = initialDelay * pow(multiplier, Double(attempt))
        return min(exponentialDelay, maxDelay)
    }

    /// Default retry logic: only retry if APIError.isRetryable returns true.
    public static func defaultShouldRetry(_ error: Error, _ attempt: Int) -> Bool {
        if let apiError = error as? APIError {
            return apiError.isRetryable
        }
        return false
    }

    // MARK: - Predefined Policies

    /// No retry policy (fails immediately on error).
    public static let noRetry = RetryPolicy(maxAttempts: 0)

    /// Aggressive retry policy (5 attempts, longer delays).
    ///
    /// Useful for critical operations or unstable networks.
    public static let aggressive = RetryPolicy(
        maxAttempts: 5,
        initialDelay: 1.0,
        maxDelay: 30.0,
        multiplier: 2.0
    )

    /// Conservative retry policy (2 attempts, short delays).
    ///
    /// Useful for user-facing operations where speed matters.
    public static let conservative = RetryPolicy(
        maxAttempts: 2,
        initialDelay: 0.25,
        maxDelay: 2.0,
        multiplier: 2.0
    )
}

// MARK: - Equatable

extension RetryPolicy: Equatable {
    public static func == (lhs: RetryPolicy, rhs: RetryPolicy) -> Bool {
        lhs.maxAttempts == rhs.maxAttempts &&
        lhs.initialDelay == rhs.initialDelay &&
        lhs.maxDelay == rhs.maxDelay &&
        lhs.multiplier == rhs.multiplier
    }
}
