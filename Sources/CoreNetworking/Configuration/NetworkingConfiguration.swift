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
///     defaultHeaders: ["X-App-Version": "1.0"],
///     environment: "production"
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

    /// Nombre del entorno actual (p. ej. "staging", "production"). Solo metadato.
    public let environment: String

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
    /// Es una FÁBRICA y no un `JSONDecoder` porque `JSONDecoder` es una clase
    /// mutable y no `Sendable`: compartir una instancia entre peticiones
    /// concurrentes sería una carrera de datos que el compilador no puede ver.
    /// Se crea uno por decode, que es lo que ya se hacía.
    public let makeDecoder: @Sendable () -> JSONDecoder

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
        environment: String = "production",
        protocolClasses: [URLProtocol.Type]? = nil,
        makeDecoder: @escaping @Sendable () -> JSONDecoder = { JSONDecoder() }
    ) {
        precondition(
            baseURL.scheme != nil && baseURL.host != nil,
            "NetworkingConfiguration: baseURL inválida ('\(baseURL)') — debe incluir scheme y host, p. ej. https://api.example.com"
        )
        self.baseURL = baseURL
        self.defaultHeaders = defaultHeaders
        self.environment = environment
        self.protocolClasses = protocolClasses
        self.makeDecoder = makeDecoder
    }
}
