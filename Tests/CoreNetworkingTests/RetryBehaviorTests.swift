import Testing
import Foundation
@testable import CoreNetworking
import CoreNetworkingTestSupport

/// Tests de comportamiento del retry: `InMemoryTransport` (sin `URLSession`,
/// sin registro global) + `ManualClock` (sin dormir de verdad — ver
/// `ManualClock.swift`). Cada test
/// crea su propia instancia de ambos, así que no hace falta ni un host único
/// por test ni contar requests filtrando por host — `transport.recorded`
/// solo ve lo que ESTE test registró.
@Suite("Retry: comportamiento observable")
struct RetryBehaviorTests {
    private struct GetRequest: BaseRequest {
        typealias Parameters = EmptyParameters
        let path = "/resource"
        let method: HTTPMethod = .GET
    }

    private struct PostRequest: BaseRequest {
        typealias Parameters = EmptyParameters
        let path = "/resource"
        let method: HTTPMethod = .POST
    }

    private struct Payload: Decodable { let ok: Bool }

    private let baseURL = URL(string: "https://unit.test")!
    private var resourceURL: URL { baseURL.appendingPathComponent("/resource") }

    private func service(
        transport: InMemoryTransport,
        clock: ManualClock,
        maxAttempts: Int,
        initialDelay: Duration = .milliseconds(1)
    ) -> APIService {
        let configuration = NetworkingConfiguration(baseURL: baseURL)
        let policy = RetryPolicy(maxAttempts: maxAttempts, initialDelay: initialDelay, maxDelay: .milliseconds(10))
        return APIService(configuration: configuration, transport: transport, retryPolicy: policy, clock: clock)
    }

    /// Corre `execute` en un `Task`, avanza el `ManualClock` `retries` veces
    /// (una por backoff esperado) y espera el resultado final. Nunca duerme
    /// de verdad: `waitUntilSleeping()` suspende hasta que el pipeline
    /// registra el `sleep`, no hasta que pasa tiempo real.
    private func runWithRetries(
        _ service: APIService,
        clock: ManualClock,
        request: GetRequest = GetRequest(),
        retries: Int
    ) async throws -> Payload {
        let task = Task { () async throws(APIError) -> Payload in
            try await service.execute(request: request)
        }
        for _ in 0..<retries {
            await clock.waitUntilSleeping()
            clock.advance(by: .seconds(10))
        }
        return try await task.value
    }

    @Test("maxAttempts=3 ⇒ EXACTAMENTE 3 requests (off-by-one A3)")
    func maxAttemptsMeansTotalRequests() async throws {
        let transport = InMemoryTransport()
        await transport.register(InMemoryTransport.Exchange(url: resourceURL, response: .response(status: 500)))
        let clock = ManualClock()
        let apiService = service(transport: transport, clock: clock, maxAttempts: 3)

        await #expect(throws: APIError.self) {
            _ = try await runWithRetries(apiService, clock: clock, retries: 2)
        }
        #expect(await transport.recorded.count == 3)
    }

    @Test("noRetry ⇒ 1 solo request")
    func noRetrySingleRequest() async throws {
        let transport = InMemoryTransport()
        await transport.register(InMemoryTransport.Exchange(url: resourceURL, response: .response(status: 500)))
        let configuration = NetworkingConfiguration(baseURL: baseURL)
        let apiService = APIService(configuration: configuration, transport: transport, retryPolicy: .noRetry)

        await #expect(throws: APIError.self) {
            let _: Payload = try await apiService.execute(request: GetRequest())
        }
        #expect(await transport.recorded.count == 1)
    }

    @Test("POST NO se reintenta por defecto (no idempotente, A4)")
    func postIsNotRetriedByDefault() async throws {
        let transport = InMemoryTransport()
        await transport.register(InMemoryTransport.Exchange(method: .POST, url: resourceURL, response: .response(status: 500)))
        let clock = ManualClock()
        let apiService = service(transport: transport, clock: clock, maxAttempts: 3)

        await #expect(throws: APIError.self) {
            let _: Payload = try await apiService.execute(request: PostRequest())
        }
        #expect(await transport.recorded.count == 1)
    }

    @Test("POST con allowsNonIdempotentRetry=true SÍ se reintenta (opt-in)")
    func postOptInRetries() async throws {
        struct OptInPostRequest: BaseRequest {
            typealias Parameters = EmptyParameters
            let path = "/resource"
            let method: HTTPMethod = .POST
            let allowsNonIdempotentRetry = true
        }

        let transport = InMemoryTransport()
        await transport.register(InMemoryTransport.Exchange(method: .POST, url: resourceURL, response: .response(status: 500)))
        let clock = ManualClock()
        let apiService = service(transport: transport, clock: clock, maxAttempts: 3)

        let task = Task { () async throws(APIError) -> Payload in
            try await apiService.execute(request: OptInPostRequest())
        }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(10))
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(10))

        await #expect(throws: APIError.self) {
            _ = try await task.value
        }
        #expect(await transport.recorded.count == 3)
    }

    @Test("Retry-After del servidor manda sobre el backoff configurado")
    func retryAfterOverridesBackoff() async throws {
        let transport = InMemoryTransport()
        await transport.register(InMemoryTransport.Exchange(
            url: resourceURL,
            // "1", no "0": un delay de CERO resuelve `clock.sleep` de forma
            // síncrona (nunca llega a registrarse como pendiente) y este test
            // no podría distinguirlo del backoff sin esperar de verdad.
            response: .response(status: 503, headers: ["Retry-After": "1"])
        ))
        let clock = ManualClock()
        // Backoff configurado ENORME: si el delay pedido a `clock` es ~1s en
        // vez de este backoff, es porque se respetó el Retry-After.
        let apiService = service(transport: transport, clock: clock, maxAttempts: 2, initialDelay: .seconds(3600))

        let task = Task { () async throws(APIError) -> Payload in
            try await apiService.execute(request: GetRequest())
        }
        await clock.waitUntilSleeping()
        let deadline = try #require(clock.pendingDeadlines.first)
        let requestedDelay = clock.now.duration(to: deadline)
        #expect(requestedDelay <= .seconds(1), "debía usar Retry-After (1s), no el backoff configurado (1h)")
        clock.advance(by: requestedDelay)

        await #expect(throws: APIError.self) {
            _ = try await task.value
        }
        #expect(await transport.recorded.count == 2)
    }

    @Test("429 es retryable")
    func tooManyRequestsRetries() async throws {
        let transport = InMemoryTransport()
        await transport.register(InMemoryTransport.Exchange(url: resourceURL, response: .response(status: 429)))
        let clock = ManualClock()
        let apiService = service(transport: transport, clock: clock, maxAttempts: 2)

        await #expect(throws: APIError.self) {
            _ = try await runWithRetries(apiService, clock: clock, retries: 1)
        }
        #expect(await transport.recorded.count == 2)
    }

    @Test("500, 500, 200 → éxito con EXACTAMENTE 3 requests (secuencia en InMemoryTransport)")
    func retriesThroughFailureSequenceThenSucceeds() async throws {
        let transport = InMemoryTransport()
        await transport.register(InMemoryTransport.Exchange(
            url: resourceURL,
            responses: [
                .response(status: 500),
                .response(status: 500),
                .response(status: 200, body: Data(#"{"ok":true}"#.utf8))
            ]
        ))
        let clock = ManualClock()
        let apiService = service(transport: transport, clock: clock, maxAttempts: 3)

        let payload = try await runWithRetries(apiService, clock: clock, retries: 2)

        #expect(payload.ok == true)
        #expect(await transport.recorded.count == 3)
    }
}
