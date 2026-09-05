import CoreNetworkingTestSupport
import Foundation
import Testing

@testable import CoreNetworking

/// Cobertura de `APIError`: el struct único y extensible que sustituye al
/// enum cerrado + `TransportError` (CN-01). Ver `AUDITORIA-2026-09-01.md` §4.
@Suite("APIError: decodeBody, category, isRetryable, LocalizedError")
struct APIErrorTests {
    // MARK: - decodeBody: la app decodifica SU sobre de error

    private struct FieldError: Decodable, Equatable { let field: String }
    private struct ValidationEnvelope: Decodable, Equatable { let errors: [FieldError] }

    @Test("422 con sobre { errors: [{ field }] } llega con statusCode y se decodifica con el tipo del consumidor")
    func decodesConsumersOwnErrorEnvelope() throws {
        let body = Data(#"{"errors":[{"field":"email"}]}"#.utf8)
        let error = APIError.stub(code: .httpStatus, statusCode: 422, body: body)

        #expect(error.statusCode == 422)
        let decoded = try error.decodeBody(ValidationEnvelope.self)
        #expect(decoded == ValidationEnvelope(errors: [FieldError(field: "email")]))
    }

    @Test("decodeBody sin response → .decoding, sin perder request/underlying")
    func decodeBodyWithoutResponseThrowsDecoding() {
        let error = APIError(code: .transport, underlying: URLError(.timedOut))
        #expect(throws: (any Error).self) {
            _ = try error.decodeBody(ValidationEnvelope.self)
        }
        do {
            _ = try error.decodeBody(ValidationEnvelope.self)
            Issue.record("debía lanzar")
        } catch {
            #expect(error.code == .decoding)
        }
    }

    @Test("decodeBody con un body que no matchea el tipo propaga el DecodingError en underlying")
    func decodeBodyMismatchWrapsDecodingError() {
        let error = APIError.stub(code: .httpStatus, statusCode: 422, body: Data(#"{"unrelated":1}"#.utf8))
        do {
            _ = try error.decodeBody(ValidationEnvelope.self)
            Issue.record("debía lanzar")
        } catch {
            #expect(error.code == .decoding)
            #expect(error.underlying is DecodingError)
            #expect(error.statusCode == 422, "response se conserva para diagnóstico")
        }
    }

    // MARK: - Ningún error del transporte se pierde

    /// `URLProtocol` local que falla con un `NSError` ARBITRARIO (no `URLError`):
    /// el caso que `MockURLProtocol` no puede simular (su `error` es
    /// `URLError?`). Vive aquí, no en `CoreNetworkingTestSupport`, para no
    /// tocar ficheros fuera del alcance de CN-01.
    private final class ArbitraryFailureProtocol: URLProtocol, @unchecked Sendable {
        static let failure = NSError(domain: "test.arbitrary", code: 999, userInfo: [NSLocalizedDescriptionKey: "boom"])

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: Self.failure)
        }

        override func stopLoading() {}
    }

    @Test("un NSError arbitrario del transporte llega como .unexpected con underlying idéntico")
    func arbitraryTransportErrorBecomesUnexpected() async throws {
        let baseURL = try #require(URL(string: "https://api-error-arbitrary.test"))
        let configuration = NetworkingConfiguration(
            baseURL: baseURL,
            sessionConfiguration: {
                let sessionConfiguration = URLSessionConfiguration.ephemeral
                sessionConfiguration.protocolClasses = [ArbitraryFailureProtocol.self]
                return sessionConfiguration
            }
        )
        let service = APIService(configuration: configuration, retryPolicy: .noRetry)

        struct Payload: Decodable, Sendable { let ok: Bool }
        struct GetRequest: BaseRequest {
            typealias Response = Payload
            let path = "/thing"
            let method: HTTPMethod = .get
        }

        do {
            let _: Payload = try await service.execute(GetRequest())
            Issue.record("debía fallar")
        } catch {
            #expect(error.code == .unexpected, "esperaba .unexpected, llegó \(error)")
            let underlying = try #require(error.underlying as? NSError)
            #expect(underlying.domain == ArbitraryFailureProtocol.failure.domain)
            #expect(underlying.code == ArbitraryFailureProtocol.failure.code)
        }
    }

    // MARK: - category: tabla completa, 401 ≠ 403

