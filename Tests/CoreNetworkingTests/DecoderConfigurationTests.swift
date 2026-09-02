import CoreNetworkingTestSupport
import Foundation
import Testing

@testable import CoreNetworking

/// El decoder que usa `execute` es del CONSUMIDOR, no del paquete.
///
/// Lo encontró la primera app que consumió `CoreNetworking` de verdad: `execute`
/// hacía `try JSONDecoder().decode(...)` con un decoder recién instanciado y sin
/// configurar, así que nadie podía elegir `keyDecodingStrategy` ni
/// `dateDecodingStrategy`. Un backend con `snake_case` obligaba a escribir
/// `CodingKeys` a mano en cada DTO, y uno con fechas ISO-8601 obligaba a
/// decodificar a `String` y convertir después — cada app repitiendo el mismo
/// trabajo que una línea de configuración resuelve.
///
/// Es justo el tipo de hallazgo por el que el paquete se publicó en `0.x` antes
/// de congelar su API: la limitación no se ve hasta que alguien lo usa.
/// ⚠️ El registro de `MockURLProtocol` es estático y COMPARTIDO, y Swift Testing
/// paraleliza las suites por defecto. Estos tests NO llaman a `removeAll()`: la
/// primera versión lo hacía en cada uno y dejó en rojo cinco tests de
/// cancelación de otra suite que corría a la vez —un fallo que no tenía nada que
/// ver con lo que se estaba probando y que costaba entender—. El aislamiento se
/// consigue con un **host distinto por test**, porque el mock casa por URL
/// exacta. Es la disciplina que necesita cualquiera que use este soporte de
/// tests, así que queda escrita aquí y no en la cabeza de quien la descubrió.
@Suite("Configuración del decoder")
struct DecoderConfigurationTests {
    /// `snake_case` en el JSON, camelCase en el tipo y SIN `CodingKeys`: solo
    /// puede funcionar si la estrategia del consumidor llega hasta el decode.
    private struct PerfilResponse: Decodable, Sendable, Equatable {
        let nombreCompleto: String
        let fechaAlta: Date
    }

    private struct PerfilRequest: BaseRequest {
        typealias Response = PerfilResponse
        var path = "/perfil"
        var method: HTTPMethod = .get
        var headers: [String: String] = [:]
        var queryItems: [URLQueryItem] = []
    }

    private func service(
        host: String,
        makeDecoder: @escaping @Sendable () -> JSONDecoder
    ) throws -> (APIService, URL) {
        let baseURL = try #require(URL(string: "https://\(host)"))
        let configuration = NetworkingConfiguration(
            baseURL: baseURL,
            protocolClasses: [MockURLProtocol.self],
            makeDecoder: makeDecoder
        )
        return (APIService(configuration: configuration, retryPolicy: .noRetry), baseURL)
    }

    @Test("la estrategia de claves del consumidor llega hasta el decode")
    func keyDecodingStrategyDelConsumidorSeAplica() async throws {
        let (api, baseURL) = try service(host: "decoder-claves.test") {
            let d = JSONDecoder()
            d.keyDecodingStrategy = .convertFromSnakeCase
            d.dateDecodingStrategy = .iso8601
            return d
        }
        let cuerpo = Data(#"{"nombre_completo":"Ada","fecha_alta":"2026-08-27T10:00:00Z"}"#.utf8)
        MockURLProtocol.register(
            MockNetworkExchange(
                url: baseURL.appendingPathComponent("perfil"),
                response: MockResponse(statusCode: 200, data: cuerpo)
            )
        )

        let perfil: PerfilResponse = try await api.execute(PerfilRequest())

        #expect(perfil.nombreCompleto == "Ada")
        // La fecha prueba la SEGUNDA estrategia: con el decoder por defecto,
        // `fecha_alta` como texto ISO ni siquiera decodifica a `Date`.
        // Se construye la esperada en vez de escribir un epoch a mano: un número
        // mágico aquí ya se equivocó una vez y el fallo no decía por qué.
        let esperada = try #require(
            DateComponents(
                calendar: Calendar(identifier: .gregorian),
                timeZone: TimeZone(secondsFromGMT: 0),
                year: 2026,
                month: 8,
                day: 27,
                hour: 10,
                minute: 0,
                second: 0
            )
            .date
        )
        #expect(perfil.fechaAlta == esperada)
    }

    /// El default no cambia: quien no configure nada sigue teniendo el decoder
    /// de siempre. Sin esta mitad, "hacerlo configurable" podría haber sido
    /// "cambiarlo para todos", que rompería a cualquiera que ya lo usara.
    @Test("sin configurar nada, el comportamiento por defecto es el de antes")
    func elDefaultSigueSiendoElDecoderDeSiempre() async throws {
        struct CrudoResponse: Decodable, Sendable, Equatable {
            // swift-format-ignore: AlwaysUseLowerCamelCase
            let nombre_completo: String  // clave literal del JSON: prueba el decoder SIN estrategia
        }
        struct CrudoRequest: BaseRequest {
            typealias Response = CrudoResponse
            var path = "/crudo"
            var method: HTTPMethod = .get
            var headers: [String: String] = [:]
            var queryItems: [URLQueryItem] = []
        }

        let baseURL = try #require(URL(string: "https://decoder-default.test"))
        let configuration = NetworkingConfiguration(
            baseURL: baseURL,
            protocolClasses: [MockURLProtocol.self]
        )
        let api = APIService(configuration: configuration, retryPolicy: .noRetry)
        MockURLProtocol.register(
            MockNetworkExchange(
                url: baseURL.appendingPathComponent("crudo"),
                response: MockResponse(statusCode: 200, data: Data(#"{"nombre_completo":"Ada"}"#.utf8))
            )
        )

        let crudo: CrudoResponse = try await api.execute(CrudoRequest())
        #expect(crudo.nombre_completo == "Ada")
    }

    /// Un decoder NUEVO por decode, no uno compartido: `JSONDecoder` es una
    /// clase mutable y no es `Sendable`. Compartir la instancia entre peticiones
    /// concurrentes sería una carrera de datos que el compilador no ve, así que
    /// la configuración se pasa como fábrica y no como objeto.
    @Test("la fábrica se invoca por cada decode, sin compartir instancia")
    func laFabricaSeInvocaPorCadaDecode() async throws {
        let veces = Contador()
        let (api, baseURL) = try service(host: "decoder-fabrica.test") {
            veces.incrementa()
            let d = JSONDecoder()
            d.keyDecodingStrategy = .convertFromSnakeCase
            d.dateDecodingStrategy = .iso8601
            return d
        }
        let cuerpo = Data(#"{"nombre_completo":"Ada","fecha_alta":"2026-08-27T10:00:00Z"}"#.utf8)
        MockURLProtocol.register(
            MockNetworkExchange(
                url: baseURL.appendingPathComponent("perfil"),
                response: MockResponse(statusCode: 200, data: cuerpo)
            )
        )

        let _: PerfilResponse = try await api.execute(PerfilRequest())
        let _: PerfilResponse = try await api.execute(PerfilRequest())

        #expect(veces.valor == 2)
    }

    /// Contador con exclusión mutua: el bloque de la fábrica es `@Sendable` y
    /// puede llamarse desde cualquier contexto, así que un `var` suelto sería
    /// justo la carrera que este paquete compila en modo estricto para impedir.
    private final class Contador: @unchecked Sendable {
        private let candado = NSLock()
        private var n = 0
        func incrementa() {
            candado.lock()
            n += 1
            candado.unlock()
        }
        var valor: Int {
            candado.lock()
            defer { candado.unlock() }
            return n
        }
    }
}
