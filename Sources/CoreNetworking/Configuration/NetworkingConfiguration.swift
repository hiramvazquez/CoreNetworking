//
//  NetworkingConfiguration.swift
//  CoreNetworking
//

import Foundation

/// Configuración de red inmutable que se inyecta en `APIService` al construirlo.
///
/// No hay singleton global ni fallback: cada servicio recibe explícitamente su
/// configuración. Una configuración inválida (URL base sin scheme/host) es un
/// error de programación y falla en la construcción, no en el primer request.
///
/// ## Ejemplo
/// ```swift
/// let configuration = NetworkingConfiguration(
///     baseURL: URL(string: "https://api.myapp.com")!, // fuerza el unwrap solo si es literal conocido
///     defaultHeaders: ["X-App-Version": "1.0"]
/// )
/// let service = APIService(configuration: configuration)
/// ```
///
/// ## Tests / Previews
/// Inyecta `protocolClasses` para interceptar el tráfico con un `URLProtocol`
/// de mock (p. ej. `MockURLProtocol` de `CoreNetworkingTestSupport`):
/// ```swift
/// let configuration = NetworkingConfiguration(
///     baseURL: URL(string: "https://unit.test")!,
///     protocolClasses: [MockURLProtocol.self]
/// )
/// ```
public struct NetworkingConfiguration: Sendable {
    /// URL base del backend. Debe tener scheme y host.
    public let baseURL: URL

    /// Headers comunes que se envían en todas las peticiones.
    /// Los headers del request concreto tienen precedencia sobre estos.
    public let defaultHeaders: [String: String]

    /// Clases `URLProtocol` a instalar en la `URLSession` del servicio.
    /// Pensado para inyectar mocks en tests/previews. `nil` = tráfico real.
    public let protocolClasses: [URLProtocol.Type]?

    /// Fábrica del `JSONDecoder` con el que se decodifican las respuestas.
    ///
    /// Es del CONSUMIDOR, no del paquete: cada backend tiene su convención de
    /// claves y de fechas, y sin esto había que repetir `CodingKeys` en cada DTO
    /// —o decodificar las fechas a `String` y convertirlas a mano—. Lo pidió la
    /// primera app que consumió el paquete de verdad.
    ///
    /// Es una FÁBRICA y no un `JSONDecoder` compartido — no porque
    /// `JSONDecoder` no sea `Sendable` (lo ES, en el SDK actual: verificado
    /// con `swiftc -swift-version 6`), sino porque es una clase MUTABLE:
    /// reconfigurarla desde dos llamadas concurrentes sería una carrera de
    /// datos real, aunque el compilador no la vea a través de `Sendable`. Una
    /// fábrica que construye una instancia fresca por decode es aislamiento
    /// por construcción, más simple que sincronizar una instancia compartida.
    public let makeDecoder: @Sendable () -> JSONDecoder

    /// Fábrica del `JSONEncoder` con el que se codifica el `body` de los
    /// requests. Mismo racional que `makeDecoder` (y mismo motivo: es una
    /// clase mutable, no una carencia de `Sendable`) y misma razón de ser:
    /// sin esto, un backend en `snake_case` obligaba a `makeDecoder` con
    /// `convertFromSnakeCase` pero dejaba el encoder por defecto sin forma de
    /// producir esas mismas claves al enviar.
    public let makeEncoder: @Sendable () -> JSONEncoder

    /// Fábrica de la `URLSessionConfiguration` de la sesión del servicio.
    ///
    /// Es una fábrica por el mismo motivo que `makeDecoder`/`makeEncoder`:
    /// `URLSessionConfiguration` es `Sendable` pero mutable, y esta fábrica
    /// se invoca una sola vez (al construir `APIService`), así que el
    /// argumento de aislamiento por request no aplica aquí — es, simplemente,
    /// el mismo punto de entrada que el resto de la configuración inyectada.
    ///
    /// El default (`defaultSessionConfiguration`) activa `waitsForConnectivity`
    /// (esperar a que vuelva la red en vez de fallar al instante — es la
    /// alternativa correcta a reintentar `notConnectedToInternet`, ver
    /// `APIError.isRetryable`), desactiva cookies (`httpShouldSetCookies`,
    /// `httpCookieAcceptPolicy`: una API JSON no las necesita y aceptarlas es
    /// superficie de ataque sin beneficio) y fija `tlsMinimumSupportedProtocolVersion`
    /// a TLS 1.2 (el mínimo aceptable hoy; nunca menos por defecto).
    public let sessionConfiguration: @Sendable () -> URLSessionConfiguration

    /// La `URLSessionConfiguration` por defecto de este paquete.
    ///
    /// NOTA (CN-03): hoy la construye `APIService.init`. `CN-03` reubica esa
    /// construcción en `URLSessionTransport`; esta fábrica es el punto de
    /// inyección que sobrevive a ese cambio.
    public static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }

    /// Crea una configuración de red.
    ///
    /// - Precondition: `baseURL` debe tener scheme y host. Se valida con
    ///   `precondition` (y no con `init throws`) porque una URL base rota es un
    ///   error de programación detectable en el arranque, no un input de runtime
    ///   recuperable: preferimos el crash inmediato con mensaje claro al fallback
    ///   silencioso que existía antes (example.com).
    public init(
        baseURL: URL,
        defaultHeaders: [String: String] = [:],
        protocolClasses: [URLProtocol.Type]? = nil,
        makeDecoder: @escaping @Sendable () -> JSONDecoder = { JSONDecoder() },
        makeEncoder: @escaping @Sendable () -> JSONEncoder = { JSONEncoder() },
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = NetworkingConfiguration
            .defaultSessionConfiguration
    ) {
        precondition(
            baseURL.scheme != nil && baseURL.host != nil,
            "NetworkingConfiguration: baseURL inválida ('\(baseURL)') — debe incluir scheme y host, p. ej. https://api.example.com"
        )
        self.baseURL = baseURL
        self.defaultHeaders = defaultHeaders
        self.protocolClasses = protocolClasses
        self.makeDecoder = makeDecoder
        self.makeEncoder = makeEncoder
        self.sessionConfiguration = sessionConfiguration
    }
}
