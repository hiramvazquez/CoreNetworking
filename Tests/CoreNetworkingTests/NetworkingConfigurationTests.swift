import Foundation
import Testing

@testable import CoreNetworking

/// `NetworkingConfiguration.validateBaseURL(_:)` — el mismo dilema que
/// `SSLPinningConfiguration.validatePins(_:)` ya resolvió: `init` sigue
/// trapeando con `precondition` (una `baseURL` constante de build rota es un
/// bug, cuanto antes falle mejor), pero cuando la URL llega de una fuente
/// remota o no confiable, hace falta poder comprobarla sin arriesgarse a
/// tirar la app abajo en producción.
@Suite("NetworkingConfiguration.validateBaseURL: valida sin trapear")
struct NetworkingConfigurationValidateBaseURLTests {
    @Test("una URL válida (scheme + host) no reporta ningún problema")
    func validURLReportsNoIssue() throws {
        let baseURL = try #require(URL(string: "https://api.example.com"))
        #expect(NetworkingConfiguration.validateBaseURL(baseURL) == nil)
    }

    @Test("sin scheme → .missingScheme")
    func urlWithoutSchemeReportsMissingScheme() throws {
        // Sin "https://" delante, `URL(string:)` no le asigna ningún scheme.
        let baseURL = try #require(URL(string: "api.example.com/path"))
        #expect(baseURL.scheme == nil, "fixture inválida: se esperaba una URL sin scheme")
        #expect(NetworkingConfiguration.validateBaseURL(baseURL) == .missingScheme)
    }

    @Test("sin host → .missingHost")
    func urlWithoutHostReportsMissingHost() throws {
        // Scheme presente, pero sin autoridad ("//host") detrás: `host` es `nil`.
        let baseURL = try #require(URL(string: "https:api.example.com"))
        #expect(baseURL.scheme != nil)
        #expect(baseURL.host == nil, "fixture inválida: se esperaba una URL sin host")
        #expect(NetworkingConfiguration.validateBaseURL(baseURL) == .missingHost)
    }

    @Test("URL de fichero (file:///...) → .missingHost")
    func fileURLReportsMissingHost() throws {
        // Un `file://` sin autoridad (el caso común, `file:///ruta`) tiene
        // scheme pero ningún host — exactamente la misma invariante que
        // rechazaría una `baseURL` remota apuntando por error al filesystem.
        let baseURL = try #require(URL(string: "file:///etc/hosts"))
        #expect(baseURL.scheme == "file")
        #expect(baseURL.host == nil, "fixture inválida: se esperaba un file:// sin host")
        #expect(NetworkingConfiguration.validateBaseURL(baseURL) == .missingHost)
    }

    @Test("BaseURLIssue.description nombra el problema, para el mensaje del precondition")
    func issueDescriptionsAreDescriptive() {
        #expect(NetworkingConfiguration.BaseURLIssue.missingScheme.description.contains("scheme"))
        #expect(NetworkingConfiguration.BaseURLIssue.missingHost.description.contains("host"))
    }

    @Test("init con una URL válida no trapea, y expone la misma baseURL")
    func initWithValidURLSucceeds() throws {
        let baseURL = try #require(URL(string: "https://api.example.com"))
        let configuration = NetworkingConfiguration(baseURL: baseURL)
        #expect(configuration.baseURL == baseURL)
    }

    // MARK: - init: la precondition de verdad (mensaje incluido)
    //
    // Los tests de arriba cubren `validateBaseURL` de forma pura, pero nunca
    // disparan la `precondition` real de `init` — su mensaje (que construye
    // `Self.validateBaseURL` una SEGUNDA vez para el `?? ""`) solo se evalúa
    // cuando la condición falla, así que sin un exit test esa construcción de
    // mensaje queda sin ejercitar. Mismo mecanismo que
    // `PinningInvariantTests.singlePinTrapsTheInit`. Solo macOS: los exit
    // tests de Swift Testing no existen en iOS.
    // NOTA: el closure de `processExitsWith` se compila a un puntero a función
    // C — NO puede capturar contexto externo (ni siquiera un `let baseURL`
    // construido antes con `try #require`; el compilador revienta con "a C
    // function pointer cannot be formed from a closure that captures
    // context"). Por eso la URL se construye como literal DENTRO del closure,
    // igual que `PinningInvariantTests.singlePinTrapsTheInit`.
    #if os(macOS)
    @Test("una baseURL sin scheme revienta el init con un mensaje que nombra el problema")
    func missingSchemeTrapsTheInit() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = NetworkingConfiguration(baseURL: URL(string: "api.example.com/path")!)
        }
        let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
        #expect(stderr.contains("scheme"))
    }

    @Test("una baseURL sin host revienta el init con un mensaje que nombra el problema")
    func missingHostTrapsTheInit() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = NetworkingConfiguration(baseURL: URL(string: "file:///etc/hosts")!)
        }
        let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
        #expect(stderr.contains("host"))
    }
    #endif
}

/// `NetworkingConfiguration.defaultSessionConfiguration()`: los defaults de
/// seguridad/comportamiento que el doc comment del tipo promete
/// (`waitsForConnectivity`, sin cookies, TLS 1.2 mínimo). Nada más en la
/// suite los verificaba — `READMEExamplesTests` solo comprueba que el punto
/// de extensión COMPILA, no qué valores trae de fábrica.
@Suite("NetworkingConfiguration.defaultSessionConfiguration: defaults documentados")
struct NetworkingConfigurationDefaultSessionTests {
    @Test("waitsForConnectivity activado, cookies desactivadas, TLS 1.2 como mínimo")
    func defaultsMatchDocumentation() {
        let configuration = NetworkingConfiguration.defaultSessionConfiguration()
        #expect(configuration.waitsForConnectivity, "esperar red en vez de fallar al instante")
        #expect(!configuration.httpShouldSetCookies, "una API JSON no necesita cookies")
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.tlsMinimumSupportedProtocolVersion == .TLSv12)
    }
}
