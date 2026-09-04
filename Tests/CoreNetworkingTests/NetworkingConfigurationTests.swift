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
}
