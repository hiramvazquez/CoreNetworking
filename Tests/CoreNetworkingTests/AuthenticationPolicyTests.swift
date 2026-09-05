import CoreNetworkingTestSupport
import Foundation
import Testing

@testable import CoreNetworking

/// `RequestAuthenticationPolicy` + `BearerTokenInterceptor`: los tres casos empresariales
/// reales (endpoint público, endpoint con credencial propia, endpoint normal) y el ciclo
/// 401 → refresh → reintento, verificados siempre contra el header REAL que
/// `InMemoryTransport` grabó — nunca contra estado interno del interceptor.
@Suite("RequestAuthenticationPolicy: precedencia de headers y BearerTokenInterceptor")
struct AuthenticationPolicyTests {
    private struct GetRequest: BaseRequest {
        typealias Response = Payload
        let path: String
        let method: HTTPMethod = .get
        var headers: [String: String]
        var authenticationPolicy: RequestAuthenticationPolicy

        init(
            path: String = "/thing",
            headers: [String: String] = [:],
            authenticationPolicy: RequestAuthenticationPolicy = .automatic
        ) {
            self.path = path
            self.headers = headers
            self.authenticationPolicy = authenticationPolicy
        }
    }

    private struct Payload: Decodable, Sendable { let ok: Bool }

    private let baseURL = URL(string: "https://unit.test")!

    private func makeService(
        transport: InMemoryTransport,
        tokenProvider: @escaping @Sendable () async -> String?
    ) -> APIService {
        APIService(
            configuration: NetworkingConfiguration(baseURL: baseURL),
            transport: transport,
            retryPolicy: .noRetry,
            interceptors: [BearerTokenInterceptor(tokenProvider: tokenProvider)]
        )
    }