    @Test(
        "category clasifica correctamente",
        arguments: [
            (APIError(code: .transport, underlying: URLError(.notConnectedToInternet)), APIError.Category.offline),
            (APIError(code: .transport, underlying: URLError(.dataNotAllowed)), .offline),
            (APIError(code: .transport, underlying: URLError(.internationalRoamingOff)), .offline),
            (APIError(code: .transport, underlying: URLError(.timedOut)), .timeout),
            (APIError(code: .transport, underlying: URLError(.networkConnectionLost)), .unreachable),
            (APIError(code: .transport, underlying: URLError(.cannotConnectToHost)), .unreachable),
            (APIError(code: .transport, underlying: URLError(.dnsLookupFailed)), .unreachable),
            (APIError(code: .transport, underlying: URLError(.cannotFindHost)), .unreachable),
            (APIError.stub(code: .httpStatus, statusCode: 401), .unauthorized),
            (APIError.stub(code: .httpStatus, statusCode: 403), .forbidden),
            (APIError.stub(code: .httpStatus, statusCode: 404), .notFound),
            (APIError.stub(code: .httpStatus, statusCode: 429), .rateLimited),
            (APIError.stub(code: .httpStatus, statusCode: 418), .client),
            (APIError.stub(code: .httpStatus, statusCode: 500), .server),
            (APIError.stub(code: .httpStatus, statusCode: 503), .server),
            (APIError(code: .untrustedServer), .untrustedServer),
            (APIError(code: .cancelled), .cancelled),
            (APIError(code: .decoding), .decoding),
            (APIError(code: .invalidResponse), .unknown),
            (APIError(code: .interceptor), .unknown),
            (APIError(code: .unexpected), .unknown)
        ] as [(APIError, APIError.Category)]
    )
    func categoryClassification(_ pair: (error: APIError, expected: APIError.Category)) {
        #expect(pair.error.category == pair.expected)
    }

