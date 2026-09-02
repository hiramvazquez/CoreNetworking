import Testing
import Foundation
@testable import CoreNetworking
import CoreNetworkingTestSupport

@Suite("Pipeline de execute: URL, headers, decode y mock determinista")
struct PipelineTests {
    private struct SampleResponse: BaseResponse, Equatable {
        let value: Int
    }

    private struct SampleRequest: BaseRequest {
        typealias Parameters = EmptyParameters
        var path = "/sample"
        var method: HTTPMethod = .GET
        var headers: [String: String] = ["Content-Type": "application/json"]
        var queryItems: [URLQueryItem]?
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

    @Test("respuesta mockeada se decodifica (migrado del test XCTest original)")
    func decodesMockedResponse() async throws {
        let (service, baseURL) = try makeService(host: "pipe-decode.test")
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/sample"),
            response: MockResponse(statusCode: 200, data: Data(#"{"value":1}"#.utf8))
        ))

        let result: SampleResponse = try await service.execute(request: SampleRequest())
        #expect(result == SampleResponse(value: 1))
    }

    @Test("merge de headers: los del request PISAN a los de la configuración")
    func headerMerge() async throws {
        let (service, baseURL) = try makeService(host: "pipe-headers.test")
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/sample"),
            response: MockResponse(statusCode: 200, data: Data(#"{"value":1}"#.utf8))
        ))

        var request = SampleRequest()
        request.headers = ["X-Default": "overridden", "X-Request": "req"]
        let _: SampleResponse = try await service.execute(request: request)

        let sent = try #require(
            MockURLProtocol.recordedRequests.last { $0.url?.host == "pipe-headers.test" }
        )
        let headers = sent.allHTTPHeaderFields ?? [:]
        #expect(headers["X-Default"] == "overridden", "el header del request debe pisar al default")
        #expect(headers["X-App-Version"] == "1.0", "el default no pisado debe sobrevivir")
        #expect(headers["X-Request"] == "req")
    }

    @Test("query items van a la URL")
    func queryItemsAppended() async throws {
        let (service, baseURL) = try makeService(host: "pipe-query.test")
        let expectedURL = try #require(URL(string: "https://pipe-query.test/sample?page=2&limit=20"))
        MockURLProtocol.register(MockNetworkExchange(
            url: expectedURL,
            response: MockResponse(statusCode: 200, data: Data(#"{"value":1}"#.utf8))
        ))
        _ = baseURL

        var request = SampleRequest()
        request.queryItems = [
            URLQueryItem(name: "page", value: "2"),
            URLQueryItem(name: "limit", value: "20")
        ]
        let result: SampleResponse = try await service.execute(request: request)
        #expect(result.value == 1)
    }

    @Test("200 con JSON inválido → code == .decoding, con el body y el DecodingError conservados")
    func invalidJSONThrowsDecodingError() async throws {
        let (service, baseURL) = try makeService(host: "pipe-badjson.test")
        let body = Data("no-json".utf8)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/sample"),
            response: MockResponse(statusCode: 200, data: body)
        ))

        do {
            let _: SampleResponse = try await service.execute(request: SampleRequest())
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
        let (service, baseURL) = try makeService(host: "pipe-reuse.test")
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/sample"),
            response: MockResponse(statusCode: 200, data: Data(#"{"value":7}"#.utf8))
        ))

        let first: SampleResponse = try await service.execute(request: SampleRequest())
        let second: SampleResponse = try await service.execute(request: SampleRequest())
        #expect(first == second)

        let count = MockURLProtocol.recordedRequests.filter { $0.url?.host == "pipe-reuse.test" }.count
        #expect(count == 2)
    }

    @Test("URL sin mock registrado falla con code == .transport (no cuelga)")
    func unmatchedURLFails() async throws {
        let (service, _) = try makeService(host: "pipe-unmatched.test")

        do {
            let _: SampleResponse = try await service.execute(request: SampleRequest())
            Issue.record("debía fallar")
        } catch {
            #expect(error.code == .transport, "esperaba .transport, llegó \(error)")
            #expect(error.urlError != nil)
        }
    }
}
