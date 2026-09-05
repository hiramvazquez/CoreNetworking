import CoreNetworkingTestSupport
import Foundation
import Testing

@testable import CoreNetworking

/// Tests de comportamiento del retry: `InMemoryTransport` (sin `URLSession`,
/// sin registro global) + `ManualClock` (sin dormir de verdad — ver
/// `ManualClock.swift`). Cada test
/// crea su propia instancia de ambos, así que no hace falta ni un host único
/// por test ni contar requests filtrando por host — `transport.recorded`
/// solo ve lo que ESTE test registró.
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
            try await service.execute(request)
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
            let _: Payload = try await apiService.execute(GetRequest())
        }
        #expect(await transport.recorded.count == 1)
    }

    @Test("POST NO se reintenta por defecto (no idempotente, A4)")
    func postIsNotRetriedByDefault() async throws {
        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(method: .post, url: resourceURL, response: .response(status: 500))
        )
        let clock = ManualClock()
        let apiService = service(transport: transport, clock: clock, maxAttempts: 3)

        await #expect(throws: APIError.self) {
            let _: Payload = try await apiService.execute(PostRequest())
        }
        #expect(await transport.recorded.count == 1)
    }

    @Test("POST con allowsNonIdempotentRetry=true SÍ se reintenta (opt-in)")
    func postOptInRetries() async throws {
        struct OptInPostRequest: BaseRequest {
            typealias Response = Payload
            let path = "/resource"
            let method: HTTPMethod = .post
            let allowsNonIdempotentRetry = true
        }

        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(method: .post, url: resourceURL, response: .response(status: 500))
        )
        let clock = ManualClock()
        let apiService = service(transport: transport, clock: clock, maxAttempts: 3)

        let task = Task { () async throws(APIError) -> Payload in
            try await apiService.execute(OptInPostRequest())
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
        await transport.register(
            InMemoryTransport.Exchange(
                url: resourceURL,
                // "1", no "0": un delay de CERO resuelve `clock.sleep` de forma
                // síncrona (nunca llega a registrarse como pendiente) y este test
                // no podría distinguirlo del backoff sin esperar de verdad.
                response: .response(status: 503, headers: ["Retry-After": "1"])
            )
        )
        let clock = ManualClock()
        // Backoff configurado ENORME: si el delay pedido a `clock` es ~1s en
        // vez de este backoff, es porque se respetó el Retry-After.
        let apiService = service(transport: transport, clock: clock, maxAttempts: 2, initialDelay: .seconds(3600))

        let task = Task { () async throws(APIError) -> Payload in
            try await apiService.execute(GetRequest())
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

    // MARK: - maxAttempts también acota el camino de `buildURLRequest` fallido
    //
    // `performWithRetry` tiene DOS ramas de `catch`: la normal (`AttemptFailure`,
    // con `RequestContext` — cubierta arriba y en `RetrierTests`) y la de un
    // `APIError` desnudo cuando `buildURLRequest` falla ANTES de crear un
    // contexto (`.invalidURL`, `.encoding`). Esa segunda rama nunca se ejercita
    // con un error reintentable en el resto de la suite: `.invalidURL` y
    // `.encoding` no son `isRetryable`, así que `retryPolicy.shouldRetry`
    // (con el predicado por defecto) corta siempre en la tercera condición del
    // guard, dejando muerta a la primera (`attemptsMade < maxAttempts`) para
    // todo lo que se prueba normalmente. Aquí se fuerza con un `shouldRetry`
    // personalizado que SÍ acepta `.encoding`.

    /// Cuenta cuántas veces se intentó codificar el body — es decir, cuántas
    /// veces `performWithRetry` reintentó tras el fallo de `buildURLRequest`.
    /// Referencia (no value type) para que el conteo sobreviva a través de
    /// las copias del `struct BaseRequest`.
    private final class EncodeAttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func recordAttempt() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private struct AlwaysFailsEncoding: Error {}

    /// Un body cuyo `encode(to:)` SIEMPRE falla — fuerza a `buildURLRequest` a
    /// lanzar `.encoding` en cada intento, antes de que exista un
    /// `RequestContext` (la rama `catch let apiError as APIError`).
    private struct UnencodableBody: Encodable, Sendable {
        let counter: EncodeAttemptCounter
        func encode(to encoder: Encoder) throws {
            _ = counter.recordAttempt()
            throw AlwaysFailsEncoding()
        }
    }

    private struct EncodingFailingRequest: BaseRequest {
        typealias Response = Payload
        let path = "/resource"
        let method: HTTPMethod = .get
        let body: UnencodableBody?
    }

    @Test("maxAttempts acota también el camino de buildURLRequest fallido (.encoding), no solo el de AttemptFailure")
    func maxAttemptsBoundsBuildURLRequestFailurePath() async throws {
        let counter = EncodeAttemptCounter()
        let transport = InMemoryTransport()  // nunca se llega a invocar: buildURLRequest falla siempre antes
        let clock = ManualClock()
        // Predicado personalizado que SÍ trata `.encoding` como reintentable —
        // el default (`APIError.isRetryable`) nunca lo haría, y por eso el
        // guard de la rama `catch let apiError as APIError` no se ejercitaba.
        let policy = RetryPolicy(
            maxAttempts: 3,
            initialDelay: .milliseconds(1),
            maxDelay: .milliseconds(10),
            shouldRetry: { error, _ in error.code == .encoding }
        )
        let apiService = APIService(
            configuration: NetworkingConfiguration(baseURL: baseURL),
            transport: transport,
            retryPolicy: policy,
            clock: clock
        )
        let request = EncodingFailingRequest(body: UnencodableBody(counter: counter))

        let task = Task { () async throws(APIError) -> Payload in
            try await apiService.execute(request)
        }
        // Conductor del reloj en SEGUNDO PLANO, sin asumir cuántos backoffs
        // habrá: con el guard correcto son 2 (3 intentos), pero negar o
        // relajar cualquiera de sus tres condiciones (lo que este test quiere
        // detectar) cambia ese número — de "lanza en el primer intento, sin
        // dormir nunca" a "un backoff de más". Si esta tarea asumiera un
        // conteo fijo de `waitUntilSleeping()`, una mutación que lanza antes
        // de tiempo colgaría el test entero (nadie volvería a dormir jamás)
        // en vez de fallar limpio. No se espera (`await`) a que termine: si
        // el pipeline ya no vuelve a dormir, esta tarea queda huérfana sin
        // más efecto que no completar nunca — no bloquea la aserción de abajo,
        // que depende solo de `task.value`.
        let driver = Task {
            for _ in 0..<8 {
                await clock.waitUntilSleeping()
                clock.advance(by: .seconds(10))
            }
        }

        await #expect(throws: APIError.self) {
            _ = try await task.value
        }
        driver.cancel()
        #expect(await transport.recorded.isEmpty, "buildURLRequest falla antes del transporte: nunca debe llegar")
        #expect(
            counter.value == 3,
            "3 intentos TOTAL como mucho, aunque shouldRetry acepte .encoding en cada uno (negar el guard no debe colarse)"
        )
    }

    @Test("500, 500, 200 → éxito con EXACTAMENTE 3 requests (secuencia en InMemoryTransport)")
    func retriesThroughFailureSequenceThenSucceeds() async throws {
        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(
                url: resourceURL,
                responses: [
                    .response(status: 500),
                    .response(status: 500),
                    .response(status: 200, body: Data(#"{"ok":true}"#.utf8))
                ]
            )
        )
        let clock = ManualClock()
        let apiService = service(transport: transport, clock: clock, maxAttempts: 3)

        let payload = try await runWithRetries(apiService, clock: clock, retries: 2)

        #expect(payload.ok == true)
        #expect(await transport.recorded.count == 3)
    }
}
