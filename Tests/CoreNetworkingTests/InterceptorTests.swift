import Testing
import Foundation
@testable import CoreNetworking
import CoreNetworkingTestSupport

/// Spy que graba los eventos del pipeline en orden.
actor InterceptorSpy: RequestInterceptor {
    private(set) var events: [String] = []
    private let label: String

    init(label: String) { self.label = label }

    private func record(_ event: String) {
        events.append(event)
    }

    nonisolated func willSend(_ request: URLRequest) async -> URLRequest {
        await record("\(label).willSend")
        return request
    }

    nonisolated func didReceive(_ response: URLResponse, data: Data) async {
        await record("\(label).didReceive")
    }

    nonisolated func didFail(_ request: URLRequest, error: APIError) async {
        let status = error.statusCode.map(String.init) ?? "-"
        await record("\(label).didFail(code: \(error.code), status: \(status))")
    }
}

@Suite("Interceptores: orden y didFail en todos los caminos")
struct InterceptorTests {
    private struct GetRequest: BaseRequest {
        typealias Parameters = EmptyParameters
        let path = "/thing"
        let method: HTTPMethod = .GET
    }

    private struct Payload: Decodable { let ok: Bool }

    private func makeService(
        host: String,
        interceptors: [any RequestInterceptor]
    ) throws -> (APIService, URL) {
        let baseURL = try #require(URL(string: "https://\(host)"))
        let configuration = NetworkingConfiguration(baseURL: baseURL, protocolClasses: [MockURLProtocol.self])
        let service = APIService(
            configuration: configuration,
            retryPolicy: .noRetry,
            interceptors: interceptors
        )
        return (service, baseURL)
    }

    @Test("orden: willSend 1→2, didReceive 1→2 en éxito")
    func orderOnSuccess() async throws {
        let first = InterceptorSpy(label: "1")
        let second = InterceptorSpy(label: "2")
        let (service, baseURL) = try makeService(host: "icept-order.test", interceptors: [first, second])
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/thing"),
            response: MockResponse(statusCode: 200, data: Data(#"{"ok":true}"#.utf8))
        ))

        let _: Payload = try await service.execute(request: GetRequest())

        #expect(await first.events == ["1.willSend", "1.didReceive"])
        #expect(await second.events == ["2.willSend", "2.didReceive"])
    }

    @Test("didFail se notifica en non-2xx (M2)")
    func didFailOnHTTPError() async throws {
        let spy = InterceptorSpy(label: "s")
        let (service, baseURL) = try makeService(host: "icept-status.test", interceptors: [spy])
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/thing"),
            response: MockResponse(statusCode: 503)
        ))

        await #expect(throws: APIError.self) {
            let _: Payload = try await service.execute(request: GetRequest())
        }

        let events = await spy.events
        #expect(events.contains("s.didFail(code: httpStatus, status: 503)"),
                "didFail no se notificó para el error de status — eventos: \(events)")
        // didReceive también se llamó (la respuesta llegó): ambos son parte del contrato.
        #expect(events.first == "s.willSend")
        #expect(events.contains("s.didReceive"))
    }

    @Test("didFail se notifica en error de transporte")
    func didFailOnTransportError() async throws {
        let spy = InterceptorSpy(label: "s")
        let (service, baseURL) = try makeService(host: "icept-transport.test", interceptors: [spy])
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/thing"),
            response: MockResponse(statusCode: 200),
            error: URLError(.timedOut)
        ))

        await #expect(throws: APIError.self) {
            let _: Payload = try await service.execute(request: GetRequest())
        }

        let events = await spy.events
        #expect(events.contains("s.didFail(code: transport, status: -)"),
                "didFail no se notificó para el error de transporte — eventos: \(events)")
    }
}

// NOTA: la suite `APIErrorEqualityTests` (M6) se borró en vez de arreglarse.
// Probaba `error == error` sobre `APIError`, y `APIError` dejó de ser
// `Equatable` a propósito en CN-01 (un `==` que ignorara `underlying` — un
// `any Error` — mentiría). La reflexividad de identidad no aporta nada sobre
// un tipo que ya no se compara; `APIErrorTests.swift` cubre `code`,
// `category` y `decodeBody` directamente.
