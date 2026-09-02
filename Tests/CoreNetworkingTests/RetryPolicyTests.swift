import Testing
import Foundation
@testable import CoreNetworking

@Suite("RetryPolicy: matemática del backoff")
struct RetryPolicyTests {
    @Test("backoff exponencial con tope")
    func exponentialBackoffCapped() {
        let policy = RetryPolicy(maxAttempts: 5, initialDelay: 1.0, maxDelay: 5.0, multiplier: 2.0)
        #expect(policy.baseDelay(for: 0) == 1.0)
        #expect(policy.baseDelay(for: 1) == 2.0)
        #expect(policy.baseDelay(for: 2) == 4.0)
        #expect(policy.baseDelay(for: 3) == 5.0) // capped
        #expect(policy.baseDelay(for: 10) == 5.0)
    }

    @Test("jitter acotado: delay ∈ [base/2, base] para todos los intentos (property)")
    func jitterBounds() {
        let policy = RetryPolicy(maxAttempts: 5, initialDelay: 0.5, maxDelay: 16.0, multiplier: 2.0)
        var generator = SystemRandomNumberGenerator()
        for attempt in 0..<8 {
            let base = policy.baseDelay(for: attempt)
            for _ in 0..<200 {
                let jittered = policy.jitteredDelay(for: attempt, using: &generator)
                #expect(jittered >= base / 2)
                #expect(jittered <= base)
            }
        }
    }

    @Test("maxAttempts < 1 se fija a 1 — cero requests no es representable")
    func maxAttemptsClamped() {
        #expect(RetryPolicy(maxAttempts: 0).maxAttempts == 1)
        #expect(RetryPolicy(maxAttempts: -3).maxAttempts == 1)
        #expect(RetryPolicy.noRetry.maxAttempts == 1)
    }

    @Test("delay 0 produce jitter 0")
    func zeroDelay() {
        let policy = RetryPolicy(maxAttempts: 2, initialDelay: 0, maxDelay: 0, multiplier: 2.0)
        #expect(policy.jitteredDelay(for: 0) == 0)
    }
}

// NOTA: la cobertura de `APIError` (mapeo, `category`, `isRetryable`,
// `retryAfter`, `decodeBody`, `LocalizedError`) vive en `APIErrorTests.swift`
// desde que `APIError` dejó de ser un enum `Equatable` (CN-01). Antes había
// aquí una suite `APIErrorMappingTests` escrita contra esa API vieja
// (`APIError.map`, `.httpStatus(_:retryAfter:)`, `APIMessageError`); se borró
// en vez de arreglarse porque ya no describe el tipo actual.