    @Test("401 y 403 son categorías distintas — no colapsan (a diferencia del TransportError borrado)")
    func unauthorizedIsNotForbidden() {
        #expect(APIError.stub(code: .httpStatus, statusCode: 401).category == .unauthorized)
        #expect(APIError.stub(code: .httpStatus, statusCode: 403).category == .forbidden)
        #expect(
            APIError.stub(code: .httpStatus, statusCode: 401).category
                != APIError.stub(code: .httpStatus, statusCode: 403).category
        )
    }

    // MARK: - isRetryable

    @Test("isRetryable es falso para notConnectedToInternet (sin red no hay nada que reintentar en 0.5s)")
    func notConnectedIsNotRetryable() {
        let error = APIError(code: .transport, underlying: URLError(.notConnectedToInternet))
        #expect(!error.isRetryable)
    }

    @Test("isRetryable es verdadero para dnsLookupFailed (transitorio)")
    func dnsLookupIsRetryable() {
        let error = APIError(code: .transport, underlying: URLError(.dnsLookupFailed))
        #expect(error.isRetryable)
    }

    @Test(
        "isRetryable: matriz de status — 5xx y 408/429 sí, resto de 4xx no",
        arguments: [
            (500, true), (503, true), (408, true), (429, true),
            (400, false), (401, false), (404, false), (418, false)
        ]
    )
    func statusRetryMatrix(_ pair: (status: Int, retryable: Bool)) {
        #expect(APIError.stub(code: .httpStatus, statusCode: pair.status).isRetryable == pair.retryable)
    }

    @Test("isRetryable es falso para .cancelled y .untrustedServer")
    func cancellationAndPinningAreNotRetryable() {
        #expect(!APIError(code: .cancelled).isRetryable)
        #expect(!APIError(code: .untrustedServer).isRetryable)
    }

    // MARK: - isRetryable: casos degenerados (nadie construye estos errores así,
    // pero un error sin información no debe considerarse reintentable)

    @Test(".transport sin underlying (sin URLError) no es reintentable")
    func transportWithoutUnderlyingIsNotRetryable() {
        // Nadie construye un `.transport` sin `underlying` en producción — lo
        // pone siempre el propio `APIService` a partir de un `URLError` real —,
        // pero `isRetryable` no debe asumir que `urlError` existe: sin datos
        // que lo respalden, "reintentable" no puede ser el default.
        let error = APIError(code: .transport)
        #expect(error.urlError == nil, "fixture inválida: se esperaba underlying == nil")
        #expect(!error.isRetryable)
    }

    @Test(".httpStatus sin response (sin statusCode) no es reintentable")
    func httpStatusWithoutResponseIsNotRetryable() {
        // Igual que arriba: nadie construye un `.httpStatus` sin `response` —
        // pero sin status no hay 5xx/408/429 que verificar, así que el default
        // debe ser "no reintentable", no "reintentable por defecto".
        let error = APIError(code: .httpStatus)
        #expect(error.statusCode == nil, "fixture inválida: se esperaba statusCode == nil")
        #expect(!error.isRetryable)
    }

    // MARK: - description: contrato log-safe (código, método, status, underlying resumido)

    @Test("description incluye code, method, status y underlying resumido")
    func descriptionIncludesEveryPart() throws {
        let url = try #require(URL(string: "https://api.example.com/thing"))
        let error = APIError(
            code: .httpStatus,
            request: APIError.RequestSummary(method: .post, url: url),
            response: APIError.ResponseSummary(statusCode: 500),
            underlying: URLError(.timedOut)
        )
        let description = error.description
        #expect(description.contains("code: httpStatus"))
        #expect(description.contains("method: POST"))
        #expect(description.contains("status: 500"))
        #expect(description.contains("underlying: URLError(-1001)"))
    }

    @Test("description de un error mínimo (solo code) no añade partes vacías")
    func descriptionMinimalHasNoExtraParts() {
        // Sin request, response ni underlying: si cualquiera de los tres
        // `parts.append` se disparase igualmente, esta cadena exacta cambiaría.
        let error = APIError(code: .cancelled)
        #expect(error.description == "APIError(code: cancelled)")
    }

    @Test("description nunca expone la URL, el body ni el mensaje de underlying (log-safe)")
    func descriptionNeverLeaksSensitiveData() throws {
        struct ServerLeak: Error, CustomStringConvertible {
            var description: String { "user secret@example.com leaked in the clear" }
        }
        let url = try #require(URL(string: "https://secret.example.com/private/path?token=abc"))
        let error = APIError(
            code: .httpStatus,
            request: APIError.RequestSummary(method: .get, url: url),
            response: APIError.ResponseSummary(statusCode: 500, body: Data("leaked body content".utf8)),
            underlying: ServerLeak()
        )
        let description = error.description
        #expect(!description.contains("secret.example.com"), "la URL nunca debe salir en la descripción técnica")
        #expect(!description.contains("token=abc"))
        #expect(!description.contains("leaked body content"), "el body nunca debe salir en la descripción técnica")
        #expect(!description.contains("secret@example.com"), "el mensaje de underlying nunca debe sobrevivir")
        #expect(!description.contains("leaked"))
    }

    // MARK: - isCancellation

    @Test("isCancellation es verdadero solo para .cancelled — nunca para .untrustedServer")
    func isCancellationOnlyForCancelledCode() {
        #expect(APIError(code: .cancelled).isCancellation)
        #expect(!APIError(code: .untrustedServer).isCancellation)
    }

    // MARK: - retryAfter (Retry-After: segundos u HTTP-date)

    @Test("Retry-After en segundos se parsea y se expone en retryAfter")
    func retryAfterSeconds() {
        let error = APIError.stub(code: .httpStatus, statusCode: 429, headers: ["Retry-After": "7"])
        #expect(error.retryAfter == .seconds(7))
    }

    @Test("Retry-After en HTTP-date se parsea (futuro ≈ delta, pasado = 0)")
    func retryAfterHTTPDate() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        let future = formatter.string(from: Date(timeIntervalSinceNow: 10))
        let futureDelay = APIError.parseRetryAfter(future)?.timeInterval
        #expect(futureDelay.map { $0 > 7 && $0 <= 10 } == true)

        let past = formatter.string(from: Date(timeIntervalSinceNow: -30))
        #expect(APIError.parseRetryAfter(past) == .seconds(0))

        #expect(APIError.parseRetryAfter("garbage") == nil)
        #expect(APIError.parseRetryAfter(nil) == nil)
    }

    @Test("sin header Retry-After, retryAfter es nil")
    func noRetryAfterHeaderIsNil() {
        let error = APIError.stub(code: .httpStatus, statusCode: 500)
        #expect(error.retryAfter == nil)
    }

    // MARK: - RequestSummary / ResponseSummary

    @Test("ResponseSummary.header es case-insensitive y normaliza las claves a minúsculas")
    func responseHeaderLookupIsCaseInsensitive() {
        let summary = APIError.ResponseSummary(statusCode: 429, headers: ["Retry-After": "3", "X-Foo": "bar"])
        #expect(summary.header("retry-after") == "3")
        #expect(summary.header("RETRY-AFTER") == "3")
        #expect(summary.header("x-foo") == "bar")
        #expect(summary.headers["retry-after"] == "3", "las claves internas quedan normalizadas")
    }

    // MARK: - LocalizedError: nunca un código pelado, EN y ES

    /// `errorDescription(locale:)` pasa `locale:` a `String(localized:bundle:locale:)`, pero
    /// ese override NO es fiable frente a un `.lproj` compilado por Xcode cuando el idioma
    /// del SIMULADOR ya coincide con OTRA localización disponible: en ese caso el bundle
    /// resuelve por el idioma preferido del dispositivo, no por el `locale:` explícito
    /// (reproducido con `xcodebuild test` en un simulador con idioma `es`: pedir `"en"`
    /// devuelve la frase en español). Es un comportamiento de Foundation/String Catalogs, no
    /// un bug de este paquete — `errorDescription` público siempre usa `.current`, así que
    /// nunca pide una localización distinta de la del dispositivo en producción. La prueba
    /// evita la ruta frágil cargando el `.lproj` exacto por *path*, el mismo mecanismo que ya
    /// usa `AppFoundation/Tests/AppFoundationTests/LocalizationTests.swift` (`localizedValue`)
    /// para el mismo problema con `.xcstrings`.
    ///
    /// `nil` cuando `Localizable.xcstrings` no está compilado a `.lproj` en este build
    /// (`swift build`/`swift test`, que copian el catálogo sin compilar — la compilación es
    /// un paso del sistema de build de Xcode).
    private static func compiledBundle(for language: String) -> Bundle? {
        Bundle.module.path(forResource: language, ofType: "lproj").flatMap { Bundle(path: $0) }
    }

    private static var hasCompiledSpanishStrings: Bool { compiledBundle(for: "es") != nil }

    @Test("errorDescription es una frase humana en inglés (nunca 'error 9')")
    func localizedDescriptionEnglish() {
        let error = APIError(code: .transport, underlying: URLError(.notConnectedToInternet))
        let expected = "No internet connection."
        let description =
            Self.compiledBundle(for: "en")?
            .localizedString(forKey: "error.offline", value: expected, table: "Localizable")
            ?? error.errorDescription(locale: Locale(identifier: "en"))
        #expect(description == expected)
        #expect(!description.lowercased().contains("error 9"))
    }

    @Test("errorDescription de .unreachable es una frase humana en inglés")
    func localizedDescriptionUnreachableEnglish() {
        let error = APIError(code: .transport, underlying: URLError(.cannotConnectToHost))
        #expect(error.category == .unreachable)
        let expected = "Could not connect to the server."
        let description =
            Self.compiledBundle(for: "en")?
            .localizedString(forKey: "error.unreachable", value: expected, table: "Localizable")
            ?? error.errorDescription(locale: Locale(identifier: "en"))
        #expect(description == expected)
    }

    @Test(
        "errorDescription de .unreachable es una frase humana en español",
        .disabled(
            if: !hasCompiledSpanishStrings,
            "Localizable.xcstrings no está compilado a es.lproj en este build (swift build/test no compila String Catalogs; xcodebuild sí)"
        )
    )
    func localizedDescriptionUnreachableSpanish() {
        let description = Self.compiledBundle(for: "es")!
            .localizedString(
                forKey: "error.unreachable",
                value: "Could not connect to the server.",
                table: "Localizable"
            )
        #expect(description == "No se pudo conectar con el servidor.")
    }

    @Test(
        "errorDescription es una frase humana en español",
        .disabled(
            if: !hasCompiledSpanishStrings,
            "Localizable.xcstrings no está compilado a es.lproj en este build (swift build/test no compila String Catalogs; xcodebuild sí)"
        )
    )
    func localizedDescriptionSpanish() {
        let description = Self.compiledBundle(for: "es")!
            .localizedString(
                forKey: "error.offline",
                value: "No internet connection.",
                table: "Localizable"
            )
        #expect(description == "No hay conexión a internet.")
    }

    @Test("errorDescription cubre cada categoría con una frase no vacía, en EN y ES")
    func localizedDescriptionCoversEveryCategory() {
        for category in APIError.Category.allCases {
            let error = Self.error(for: category)
            for localeID in ["en", "es"] {
                let description = error.errorDescription(locale: Locale(identifier: localeID))
                #expect(!description.isEmpty, "\(category) / \(localeID)")
            }
        }
    }

    private static func error(for category: APIError.Category) -> APIError {
        switch category {
        case .offline: return APIError(code: .transport, underlying: URLError(.notConnectedToInternet))
        case .timeout: return APIError(code: .transport, underlying: URLError(.timedOut))
        case .unreachable: return APIError(code: .transport, underlying: URLError(.dnsLookupFailed))
        case .unauthorized: return APIError.stub(code: .httpStatus, statusCode: 401)
        case .forbidden: return APIError.stub(code: .httpStatus, statusCode: 403)
        case .notFound: return APIError.stub(code: .httpStatus, statusCode: 404)
        case .rateLimited: return APIError.stub(code: .httpStatus, statusCode: 429)
        case .client: return APIError.stub(code: .httpStatus, statusCode: 418)
        case .server: return APIError.stub(code: .httpStatus, statusCode: 500)
        case .untrustedServer: return APIError(code: .untrustedServer)
        case .cancelled: return APIError(code: .cancelled)
        case .decoding: return APIError(code: .decoding)
        case .unknown: return APIError(code: .unexpected)
        }
    }
}
