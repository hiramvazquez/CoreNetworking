import CoreNetworkingTestSupport
import Foundation
import Testing

@testable import CoreNetworking

/// Transporte de prueba que decide el status según el header `Authorization`
/// del request — a diferencia de `InMemoryTransport` (secuencia fija por
/// URL), esto modela "el servidor acepta el token nuevo" sin depender de
/// CUÁNTAS veces se llame antes del refresh, algo que importa en el test de
/// deduplicación concurrente (10 requests en carrera, orden no determinista).
private actor HeaderGatedTransport: HTTPTransport {
    private let validToken: String
    private(set) var requestCount = 0

    init(validToken: String) {
        self.validToken = validToken
    }

    func send(_ request: URLRequest, progress: TransferProgress?) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(validToken)"
        let statusCode = authorized ? 200 : 401
        let body = authorized ? Data(#"{"ok":true}"#.utf8) : Data()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (body, response)
    }

    func download(
        _ request: URLRequest,
        to destination: URL,
        progress: TransferProgress?
    ) async throws -> HTTPURLResponse {
        let (data, response) = try await send(request, progress: progress)
        try data.write(to: destination, options: .atomic)
        return response
    }
}

private actor TokenBox {
    private(set) var token: String
    init(_ token: String) { self.token = token }
    func set(_ newToken: String) { token = newToken }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// El closure de refresh necesita observar al propio `TokenRefresher` que lo
/// ejecuta; la caja rompe la dependencia circular en la construcción.
private actor RefresherBox {
    private(set) var refresher: TokenRefresher?
    func set(_ refresher: TokenRefresher) { self.refresher = refresher }
}

@Suite("RequestRetrier / TokenRefreshRetrier: decisión de reintento")
struct RetrierTests {
    private struct GetRequest: BaseRequest {
        typealias Response = Payload
        let path = "/resource"
        let method: HTTPMethod = .get
    }

    private struct Payload: Decodable, Sendable { let ok: Bool }

    private let baseURL = URL(string: "https://unit.test")!
    private var resourceURL: URL { baseURL.appendingPathComponent("/resource") }

    @Test("401 → refresh → 200: EXACTAMENTE 2 requests, el segundo con el token nuevo")
    func refreshOn401ThenSucceeds() async throws {
        let tokenBox = TokenBox("old-token")
        let transport = HeaderGatedTransport(validToken: "new-token")
        let refresher = TokenRefresher { await tokenBox.set("new-token") }
        let interceptor = BearerTokenInterceptor { await tokenBox.token }
        let retrier = TokenRefreshRetrier(refresher: refresher)
        let clock = ManualClock()
        let policy = RetryPolicy(maxAttempts: 2, initialDelay: .milliseconds(1), maxDelay: .milliseconds(10))
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: baseURL),
            transport: transport,
            retryPolicy: policy,
            interceptors: [interceptor],
            retriers: [retrier],
            clock: clock
        )

        let task = Task { () async throws(APIError) -> Payload in
            try await service.execute(GetRequest())
        }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(10))
        let payload = try await task.value

        #expect(payload.ok == true)
        #expect(
            await transport.requestCount == 2,
            "EXACTAMENTE 2 requests: el 401 original y el reintento tras el refresh"
        )
    }

    @Test("10 requests concurrentes con 401 → un ÚNICO refresh")
    func concurrentRequestsDedupRefresh() async throws {
        let tokenBox = TokenBox("old-token")
        let transport = HeaderGatedTransport(validToken: "new-token")
        let refreshCount = Counter()
        let refresherBox = RefresherBox()
        let refresher = TokenRefresher {
            await refreshCount.increment()
            // Solape DETERMINISTA, sin `sleep`: el refresh no termina hasta que
            // las otras 9 requests (que reciben su 401 mientras el token siga
            // siendo el viejo) se han enganchado al refresh en vuelo. Todas
            // llegarán, porque el token no cambia hasta que este closure
            // acaba; `Task.yield()` solo cede el turno mientras tanto.
            // `TokenRefresher` deduplica refreshes que se SOLAPAN, no "uno por
            // sesión": este test garantiza el solape en vez de confiar en el
            // scheduler.
            while await refresherBox.refresher?.joinedInFlightCount ?? 0 < 9 {
                await Task.yield()
            }
            await tokenBox.set("new-token")
        }
        await refresherBox.set(refresher)
        let interceptor = BearerTokenInterceptor { await tokenBox.token }
        let retrier = TokenRefreshRetrier(refresher: refresher)
        // `initialDelay`/`maxDelay` en CERO: `jitteredDelay` devuelve `.zero`
        // exacto (ver `RetryPolicy.jitteredDelay`), así que `clock.sleep(for:
        // .zero)` no espera de verdad — es un punto de suspensión, no un
        // retraso — y el reloj real por defecto (`ContinuousClock`) no
        // introduce flakiness: lo que este test verifica es la deduplicación
        // bajo concurrencia real, no temporización.
        let policy = RetryPolicy(maxAttempts: 2, initialDelay: .zero, maxDelay: .zero)
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: baseURL),
            transport: transport,
            retryPolicy: policy,
            interceptors: [interceptor],
            retriers: [retrier]
        )

        try await withThrowingTaskGroup(of: Payload.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await service.execute(GetRequest())
                }
            }
            for try await payload in group {
                #expect(payload.ok == true)
            }
        }

        #expect(await refreshCount.value == 1, "10 401 concurrentes deben deduplicarse en UN único refresh")
        #expect(await refresher.joinedInFlightCount == 9)
        #expect(await transport.requestCount == 20, "10 requests con 401 + 10 reintentos con el token nuevo")
        #expect(await tokenBox.token == "new-token")
    }

    @Test("Refresh que falla → .doNotRetry: el 401 original llega sin reintentos extra")
    func refreshFailureDoesNotRetry() async throws {
        struct RefreshError: Error {}
        let transport = InMemoryTransport()
        await transport.register(InMemoryTransport.Exchange(url: resourceURL, response: .response(status: 401)))
        let refresher = TokenRefresher { throw RefreshError() }
        let retrier = TokenRefreshRetrier(refresher: refresher)
        let clock = ManualClock()
        // maxAttempts > 1 a propósito: si fuera 1, el corte sería por
        // `maxAttempts`, no por la decisión `.doNotRetry` del retrier — este
        // test quiere probar lo segundo.
        let policy = RetryPolicy(maxAttempts: 3, initialDelay: .milliseconds(1), maxDelay: .milliseconds(10))
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: baseURL),
            transport: transport,
            retryPolicy: policy,
            retriers: [retrier],
            clock: clock
        )

        do {
            let _: Payload = try await service.execute(GetRequest())
            Issue.record("debía lanzar")
        } catch {
            #expect(error.code == .httpStatus)
            #expect(error.statusCode == 401)
        }

        #expect(await transport.recorded.count == 1, "sin reintentos extra tras un refresh fallido")
    }

    @Test("RetryDecision.retryAfter manda sobre RetryPolicy Y sobre el Retry-After del servidor")
    func retryAfterDecisionOverridesEverything() async throws {
        struct FixedRetrier: RequestRetrier {
            let after: Duration
            func retry(_ error: APIError, context: RequestContext) async -> RetryDecision {
                .retryAfter(after)
            }
        }

        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(
                url: resourceURL,
                responses: [
                    .response(status: 503, headers: ["Retry-After": "1"]),
                    .response(status: 200, body: Data(#"{"ok":true}"#.utf8))
                ]
            )
        )
        let clock = ManualClock()
        // backoff configurado ENORME (1h) y Retry-After del servidor (1s):
        // si el delay pedido al reloj es el que fija el retrier (2s exactos),
        // es porque `.retryAfter` mandó sobre ambos.
        let policy = RetryPolicy(maxAttempts: 2, initialDelay: .seconds(3600), maxDelay: .seconds(7200))
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: baseURL),
            transport: transport,
            retryPolicy: policy,
            retriers: [FixedRetrier(after: .seconds(2))],
            clock: clock
        )

        let task = Task { () async throws(APIError) -> Payload in
            try await service.execute(GetRequest())
        }
        await clock.waitUntilSleeping()
        let deadline = try #require(clock.pendingDeadlines.first)
        let requestedDelay = clock.now.duration(to: deadline)
        #expect(
            requestedDelay == .seconds(2),
            "debía usar RetryDecision.retryAfter (2s), no Retry-After (1s) ni el backoff (1h)"
        )
        clock.advance(by: requestedDelay)

        let payload = try await task.value
        #expect(payload.ok == true)
        #expect(await transport.recorded.count == 2)
    }

    @Test("maxAttempts limita también el camino de retriers")
    func maxAttemptsBoundsRetrierPath() async throws {
        struct AlwaysRetry: RequestRetrier {
            func retry(_ error: APIError, context: RequestContext) async -> RetryDecision { .retry }
        }
        let transport = InMemoryTransport()
        await transport.register(InMemoryTransport.Exchange(url: resourceURL, response: .response(status: 500)))
        let clock = ManualClock()
        let policy = RetryPolicy(maxAttempts: 3, initialDelay: .milliseconds(1), maxDelay: .milliseconds(10))
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: baseURL),
            transport: transport,
            retryPolicy: policy,
            retriers: [AlwaysRetry()],
            clock: clock
        )

        let task = Task { () async throws(APIError) -> Payload in
            try await service.execute(GetRequest())
        }
        for _ in 0..<2 {
            await clock.waitUntilSleeping()
            clock.advance(by: .seconds(10))
        }
        await #expect(throws: APIError.self) {
            _ = try await task.value
        }
        #expect(
            await transport.recorded.count == 3,
            "3 intentos TOTAL como mucho, aunque el retrier siempre pida .retry"
        )
    }

    @Test("el primer retrier que no devuelve .doNotRetry decide; los siguientes no se consultan")
    func firstNonDoNotRetryWins() async throws {
        actor CallLog {
            private(set) var calls: [String] = []
            func record(_ label: String) { calls.append(label) }
        }
        struct LoggingRetrier: RequestRetrier {
            let label: String
            let decision: RetryDecision
            let log: CallLog
            func retry(_ error: APIError, context: RequestContext) async -> RetryDecision {
                await log.record(label)
                return decision
            }
        }

        let log = CallLog()
        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(
                url: resourceURL,
                responses: [.response(status: 500), .response(status: 200, body: Data(#"{"ok":true}"#.utf8))]
            )
        )
        let clock = ManualClock()
        let policy = RetryPolicy(maxAttempts: 2, initialDelay: .milliseconds(1), maxDelay: .milliseconds(10))
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: baseURL),
            transport: transport,
            retryPolicy: policy,
            retriers: [
                LoggingRetrier(label: "A", decision: .doNotRetry, log: log),
                LoggingRetrier(label: "B", decision: .retry, log: log),
                LoggingRetrier(label: "C", decision: .doNotRetry, log: log)
            ],
            clock: clock
        )

        let task = Task { () async throws(APIError) -> Payload in
            try await service.execute(GetRequest())
        }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(10))
        let payload = try await task.value

        #expect(payload.ok == true)
        #expect(await log.calls == ["A", "B"], "C no debía consultarse: B ya decidió")
    }

    // MARK: - Precedencia retriers → retryPolicy
    //
    // `RequestRetrier`'s doc: los retriers se consultan ANTES que
    // `RetryPolicy.shouldRetry`, en el orden dado, y el primero que no
    // responde `.doNotRetry` decide — ningún retrier posterior NI
    // `retryPolicy.shouldRetry` se consulta para ese fallo. Los tests de
    // arriba (`firstNonDoNotRetryWins`, `maxAttemptsBoundsRetrierPath`) prueban
    // que un retrier posterior no se consulta, pero ninguno prueba el otro
    // lado de la promesa: que `retryPolicy.shouldRetry` en sí NO se invoca
    // cuando un retrier ya decidió. Invertir las dos ramas del `if` en
    // `performWithRetry` (consultar `retryPolicy` primero) seguiría en verde
    // en `firstNonDoNotRetryWins` — 500 es `isRetryable` por defecto, así que
    // el camino roto retrasaría igual y B seguiría viendo su turno — pero
    // rompe aquí, donde `shouldRetry` lleva una marca que solo un camino
    // puede activar.

    /// `RetryPolicy` no es `Equatable` (su `shouldRetry` es un closure), así
    /// que el espía vive en el propio closure — grabando en un log compartido
    /// con los retriers, para verificar tanto SI se consultó como EN QUÉ
    /// ORDEN respecto a ellos.
    private actor CallLog {
        private(set) var calls: [String] = []
        func record(_ label: String) { calls.append(label) }
    }

    private struct LoggingRetrier: RequestRetrier {
        let label: String
        let decision: RetryDecision
        let log: CallLog
        func retry(_ error: APIError, context: RequestContext) async -> RetryDecision {
            await log.record(label)
            return decision
        }
    }

    /// `shouldRetry` no es `async`: graba de forma síncrona con
    /// `DispatchSemaphore` sería una complicación innecesaria — un `Task`
    /// disparado y no esperado basta porque el test solo necesita saber SI se
    /// llamó, no sincronizarse con él (la llamada, si ocurre, sucede antes de
    /// que `performWithRetry` continúe, y el test espera al resultado final
    /// de `execute` antes de leer el log).
    private func loggingShouldRetry(_ log: CallLog, label: String, result: Bool) -> @Sendable (APIError, Int) -> Bool {
        { _, _ in
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await log.record(label)
                semaphore.signal()
            }
            semaphore.wait()
            return result
        }
    }

    @Test("un retrier que decide (.retry) evita que se consulte retryPolicy.shouldRetry")
    func retrierDecisionSkipsRetryPolicyShouldRetry() async throws {
        let log = CallLog()
        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(
                url: resourceURL,
                responses: [.response(status: 500), .response(status: 200, body: Data(#"{"ok":true}"#.utf8))]
            )
        )
        let clock = ManualClock()
        let policy = RetryPolicy(
            maxAttempts: 2,
            initialDelay: .milliseconds(1),
            maxDelay: .milliseconds(10),
            shouldRetry: loggingShouldRetry(log, label: "shouldRetry", result: true)
        )
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: baseURL),
            transport: transport,
            retryPolicy: policy,
            retriers: [LoggingRetrier(label: "A", decision: .retry, log: log)],
            clock: clock
        )

        let task = Task { () async throws(APIError) -> Payload in
            try await service.execute(GetRequest())
        }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(10))
        let payload = try await task.value

        #expect(payload.ok == true)
        let calls = await log.calls
        #expect(calls == ["A"], "retryPolicy.shouldRetry NO debía consultarse — se llamó: \(calls)")
    }

    @Test("si TODOS los retriers responden .doNotRetry, retryPolicy.shouldRetry SÍ se consulta, tras ellos y en orden")
    func allRetriersDoNotRetryFallsBackToRetryPolicy() async throws {
        let log = CallLog()
        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(
                url: resourceURL,
                responses: [.response(status: 500), .response(status: 200, body: Data(#"{"ok":true}"#.utf8))]
            )
        )
        let clock = ManualClock()
        let policy = RetryPolicy(
            maxAttempts: 2,
            initialDelay: .milliseconds(1),
            maxDelay: .milliseconds(10),
            shouldRetry: loggingShouldRetry(log, label: "shouldRetry", result: true)
        )
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: baseURL),
            transport: transport,
            retryPolicy: policy,
            retriers: [
                LoggingRetrier(label: "A", decision: .doNotRetry, log: log),
                LoggingRetrier(label: "B", decision: .doNotRetry, log: log)
            ],
            clock: clock
        )

        let task = Task { () async throws(APIError) -> Payload in
            try await service.execute(GetRequest())
        }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(10))
        let payload = try await task.value

        #expect(payload.ok == true)
        let calls = await log.calls
        #expect(
            calls == ["A", "B", "shouldRetry"],
            "orden esperado: A, B (en el orden del array), y shouldRetry SOLO después de que ambos respondieran .doNotRetry — se llamó: \(calls)"
        )
    }

    // MARK: - Precedencia de delays con RetryDecision.retry
    //
    // El doc de `RetryDecision` fija tres combinaciones:
    // 1. `.retryAfter(d)` ignora TANTO el Retry-After del servidor COMO el
    //    backoff de RetryPolicy — ya cubierto arriba
    //    (`retryAfterDecisionOverridesEverything`).
    // 2. `.retry` prefiere el Retry-After del servidor sobre el backoff —
    //    cubierto para el camino SIN retriers en `RetryBehaviorTests
    //    .retryAfterOverridesBackoff`, pero ese test nunca pasa por
    //    `RetryDecision` (no hay retriers ahí): es el mismo cálculo de delay,
    //    pero un contrato distinto. Aquí se prueba a través de un retrier que
    //    de verdad devuelve `.retry`.
    // 3. `.retry` sin Retry-After del servidor usa el backoff de RetryPolicy
    //    — tampoco probado hasta ahora pasando por un retrier.

    @Test("RetryDecision.retry (de un retrier) prefiere el Retry-After del servidor sobre el backoff")
    func retryDecisionPrefersServerRetryAfterOverBackoff() async throws {
        struct AlwaysRetry: RequestRetrier {
            func retry(_ error: APIError, context: RequestContext) async -> RetryDecision { .retry }
        }

        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(
                url: resourceURL,
                responses: [
                    .response(status: 503, headers: ["Retry-After": "1"]),
                    .response(status: 200, body: Data(#"{"ok":true}"#.utf8))
                ]
            )
        )
        let clock = ManualClock()
        // Backoff configurado ENORME (1h): si el delay pedido es ~1s, es
        // porque `.retry` usó el Retry-After del servidor, no el backoff.
        let policy = RetryPolicy(maxAttempts: 2, initialDelay: .seconds(3600), maxDelay: .seconds(7200))
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: baseURL),
            transport: transport,
            retryPolicy: policy,
            retriers: [AlwaysRetry()],
            clock: clock
        )

        let task = Task { () async throws(APIError) -> Payload in
            try await service.execute(GetRequest())
        }
        await clock.waitUntilSleeping()
        let deadline = try #require(clock.pendingDeadlines.first)
        let requestedDelay = clock.now.duration(to: deadline)
        #expect(
            requestedDelay <= .seconds(1),
            "RetryDecision.retry debía usar el Retry-After del servidor (1s), no el backoff configurado (1h) — pidió \(requestedDelay)"
        )
        clock.advance(by: requestedDelay)

        let payload = try await task.value
        #expect(payload.ok == true)
    }

    @Test("RetryDecision.retry (de un retrier) usa el backoff de RetryPolicy cuando el servidor no manda Retry-After")
    func retryDecisionFallsBackToRetryPolicyBackoffWithoutServerHeader() async throws {
        struct AlwaysRetry: RequestRetrier {
            func retry(_ error: APIError, context: RequestContext) async -> RetryDecision { .retry }
        }

        let transport = InMemoryTransport()
        await transport.register(
            // Sin header Retry-After: solo el backoff de RetryPolicy puede
            // haber fijado el delay pedido al reloj.
            InMemoryTransport.Exchange(
                url: resourceURL,
                responses: [.response(status: 503), .response(status: 200, body: Data(#"{"ok":true}"#.utf8))]
            )
        )
        let clock = ManualClock()
        // initialDelay == maxDelay: el backoff (attempt 0) es exactamente
        // 4s, sea cual sea el multiplier — así el rango de jitter (mitad a
        // entero de la base, ver RetryPolicyTests.jitterBounds) es acotado y
        // verificable sin depender del RNG exacto.
        let policy = RetryPolicy(maxAttempts: 2, initialDelay: .seconds(4), maxDelay: .seconds(4))
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: baseURL),
            transport: transport,
            retryPolicy: policy,
            retriers: [AlwaysRetry()],
            clock: clock
        )

        let task = Task { () async throws(APIError) -> Payload in
            try await service.execute(GetRequest())
        }
        await clock.waitUntilSleeping()
        let deadline = try #require(clock.pendingDeadlines.first)
        let requestedDelay = clock.now.duration(to: deadline)
        #expect(
            requestedDelay >= .seconds(2) && requestedDelay <= .seconds(4),
            "sin Retry-After del servidor, RetryDecision.retry debía usar el backoff de RetryPolicy (jitter en [2s, 4s]) — pidió \(requestedDelay)"
        )
        clock.advance(by: requestedDelay)

        let payload = try await task.value
        #expect(payload.ok == true)
    }

    // MARK: - TokenRefreshRetrier: solo dispara en el primer intento
    //
    // Su doc: "a 401 on a LATER attempt means the just-refreshed token isn't
    // good either, and refreshing again in a loop would never terminate."
    // `refreshOn401ThenSucceeds` (arriba) prueba el camino feliz — refresca y
    // el segundo intento tiene éxito — pero nunca fuerza un SEGUNDO 401 tras
    // el refresh, así que nunca ejercita el `context.attempt == 1` del
    // guard. Aquí el servidor sigue devolviendo 401 pase lo que pase (el
    // "token recién refrescado tampoco vale" del doc), con maxAttempts alto
    // para que el corte sea la propia lógica del retrier, no `maxAttempts`.

    /// Espía sobre `TokenRefreshing`: cuenta llamadas a `refreshToken()` sin
    /// delegar en `TokenRefresher` (aquí no hace falta deduplicación
    /// concurrente, solo contar).
    private actor RefreshCountingSpy: TokenRefreshing {
        private(set) var callCount = 0
        func refreshToken() async throws {
            callCount += 1
        }
    }

    @Test(
        "401 persistente tras el refresh: refreshToken() se llama EXACTAMENTE una vez, el 401 final llega al llamador"
    )
    func tokenRefreshRetrierFiresOnlyOnFirstAttempt() async throws {
        let transport = InMemoryTransport()
        // Un único outcome reutilizable (ver Exchange.init(response:)): CADA
        // intento, incluido el que sigue al refresh, recibe 401 — modela que
        // el token recién refrescado tampoco es válido.
        await transport.register(InMemoryTransport.Exchange(url: resourceURL, response: .response(status: 401)))
        let refreshSpy = RefreshCountingSpy()
        let retrier = TokenRefreshRetrier(refresher: refreshSpy)
        let clock = ManualClock()
        // maxAttempts alto A PROPÓSITO: si el corte fuera por maxAttempts en
        // vez de por `context.attempt == 1`, este test no distinguiría "el
        // retrier deja de refrescar" de "se acabaron los intentos" — y con
        // maxAttempts alto, un refresh en bucle (el bug que el guard evita)
        // agotaría igualmente los intentos en vez de fallar rápido, así que
        // solo el conteo de refreshToken() (no el de requests) demuestra el
        // guard.
        let policy = RetryPolicy(maxAttempts: 5, initialDelay: .milliseconds(1), maxDelay: .milliseconds(10))
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: baseURL),
            transport: transport,
            retryPolicy: policy,
            retriers: [retrier],
            clock: clock
        )

        let task = Task { () async throws(APIError) -> Payload in
            try await service.execute(GetRequest())
        }
        // Un solo backoff esperado: intento 1 (401) → refresh → .retry →
        // intento 2 (401 otra vez) → `context.attempt == 2` así que el
        // retrier ya responde `.doNotRetry` sin tocar `refreshSpy`, y
        // `retryPolicy.shouldRetry` (401 no es retryable por defecto) corta
        // ahí mismo, sin un segundo backoff.
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(10))

        do {
            let _: Payload = try await task.value
            Issue.record("debía lanzar: el servidor nunca deja de devolver 401")
        } catch let apiError as APIError {
            #expect(apiError.code == .httpStatus, "esperaba .httpStatus, llegó \(apiError.code)")
            #expect(apiError.statusCode == 401, "el 401 final debía llegar al llamador sin traducir")
        }

        let refreshCallCount = await refreshSpy.callCount
        #expect(
            refreshCallCount == 1,
            "refreshToken() debía llamarse EXACTAMENTE una vez (solo en el primer intento), se llamó \(refreshCallCount) veces"
        )
        #expect(
            await transport.recorded.count == 2,
            "2 requests TOTAL: el 401 original (attempt 1, dispara el refresh) y el reintento (attempt 2, ya no refresca)"
        )
    }
}
