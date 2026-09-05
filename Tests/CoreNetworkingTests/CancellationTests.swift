import CoreNetworkingTestSupport
import Foundation
import Testing

@testable import CoreNetworking

/// Cancelación REAL: el mock entrega con latencia larga (5 s) y `stopLoading`
/// cancela la entrega pendiente. Se assertan el error Y el desmontaje de la
/// transferencia en vuelo — este último con la señal observable del mock
/// (`MockURLProtocol.cancelledDeliveries`), no con el reloj.
///
/// Antes se medía "tardó menos de 2 s, luego se canceló": la misma afirmación por vía
/// indirecta, y falsa en cuanto la máquina va cargada. En el simulador de un runner de
/// CI estos cinco tests fallaban a la vez con ~4 s de elapsed, todos por el mismo
/// motivo — la máquina, no el paquete. La señal no depende de lo rápido que vaya nadie:
/// o el mock vio cancelada su entrega pendiente, o no la vio.
@Suite("Cancelación de execute / upload / download / backoff")
struct CancellationTests {
    private struct SlowRequest: BaseRequest {
        typealias Response = Payload
        let path = "/slow"
        let method: HTTPMethod = .get
    }

    private struct SlowPut: BaseRequest {
        typealias Response = Payload
        let path = "/slow"
        let method: HTTPMethod = .put
    }

    private struct Payload: Decodable, Sendable { let ok: Bool }

    private func makeService(
        host: String,
        policy: RetryPolicy = .noRetry,
        retriers: [any RequestRetrier] = []
    ) throws -> (APIService, URL) {
        let baseURL = try #require(URL(string: "https://\(host)"))
        let configuration = NetworkingConfiguration(baseURL: baseURL, protocolClasses: [MockURLProtocol.self])
        return (
            APIService(configuration: configuration, retryPolicy: policy, retriers: retriers),
            baseURL
        )
    }

    /// Sella el instante en que `APIService` decide reintentar — justo ANTES de dormir el
    /// backoff. Devuelve siempre `.doNotRetry`, así que no cambia ninguna decisión: la
    /// sigue tomando `RetryPolicy`. Es solo un mirador dentro del bucle.
    private actor RetryInstantProbe: RequestRetrier {
        private(set) var decidedAt: ContinuousClock.Instant?

        func retry(_ error: APIError, context: RequestContext) async -> RetryDecision {
            if decidedAt == nil { decidedAt = .now }
            return .doNotRetry
        }
    }

