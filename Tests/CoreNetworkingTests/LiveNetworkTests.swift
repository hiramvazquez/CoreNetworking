import Foundation
import Security
import Testing
import os

@testable import CoreNetworking

/// Nombre de la variable de entorno que enciende ``LiveNetworkTests``. Vive FUERA del tipo
/// a propósito: referenciar un `static` del propio `LiveNetworkTests` dentro de su propio
/// atributo `@Suite(...)` produce "circular reference resolving attached macro 'Suite'" —
/// el macro necesita evaluar el argumento antes de que el tipo termine de declararse, y en
/// ese momento un miembro `static` de ESE MISMO tipo todavía no existe.
private let liveNetworkTestsEnvironmentVariable = "CORENETWORKING_LIVE_NETWORK_TESTS"

/// Ver el doc comment de ``liveNetworkTestsEnvironmentVariable``: por el mismo motivo, esta
/// condición también vive fuera de `LiveNetworkTests`.
private func liveNetworkTestsAreEnabled() -> Bool {
    ProcessInfo.processInfo.environment[liveNetworkTestsEnvironmentVariable] != nil
}

/// Suite de red REAL, apagada por defecto: `swift test` a secas la salta entera.
///
/// ## Por qué existe esto además de los 226 tests deterministas
///
/// Todo el resto de la suite corre contra `InMemoryTransport` o `MockURLProtocol` —
/// dominios falsos, sin socket real detrás. Eso es perfecto para el pipeline (retry,
/// interceptores, decodificación, mapeo de errores), pero ninguno de los dos atraviesa la
/// costura del transporte real:
///
/// - `MockURLProtocol` sustituye el transporte DESPUÉS de la fase de TLS — nunca dispara un
///   `didReceive challenge:` de verdad. `PinningPipelineTests` lo dice explícitamente en su
///   doc comment: "reproducir esto de verdad exigiría un servidor HTTPS con un certificado
///   que el pinning rechace, algo que ni `URLProtocol` ni `MockURLProtocol` pueden simular".
///   Esta suite es exactamente ese servidor — solo que real, no local (ver más abajo el
///   motivo de no montar uno propio).
/// - Ni `MockURLProtocol` ni `InMemoryTransport` producen gzip real, un `Retry-After` que no
///   escribimos nosotros, una redirección servida por un `gunicorn` de verdad, ni una
///   respuesta lenta de verdad contra la que expire `timeoutIntervalForResource`.
///
/// ## Por qué está apagada por defecto (Swift Testing, no un target aparte)
///
/// `.enabled(if:)` a nivel de `@Suite`, leyendo ``environmentVariable``, en vez de un
/// `testTarget` nuevo en `Package.swift`: un target de test adicional lo compila y corre
/// `swift test` igual que el principal salvo que alguien recuerde `--filter`
/// (`--skip`/`--filter` son responsabilidad de quien invoca, no del paquete) — sigue
/// requiriendo la misma disciplina humana que un CI inestable erosiona con el tiempo. El
/// trait deja el test en el MISMO target (nada que enlazar, nada que mantener sincronizado
/// en `Package.swift`) y lo apaga por construcción: sin la variable de entorno, Swift
/// Testing ni siquiera lo ejecuta — no es un `skip` en tiempo de ejecución, es
/// "deshabilitado", y así lo reporta `swift test`.
///
/// ## Contra qué backend(s)
///
/// - **`dummyjson.com`**: el backend de referencia de `AppStarter` (la app de referencia
///   de este paquete) — continuidad con lo que ya usa un consumidor real. Payload JSON real,
///   404 real con cuerpo, y el host contra el que se mide el pinning en un handshake TLS
///   real (ver más abajo).
/// - **`httpbin.org`**: comportamientos de TRANSPORTE que `dummyjson.com` no ofrece —
///   redirecciones encadenadas, `Content-Encoding: gzip`, un cuerpo servido en más de un
///   frame, un `Retry-After` real, un 429 real y una respuesta deliberadamente lenta para el
///   timeout. Es menos fiable como servicio (lo dice su propia página de estado
///   públicamente) que un backend de producción como `dummyjson.com` — aceptable aquí
///   PRECISAMENTE porque esta suite nunca corre en el camino normal de un PR (ver
///   `.github/workflows/ci.yml`, job `red-real`), y porque cada fallo se anota (ver
///   ``annotatingBackendFailures(backend:_:)``) para no confundirse con una regresión de
///   este paquete.
///
/// ## Por qué NO hay un servidor HTTPS local con certificado autofirmado
///
/// Era la opción más atractiva para el pinning — determinista, sin terceros, pin calculado
/// del propio certificado. Se descartó por un motivo concreto, no por pereza: sobre Apple
/// platforms, servir TLS (con `Network`/`URLSession` en el lado servidor) exige un
/// `SecIdentity`, y la ÚNICA vía pública para construir uno a partir de un certificado y una
/// clave privada propios es importarlo a un llavero (`SecPKCS12Import` + `SecItemAdd`/
/// `SecIdentityCopyPreferred`) — no existe una API pública que construya un `SecIdentity`
/// puramente en memoria. Un runner de CI headless (sin sesión de usuario, `macos-15` de
/// GitHub Actions incluido) puede bloquearse indefinidamente en el diálogo de control de
/// acceso al llavero la primera vez que un proceso pide usar una clave privada importada —
/// sin nadie que pueda pulsar "Permitir", el job cuelga hasta el timeout, no falla con un
/// mensaje claro. Evitarlo exige aprovisionar un llavero desechable y forzar el acceso
/// (`security import … -A`, `security set-key-partition-list`) — infraestructura de CI para
/// mantener, específica de versión de macOS, para conseguir EXACTAMENTE lo que ya se
/// consigue de otra forma: ver ``pinningAcceptsTheRealPinOfALiveHandshake()`` calcula el pin
/// SPKI de lo que `dummyjson.com` esté sirviendo EN ESE MOMENTO (no un valor congelado que
/// quedaría obsoleto en cuanto rote la clave) y prueba que el pinning lo acepta; el test
/// hermano prueba que un pin que nunca puede coincidir lo rechaza con `.untrustedServer`.
/// Entre los dos, exactamente el mismo invariante que un servidor local demostraría —pin
/// correcto pasa, pin incorrecto no— contra un handshake real, sin la fragilidad del
/// llavero.
///
/// ## Qué NO hay aquí
///
/// Nada de lo que ya prueban los 226 tests deterministas: la precedencia de interceptores,
/// el backoff de retry, el parseo de `RetryPolicy`, la lógica pura de
/// `SSLPinningConfiguration.decision(...)`, o el filtrado de headers sensibles en
/// redirecciones (`RedirectSecurityTests` ya lo hace con sockets loopback reales — eso YA
/// es "real": mismo `URLSession`/CFNetwork, mismo camino de redirección, la única diferencia
/// con un host de Internet es la resolución DNS, que `RedirectPolicy` no toca). Si algo aquí
/// empieza a parecerse a un test del pipeline, es que sobra — muévelo a un mock.
@Suite(
    "Red real (opt-in): TLS, HTTP y pinning contra backends públicos",
    .enabled(if: liveNetworkTestsAreEnabled()),
    .serialized
)
struct LiveNetworkTests {
    // MARK: - Interruptor