    @Test("policy .none: sin Authorization aunque haya un token disponible")
    func noneNeverAttachesAuthorization() async throws {
        let transport = InMemoryTransport()
        let url = baseURL.appendingPathComponent("/public")
        await transport.register(
            InMemoryTransport.Exchange(
                url: url,
                response: .response(status: 200, body: Data(#"{"ok":true}"#.utf8))
            )
        )
        let service = makeService(transport: transport, tokenProvider: { "secret-token" })

        let _: Payload = try await service.execute(
            GetRequest(path: "/public", authenticationPolicy: .none)
        )

        let recorded = await transport.recorded
        #expect(recorded.count == 1)
        #expect(
            recorded[0].value(forHTTPHeaderField: "Authorization") == nil,
            "un endpoint .none NUNCA debe llevar Authorization, ni con token presente"
        )
    }

    @Test("Authorization propio del BaseRequest no se pisa")
    func explicitAuthorizationIsPreserved() async throws {
        let transport = InMemoryTransport()
        let url = baseURL.appendingPathComponent("/thing")
        await transport.register(
            InMemoryTransport.Exchange(
                url: url,
                response: .response(status: 200, body: Data(#"{"ok":true}"#.utf8))
            )
        )
        let service = makeService(transport: transport, tokenProvider: { "secret-token" })

        let _: Payload = try await service.execute(
            GetRequest(headers: ["Authorization": "ApiKey own-credential"])
        )

        let recorded = await transport.recorded
        #expect(
            recorded[0].value(forHTTPHeaderField: "Authorization") == "ApiKey own-credential",
            "BearerTokenInterceptor no debe pisar un Authorization que el BaseRequest ya puso"
        )
    }

    @Test("endpoint normal sigue recibiendo el Bearer (comportamiento preexistente)")
    func normalRequestGetsBearer() async throws {
        let transport = InMemoryTransport()
        let url = baseURL.appendingPathComponent("/thing")
        await transport.register(
            InMemoryTransport.Exchange(
                url: url,
                response: .response(status: 200, body: Data(#"{"ok":true}"#.utf8))
            )
        )
        let service = makeService(transport: transport, tokenProvider: { "secret-token" })

        let _: Payload = try await service.execute(GetRequest())

        let recorded = await transport.recorded
        #expect(recorded[0].value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    }

    @Test("401 → refresh → reintento: el segundo request lleva el token nuevo en el header real")
    func fullRefreshCycleCarriesNewToken() async throws {
        let transport = InMemoryTransport()
        let url = baseURL.appendingPathComponent("/thing")
        await transport.register(
            InMemoryTransport.Exchange(
                url: url,
                responses: [
                    .response(status: 401),
                    .response(status: 200, body: Data(#"{"ok":true}"#.utf8))
                ]
            )
        )
        actor TokenBox {
            private(set) var token = "old-token"
            func set(_ newToken: String) { token = newToken }
        }
        let tokenBox = TokenBox()
        let refresher = TokenRefresher { await tokenBox.set("new-token") }
        let retrier = TokenRefreshRetrier(refresher: refresher)
        let clock = ManualClock()
        let policy = RetryPolicy(maxAttempts: 2, initialDelay: .milliseconds(1), maxDelay: .milliseconds(10))
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: baseURL),
            transport: transport,
            retryPolicy: policy,
            interceptors: [BearerTokenInterceptor { await tokenBox.token }],
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
        let recorded = await transport.recorded
        #expect(recorded.count == 2, "el 401 original y el reintento tras el refresh")
        #expect(recorded[0].value(forHTTPHeaderField: "Authorization") == "Bearer old-token")
        #expect(
            recorded[1].value(forHTTPHeaderField: "Authorization") == "Bearer new-token",
            "el reintento debe llevar el token NUEVO, no el que acaba de recibir el 401"
        )
    }

    // MARK: - Vía AMBIENTAL: `NetworkingConfiguration.defaultHeaders`
    //
    // El hueco que `noneNeverAttachesAuthorization` NO cubría: esa prueba solo demuestra
    // que el INTERCEPTOR respeta `.none`, pero `Authorization` puede llegar sin ningún
    // interceptor de por medio — puesto directamente por `defaultHeaders` en
    // `buildURLRequest`, antes de que corra ningún interceptor. Reproduce la sonda exacta
    // reportada: una API key fija en `defaultHeaders` (patrón normal) fugándose a un
    // endpoint `.none` de terceros.

    @Test("AUDIT_AUTH: .none también corta un Authorization puesto por defaultHeaders (sin interceptores)")
    func noneStripsAmbientAuthorizationFromDefaultHeaders() async throws {
        let transport = InMemoryTransport()
        let url = baseURL.appendingPathComponent("/tercero")
        await transport.register(
            InMemoryTransport.Exchange(
                url: url,
                response: .response(status: 200, body: Data(#"{"ok":true}"#.utf8))
            )
        )
        let service = APIService(
            configuration: NetworkingConfiguration(
                baseURL: baseURL,
                defaultHeaders: ["Authorization": "Bearer TOKEN-INTERNO-DE-LA-APP"]
            ),
            transport: transport,
            retryPolicy: .noRetry,
            interceptors: [BearerTokenInterceptor { "TOKEN-DEL-INTERCEPTOR" }]
        )

        let _: Payload = try await service.execute(
            GetRequest(path: "/tercero", authenticationPolicy: .none)
        )

        let recorded = await transport.recorded
        #expect(
            recorded[0].value(forHTTPHeaderField: "Authorization") == nil,
            "defaultHeaders no debe filtrar la credencial interna a un endpoint .none"
        )
    }

    @Test("caso simétrico: bajo .automatic, el Authorization de defaultHeaders SÍ llega (API key global intacta)")
    func automaticStillDeliversDefaultHeadersAuthorization() async throws {
        let transport = InMemoryTransport()
        let url = baseURL.appendingPathComponent("/thing")
        await transport.register(
            InMemoryTransport.Exchange(
                url: url,
                response: .response(status: 200, body: Data(#"{"ok":true}"#.utf8))
            )
        )
        // Sin interceptor de Bearer: lo que llegue es EXCLUSIVAMENTE lo que
        // puso `defaultHeaders` — aísla la vía ambiental de headers de
        // cualquier interceptor.
        let service = APIService(
            configuration: NetworkingConfiguration(
                baseURL: baseURL,
                defaultHeaders: ["Authorization": "Bearer API-KEY-GLOBAL"]
            ),
            transport: transport,
            retryPolicy: .noRetry
        )

        let _: Payload = try await service.execute(GetRequest())

        let recorded = await transport.recorded
        #expect(
            recorded[0].value(forHTTPHeaderField: "Authorization") == "Bearer API-KEY-GLOBAL",
            "el uso normal de una API key global en defaultHeaders no debe romperse"
        )
    }

    @Test(
        "bajo .automatic, el interceptor SÍ pisa un Authorization AMBIENTAL de defaultHeaders (placeholder + credencial viva)"
    )
    func automaticInterceptorOverwritesAmbientDefaultHeadersAuthorization() async throws {
        let transport = InMemoryTransport()
        let url = baseURL.appendingPathComponent("/thing")
        await transport.register(
            InMemoryTransport.Exchange(
                url: url,
                response: .response(status: 200, body: Data(#"{"ok":true}"#.utf8))
            )
        )
        // Un placeholder estático en defaultHeaders (diccionario capturado
        // al construir la configuración: no puede llevar un token vivo) MÁS
        // un BearerTokenInterceptor real. `defaultHeaders` es ambiental, no
        // una decisión del endpoint concreto — el interceptor debe pisarlo
        // con la credencial viva, o cualquier request normal saldría con el
        // placeholder y un 401 inexplicable.
        let service = APIService(
            configuration: NetworkingConfiguration(
                baseURL: baseURL,
                defaultHeaders: ["Authorization": "Bearer PLACEHOLDER-ESTATICO"]
            ),
            transport: transport,
            retryPolicy: .noRetry,
            interceptors: [BearerTokenInterceptor { "TOKEN-VIVO-DEL-INTERCEPTOR" }]
        )

        let _: Payload = try await service.execute(GetRequest())

        let recorded = await transport.recorded
        #expect(
            recorded[0].value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN-VIVO-DEL-INTERCEPTOR",
            "un Authorization que solo vino de defaultHeaders es ambiental: el interceptor debe pisarlo"
        )
    }

    @Test("bajo .none, un Authorization EXPLÍCITO del propio request sobrevive (no es ambiental)")
    func noneDoesNotStripExplicitRequestHeader() async throws {
        let transport = InMemoryTransport()
        let url = baseURL.appendingPathComponent("/tercero")
        await transport.register(
            InMemoryTransport.Exchange(
                url: url,
                response: .response(status: 200, body: Data(#"{"ok":true}"#.utf8))
            )
        )
        let service = APIService(
            configuration: NetworkingConfiguration(
                baseURL: baseURL,
                // La credencial interna de la app, ambiental — debe desaparecer.
                defaultHeaders: ["Authorization": "Bearer TOKEN-INTERNO-DE-LA-APP"]
            ),
            transport: transport,
            retryPolicy: .noRetry,
            interceptors: [BearerTokenInterceptor { "TOKEN-DEL-INTERCEPTOR" }]
        )

        let _: Payload = try await service.execute(
            GetRequest(
                path: "/tercero",
                // La credencial del partner, EXPLÍCITA — la declaró quien
                // escribió este endpoint a propósito, no es ambiental.
                headers: ["Authorization": "ApiKey partner-xyz"],
                authenticationPolicy: .none
            )
        )

        let recorded = await transport.recorded
        #expect(
            recorded[0].value(forHTTPHeaderField: "Authorization") == "ApiKey partner-xyz",
            ".none corta la vía ambiental, no una credencial que el propio request declaró"
        )
    }
}
