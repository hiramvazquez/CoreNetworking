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
}
