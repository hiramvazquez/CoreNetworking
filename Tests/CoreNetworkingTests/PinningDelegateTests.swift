import Testing
import Foundation
import Security
@testable import CoreNetworking

/// El DELEGADO de pinning, que es quien de verdad decide en runtime si se
/// acepta un certificado.
///
/// Estos tests existen porque la primera medición de mutación del paquete
/// (`swift-mutation-testing`, score global 42.1%) señaló `SessionDelegates.swift`
/// como el archivo con MÁS mutantes vivos: invertir `if result == .failed` o
/// cambiar `== NSURLAuthenticationMethodServerTrust` por `!=` no rompía ningún
/// test. La causa era un hueco de cableado, no de lógica: `PinningTests.swift`
/// ejercita `SSLPinningConfiguration.validate()` a fondo y el mapeo
/// resultado→disposition, pero nadie invocaba
/// `urlSession(_:didReceive:completionHandler:)`, que es el método que los une.
///
/// Es el mismo patrón del bug que la auditoría ya encontró en este paquete —la
/// sesión se creaba con delegate y se descartaba, o sea el validador funcionaba
/// y el cableado no—, esta vez en la capa de tests: doce tests daban sensación
/// de cobertura sobre el punto más sensible del paquete y el cableado real no
/// estaba verificado.
///
/// ## Qué matan estos tests, y qué NO
///
/// Verificado mutando `SessionDelegates.swift` a mano:
/// - invertir `result == .validated` (la línea que decide si se entrega
///   credencial) → **muere**;
/// - invertir el guard `== NSURLAuthenticationMethodServerTrust` → **muere**;
/// - invertir `if result == .failed` → **SOBREVIVE**, y seguirá haciéndolo.
///
/// Ese último no controla ninguna decisión: solo decide si se emite el log de
/// "pinning falló". Su efecto observable es una línea en `os.Logger`, y matarlo
/// exigiría inyectar el logger en el delegado — un cambio de diseño del
/// paquete, no un test más. No es cosmético del todo: invertido, un fallo de
/// pinning en producción dejaría de avisar, y AGENTS.md §6 pide que los fallos
/// de observabilidad se hagan visibles. Queda registrado como finding en vez de
/// fingir que esta suite lo cubre.
@Suite("Delegado de pinning: el cableado que decide en runtime")
struct PinningDelegateTests {

    // MARK: - Fixture

    /// Certificado autofirmado EC P-256 generado con openssl para estos tests.
    /// No es un secreto: es una clave PÚBLICA de un certificado de juguete que
    /// no protege nada. Se embebe en vez de generarse al vuelo para que el test
    /// no dependa de tener openssl en la máquina.
    ///
    ///   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    ///     -keyout k.pem -out c.pem -days 3650 -nodes -subj "/CN=pinning.test"
    private static let certificadoDER = """
    MIIBgjCCASmgAwIBAgIURhTNAZdQ3+8Wo/yucOXP6k0wy/QwCgYIKoZIzj0EAwIwFzEVMBMGA1UEAwwMcGlubmluZy50ZXN0MB4X\
    DTI2MDgyODE1MjMxOFoXDTM2MDgyNTE1MjMxOFowFzEVMBMGA1UEAwwMcGlubmluZy50ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0D\
    AQcDQgAELzCfRZ4CeW7OsKx7MHQfnD6bX5QDiAa7Grj+SEQNzefKTAwr3x6ABMFdE3dF9Iu/1213azkKg8srtm6seYJf4qNTMFEw\
    HQYDVR0OBBYEFGm84OwzN47FA022UklrpSvWv05hMB8GA1UdIwQYMBaAFGm84OwzN47FA022UklrpSvWv05hMA8GA1UdEwEB/wQF\
    MAMBAf8wCgYIKoZIzj0EAwIDRwAwRAIge9yJUXBKBGAIzpRhJIhic8rcX3jdyAKy2YyN6I3V/+4CIFVAE1bFOIs8A8VMtZ/9w6ky\
    QjFc5gXPD55BYuR8yTm0
    """

    /// `openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER
    ///  | openssl dgst -sha256 -binary | base64`
    private static let pinDelCertificado = "+lD8v37mBY5UxmpJvlpNcZPaSN9r1/XEZI8gAftIFjc="

    private static let otroPin = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    private func trustDePrueba() throws -> SecTrust {
        let der = try #require(Data(base64Encoded: Self.certificadoDER))
        let certificado = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        let estado = SecTrustCreateWithCertificates(
            certificado as CFTypeRef,
            SecPolicyCreateBasicX509(),
            &trust
        )
        #expect(estado == errSecSuccess)
        return try #require(trust)
    }

    /// `URLProtectionSpace` no deja inyectar un `serverTrust`: la propiedad es
    /// de solo lectura y solo la rellena el sistema. Subclasear es la única
    /// forma de construir el challenge que el delegado recibe en producción —
    /// y sin poder construirlo, este método simplemente no se podía probar,
    /// que es exactamente por qué no estaba probado.
    private final class EspacioConTrust: URLProtectionSpace {
        private let trust: SecTrust?
        private let metodo: String

