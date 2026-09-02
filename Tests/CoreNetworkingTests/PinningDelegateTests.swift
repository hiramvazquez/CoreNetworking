import Foundation
import Security
import Testing

@testable import CoreNetworking

/// El DELEGADO de pinning, que es quien de verdad decide en runtime si se
/// acepta un certificado.
///
/// Estos tests existen porque la primera medición de mutación del paquete
/// (`swift-mutation-testing`, score global 42.1%) señaló el delegado de
/// pinning (entonces `PinningSessionDelegate`, en `SessionDelegates.swift`)
/// como el archivo con MÁS mutantes vivos: invertir `if result == .failed` o
/// cambiar `== NSURLAuthenticationMethodServerTrust` por `!=` no rompía ningún
/// test. La causa era un hueco de cableado, no de lógica: `PinningTests.swift`
/// ejercita `SSLPinningConfiguration.validate()` a fondo y el mapeo
/// resultado→disposition, pero nadie invocaba
/// `urlSession(_:task:didReceive:completionHandler:)`, que es el método que los une.
///
/// CN-04 migró el delegado de sesión a `TaskDelegate` (por tarea, no por
/// sesión) — el mismo patrón de bug que la auditoría encontró en el pipeline
/// (CN-01: un fallo de pinning llegaba como `.cancelled` indistinguible de
/// que el llamador cancelase) se repite aquí, esta vez en la capa de tests:
/// doce tests daban sensación de cobertura sobre el punto más sensible del
/// paquete y el cableado real no estaba verificado.
///
/// ## Qué matan estos tests, y qué NO
///
/// Verificado mutando el delegado a mano:
/// - invertir `result == .validated` (la línea que decide si se entrega
///   credencial) → **muere**;
/// - invertir el guard `== NSURLAuthenticationMethodServerTrust` → **muere**;
/// - invertir `if result == .failed` → **SOBREVIVE** para el LOG, pero desde
///   CN-04 esa misma rama también marca `pinningFailed = true` bajo lock —
///   invertirla ahora sí mata el test "tras `.failed`, `pinningFailed == true`"
///   de más abajo, que es exactamente el hueco que dejaba viva esta mutación.
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

    /// Dos pins ajenos (32 bytes cada uno): el constructor exige un pin de
    /// respaldo (RFC 7469), así que nunca se puede pasar uno solo.
    private static let otroPin = Data(repeating: 0x00, count: 32).base64EncodedString()
    private static let otroPinDeRespaldo = Data(repeating: 0xFF, count: 32).base64EncodedString()

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
    private final class EspacioConTrust: URLProtectionSpace, @unchecked Sendable {
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

    /// Una `URLSessionTask` inerte: el delegado por tarea no la usa (ignora el
    /// parámetro `task`), pero el método de protocolo la exige. Nunca se
    /// llama `.resume()`.
    private func tareaInerte() -> URLSessionTask {
        URLSession.shared.dataTask(with: URL(string: "https://pinning.test")!)
    }

    /// Invoca el delegado y devuelve lo que le pasó al `completionHandler`.
    private func decidir(
        pinning: SSLPinningConfiguration?,
        espacio: URLProtectionSpace,
        delegado: TaskDelegate? = nil
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?, TaskDelegate) {
        let delegado = delegado ?? TaskDelegate(pinning: pinning)
        let challenge = URLAuthenticationChallenge(
            protectionSpace: espacio,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: SenderInerte()
        )
        let (disposition, credential) = await withCheckedContinuation { continuation in
            delegado.urlSession(URLSession.shared, task: tareaInerte(), didReceive: challenge) {
                disposition,
                credential in
                continuation.resume(returning: (disposition, credential))
            }
        }
        return (disposition, credential, delegado)
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
            publicKeyHashes: [Self.otroPin, Self.otroPinDeRespaldo],
            hosts: .only(["pinning.test"]),
            chainValidation: .unsafeSkipForDevelopment  // el cert es autofirmado: la cadena no evalúa
        )
        let (disposition, credential, _) = await decidir(
            pinning: pinning,
            espacio: EspacioConTrust(trust: trust, host: "pinning.test")
        )
        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(credential == nil, "cancelar y a la vez entregar credencial sería contradictorio")
    }

    // MARK: - Tras `.failed`, el delegado recuerda que fue ÉL quien canceló (CN-01)

    /// El fix de CN-01: sin este flag, Foundation convierte la cancelación
    /// del challenge en `URLError(.cancelled)`, indistinguible de que el
    /// llamador cancelara el `Task`. `URLSessionTransport` lee este flag
    /// justo después de que `session.data(for:)`/`download(for:)` lance esa
    /// `URLError`, para decidir si la reemplaza por `PinningFailure`.
    @Test("tras un pin que no coincide, pinningFailed == true")
    func pinQueNoCoincideMarcaPinningFailed() async throws {
        let trust = try trustDePrueba()
        let pinning = SSLPinningConfiguration(
            publicKeyHashes: [Self.otroPin, Self.otroPinDeRespaldo],
            hosts: .only(["pinning.test"]),
            chainValidation: .unsafeSkipForDevelopment
        )
        let delegado = TaskDelegate(pinning: pinning)
        #expect(delegado.pinningFailed == false, "antes de decidir nada, no ha fallado nada")
        _ = await decidir(
            pinning: pinning,
            espacio: EspacioConTrust(trust: trust, host: "pinning.test"),
            delegado: delegado
        )
        #expect(delegado.pinningFailed == true)
    }

    // MARK: - El pin coincide: se ACEPTA con credencial

    @Test("pin que coincide → usa credencial, y la credencial existe")
    func pinQueCoincideAcepta() async throws {
        let trust = try trustDePrueba()
        let pinning = SSLPinningConfiguration(
            publicKeyHashes: [Self.pinDelCertificado, Self.otroPinDeRespaldo],
            hosts: .only(["pinning.test"]),
            chainValidation: .unsafeSkipForDevelopment
        )
        let (disposition, credential, delegado) = await decidir(
            pinning: pinning,
            espacio: EspacioConTrust(trust: trust, host: "pinning.test")
        )
        #expect(disposition == .useCredential)
        #expect(credential != nil, "useCredential sin credencial deja la conexión sin resolver")
        #expect(delegado.pinningFailed == false, "un pin que coincide no es un fallo de pinning")
    }

    // MARK: - No aplica: se delega en el sistema, JAMÁS useCredential a ciegas

    @Test("host fuera de la lista pinneada → lo decide el sistema, sin credencial")
    func hostNoPinneadoDelegaEnElSistema() async throws {
        let trust = try trustDePrueba()
        let pinning = SSLPinningConfiguration(
            publicKeyHashes: [Self.pinDelCertificado, Self.otroPinDeRespaldo],
            hosts: .only(["otro.host"]),
            chainValidation: .unsafeSkipForDevelopment
        )
        let (disposition, credential, delegado) = await decidir(
            pinning: pinning,
            espacio: EspacioConTrust(trust: trust, host: "pinning.test")
        )
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
        #expect(delegado.pinningFailed == false)
    }

    @Test("sin pinning configurado → lo decide el sistema")
    func sinPinningDelegaEnElSistema() async throws {
        let trust = try trustDePrueba()
        let (disposition, credential, delegado) = await decidir(
            pinning: nil,
            espacio: EspacioConTrust(trust: trust, host: "pinning.test")
        )
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
        #expect(delegado.pinningFailed == false)
    }

    // MARK: - Challenges que NO son server-trust

    /// El guard de la primera línea. Si se invierte, el delegado intentaría
    /// aplicar pinning a un challenge de credenciales de usuario (Basic, NTLM,
    /// cliente-certificado), donde `serverTrust` es nil.
    @Test("challenge que no es server-trust → lo decide el sistema")
    func challengeQueNoEsServerTrust() async throws {
        let pinning = SSLPinningConfiguration(
            publicKeyHashes: [Self.pinDelCertificado, Self.otroPinDeRespaldo],
            hosts: .all  // pinnearía TODO host…
        )
        let (disposition, credential, delegado) = await decidir(
            pinning: pinning,
            espacio: EspacioConTrust(
                trust: nil,
                metodo: NSURLAuthenticationMethodHTTPBasic,  // …pero esto no es TLS
                host: "pinning.test"
            )
        )
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
        #expect(delegado.pinningFailed == false)
    }

    /// Caso degenerado: método correcto pero sin trust. No debe reventar ni
    /// aceptar nada; delega.
    @Test("server-trust sin trust → lo decide el sistema, sin crash")
    func serverTrustSinTrust() async {
        let pinning = SSLPinningConfiguration(
            publicKeyHashes: [Self.pinDelCertificado, Self.otroPinDeRespaldo],
            hosts: .all
        )
        let (disposition, credential, delegado) = await decidir(
            pinning: pinning,
            espacio: EspacioConTrust(trust: nil, host: "pinning.test")
        )
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
        #expect(delegado.pinningFailed == false)
    }
}
