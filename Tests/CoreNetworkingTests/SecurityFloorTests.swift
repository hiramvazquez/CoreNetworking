import Foundation
import Testing

@testable import CoreNetworking

/// `NetworkingConfiguration.enforceSecurityFloor(on:defaultResourceTimeout:)`.
///
/// `init(sessionConfiguration:)` acepta cualquier fábrica — nada obliga a que
/// parta de `defaultSessionConfiguration()`. Un consumidor que solo quiera
/// tocar una propiedad puede escribir `{ URLSessionConfiguration.default }` y
/// perder en silencio el TLS mínimo y el timeout de recurso. Esta suite
/// verifica el suelo que evita eso: SOLO SUBE (nunca baja) lo que es un
/// mínimo de seguridad comparable (TLS), y solo RELLENA (nunca pisa una
/// decisión explícita) lo que no tiene un "más seguro" universal (el timeout
/// de recurso).
@Suite("NetworkingConfiguration.enforceSecurityFloor: sube el suelo, nunca lo baja")
struct SecurityFloorTests {
    // MARK: - TLS: sube, nunca baja

    @Test("TLS 1.0 (o el default de Foundation, que ya es TLS 1.0) se sube a TLS 1.2")
    func tlsBelowFloorIsRaised() throws {
        let configuration = URLSessionConfiguration.ephemeral
        // `.TLSv10` está deprecado (con razón) — se construye por `rawValue`
        // (0x0301, el mismo valor que `.TLSv10`) para no arrastrar la
        // deprecación al propio test, que necesita EXACTAMENTE ese valor
        // como fixture de "por debajo del suelo".
        configuration.tlsMinimumSupportedProtocolVersion = try #require(tls_protocol_version_t(rawValue: 0x0301))
        NetworkingConfiguration.enforceSecurityFloor(on: configuration)
        #expect(configuration.tlsMinimumSupportedProtocolVersion == .TLSv12)
    }

    @Test("TLS 1.1 también se sube a TLS 1.2")
    func tls11IsRaisedToFloor() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = try #require(tls_protocol_version_t(rawValue: 0x0302))
        NetworkingConfiguration.enforceSecurityFloor(on: configuration)
        #expect(configuration.tlsMinimumSupportedProtocolVersion == .TLSv12)
    }

    @Test("TLS 1.3, pedido explícitamente, NO se baja a 1.2 — es más seguro, se respeta")
    func tls13IsNeverLowered() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        NetworkingConfiguration.enforceSecurityFloor(on: configuration)
        #expect(configuration.tlsMinimumSupportedProtocolVersion == .TLSv13)
    }

    @Test("TLS 1.2, ya en el suelo, se queda tal cual (no-op)")
    func tls12StaysAtTheFloor() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        NetworkingConfiguration.enforceSecurityFloor(on: configuration)
        #expect(configuration.tlsMinimumSupportedProtocolVersion == .TLSv12)
    }

    // MARK: - timeoutIntervalForResource: rellena, no pisa

    @Test("sin tocar (el default de Foundation, 7 días) se rellena con el suelo del paquete")
    func untouchedResourceTimeoutIsFilled() {
        let configuration = URLSessionConfiguration.ephemeral
        // `URLSessionConfiguration.ephemeral`/`.default` traen 604 800 s
        // (7 días) hasta que alguien los toca — la misma fixture es la
        // documentación del hallazgo.
        #expect(configuration.timeoutIntervalForResource == 604_800)
        NetworkingConfiguration.enforceSecurityFloor(on: configuration)
        #expect(configuration.timeoutIntervalForResource == NetworkingConfiguration.defaultResourceTimeoutFloor)
        #expect(configuration.timeoutIntervalForResource == 60)
    }

    @Test("un timeout de recurso elegido a propósito (p. ej. para una descarga grande) se respeta")
    func explicitResourceTimeoutIsRespected() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 120
        NetworkingConfiguration.enforceSecurityFloor(on: configuration)
        #expect(configuration.timeoutIntervalForResource == 120)
    }

    @Test("un `defaultResourceTimeout` distinto es configurable, para un suelo propio")
    func customDefaultResourceTimeoutIsHonored() {
        let configuration = URLSessionConfiguration.ephemeral
        NetworkingConfiguration.enforceSecurityFloor(on: configuration, defaultResourceTimeout: 300)
        #expect(configuration.timeoutIntervalForResource == 300)
    }

    // MARK: - Lo que el suelo deliberadamente NO toca

    @Test("cookies y waitsForConnectivity no son parte del suelo: se dejan tal cual")
    func nonSecurityPreferencesAreUntouched() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.waitsForConnectivity = false
        NetworkingConfiguration.enforceSecurityFloor(on: configuration)
        #expect(configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .always)
        #expect(!configuration.waitsForConnectivity)
    }

    // MARK: - Retrocompatibilidad: defaultSessionConfiguration() gana el suelo sin romper nada

    @Test("defaultSessionConfiguration() sigue con TLS 1.2, cookies desactivadas y waitsForConnectivity")
    func defaultSessionConfigurationKeepsItsExistingGuarantees() {
        let configuration = NetworkingConfiguration.defaultSessionConfiguration()
        #expect(configuration.tlsMinimumSupportedProtocolVersion == .TLSv12)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.waitsForConnectivity)
    }

    @Test(
        "defaultSessionConfiguration() ahora también trae el timeout de recurso del suelo, no los 7 días de Foundation"
    )
    func defaultSessionConfigurationGainsTheResourceTimeoutFloor() {
        let configuration = NetworkingConfiguration.defaultSessionConfiguration()
        #expect(configuration.timeoutIntervalForResource == NetworkingConfiguration.defaultResourceTimeoutFloor)
    }

    // MARK: - El caso real del HALLAZGO 1: una fábrica que ignora `defaultSessionConfiguration()`

    @Test(
        "una fábrica de consumidor que parte de .default a pelo (el error real que motiva el suelo) también sale con TLS 1.2 y sin el timeout de 7 días"
    )
    func aConsumerFactoryThatIgnoresTheDefaultStillGetsTheFloor() {
        // Exactamente el patrón que enseña (por accidente) HALLAZGO 1: alguien
        // solo quiere ajustar una cosa y parte de `.default` en vez de
        // `defaultSessionConfiguration()`.
        let consumerFactory: @Sendable () -> URLSessionConfiguration = {
            let configuration = URLSessionConfiguration.default
            configuration.httpMaximumConnectionsPerHost = 4
            return configuration
        }
        let configuration = NetworkingConfiguration.enforceSecurityFloor(on: consumerFactory())
        #expect(configuration.tlsMinimumSupportedProtocolVersion == .TLSv12)
        #expect(configuration.timeoutIntervalForResource == NetworkingConfiguration.defaultResourceTimeoutFloor)
        #expect(configuration.httpMaximumConnectionsPerHost == 4, "el resto de la fábrica del consumidor se respeta")
    }
}