    /// Nombre de la variable de entorno que enciende esta suite. Ver <doc:Testing>.
    static let environmentVariable = liveNetworkTestsEnvironmentVariable

    // MARK: - Diagnóstico: backend caído vs. CoreNetworking roto

    /// Registra (`Issue.record`, sin cambiar si el test pasa o falla) de qué lado pinta el
    /// error antes de relanzarlo: una categoría típica de "el servidor no respondió como se
    /// esperaba" (offline/timeout/unreachable/servidor) apunta a `backend`; cualquier otra
    /// cosa —una aserción sobre lo que decodificamos, un código inesperado— apunta a una
    /// regresión de este paquete. No es infalible (un 500 real de nuestro propio código
    /// también caería en la primera categoría), pero es la señal correcta el 99% de las
    /// veces y ahorra el primer paso de cualquier triage.
    private func annotatingBackendFailures<T>(
        backend: String,
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            let looksLikeBackend: Bool
            if let apiError = error as? APIError {
                looksLikeBackend = [.offline, .timeout, .unreachable, .server].contains(apiError.category)
            } else if let urlError = error as? URLError {
                looksLikeBackend = Self.transientURLErrorCodes.contains(urlError.code)
            } else {
                looksLikeBackend = false
            }
            if looksLikeBackend {
                Issue.record(
                    """
                    \(backend) no respondió como se esperaba — antes de sospechar de CoreNetworking, \
                    comprueba que \(backend) esté arriba y que esta máquina tenga salida a Internet. \
                    Error: \(error)
                    """
                )
            } else {
                Issue.record(
                    """
                    Fallo que no pinta a \(backend) caído (la forma del error no encaja con un backend \
                    caído) — probablemente una regresión real en CoreNetworking: \(error)
                    """
                )
            }
            throw error
        }
    }

    private static let transientURLErrorCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost,
        .notConnectedToInternet
    ]

    // MARK: - Fixtures

    private struct Product: Decodable, Sendable {
        let id: Int
        let title: String
    }

    private struct GetProduct: BaseRequest {
        typealias Response = Product
        let path = "/products/1"
        let method = HTTPMethod.get
    }

    private struct GetMissingProduct: BaseRequest {
        let path = "/products/999999999"
        let method = HTTPMethod.get
    }

    private struct NotFoundBody: Decodable, Sendable {
        let message: String
    }

    private func dummyJSONService(sslPinning: SSLPinningConfiguration? = nil) -> APIService {
        let configuration = NetworkingConfiguration(baseURL: URL(string: "https://dummyjson.com")!)
        return APIService(configuration: configuration, retryPolicy: .noRetry, sslPinning: sslPinning)
    }

    private func httpbinService() -> APIService {
        let configuration = NetworkingConfiguration(baseURL: URL(string: "https://httpbin.org")!)
        return APIService(configuration: configuration, retryPolicy: .noRetry)
    }

    // MARK: - dummyjson.com: payload real, 404 real

    @Test("un payload JSON real decodifica con el JSONDecoder por defecto del paquete")
    func realPayloadDecodesWithPackageDecoder() async throws {
        let service = dummyJSONService()
        let product = try await annotatingBackendFailures(backend: "dummyjson.com") {
            try await service.execute(GetProduct())
        }
        #expect(product.id == 1)
        #expect(!product.title.isEmpty)
    }

    @Test("un 404 real produce .notFound con el cuerpo del servidor accesible por decodeBody")
    func real404ProducesNotFoundWithAccessibleBody() async throws {
        let service = dummyJSONService()
        do {
            let _: Empty = try await service.execute(GetMissingProduct())
            Issue.record("dummyjson.com/products/999999999 debía responder 404")
        } catch {
            guard error.category == .notFound else {
                // Cualquier categoría que no sea notFound (offline/timeout/server) es un
                // problema del backend, no de nuestro mapeo de status — el helper de
                // arriba ya lo habría anotado si viniera de una llamada envuelta, pero este
                // catch es manual porque también queremos aceptar el caso "no lanzó nada".
                Issue.record("se esperaba .notFound (404 real); llegó \(error.category): \(error)")
                throw error
            }
            let body = try error.decodeBody(NotFoundBody.self)
            #expect(body.message.localizedCaseInsensitiveContains("not found"))
        }
    }

    // MARK: - httpbin.org: redirecciones, gzip, multi-frame, Retry-After, 429, timeout

    @Test("una cadena de redirecciones reales (302 → 302 → 200) se sigue hasta el final")
    func realRedirectChainIsFollowed() async throws {
        let service = httpbinService()
        struct RedirectChain: BaseRequest {
            let path = "/redirect/2"
            let method = HTTPMethod.get
        }
        let response = try await annotatingBackendFailures(backend: "httpbin.org") {
            try await service.data(for: RedirectChain(), progress: nil)
        }
        // No decodificamos nada (httpbin devuelve un JSON de diagnóstico que no nos
        // interesa) — lo que prueba este test es que la cadena de 302 se siguió hasta un
        // 200 real sin que nada tenga que hacer `data(for:)` explícitamente al respecto:
        // si `RedirectPolicy` dejara de seguir redirecciones, esto habría lanzado
        // `APIError(code: .httpStatus, statusCode: 302)` en su lugar.
        #expect(!response.isEmpty)
    }

    @Test("Content-Encoding: gzip real se descomprime de forma transparente antes de decodeBody")
    func realGzipIsTransparentlyDecompressed() async throws {
        let service = httpbinService()
        struct GzipResponse: Decodable, Sendable {
            let gzipped: Bool
        }
        struct GetGzip: BaseRequest {
            typealias Response = GzipResponse
            let path = "/gzip"
            let method = HTTPMethod.get
        }
        let decoded = try await annotatingBackendFailures(backend: "httpbin.org") {
            try await service.execute(GetGzip())
        }
        // Si `Content-Encoding: gzip` llegara SIN descomprimir a `JSONDecoder`, esto
        // fallaría con `.decoding` (los bytes gzip no son JSON válido) en vez de decodificar
        // — la aserción real es "no lanzó", `gzipped` solo confirma que además es el cuerpo
        // correcto y no una respuesta vacía que decodificó por casualidad.
        #expect(decoded.gzipped)
    }

    @Test("un cuerpo servido en más de un frame de red se reensambla completo")
    func realMultiFrameBodyIsReassembled() async throws {
        let service = httpbinService()
        struct StreamLine: BaseRequest {
            let path = "/stream/3"
            let method = HTTPMethod.get
        }
        let data = try await annotatingBackendFailures(backend: "httpbin.org") {
            try await service.data(for: StreamLine(), progress: nil)
        }
        // httpbin sirve `/stream/N` como N objetos JSON, uno por línea, escritos con un
        // `write()` (o un frame HTTP/2) POR LÍNEA — un cuerpo que nunca llega en un solo
        // trozo desde el socket. `data(for:)` debe entregar los tres completos y en orden,
        // no un prefijo cortado a mitad de línea.
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { !$0.isEmpty }
        #expect(lines.count == 3, "se esperaban 3 líneas completas, llegaron \(lines.count): \(data.count) bytes")
    }

    @Test("un 429 real (no escrito por nosotros) mapea a la categoría .rateLimited")
    func real429MapsToRateLimitedCategory() async throws {
        let service = httpbinService()
        struct GetTooManyRequests: BaseRequest {
            let path = "/status/429"
            let method = HTTPMethod.get
        }
        do {
            let _: Empty = try await service.execute(GetTooManyRequests())
            Issue.record("httpbin.org/status/429 debía responder 429")
        } catch {
            guard error.statusCode == 429 else {
                Issue.record("se esperaba un 429 real de httpbin.org; llegó \(error): ¿backend caído?")
                throw error
            }
            #expect(error.category == .rateLimited)
        }
    }

    @Test("un Retry-After real, en minúsculas (HTTP/2), se parsea igual que uno canónico")
    func realRetryAfterHeaderIsParsedCaseInsensitively() async throws {
        // httpbin.org/response-headers no cambia el status HTTP real (el "status_code" que
        // acepta como parámetro solo se ECO en el cuerpo/headers, comprobado con curl) —
        // por eso este test no pasa por `APIService` (que solo adjunta `response` a un
        // `APIError` en un status no-2xx): construye el `APIError.ResponseSummary` a mano a
        // partir de una `HTTPURLResponse` real, exactamente como haría `APIService`, para
        // aislar lo único que puede fallar aquí — el parseo de `Retry-After` contra un
        // nombre de header en la capitalización real que manda un servidor HTTP/2 (siempre
        // minúsculas, nunca "Retry-After" — eso solo lo escribiríamos nosotros en un mock).
        var request = URLRequest(url: URL(string: "https://httpbin.org/response-headers?Retry-After=7")!)
        request.timeoutInterval = 15
        let transport = URLSessionTransport()
        let (body, httpResponse) = try await annotatingBackendFailures(backend: "httpbin.org") {
            try await transport.send(request, progress: nil)
        }
        let summary = APIError.ResponseSummary(response: httpResponse, body: body)
        let error = APIError(code: .httpStatus, response: summary)
        #expect(error.retryAfter == .seconds(7), "cabeceras reales: \(summary.headers.keys.sorted())")
    }

    @Test("una respuesta real lenta agota el timeout de la petición y mapea a .timeout")
    func realSlowResponseTimesOutAndMapsToTimeoutCategory() async throws {
        struct SlowRequest: BaseRequest {
            let path = "/delay/5"
            let method = HTTPMethod.get
            // Muy por debajo de los 5 s reales que tarda httpbin en responder: fuerza un
            // `URLError(.timedOut)` genuino, no uno que un mock produzca por construcción.
            let timeout: Duration = .milliseconds(500)
        }
        // Hallazgo de escribir ESTE test (imposible de ver con un mock, que no espera de
        // verdad): `waitsForConnectivity = true` — el default del paquete, ver
        // `NetworkingConfiguration.defaultSessionConfiguration()` — SUPRIME el timeout de
        // INACTIVIDAD por request contra un servidor que sigue conectado pero no manda ni
        // un byte mientras se espera (exactamente `httpbin.org/delay/5`). Verificado en
        // esta máquina con una `URLSession` mínima: con `waitsForConnectivity = true`, un
        // `timeoutInterval` de 500 ms contra `/delay/5` NO dispara y la llamada completa en
        // ~5 s; con `waitsForConnectivity = false` sí dispara a los 500 ms, como cabría
        // esperar de la documentación de Apple. `MockURLProtocol` no tiene una noción de
        // "conectividad degradada" que active esta rama de CFNetwork, así que ningún test
        // determinista puede tropezar con esto. Este test existe para probar
        // `BaseRequest.timeout`, no esa interacción — por eso fija `waitsForConnectivity =
        // false` explícitamente en vez de heredar el default del paquete.
        let configuration = NetworkingConfiguration(
            baseURL: URL(string: "https://httpbin.org")!,
            sessionConfiguration: {
                let sessionConfiguration = NetworkingConfiguration.defaultSessionConfiguration()
                sessionConfiguration.waitsForConnectivity = false
                return sessionConfiguration
            }
        )
        let service = APIService(configuration: configuration, retryPolicy: .noRetry)
        do {
            let _: Empty = try await service.execute(SlowRequest())
            Issue.record("httpbin.org/delay/5 con timeout de 500 ms debía agotar el tiempo")
        } catch {
            guard error.code == .transport, error.urlError?.code == .timedOut else {
                Issue.record(
                    """
                    se esperaba .transport/.timedOut; llegó \(error) — si es .offline/.unreachable \
                    puede ser la propia httpbin.org, no CoreNetworking
                    """
                )
                throw error
            }
            #expect(error.category == .timeout)
        }
    }

    // MARK: - Pinning contra un handshake TLS real (dummyjson.com)

    /// Delegate mínimo que deja pasar CUALQUIER certificado (`.performDefaultHandling`,
    /// igual que si no hubiera pinning) y se queda con el pin SPKI (SHA-256, base64) del
    /// certificado hoja que el servidor presentó en ESTE handshake — nunca un valor fijado a
    /// mano en este fichero, que quedaría obsoleto en cuanto `dummyjson.com` rote su clave.
    private final class SPKICapturingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let state = OSAllocatedUnfairLock<String?>(initialState: nil)
        var capturedPin: String? { state.withLock { $0 } }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            defer { completionHandler(.performDefaultHandling, nil) }
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                let serverTrust = challenge.protectionSpace.serverTrust,
                let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
                let leaf = chain.first,
                let key = SecCertificateCopyKey(leaf),
                let pin = SPKIHasher.sha256Base64(of: key)
            else {
                return
            }
            state.withLock { $0 = pin }
        }
    }

    /// Dos pines que jamás pueden coincidir con la clave real de `dummyjson.com` (o de
    /// cualquier host): el constructor exige un pin de respaldo (RFC 7469), así que nunca se
    /// puede pasar uno solo, ni siquiera para forzar un rechazo.
    private static let pinImposible = Data(repeating: 0x00, count: 32).base64EncodedString()
    private static let pinImposibleDeRespaldo = Data(repeating: 0xFF, count: 32).base64EncodedString()

    @Test("el pinning ACEPTA el pin SPKI real de un handshake TLS en vivo contra dummyjson.com")
    func pinningAcceptsTheRealPinOfALiveHandshake() async throws {
        let host = "dummyjson.com"
        let capturer = SPKICapturingDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: capturer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        _ = try await annotatingBackendFailures(backend: host) {
            try await session.data(from: URL(string: "https://\(host)/products/1")!)
        }
        let realPin = try #require(
            capturer.capturedPin,
            """
            no se obtuvo un pin SPKI del handshake — o \(host) no respondió, o presentó un \
            tipo/tamaño de clave que SPKIHasher no reconoce (ver su tabla de cabeceras ASN.1)
            """
        )

        let pinning = SSLPinningConfiguration(
            publicKeyHashes: [realPin, Self.pinImposibleDeRespaldo],
            hosts: .only([host])
        )
        let service = dummyJSONService(sslPinning: pinning)
        let product = try await annotatingBackendFailures(backend: host) {
            try await service.execute(GetProduct())
        }
        #expect(product.id == 1, "el pin correcto debía dejar pasar la conexión con normalidad")
    }

    @Test("el pinning RECHAZA un pin que nunca coincide, con .untrustedServer, contra un handshake TLS en vivo")
    func pinningRejectsAWrongPinAgainstALiveHandshake() async throws {
        let host = "dummyjson.com"
        let pinning = SSLPinningConfiguration(
            publicKeyHashes: [Self.pinImposible, Self.pinImposibleDeRespaldo],
            hosts: .only([host])
        )
        let service = dummyJSONService(sslPinning: pinning)

        do {
            let _: Product = try await service.execute(GetProduct())
            Issue.record(
                """
                el pinning debía rechazar la conexión (los pines configurados no pueden coincidir \
                con ninguna clave real) — si esto pasó, el handshake nunca llegó a comparar pines
                """
            )
        } catch {
            guard error.code == .untrustedServer else {
                // .transport/.offline/.unreachable aquí SÍ apunta a que dummyjson.com no
                // respondió (ni siquiera llegó a TLS) — no a que el pinning fallara en
                // aceptar algo que debía rechazar.
                let looksLikeBackend = [.offline, .timeout, .unreachable].contains(error.category)
                let message =
                    looksLikeBackend
                    ? """
                    \(host) no respondió antes de completar el handshake — no se pudo ejercitar \
                    el rechazo del pinning: \(error)
                    """
                    : """
                    se esperaba .untrustedServer; llegó \(error) — posible regresión en el mapeo \
                    PinningFailure → APIError
                    """
                Issue.record(Comment(rawValue: message))
                throw error
            }
        }
    }
}
