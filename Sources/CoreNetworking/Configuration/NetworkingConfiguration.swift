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
/// Inyecta `sessionConfiguration` para interceptar el tráfico con un
/// `URLProtocol` de mock (p. ej. `MockURLProtocol` de
/// `CoreNetworkingTestSupport`):
/// ```swift
/// let configuration = NetworkingConfiguration(
///     baseURL: URL(string: "https://unit.test")!,
///     sessionConfiguration: {
///         let sessionConfiguration = URLSessionConfiguration.ephemeral
///         sessionConfiguration.protocolClasses = [MockURLProtocol.self]
///         return sessionConfiguration
///     }
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
    @available(*, deprecated, message: "Configura protocolClasses en sessionConfiguration")
    public var protocolClasses: [URLProtocol.Type]? { legacyProtocolClasses }

    /// Almacenamiento real de `protocolClasses` (arriba). Vive sin la
    /// anotación de deprecación porque el paquete SIGUE necesitando leerlo
    /// mientras exista — la convenience `init` de `APIService` lo fusiona en
    /// `sessionConfiguration` para que lo que alguien pase aquí siga
    /// funcionando —: lo deprecado es la LECTURA pública, no el dato que la
    /// sostiene por dentro.
    let legacyProtocolClasses: [URLProtocol.Type]?

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
    /// Es también, hoy, el único punto de entrada real para instalar un
    /// `URLProtocol` de mock: `protocolClasses` (arriba) queda deprecado en
    /// favor de esto — una sola forma de hacerlo, no dos que conviven. Ver el
    /// bloque "Tests / Previews" en el doc del tipo.
    ///
    /// El default (`defaultSessionConfiguration`) activa `waitsForConnectivity`
    /// (esperar a que vuelva la red en vez de fallar al instante — es la
    /// alternativa correcta a reintentar `notConnectedToInternet`, ver
    /// `APIError.isRetryable`), desactiva cookies (`httpShouldSetCookies`,
    /// `httpCookieAcceptPolicy`: una API JSON no las necesita y aceptarlas es
    /// superficie de ataque sin beneficio) y aplica ``enforceSecurityFloor(on:defaultResourceTimeout:)``
    /// (TLS 1.2 mínimo y un `timeoutIntervalForResource` sensato — ver ahí el
    /// porqué de cada uno).
    public let sessionConfiguration: @Sendable () -> URLSessionConfiguration

    /// La `URLSessionConfiguration` por defecto de este paquete.
    public static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // El suelo de seguridad (TLS mínimo + timeout de recurso) se aplica
        // aquí también, y no solo cuando alguien pasa una fábrica propia:
        // una sola fuente de verdad para "qué es lo mínimo aceptable", en
        // vez de duplicar `tlsMinimumSupportedProtocolVersion = .TLSv12` a
        // mano en dos sitios que podrían divergir con el tiempo.
        return enforceSecurityFloor(on: configuration)
    }

    // MARK: - Suelo de seguridad (independiente de qué fábrica use el consumidor)

    /// El valor de `timeoutIntervalForResource` que trae Foundation cuando
    /// NADIE lo toca: 7 días (604 800 s). Es el sentinel que usa
    /// ``enforceSecurityFloor(on:defaultResourceTimeout:)`` para distinguir
    /// "no lo tocaron" de "lo pusieron a propósito, aunque sea un valor raro".
    static let unsetFoundationResourceTimeout: TimeInterval = 604_800

    /// Valor de `timeoutIntervalForResource` que aplica el suelo cuando
    /// detecta que nadie lo tocó (ver ``unsetFoundationResourceTimeout``).
    ///
    /// 60 s: el doble del timeout de INACTIVIDAD por request
    /// (`BaseRequest.timeout`, 30 s por defecto — mide huecos entre paquetes,
    /// no la duración total), margen suficiente para una respuesta lenta pero
    /// que sigue progresando, y cuatro órdenes de magnitud por debajo del
    /// default silencioso de Foundation. No es el valor correcto para TODO:
    /// una subida/descarga de un fichero grande es legítimamente más larga, y
    /// quien la haga debe fijar su propio `timeoutIntervalForResource` más alto
    /// (ver <doc:Transport>, que ya documenta `c.timeoutIntervalForResource = 120`
    /// como ejemplo). `URLSessionConfiguration.timeoutIntervalForResource` es
    /// un ajuste de SESIÓN, no de request individual — hoy no hay forma de que
    /// `execute` y `download`/`upload` usen valores distintos dentro de la
    /// misma `URLSession` (ver `URLSessionTransport`, fuera del alcance de
    /// este fichero).
    public static let defaultResourceTimeoutFloor: TimeInterval = 60

    /// Sube (nunca baja) una `URLSessionConfiguration` cualquiera al mínimo de
    /// seguridad de este paquete.
    ///
    /// Existe porque `init(sessionConfiguration:)` acepta CUALQUIER fábrica:
    /// alguien que solo quiera cambiar `timeoutIntervalForResource` puede
    /// escribir `{ URLSessionConfiguration.default }` y perder en silencio el
    /// TLS 1.2 mínimo (y quedarse con los 7 días de Foundation en
    /// `timeoutIntervalForResource`) sin ningún aviso. Esta función es el
    /// suelo que no depende de que quien la llama se acuerde de partir de
    /// ``defaultSessionConfiguration()``.
    ///
    /// Dos reglas, una por propiedad, cada una justificada por separado:
    ///
    /// - `tlsMinimumSupportedProtocolVersion`: SOLO SUBE, nunca baja. Si el
    ///   consumidor pidió TLS 1.3 (o algo que este paquete no sepa comparar,
    ///   como una versión DTLS), se respeta — es tan seguro o más. Si pidió
    ///   TLS 1.0/1.1, o no dijo nada (el default de Foundation es TLS 1.0), se
    ///   sube a TLS 1.2. Comparar por `rawValue` es seguro aquí: los cuatro
    ///   valores TLS de `tls_protocol_version_t` son consecutivos y crecientes
    ///   con la versión (0x0301…0x0304), y los dos valores DTLS son mucho
    ///   MAYORES que cualquier TLS (0xfeff, 0xfefd) — así que nunca se tocan
    ///   por esta comparación, ni deben: DTLS no es "más o menos seguro" que
    ///   TLS, es un protocolo distinto (datagramas), y este paquete no tiene
    ///   base para imponer nada ahí.
    /// - `timeoutIntervalForResource`: solo se toca si sigue en el sentinel de
    ///   "nadie lo tocó" (``unsetFoundationResourceTimeout``, los 7 días de
    ///   Foundation). Cualquier otro valor — el que ponga
    ///   ``defaultResourceTimeoutFloor``, el `120` del ejemplo de
    ///   <doc:Transport>, o cualquier cosa que el consumidor haya elegido a
    ///   propósito — se respeta tal cual. A diferencia de TLS, aquí no hay un
    ///   orden "más seguro" universal (un valor grande es legítimo para una
    ///   descarga grande), así que la única señal fiable de "esto es un
    ///   descuido, no una decisión" es que siga siendo EXACTAMENTE el default
    ///   de Foundation.
    ///
    /// Deliberadamente NO toca `httpShouldSetCookies`/`httpCookieAcceptPolicy`
    /// ni `waitsForConnectivity`: son preferencias legítimas del consumidor,
    /// no un suelo de seguridad.
    /// - Cookies: desactivarlas es la postura correcta para una API JSON
    ///   (``defaultSessionConfiguration()`` lo hace), pero hay backends reales
    ///   que autentican con cookies de sesión — forzar `.never` ahí rompería
    ///   la app en vez de protegerla. Aceptar cookies no abre una brecha de
    ///   TLS ni de integridad; es, como mucho, una superficie de ataque
    ///   adicional que el consumidor puede evaluar y asumir con conocimiento
    ///   de causa, cosa que TLS 1.0 o un timeout de 7 días no permiten evaluar
    ///   porque son fallos silenciosos.
    /// - `waitsForConnectivity`: es UX (esperar a que vuelva la red en vez de
    ///   fallar al instante), no seguridad — no pertenece a este suelo.
    ///
    /// - Parameters:
    ///   - sessionConfiguration: la configuración a elevar, MUTADA in place
    ///     (y devuelta, para poder encadenar). `URLSessionConfiguration` es
    ///     `Sendable` pero es una clase — el resto del tipo la trata como
    ///     "una construcción, una fábrica" (ver el doc de `sessionConfiguration`
    ///     arriba); esta función respeta esa misma disciplina.
    ///   - defaultResourceTimeout: qué usar cuando `timeoutIntervalForResource`
    ///     sigue en el sentinel de Foundation. Configurable para quien quiera
    ///     un suelo distinto (p. ej. un servicio dedicado a
    ///     descargas/subidas) sin renunciar al resto del suelo.
    /// - Returns: la misma instancia que se pasó, para poder escribir
    ///   `enforceSecurityFloor(on: miConfiguracion)` como expresión.
    @discardableResult
    public static func enforceSecurityFloor(
        on sessionConfiguration: URLSessionConfiguration,
        defaultResourceTimeout: TimeInterval = defaultResourceTimeoutFloor
    ) -> URLSessionConfiguration {
        let minimumTLSVersion = tls_protocol_version_t.TLSv12
        if sessionConfiguration.tlsMinimumSupportedProtocolVersion.rawValue < minimumTLSVersion.rawValue {
            sessionConfiguration.tlsMinimumSupportedProtocolVersion = minimumTLSVersion
        }

        if sessionConfiguration.timeoutIntervalForResource == unsetFoundationResourceTimeout {
            sessionConfiguration.timeoutIntervalForResource = defaultResourceTimeout
        }

        return sessionConfiguration
    }

    // MARK: - Invariantes de `baseURL` (puro, testable sin trapear)

    /// Por qué una `baseURL` no es aceptable. Ver ``validateBaseURL(_:)``.
    public enum BaseURLIssue: Sendable, Equatable, CustomStringConvertible {
        /// La URL no tiene `scheme` (p. ej. viene de un string sin `https://`).
        case missingScheme
        /// La URL no tiene `host` (p. ej. `file:///etc/hosts`, o una URL con
        /// scheme pero sin autoridad).
        case missingHost

        public var description: String {
            switch self {
            case .missingScheme:
                "NetworkingConfiguration: baseURL sin scheme — debe incluir uno, "
                    + "p. ej. https://api.example.com"
            case .missingHost:
                "NetworkingConfiguration: baseURL sin host — debe incluir uno, "
                    + "p. ej. https://api.example.com"
            }
        }
    }

    /// Comprueba `baseURL` contra la misma invariante que exige `init`
    /// (scheme y host), sin trapear. `nil` significa que la URL es aceptable.
    ///
    /// Úsalo ANTES de `init` cuando la URL venga de una fuente remota o no
    /// confiable (config remota, deep link, valor introducido por la
    /// persona usuaria) — ahí una URL rota es un input de runtime que hay
    /// que manejar, no un error de programación que deba tirar la app abajo.
    /// Para una `baseURL` constante conocida en tiempo de compilación, sigue
    /// siendo preferible dejar que `init` trapee: un typo ahí es un bug, y
    /// cuanto antes falle, mejor.
    public static func validateBaseURL(_ baseURL: URL) -> BaseURLIssue? {
        guard baseURL.scheme != nil else { return .missingScheme }
        guard baseURL.host != nil else { return .missingHost }
        return nil
    }

    /// Crea una configuración de red.
    ///
    /// - Precondition: `baseURL` pasa ``validateBaseURL(_:)`` — debe tener
    ///   scheme y host. Se valida con `precondition` (y no con `init throws`)
    ///   porque una URL base rota es un error de programación detectable en
    ///   el arranque, no un input de runtime recuperable: preferimos el
    ///   crash inmediato con mensaje claro al fallback silencioso que
    ///   existía antes (example.com). Si `baseURL` viene de una fuente
    ///   remota o no confiable, usa ``validateBaseURL(_:)`` primero.
    public init(
        baseURL: URL,
        defaultHeaders: [String: String] = [:],
        protocolClasses: [URLProtocol.Type]? = nil,
        makeDecoder: @escaping @Sendable () -> JSONDecoder = { JSONDecoder() },
        makeEncoder: @escaping @Sendable () -> JSONEncoder = { JSONEncoder() },
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = NetworkingConfiguration
            .defaultSessionConfiguration
    ) {
        // El mensaje se construye a partir del mismo `BaseURLIssue` que
        // `validateBaseURL(_:)` expone — una sola fuente de verdad para "qué
        // está mal", trapee o no.
        precondition(
            Self.validateBaseURL(baseURL) == nil,
            "NetworkingConfiguration: baseURL inválida ('\(baseURL)') — "
                + (Self.validateBaseURL(baseURL)?.description ?? "")
        )
        self.baseURL = baseURL
        self.defaultHeaders = defaultHeaders
        self.legacyProtocolClasses = protocolClasses
        self.makeDecoder = makeDecoder
        self.makeEncoder = makeEncoder
        self.sessionConfiguration = sessionConfiguration
    }
}
