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

@Suite("APIError: mapeo y retryabilidad")
struct APIErrorMappingTests {
    private func response(
        status: Int,
        headers: [String: String] = [:]
    ) throws -> HTTPURLResponse {
        let url = try #require(URL(string: "https://unit.test/x"))
        return try #require(HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        ))
    }

    @Test("status sin body decodificable → httpStatus")
    func plainStatus() throws {
        let error = APIError.map(data: Data(), response: try response(status: 404))
        #expect(error == .httpStatus(404, retryAfter: nil))
        #expect(error.statusCode == 404)
        #expect(!error.isRetryable)
    }

    @Test(".custom conserva el statusCode y decide retryabilidad por status")
    func customPreservesStatus() throws {
        let body = Data(#"{"message":"rate limited"}"#.utf8)
        let error = APIError.map(data: body, response: try response(status: 429))
        #expect(error == .custom(APIMessageError(message: "rate limited"), statusCode: 429, retryAfter: nil))
        #expect(error.statusCode == 429)
        #expect(error.isRetryable)

        let badRequest = APIError.map(data: body, response: try response(status: 400))
        #expect(!badRequest.isRetryable)
    }

    @Test("retryabilidad por status: 5xx y 408/429 sí; resto de 4xx no")
    func retryableMatrix() {
        #expect(APIError.httpStatus(500, retryAfter: nil).isRetryable)
        #expect(APIError.httpStatus(503, retryAfter: nil).isRetryable)
        #expect(APIError.httpStatus(408, retryAfter: nil).isRetryable)
        #expect(APIError.httpStatus(429, retryAfter: nil).isRetryable)
        #expect(!APIError.httpStatus(400, retryAfter: nil).isRetryable)
        #expect(!APIError.httpStatus(401, retryAfter: nil).isRetryable)
        #expect(!APIError.httpStatus(404, retryAfter: nil).isRetryable)
        #expect(!APIError.cancelled.isRetryable)
        #expect(APIError.networkError(URLError(.timedOut)).isRetryable)
        #expect(!APIError.networkError(URLError(.badURL)).isRetryable)
    }

    @Test("Retry-After en segundos se parsea y expone")
    func retryAfterSeconds() throws {
        let error = APIError.map(data: Data(), response: try response(
            status: 429, headers: ["Retry-After": "7"]
        ))
        #expect(error.retryAfterDelay == 7)
    }

    @Test("Retry-After en HTTP-date se parsea (futuro ≈ delta, pasado = 0)")
    func retryAfterHTTPDate() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        let future = formatter.string(from: Date(timeIntervalSinceNow: 10))
        let futureDelay = try #require(APIError.parseRetryAfter(future))
        #expect(futureDelay > 7 && futureDelay <= 10)

        let past = formatter.string(from: Date(timeIntervalSinceNow: -30))
        #expect(APIError.parseRetryAfter(past) == 0)

        #expect(APIError.parseRetryAfter("garbage") == nil)
        #expect(APIError.parseRetryAfter(nil) == nil)
    }

    @Test("URLError.cancelled → .cancelled; el resto conserva el URLError")
    func urlErrorMapping() {
        #expect(APIError.map(URLError(.cancelled)) == .cancelled)
        #expect(APIError.map(URLError(.timedOut)) == .networkError(URLError(.timedOut)))
    }

    @Test("la igualdad ignora retryAfter (metadato volátil, documentado)")
    func equalityIgnoresRetryAfter() {
        #expect(APIError.httpStatus(500, retryAfter: 3) == .httpStatus(500, retryAfter: nil))
        #expect(APIError.httpStatus(500, retryAfter: nil) != .httpStatus(502, retryAfter: nil))
    }
}
