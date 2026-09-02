import Testing
import Foundation
@testable import CoreNetworking
import CoreNetworkingTestSupport

@Suite("Pipeline de execute: URL, headers, decode — InMemoryTransport (unidad)")
struct PipelineTests {
    private struct SampleResponse: Decodable, Sendable, Equatable {
        let value: Int
    }

    private struct SampleRequest: BaseRequest {
        typealias Response = SampleResponse
        var path = "/sample"
        var method: HTTPMethod = .get
        var headers: [String: String] = [:]
        var queryItems: [URLQueryItem] = []
    }

    private let baseURL = URL(string: "https://unit.test")!

    private func makeService(transport: InMemoryTransport) -> APIService {
        let configuration = NetworkingConfiguration(
            baseURL: baseURL,
            defaultHeaders: ["X-App-Version": "1.0", "X-Default": "default"]
        )
        return APIService(configuration: configuration, transport: transport, retryPolicy: .noRetry)
    }

    @Test("respuesta mockeada se decodifica")
    func decodesMockedResponse() async throws {
        let transport = InMemoryTransport()
        await transport.register(InMemoryTransport.Exchange(
            url: baseURL.appendingPathComponent("/sample"),
            response: .response(status: 200, body: Data(#"{"value":1}"#.utf8))
        ))
        let service = makeService(transport: transport)

        let result = try await service.execute(SampleRequest())
        #expect(result == SampleResponse(value: 1))
    }

    @Test("query items van a la URL")
    func queryItemsAppended() async throws {
        let transport = InMemoryTransport()
        let expectedURL = try #require(URL(string: "https://unit.test/sample?page=2&limit=20"))
        await transport.register(InMemoryTransport.Exchange(
            url: expectedURL,
            response: .response(status: 200, body: Data(#"{"value":1}"#.utf8))
        ))
        let service = makeService(transport: transport)

        var request = SampleRequest()
        request.queryItems = [
            URLQueryItem(name: "page", value: "2"),
            URLQueryItem(name: "limit", value: "20")
        ]
        let result = try await service.execute(request)
        #expect(result.value == 1)
    }

    @Test("200 con JSON inválido → code == .decoding, con el body y el DecodingError conservados")
    func invalidJSONThrowsDecodingError() async throws {
        let transport = InMemoryTransport()
        let body = Data("no-json".utf8)
        await transport.register(InMemoryTransport.Exchange(
            url: baseURL.appendingPathComponent("/sample"),
            response: .response(status: 200, body: body)
        ))
        let service = makeService(transport: transport)

        do {
            let _ = try await service.execute(SampleRequest())
            Issue.record("debía lanzar .decoding")
        } catch {
            // typed throws: error ya es APIError
            #expect(error.code == .decoding, "esperaba .decoding, llegó \(error)")
            #expect(error.response?.body == body, "el body debe quedar disponible para diagnóstico")
            #expect(error.underlying is DecodingError, "underlying debe ser el DecodingError original")
        }
    }

    @Test("mock determinista y reutilizable: el mismo mock responde N veces")
    func mockIsReusable() async throws {
        let transport = InMemoryTransport()
        let url = baseURL.appendingPathComponent("/sample")
        await transport.register(InMemoryTransport.Exchange(
            url: url,
            response: .response(status: 200, body: Data(#"{"value":7}"#.utf8))
        ))
        let service = makeService(transport: transport)

        let first = try await service.execute(SampleRequest())
        let second = try await service.execute(SampleRequest())
        #expect(first == second)

        #expect(await transport.recorded.count == 2)
    }
}

// MARK: - Integración a través de MockURLProtocol / URLSession real

/// Un puñado de tests deliberadamente NO migrados a `InMemoryTransport`: estos
/// atraviesan el URL loading system de verdad (`URLSessionTransport` +
/// `MockURLProtocol`), que es donde vive el merge de headers real y el
/// mapeo `.transport` de una URL sin mock — comportamiento de `URLSession`
/// que `InMemoryTransport` no puede ejercitar porque nunca toca `URLSession`.
@Suite("Pipeline de execute: integración con MockURLProtocol")
struct PipelineIntegrationTests {
    private struct SampleResponse: Decodable, Sendable, Equatable {
        let value: Int
    }

    private struct SampleRequest: BaseRequest {
        typealias Response = SampleResponse
        var path = "/sample"
        var method: HTTPMethod = .get
        var headers: [String: String] = ["Content-Type": "application/json"]
        var queryItems: [URLQueryItem] = []
    }

    private func makeService(host: String) throws -> (APIService, URL) {
        let baseURL = try #require(URL(string: "https://\(host)"))
        let configuration = NetworkingConfiguration(
            baseURL: baseURL,
            defaultHeaders: ["X-App-Version": "1.0", "X-Default": "default"],
            protocolClasses: [MockURLProtocol.self]
        )
        return (APIService(configuration: configuration, retryPolicy: .noRetry), baseURL)
    }

    @Test("merge de headers a través de URLSession real: los del request PISAN a los de la configuración")
    func headerMerge() async throws {
        let (service, baseURL) = try makeService(host: "pipe-headers.test")
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/sample"),
            response: MockResponse(statusCode: 200, data: Data(#"{"value":1}"#.utf8))
        ))

        var request = SampleRequest()
        request.headers = ["X-Default": "overridden", "X-Request": "req"]
        let _: SampleResponse = try await service.execute(request)

        let sent = try #require(
            MockURLProtocol.recordedRequests.last { $0.url?.host == "pipe-headers.test" }
        )
        let headers = sent.allHTTPHeaderFields ?? [:]
        #expect(headers["X-Default"] == "overridden", "el header del request debe pisar al default")
        #expect(headers["X-App-Version"] == "1.0", "el default no pisado debe sobrevivir")
        #expect(headers["X-Request"] == "req")
    }

    @Test("URL sin mock registrado falla con code == .transport (no cuelga)")
    func unmatchedURLFails() async throws {
        let (service, _) = try makeService(host: "pipe-unmatched.test")

        do {
            let _: SampleResponse = try await service.execute(SampleRequest())
            Issue.record("debía fallar")
        } catch {
            #expect(error.code == .transport, "esperaba .transport, llegó \(error)")
            #expect(error.urlError != nil)
        }
    }
}
