import Testing
import Foundation
@testable import CoreNetworking
import CoreNetworkingTestSupport

/// `buildURLRequest`: `Empty`/204, `Accept`/`Content-Type`, `makeEncoder` y
/// `sessionConfiguration` (CN-05). Cubre lo que `PipelineTests` y
/// `DecoderConfigurationTests` no probaban porque el request no declaraba su
/// propio `Response` todavía.
@Suite("Construcción del request: Empty/204, Accept/Content-Type, encoder, sessionConfiguration")
struct RequestBuildingTests {

    // MARK: - Un endpoint sin ceremonia

    /// `struct GetGames: BaseRequest { let path = "/games"; let method = HTTPMethod.get }`
    /// compila SIN `typealias`: `Body` y `Response` toman sus defaults
    /// (`Never` y `Empty`).
    private struct GetGames: BaseRequest {
        let path = "/games"
        let method = HTTPMethod.get
    }

    @Test("request mínimo (sin typealias) compila y execute devuelve Empty")
    func minimalRequestReturnsEmpty() async throws {
        let baseURL = try #require(URL(string: "https://request-building-minimal.test"))
        let configuration = NetworkingConfiguration(baseURL: baseURL, protocolClasses: [MockURLProtocol.self])
        let service = APIService(configuration: configuration, retryPolicy: .noRetry)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/games"),
            response: MockResponse(statusCode: 200)
        ))

        // El propio tipo de retorno YA es `Empty` (inferido de `GetGames.Response`,
        // que no declara nada): si esto compila, ya probó lo que hace falta.
        let result: Empty = try await service.execute(GetGames())
        _ = result
    }

    // MARK: - Empty / 204 / cuerpo vacío inesperado

    private struct GetGamesTyped: BaseRequest {
        struct Response: Decodable, Sendable, Equatable { let games: [String] }
        let path = "/games"
        let method = HTTPMethod.get
    }

    @Test("204 sin body con Response == Empty ⇒ éxito, sin tocar el decoder")
    func status204WithEmptyResponseSucceeds() async throws {
        let baseURL = try #require(URL(string: "https://request-building-204.test"))
        let configuration = NetworkingConfiguration(baseURL: baseURL, protocolClasses: [MockURLProtocol.self])
        let service = APIService(configuration: configuration, retryPolicy: .noRetry)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/games"),
            response: MockResponse(statusCode: 204)
        ))

        _ = try await service.execute(GetGames())
    }

    @Test("200 con body vacío y Response != Empty ⇒ .decoding, con response.body.isEmpty")
    func emptyBodyWithNonEmptyResponseIsDecodingError() async throws {
        let baseURL = try #require(URL(string: "https://request-building-emptybody.test"))
        let configuration = NetworkingConfiguration(baseURL: baseURL, protocolClasses: [MockURLProtocol.self])
        let service = APIService(configuration: configuration, retryPolicy: .noRetry)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/games"),
            response: MockResponse(statusCode: 200)
        ))

        do {
            _ = try await service.execute(GetGamesTyped())
            Issue.record("debía lanzar .decoding")
        } catch {
            #expect(error.code == .decoding, "esperaba .decoding, llegó \(error)")
            #expect(error.response?.body.isEmpty == true, "el body vacío debe quedar disponible para diagnóstico")
        }
    }

    @Test("Empty declarado ignora un body no vacío: éxito aunque el servidor mande algo")
    func explicitEmptyResponseIgnoresNonEmptyBody() async throws {
        let baseURL = try #require(URL(string: "https://request-building-empty-ignores-body.test"))
        let configuration = NetworkingConfiguration(baseURL: baseURL, protocolClasses: [MockURLProtocol.self])
        let service = APIService(configuration: configuration, retryPolicy: .noRetry)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/games"),
            response: MockResponse(statusCode: 200, data: Data(#"{"unexpected":true}"#.utf8))
        ))

        _ = try await service.execute(GetGames())
    }

    // MARK: - Accept siempre, Content-Type solo con body

    private struct GetNoBody: BaseRequest {
        let path = "/no-body"
        let method = HTTPMethod.get
    }

    private struct PostWithBody: BaseRequest {
        struct Body: Encodable, Sendable { let title: String }
        let path = "/with-body"
        let method = HTTPMethod.post
        let body: Body?
    }

    @Test("GET sin body: Accept sí, Content-Type no")
    func getRequestOmitsContentType() async throws {
        let baseURL = try #require(URL(string: "https://request-building-headers-get.test"))
        let configuration = NetworkingConfiguration(baseURL: baseURL, protocolClasses: [MockURLProtocol.self])
        let service = APIService(configuration: configuration, retryPolicy: .noRetry)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/no-body"),
            response: MockResponse(statusCode: 200)
        ))

        _ = try await service.execute(GetNoBody())

        let sent = try #require(
            MockURLProtocol.recordedRequests.last { $0.url?.host == "request-building-headers-get.test" }
        )
        let headers = sent.allHTTPHeaderFields ?? [:]
        #expect(headers["Accept"] == "application/json")
        #expect(headers["Content-Type"] == nil, "un GET sin body no describe un Content-Type")
    }

    @Test("POST con body: Accept y Content-Type")
    func postRequestSendsContentType() async throws {
        let baseURL = try #require(URL(string: "https://request-building-headers-post.test"))
        let configuration = NetworkingConfiguration(baseURL: baseURL, protocolClasses: [MockURLProtocol.self])
        let service = APIService(configuration: configuration, retryPolicy: .noRetry)
        MockURLProtocol.register(MockNetworkExchange(
            method: .post,
            url: baseURL.appendingPathComponent("/with-body"),
            response: MockResponse(statusCode: 200)
        ))

        _ = try await service.execute(PostWithBody(body: .init(title: "x")))

        let sent = try #require(
            MockURLProtocol.recordedRequests.last { $0.url?.host == "request-building-headers-post.test" }
        )
        let headers = sent.allHTTPHeaderFields ?? [:]
        #expect(headers["Accept"] == "application/json")
        #expect(headers["Content-Type"] == "application/json")
    }

    // MARK: - makeEncoder

    private struct CreateGame: BaseRequest {
        struct Body: Encodable, Sendable { let gameTitle: String }
        let path = "/games"
        let method = HTTPMethod.post
        let body: Body?
    }

    @Test("makeEncoder con .convertToSnakeCase produce las claves del consumidor en el body enviado")
    func makeEncoderConvertsToSnakeCase() async throws {
        let baseURL = try #require(URL(string: "https://request-building-encoder.test"))
        let configuration = NetworkingConfiguration(
            baseURL: baseURL,
            protocolClasses: [MockURLProtocol.self],
            makeEncoder: {
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                return encoder
            }
        )
        let service = APIService(configuration: configuration, retryPolicy: .noRetry)
        MockURLProtocol.register(MockNetworkExchange(
            method: .post,
            url: baseURL.appendingPathComponent("/games"),
            response: MockResponse(statusCode: 200)
        ))

        _ = try await service.execute(CreateGame(body: .init(gameTitle: "Ada")))

        let sent = try #require(
            MockURLProtocol.recordedRequests.last { $0.url?.host == "request-building-encoder.test" }
        )
        let body = try #require(sent.recordedBodyData, "el body no llegó (¿httpBody vs httpBodyStream?)")
        let json = try #require(String(data: body, encoding: .utf8))
        #expect(json.contains(#""game_title":"Ada""#), "esperaba game_title en snake_case, llegó \(json)")
    }

    // MARK: - sessionConfiguration

    @Test("sessionConfiguration inyectada llega a la URLSession real (protocolClasses vía esa fábrica)")
    func sessionConfigurationFactoryReachesURLSession() async throws {
        let baseURL = try #require(URL(string: "https://request-building-sessionconfig.test"))
        // OJO: `protocolClasses` del init NO se pasa — si la petición llega al
        // mock es porque `sessionConfiguration` (y no el parámetro aparte) es
        // lo que instaló `MockURLProtocol` en la sesión real.
        let configuration = NetworkingConfiguration(
            baseURL: baseURL,
            sessionConfiguration: {
                let sessionConfiguration = URLSessionConfiguration.ephemeral
                sessionConfiguration.protocolClasses = [MockURLProtocol.self]
                return sessionConfiguration
            }
        )
        let service = APIService(configuration: configuration, retryPolicy: .noRetry)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/games"),
            response: MockResponse(statusCode: 200)
        ))

        // Si `sessionConfiguration` no hubiera llegado a la URLSession, esto
        // fallaría con `.transport` (petición real a un host que no existe)
        // en vez de resolverse contra el mock.
        _ = try await service.execute(GetGames())
    }
}

// MARK: - Leer el body grabado

private extension URLRequest {
    /// El body de un `URLRequest` que atravesó el URL loading system real
    /// llega como `httpBodyStream`, no como `httpBody` (gotcha documentado en
    /// el README de testing). Se intenta `httpBody` primero por si acaso.
    var recordedBodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