    private func registerSlowMock(url: URL, method: HTTPMethod = .get) {
        MockURLProtocol.register(
            MockNetworkExchange(
                method: method,
                url: url,
                response: MockResponse(statusCode: 200, data: Data(#"{"ok":true}"#.utf8)),
                latency: .seconds(5)
            )
        )
    }

    /// Lanza `body`, lo cancela a los 100 ms y comprueba que sale por `.cancelled`.
    /// Devuelve lo que tardó, para los pocos casos que aún tienen algo que decir sobre
    /// el tiempo (el backoff).
    @discardableResult
    private func expectCancelled(
        _ body: @escaping @Sendable () async throws -> Void
    ) async -> Duration {
        let start = ContinuousClock.now
        let task = Task {
            try await body()
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        let outcome = await task.result
        let elapsed = start.duration(to: .now)

        switch outcome {
        case .success:
            Issue.record("la operación debía cancelarse, no completarse")
        case .failure(let error):
            let apiError = error as? APIError
            #expect(apiError?.code == .cancelled, "esperaba .cancelled, llegó \(error)")
        }
        return elapsed
    }

    /// Cancela y además exige que el mock haya visto cancelada su entrega pendiente:
    /// la transferencia en vuelo se desmontó de verdad, no se quedó corriendo hasta
    /// entregar los 5 s de latencia.
    private func expectCancelledAndTornDown(
        deliveryFor url: URL,
        method: HTTPMethod = .get,
        _ body: @escaping @Sendable () async throws -> Void
    ) async {
        await expectCancelled(body)
        let tornDown = await MockURLProtocol.waitForCancelledDelivery(method: method, url: url)
        #expect(
            tornDown,
            "el mock nunca vio cancelada su entrega pendiente: la transferencia siguió viva tras cancelar el Task"
        )
    }

    @Test("execute se cancela de verdad")
    func executeCancels() async throws {
        let (service, baseURL) = try makeService(host: "cancel-exec.test")
        registerSlowMock(url: baseURL.appendingPathComponent("/slow"))

        await expectCancelledAndTornDown(deliveryFor: baseURL.appendingPathComponent("/slow")) {
            let _: Payload = try await service.execute(SlowRequest())
        }
    }

    @Test("upload se cancela de verdad")
    func uploadCancels() async throws {
        let (service, baseURL) = try makeService(host: "cancel-upload.test")
        registerSlowMock(url: baseURL.appendingPathComponent("/slow"), method: .put)

        await expectCancelledAndTornDown(
            deliveryFor: baseURL.appendingPathComponent("/slow"),
            method: .put
        ) {
            let _: Payload = try await service.upload(SlowPut(), data: Data("x".utf8))
        }
    }

    @Test("data(for:) se cancela de verdad")
    func dataCancels() async throws {
        let (service, baseURL) = try makeService(host: "cancel-data.test")
        registerSlowMock(url: baseURL.appendingPathComponent("/slow"))

        await expectCancelledAndTornDown(deliveryFor: baseURL.appendingPathComponent("/slow")) {
            _ = try await service.data(for: SlowRequest(), progress: nil)
        }
    }

    @Test("download(to:) se cancela de verdad, sin fichero huérfano en destination")
    func downloadToDiskCancels() async throws {
        let (service, baseURL) = try makeService(host: "cancel-download-disk.test")
        registerSlowMock(url: baseURL.appendingPathComponent("/slow"))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn04-cancel-download-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        await expectCancelledAndTornDown(deliveryFor: baseURL.appendingPathComponent("/slow")) {
            try await service.download(SlowRequest(), to: destination, progress: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    /// Único caso que sigue mirando el reloj, porque aquí no hay transferencia en vuelo
    /// que desmontar: el 500 se entrega al instante y lo que se cancela es la ESPERA del
    /// backoff, que no deja más rastro observable que no haberse consumido. El `count ==
    /// 1` no lo cubre: sin interrumpir la espera tampoco habría segundo request (el bucle
    /// de reintento ve el Task cancelado al despertar), solo se tardaría el backoff.
    ///
    /// Y se mide la VENTANA DEL BACKOFF, no la operación entera. Medir el total mezcla
    /// dos cosas que no tienen nada que ver: lo que tarda el primer request —en el
    /// simulador de un runner, segundos, sobre todo el primero de la sesión— y lo que
    /// tarda la cancelación en sacar al bucle de la espera, que es lo único que este
    /// test afirma. Con el total, la primera se comía a la segunda y el fallo no decía
    /// cuál de las dos había pasado: dos runs de CI y dos diagnósticos distintos, ambos
    /// equivocados. Un `RequestRetrier` que no decide nada sella el instante en que el
    /// bucle va a dormir, y desde ahí se cronometra.
    @Test("cancelar durante el backoff del retry → .cancelled sin segundo request")
    func cancelDuringBackoff() async throws {
        let host = "cancel-backoff.test"
        let backoff = Duration.seconds(5)
        let policy = RetryPolicy(maxAttempts: 2, initialDelay: backoff, maxDelay: backoff)
        let probe = RetryInstantProbe()
        let (service, baseURL) = try makeService(host: host, policy: policy, retriers: [probe])
        MockURLProtocol.register(
            MockNetworkExchange(
                url: baseURL.appendingPathComponent("/slow"),
                response: MockResponse(statusCode: 500)
            )
        )

        let total = await expectCancelled {
            let _: Payload = try await service.execute(SlowRequest())
        }
        let finishedAt = ContinuousClock.now

        let decidedAt = try #require(
            await probe.decidedAt,
            "el bucle no llegó a decidir el reintento: sin backoff que cancelar, este test no mide nada"
        )
        let backoffWindow = decidedAt.duration(to: finishedAt)
        #expect(
            backoffWindow < .seconds(3),
            "la cancelación no interrumpió el backoff de \(backoff): \(backoffWindow) en la espera (\(total) en total, primer request incluido)"
        )
        let count = MockURLProtocol.recordedRequests.filter { $0.url?.host == host }.count
        #expect(count == 1, "no debe haber segundo request tras cancelar en el backoff")
    }
}
