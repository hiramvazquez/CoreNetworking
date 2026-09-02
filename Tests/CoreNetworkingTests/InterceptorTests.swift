import CoreNetworkingTestSupport
import Foundation
import Testing

@testable import CoreNetworking

/// Spy que graba los eventos del pipeline en orden, con etiquetas legibles.
/// (Para asertar `context.id`/`context.attempt` usa `RecordingInterceptor`
/// de `CoreNetworkingTestSupport` — ver `RequestContextTests` más abajo.)
actor InterceptorSpy: RequestInterceptor {
    private(set) var events: [String] = []
    private let label: String

    init(label: String) { self.label = label }

    private func record(_ event: String) {
        events.append(event)
    }

    func willSend(_ request: URLRequest, context: RequestContext) async throws(APIError) -> URLRequest {
        record("\(label).willSend")
        return request
    }

    func didReceive(_ response: HTTPURLResponse, data: Data, context: RequestContext) async {
        record("\(label).didReceive")
    }

    func didFail(_ error: APIError, context: RequestContext) async {
        let status = error.statusCode.map(String.init) ?? "-"
        record("\(label).didFail(code: \(error.code), status: \(status))")
    }
}

@Suite("Interceptores: orden, willSend que aborta, didFail en todos los caminos")
struct InterceptorTests {
    private struct GetRequest: BaseRequest {
        typealias Response = Payload
        let path = "/thing"
        let method: HTTPMethod = .get
    }

    private struct Payload: Decodable, Sendable { let ok: Bool }

    private let baseURL = URL(string: "https://unit.test")!
    private var thingURL: URL { baseURL.appendingPathComponent("/thing") }

    private func makeService(
        transport: InMemoryTransport,
        interceptors: [any RequestInterceptor],
        retryPolicy: RetryPolicy = .noRetry
    ) -> APIService {
        let configuration = NetworkingConfiguration(baseURL: baseURL)
        return APIService(
            configuration: configuration,
            transport: transport,
            retryPolicy: retryPolicy,
            interceptors: interceptors
        )
    }

    @Test("orden: willSend 1→2, didReceive 1→2 en éxito")
    func orderOnSuccess() async throws {
        let first = InterceptorSpy(label: "1")
        let second = InterceptorSpy(label: "2")
        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(
                url: thingURL,
                response: .response(status: 200, body: Data(#"{"ok":true}"#.utf8))
            )
        )
        let service = makeService(transport: transport, interceptors: [first, second])

        let _: Payload = try await service.execute(GetRequest())

        #expect(await first.events == ["1.willSend", "1.didReceive"])
        #expect(await second.events == ["2.willSend", "2.didReceive"])
    }

    @Test("didFail se notifica en non-2xx")
    func didFailOnHTTPError() async throws {
        let spy = InterceptorSpy(label: "s")
        let transport = InMemoryTransport()
        await transport.register(InMemoryTransport.Exchange(url: thingURL, response: .response(status: 503)))
        let service = makeService(transport: transport, interceptors: [spy])

        await #expect(throws: APIError.self) {
            let _: Payload = try await service.execute(GetRequest())
        }

        let events = await spy.events
        #expect(
            events.contains("s.didFail(code: httpStatus, status: 503)"),
            "didFail no se notificó para el error de status — eventos: \(events)"
        )
        // didReceive también se llamó (la respuesta llegó): ambos son parte del contrato.
        #expect(events.first == "s.willSend")
        #expect(events.contains("s.didReceive"))
    }

    @Test("didFail se notifica en error de transporte")
    func didFailOnTransportError() async throws {
        let spy = InterceptorSpy(label: "s")
        let transport = InMemoryTransport()
        await transport.register(InMemoryTransport.Exchange(url: thingURL, response: .failure(URLError(.timedOut))))
        let service = makeService(transport: transport, interceptors: [spy])

        await #expect(throws: APIError.self) {
            let _: Payload = try await service.execute(GetRequest())
        }

        let events = await spy.events
        #expect(
            events.contains("s.didFail(code: transport, status: -)"),
            "didFail no se notificó para el error de transporte — eventos: \(events)"
        )
    }

    @Test("willSend que lanza: el transporte no recibe nada, code == .interceptor, didFail una sola vez")
    func willSendThrowsAbortsBeforeTransport() async throws {
        struct BoomError: Error {}
        let thrown = APIError(code: .encoding, underlying: BoomError())
        let recorder = RecordingInterceptor(willSendThrows: thrown)
        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(
                url: thingURL,
                response: .response(status: 200, body: Data(#"{"ok":true}"#.utf8))
            )
        )
        let service = makeService(transport: transport, interceptors: [recorder])

        do {
            let _: Payload = try await service.execute(GetRequest())
            Issue.record("debía lanzar")
        } catch {
            #expect(error.code == .interceptor, "esperaba .interceptor, llegó \(error.code)")
            #expect(error.underlying is APIError, "underlying debe ser lo que willSend lanzó")
        }

        #expect(await transport.recorded.isEmpty, "el transporte NO debe recibir nada si willSend aborta")

        let events = await recorder.events
        let didFailCount = events.filter { if case .didFail = $0 { return true } else { return false } }.count
        #expect(didFailCount == 1, "didFail debe invocarse EXACTAMENTE una vez — eventos: \(events.count)")
        #expect(events.count == 2, "solo willSend + didFail, sin didReceive")
    }

    @Test("didReceive/didFail comparten context.id dentro de un intento; el attempt cambia por reintento")
    func contextIdentityAcrossRetries() async throws {
        let recorder = RecordingInterceptor()
        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(
                url: thingURL,
                responses: [
                    .response(status: 500),
                    .response(status: 500),
                    .response(status: 200, body: Data(#"{"ok":true}"#.utf8))
                ]
            )
        )
        let clock = ManualClock()
        let policy = RetryPolicy(maxAttempts: 3, initialDelay: .milliseconds(1), maxDelay: .milliseconds(10))
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: baseURL),
            transport: transport,
            retryPolicy: policy,
            interceptors: [recorder],
            clock: clock
        )

        let task = Task { () async throws(APIError) -> Payload in
            try await service.execute(GetRequest())
        }
        for _ in 0..<2 {
            await clock.waitUntilSleeping()
            clock.advance(by: .seconds(10))
        }
        let payload = try await task.value
        #expect(payload.ok == true)

        let events = await recorder.events
        var idByAttempt: [Int: Set<UUID>] = [:]
        for event in events {
            switch event {
            case .willSend(_, let context):
                idByAttempt[context.attempt, default: []].insert(context.id)
            case .didReceive(_, _, let context):
                idByAttempt[context.attempt, default: []].insert(context.id)
            case .didFail(_, let context):
                idByAttempt[context.attempt, default: []].insert(context.id)
            }
        }

        #expect(idByAttempt.keys.sorted() == [1, 2, 3], "un attempt por intento (1, 2, 3)")
        for (attempt, ids) in idByAttempt {
            #expect(ids.count == 1, "el intento \(attempt) debía compartir un único context.id, tuvo \(ids.count)")
        }
        let allIDs = Set(idByAttempt.values.flatMap { $0 })
        #expect(allIDs.count == 3, "cada intento debe tener un context.id DISTINTO")
    }
}
