import Foundation
import Security
import Testing

@testable import CoreNetworking

/// Redirecciones HTTP 3xx: qué le pasa a `Authorization` (y a cualquier otro
/// header con pinta de credencial) cuando el servidor — o quien consiga
/// influir en `Location` — manda al cliente a otro sitio.
///
/// ## El comportamiento de Foundation ANTES de este cambio (medido, no supuesto)
///
/// `TaskDelegate` no implementaba
/// `willPerformHTTPRedirection(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`
/// — así que, antes de esta tarea, toda redirección la seguía Foundation con
/// su comportamiento por defecto, sin que ningún `catch` de este paquete la
/// viera pasar (un 3xx no es un error). Medido empíricamente en esta máquina
/// (macOS 26.5.2, Swift 6.3.3, CFNetwork 3860.600.21) con
/// `session.data(for:delegate:)` y un delegate que NO implementaba ese
/// método, contra sockets loopback reales — nunca `MockURLProtocol`:
/// comprobado aparte (con un `URLProtocol` a medida que responde 302) que
/// devolver un 3xx desde un `URLProtocol` propio JAMÁS invoca
/// `willPerformHTTPRedirection`; el 3xx llega al llamador como respuesta
/// final sin seguir nada — mismo motivo, ya documentado en
/// `LoopbackHTTPServer` (`TransferTests.swift`), por el que
/// `didFinishDownloadingTo` tampoco se puede probar con un mock:
///
/// 1. `Authorization` y `Proxy-Authorization` — y SOLO esos dos nombres
///    exactos — desaparecen de la petición redirigida en TODAS las
///    redirecciones, INCLUIDAS las de mismo origen. Es comportamiento no
///    documentado de CFNetwork, no parte del contrato público de
///    `URLSession`, y por eso no es algo con lo que este paquete pueda
///    contar en otra plataforma (`swift-corelibs-foundation` en Linux, que
///    este paquete también soporta — ver `#if canImport(Glibc)` en
///    `Tests/`) ni en otra versión de Darwin.
/// 2. Cualquier OTRO header con pinta de credencial — `Cookie`,
///    `X-Api-Key`, `X-Auth-Token`, una `Authentication` a medida — viaja SIN
///    TOCAR a CUALQUIER destino, incluido uno de otro origen. Esta es la
///    fuga real: ninguna de las dos ramas del comportamiento de Foundation
///    la cubre, y es exactamente el escenario de "el backend redirige a
///    otro dominio y el token se va con él" que motivó esta tarea.
///
/// Consecuencia adicional del punto 1: una redirección de MISMO origen
/// pierde `Authorization` en silencio si nadie la restaura — no solo un
/// problema de seguridad, sino una regresión funcional para el caso más
/// común (un balanceador que reenvía a otra ruta del mismo host de API).
///
/// Este suite prueba el comportamiento DESPUÉS del cambio:
/// `RedirectPolicy` (`Transport/RedirectPolicy.swift`), aplicado por
/// `TaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`.
@Suite("Redirecciones HTTP: Authorization y headers sensibles")
struct RedirectSecurityTests {
    private static let authorizationValue = "Bearer super-secreto"
    private static let apiKeyValue = "clave-api-secreta"

    private func request(
        to url: URL,
        authorization: String? = authorizationValue,
        apiKey: String? = apiKeyValue
    ) -> URLRequest {
        var request = URLRequest(url: url)
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        return request
    }

    // MARK: - Cross-origin (default): se retira

