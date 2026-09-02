import Testing
import Foundation
@testable import CoreNetworking
import CoreNetworkingTestSupport

/// Tests de comportamiento del retry contra el mock determinista.
///
/// Cada test usa un host ÚNICO y cuenta requests filtrando por host, para que
/// la ejecución paralela de Swift Testing no cruce conteos entre tests.
@Suite("Retry: comportamiento observable")
struct RetryBehaviorTests {
    private struct GetRequest: BaseRequest {
        typealias Response = Payload
        let path = "/resource"
        let method: HTTPMethod = .get
    }

    private struct PostRequest: BaseRequest {
        typealias Response = Payload
        let path = "/resource"
        let method: HTTPMethod = .post
    }

    private struct Payload: Decodable, Sendable { let ok: Bool }

    private func service(
        host: String,
        maxAttempts: Int,
        initialDelay: TimeInterval = 0.01
    ) throws -> (APIService, URL) {
        let baseURL = try #require(URL(string: "https://\(host)"))
        let configuration = NetworkingConfiguration(
            baseURL: baseURL,
            protocolClasses: [MockURLProtocol.self]
        )
        let policy = RetryPolicy(maxAttempts: maxAttempts, initialDelay: initialDelay, maxDelay: 0.05)
        return (APIService(configuration: configuration, retryPolicy: policy), baseURL)
    }

    private func requestCount(host: String) -> Int {
        MockURLProtocol.recordedRequests.filter { $0.url?.host == host }.count
    }

    @Test("maxAttempts=3 ⇒ EXACTAMENTE 3 requests (off-by-one A3)")
    func maxAttemptsMeansTotalRequests() async throws {
        let host = "retry-offbyone.test"
        let (service, baseURL) = try service(host: host, maxAttempts: 3)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/resource"),
            response: MockResponse(statusCode: 500)
        ))

        await #expect(throws: APIError.self) {
            let _: Payload = try await service.execute(GetRequest())
        }
        #expect(requestCount(host: host) == 3)
    }

    @Test("noRetry ⇒ 1 solo request")
    func noRetrySingleRequest() async throws {
        let host = "retry-noretry.test"
        let baseURL = try #require(URL(string: "https://\(host)"))
        let configuration = NetworkingConfiguration(baseURL: baseURL, protocolClasses: [MockURLProtocol.self])
        let service = APIService(configuration: configuration, retryPolicy: .noRetry)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/resource"),
            response: MockResponse(statusCode: 500)
        ))

        await #expect(throws: APIError.self) {
            let _: Payload = try await service.execute(GetRequest())
        }
        #expect(requestCount(host: host) == 1)
    }

    @Test("POST NO se reintenta por defecto (no idempotente, A4)")
    func postIsNotRetriedByDefault() async throws {
        let host = "retry-post.test"
        let (service, baseURL) = try service(host: host, maxAttempts: 3)
        MockURLProtocol.register(MockNetworkExchange(
            method: .post,
            url: baseURL.appendingPathComponent("/resource"),
            response: MockResponse(statusCode: 500)
        ))

        await #expect(throws: APIError.self) {
            let _: Payload = try await service.execute(PostRequest())
        }
        #expect(requestCount(host: host) == 1)
    }

    @Test("POST con allowsNonIdempotentRetry=true SÍ se reintenta (opt-in)")
    func postOptInRetries() async throws {
        struct OptInPostRequest: BaseRequest {
            typealias Response = Payload
            let path = "/resource"
            let method: HTTPMethod = .post
            let allowsNonIdempotentRetry = true
        }

        let host = "retry-post-optin.test"
        let (service, baseURL) = try service(host: host, maxAttempts: 3)
        MockURLProtocol.register(MockNetworkExchange(
            method: .post,
            url: baseURL.appendingPathComponent("/resource"),
            response: MockResponse(statusCode: 500)
        ))

        await #expect(throws: APIError.self) {
            let _: Payload = try await service.execute(OptInPostRequest())
        }
        #expect(requestCount(host: host) == 3)
    }

    @Test("Retry-After del servidor manda sobre el backoff configurado")
    func retryAfterOverridesBackoff() async throws {
        let host = "retry-after.test"
        // Backoff configurado ENORME (2 s): si el retry ocurre rápido es porque
        // se respetó el Retry-After: 0 del servidor.
        let (service, baseURL) = try service(host: host, maxAttempts: 2, initialDelay: 2.0)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/resource"),
            response: MockResponse(statusCode: 503, headers: ["Retry-After": "0"])
        ))

        let start = ContinuousClock.now
        await #expect(throws: APIError.self) {
            let _: Payload = try await service.execute(GetRequest())
        }
        let elapsed = start.duration(to: .now)

        #expect(requestCount(host: host) == 2)
        #expect(elapsed < .seconds(1.5), "el retry esperó el backoff en vez del Retry-After")
    }

    @Test("429 es retryable")
    func tooManyRequestsRetries() async throws {
        let host = "retry-429.test"
        let (service, baseURL) = try service(host: host, maxAttempts: 2)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/resource"),
            response: MockResponse(statusCode: 429)
        ))

        await #expect(throws: APIError.self) {
            let _: Payload = try await service.execute(GetRequest())
        }
        #expect(requestCount(host: host) == 2)
    }
}