        init(trust: SecTrust?, metodo: String = NSURLAuthenticationMethodServerTrust, host: String) {
            self.trust = trust
            self.metodo = metodo
            super.init(host: host, port: 443, protocol: "https", realm: nil, authenticationMethod: metodo)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("no se usa") }

        override var serverTrust: SecTrust? { trust }
        override var authenticationMethod: String { metodo }
    }

    /// Invoca el delegado y devuelve lo que le pasó al `completionHandler`.
    private func decidir(
        pinning: SSLPinningConfiguration?,
        espacio: URLProtectionSpace
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let delegado = PinningSessionDelegate(pinning: pinning)
        let challenge = URLAuthenticationChallenge(
            protectionSpace: espacio,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: SenderInerte()
        )
        return await withCheckedContinuation { continuation in
            delegado.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
                continuation.resume(returning: (disposition, credential))
            }
        }
    }

    /// El challenge exige un sender; el delegado no lo usa, pero sin él no se
    /// puede construir.
    private final class SenderInerte: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    // MARK: - El pin NO coincide: se CANCELA, y sin credencial

    /// El caso que de verdad protege al usuario. Si esta rama se invierte, la
    /// app aceptaría un certificado que el pinning rechazó — o sea, el pinning
    /// dejaría de servir para nada sin que ningún test se enterara.
    @Test("pin que no coincide → cancela el challenge y NO entrega credencial")
    func pinQueNoCoincideCancela() async throws {
        let trust = try trustDePrueba()
        let pinning = SSLPinningConfiguration(
            publicKeyHashes: [Self.otroPin],
            pinnedHosts: ["pinning.test"],
            validateCertificateChain: false   // el cert es autofirmado: la cadena no evalúa
        )
        let (disposition, credential) = await decidir(
            pinning: pinning,
            espacio: EspacioConTrust(trust: trust, host: "pinning.test")
        )
        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(credential == nil, "cancelar y a la vez entregar credencial sería contradictorio")
    }

    // MARK: - El pin coincide: se ACEPTA con credencial

    @Test("pin que coincide → usa credencial, y la credencial existe")
    func pinQueCoincideAcepta() async throws {
        let trust = try trustDePrueba()
        let pinning = SSLPinningConfiguration(
            publicKeyHashes: [Self.pinDelCertificado],
            pinnedHosts: ["pinning.test"],
            validateCertificateChain: false
        )
        let (disposition, credential) = await decidir(
            pinning: pinning,
            espacio: EspacioConTrust(trust: trust, host: "pinning.test")
        )
        #expect(disposition == .useCredential)
        #expect(credential != nil, "useCredential sin credencial deja la conexión sin resolver")
    }

    // MARK: - No aplica: se delega en el sistema, JAMÁS useCredential a ciegas

    @Test("host fuera de la lista pinneada → lo decide el sistema, sin credencial")
    func hostNoPinneadoDelegaEnElSistema() async throws {
        let trust = try trustDePrueba()
        let pinning = SSLPinningConfiguration(
            publicKeyHashes: [Self.pinDelCertificado],
            pinnedHosts: ["otro.host"],
            validateCertificateChain: false
        )
        let (disposition, credential) = await decidir(
            pinning: pinning,
            espacio: EspacioConTrust(trust: trust, host: "pinning.test")
        )
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    @Test("sin pinning configurado → lo decide el sistema")
    func sinPinningDelegaEnElSistema() async throws {
        let trust = try trustDePrueba()
        let (disposition, credential) = await decidir(
            pinning: nil,
            espacio: EspacioConTrust(trust: trust, host: "pinning.test")
        )
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    // MARK: - Challenges que NO son server-trust

    /// El guard de la primera línea. Si se invierte, el delegado intentaría
    /// aplicar pinning a un challenge de credenciales de usuario (Basic, NTLM,
    /// cliente-certificado), donde `serverTrust` es nil.
    @Test("challenge que no es server-trust → lo decide el sistema")
    func challengeQueNoEsServerTrust() async throws {
        let pinning = SSLPinningConfiguration(
            publicKeyHashes: [Self.pinDelCertificado],
            pinnedHosts: nil                     // pinnearía TODO host…
        )
        let (disposition, credential) = await decidir(
            pinning: pinning,
            espacio: EspacioConTrust(
                trust: nil,
                metodo: NSURLAuthenticationMethodHTTPBasic,   // …pero esto no es TLS
                host: "pinning.test"
            )
        )
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    /// Caso degenerado: método correcto pero sin trust. No debe reventar ni
    /// aceptar nada; delega.
    @Test("server-trust sin trust → lo decide el sistema, sin crash")
    func serverTrustSinTrust() async {
        let pinning = SSLPinningConfiguration(publicKeyHashes: [Self.pinDelCertificado], pinnedHosts: nil)
        let (disposition, credential) = await decidir(
            pinning: pinning,
            espacio: EspacioConTrust(trust: nil, host: "pinning.test")
        )
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }
}