    @Test("redirección a OTRO origen (mismo host, distinto puerto): Authorization y X-Api-Key NO llegan al destino")
    func crossOriginStripsSensitiveHeaders() async throws {
        let finalBody = Data("cross-origin-final".utf8)
        let destination = try LoopbackHTTPServer(responses: [.init(statusCode: 200, body: finalBody)])
        let redirector = try LoopbackHTTPServer(
            responses: [.init(statusCode: 302, headers: ["Location": destination.url.absoluteString])]
        )
        let transport = URLSessionTransport()  // default: .followSanitizingCrossOrigin

        let (data, response) = try await transport.send(request(to: redirector.url), progress: nil)

        #expect(response.statusCode == 200)
        #expect(response.url == destination.url)
        #expect(data == finalBody)
        let received = try #require(destination.receivedHeaders(at: 0))
        #expect(received["authorization"] == nil, "Authorization no debe cruzar a un origen distinto")
        #expect(
            received["x-api-key"] == nil,
            "X-Api-Key no debe cruzar a un origen distinto (Foundation NO lo retira por sí sola — el agujero real)"
        )
    }

    // MARK: - Same-origin: se conserva (y se restaura lo que Foundation retira igualmente)

    @Test("redirección al MISMO origen: Authorization y X-Api-Key SÍ llegan al destino")
    func sameOriginPreservesSensitiveHeaders() async throws {
        let finalBody = Data("same-origin-final".utf8)
        let server = try LoopbackHTTPServer(
            responses: [
                .init(statusCode: 302, headers: ["Location": "/dest"]),
                .init(statusCode: 200, body: finalBody)
            ]
        )
        let transport = URLSessionTransport()

        let (data, response) = try await transport.send(request(to: server.url), progress: nil)

        #expect(response.statusCode == 200)
        #expect(data == finalBody)
        let received = try #require(server.receivedHeaders(at: 1))
        #expect(
            received["authorization"] == Self.authorizationValue,
            "mismo origen: Authorization debe restaurarse (Foundation lo retira incluso aquí, ver el doc comment del suite)"
        )
        #expect(received["x-api-key"] == Self.apiKeyValue)
    }

    // MARK: - Redirección normal: se sigue y el cuerpo final es el correcto

    @Test("una redirección sin headers sensibles se sigue con normalidad")
    func plainRedirectIsFollowed() async throws {
        let finalBody = Data("plain-final".utf8)
        let destination = try LoopbackHTTPServer(responses: [.init(statusCode: 200, body: finalBody)])
        let redirector = try LoopbackHTTPServer(
            responses: [.init(statusCode: 302, headers: ["Location": destination.url.absoluteString])]
        )
        let transport = URLSessionTransport()

        let (data, response) = try await transport.send(
            request(to: redirector.url, authorization: nil, apiKey: nil),
            progress: nil
        )

        #expect(response.statusCode == 200)
        #expect(response.url == destination.url)
        #expect(data == finalBody)
    }

    // MARK: - RedirectPolicy.never: no sigue ninguna redirección

    @Test("RedirectPolicy.never: la 3xx vuelve al llamador tal cual, sin seguirla")
    func neverPolicyDoesNotFollow() async throws {
        let destination = try LoopbackHTTPServer(
            responses: [.init(statusCode: 200, body: Data("nunca debería llegar aquí".utf8))]
        )
        let redirector = try LoopbackHTTPServer(
            responses: [
                .init(
                    statusCode: 302,
                    headers: ["Location": destination.url.absoluteString],
                    body: Data("cuerpo del 302".utf8)
                )
            ]
        )
        let transport = URLSessionTransport(redirectPolicy: .never)

        let (data, response) = try await transport.send(request(to: redirector.url), progress: nil)

        #expect(response.statusCode == 302)
        #expect(response.url == redirector.url)
        #expect(data == Data("cuerpo del 302".utf8))
        #expect(
            destination.receivedHeaders(at: 0) == nil,
            "con .never no debe llegar a establecerse conexión con el destino de la redirección"
        )
    }

    // MARK: - RedirectPolicy.followPreservingAllHeaders: opt-out explícito

    @Test("RedirectPolicy.followPreservingAllHeaders: X-Api-Key SÍ cruza de origen (opt-out explícito)")
    func followPreservingAllHeadersDoesNotStrip() async throws {
        let finalBody = Data("preserved-final".utf8)
        let destination = try LoopbackHTTPServer(responses: [.init(statusCode: 200, body: finalBody)])
        let redirector = try LoopbackHTTPServer(
            responses: [.init(statusCode: 302, headers: ["Location": destination.url.absoluteString])]
        )
        let transport = URLSessionTransport(redirectPolicy: .followPreservingAllHeaders)

        let (data, _) = try await transport.send(request(to: redirector.url), progress: nil)

        #expect(data == finalBody)
        let received = try #require(destination.receivedHeaders(at: 0))
        #expect(received["x-api-key"] == Self.apiKeyValue, "followPreservingAllHeaders no filtra nada por su cuenta")
        // Authorization sigue sin llegar aun así: eso lo retira Foundation
        // ANTES de que el delegate vea el `newRequest` (ver el doc comment
        // del suite) — `followPreservingAllHeaders` no deshace eso, solo
        // evita que NOSOTROS retiremos algo más.
        #expect(received["authorization"] == nil)
    }

    // MARK: - Pinning tras redirección: se re-evalúa para el host NUEVO

    /// El pinning es un challenge POR TAREA (`didReceive challenge:`) y el
    /// MISMO `TaskDelegate` sigue siendo el delegate de la tarea después de
    /// una redirección — no hay ningún estado que "arrastre" la decisión del
    /// primer host al segundo. Verificado aquí sin TLS real (mismo patrón que
    /// `PinningDelegateTests`: un `URLProtectionSpace` subclaseado inyecta el
    /// `SecTrust` que, en producción, solo rellena una conexión real):
    /// - el primer host NO está en la lista pinneada → `.performDefaultHandling`.
    /// - `willPerformHTTPRedirection` mueve la tarea a un segundo host.
    /// - el segundo host SÍ está pinneado, con pines que NO coinciden con su
    ///   certificado → se cancela (`pinningFailed == true`), exactamente
    ///   igual que si ese host hubiera sido el destino desde el principio.
    @Test("tras redirigir a otro host, el pinning se re-evalúa para el host NUEVO, no arrastra el primero")
    func pinningReevaluatesForRedirectedHost() async throws {
        let trust = try Self.trustDePrueba()
        let pinning = SSLPinningConfiguration(
            publicKeyHashes: [Self.pinAjeno, Self.pinAjenoDeRespaldo],  // no coinciden con `trust`
            hosts: .only(["redirected-to.test"]),  // el host de PARTIDA queda fuera a propósito
            chainValidation: .unsafeSkipForDevelopment  // el cert de prueba es autofirmado
        )
        let delegate = TaskDelegate(pinning: pinning)
        let task = URLSession.shared.dataTask(with: URL(string: "https://start.test/a")!)

        // Hop 1: "start.test" no está pinneado → decide el sistema, sin marcar fallo.
        let (dispositionHop1, credentialHop1) = await Self.decidir(
            delegate: delegate,
            task: task,
            espacio: Self.espacio(trust: trust, host: "start.test")
        )
        #expect(dispositionHop1 == .performDefaultHandling)
        #expect(credentialHop1 == nil)
        #expect(delegate.pinningFailed == false)

        // La redirección en sí no toca pinning — solo demuestra que es el
        // MISMO delegate el que sigue atendiendo la tarea tras ella.
        let redirectResponse = try #require(
            HTTPURLResponse(
                url: URL(string: "https://start.test/a")!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://redirected-to.test/b"]
            )
        )
        let redirectedURL = try #require(URL(string: "https://redirected-to.test/b"))
        let newRequest = URLRequest(url: redirectedURL)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.urlSession(
                .shared,
                task: task,
                willPerformHTTPRedirection: redirectResponse,
                newRequest: newRequest
            ) { _ in
                continuation.resume()
            }
        }

        // Hop 2: "redirected-to.test" SÍ está pinneado y el pin no coincide
        // → cancela, y lo marca como fallo de pinning — el MISMO delegate,
        // sin ningún estado del hop 1 filtrándose.
        let (dispositionHop2, credentialHop2) = await Self.decidir(
            delegate: delegate,
            task: task,
            espacio: Self.espacio(trust: trust, host: "redirected-to.test")
        )
        #expect(dispositionHop2 == .cancelAuthenticationChallenge)
        #expect(credentialHop2 == nil)
        #expect(delegate.pinningFailed == true)
    }

    // MARK: - Fixtures de pinning (mismo patrón que `PinningDelegateTests`)

    /// Mismo certificado de juguete que `PinningDelegateTests` (autofirmado,
    /// generado con openssl solo para tests — no protege nada real):
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

    /// Dos pines ajenos que NO coinciden con `certificadoDER` — el
    /// constructor exige un pin de respaldo (RFC 7469), así que nunca se
    /// puede pasar uno solo.
    private static let pinAjeno = Data(repeating: 0x00, count: 32).base64EncodedString()
    private static let pinAjenoDeRespaldo = Data(repeating: 0xFF, count: 32).base64EncodedString()

    private static func trustDePrueba() throws -> SecTrust {
        let der = try #require(Data(base64Encoded: certificadoDER))
        let certificado = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        let estado = SecTrustCreateWithCertificates(certificado as CFTypeRef, SecPolicyCreateBasicX509(), &trust)
        #expect(estado == errSecSuccess)
        return try #require(trust)
    }

    /// `URLProtectionSpace` no deja inyectar un `serverTrust` (propiedad de
    /// solo lectura, la rellena el sistema) — subclasear es la única forma de
    /// construir el challenge que el delegate recibe en producción. Mismo
    /// patrón que `PinningDelegateTests.EspacioConTrust`.
    private final class EspacioConTrust: URLProtectionSpace, @unchecked Sendable {
        private let trust: SecTrust?

        init(trust: SecTrust?, host: String) {
            self.trust = trust
            super
                .init(
                    host: host,
                    port: 443,
                    protocol: "https",
                    realm: nil,
                    authenticationMethod: NSURLAuthenticationMethodServerTrust
                )
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("no se usa") }

        override var serverTrust: SecTrust? { trust }
    }

    private static func espacio(trust: SecTrust?, host: String) -> URLProtectionSpace {
        EspacioConTrust(trust: trust, host: host)
    }

    private final class SenderInerte: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private static func decidir(
        delegate: TaskDelegate,
        task: URLSessionTask,
        espacio: URLProtectionSpace
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let challenge = URLAuthenticationChallenge(
            protectionSpace: espacio,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: SenderInerte()
        )
        return await withCheckedContinuation { continuation in
            delegate.urlSession(.shared, task: task, didReceive: challenge) { disposition, credential in
                continuation.resume(returning: (disposition, credential))
            }
        }
    }
}
