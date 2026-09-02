import Testing
import Foundation
@testable import CoreNetworking
import CoreNetworkingTestSupport

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
            protocolClasses: [ArbitraryFailureProtocol.self]
        )
        let service = APIService(configuration: configuration, retryPolicy: .noRetry)

        struct GetRequest: BaseRequest {
            typealias Parameters = EmptyParameters
            let path = "/thing"
            let method: HTTPMethod = .GET
        }
        struct Payload: Decodable { let ok: Bool }

        do {
            let _: Payload = try await service.execute(request: GetRequest())
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
            (APIError(code: .transport, underlying: URLError(.networkConnectionLost)), .unknown),
            (APIError(code: .transport, underlying: URLError(.dnsLookupFailed)), .unknown),
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
        #expect(APIError.stub(code: .httpStatus, statusCode: 401).category != APIError.stub(code: .httpStatus, statusCode: 403).category)
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

    @Test("errorDescription es una frase humana en inglés (nunca 'error 9')")
    func localizedDescriptionEnglish() {
        let error = APIError(code: .transport, underlying: URLError(.notConnectedToInternet))
        let description = error.errorDescription(locale: Locale(identifier: "en"))
        #expect(description == "No internet connection.")
        #expect(!description.lowercased().contains("error 9"))
    }

    /// `swift build`/`swift test` (SwiftPM en línea de comandos) copian
    /// `Localizable.xcstrings` tal cual, sin compilarlo a `es.lproj/*.strings`
    /// — la compilación del String Catalog es un paso del sistema de build de
    /// Xcode (verificado: `xcodebuild build -scheme CoreNetworking-Package`
    /// SÍ genera `es.lproj/Localizable.strings`; `swift build` no genera
    /// ningún `.lproj`). Sin la tabla compilada, `String(localized:...)` cae
    /// a `defaultValue` (inglés) para cualquier locale. Se salta la
    /// comparación estricta cuando corre bajo ese modo, en vez de fingir que
    /// pasa: `errorDescription(locale:)` sigue devolviendo una frase humana
    /// (lo prueba `localizedDescriptionCoversEveryCategory`), solo que no la
    /// traducida.
    private static var hasCompiledSpanishStrings: Bool {
        Bundle.module.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "es") != nil
    }

    @Test(
        "errorDescription es una frase humana en español",
        .disabled(
            if: !hasCompiledSpanishStrings,
            "Localizable.xcstrings no está compilado a es.lproj en este build (swift build/test no compila String Catalogs; xcodebuild sí)"
        )
    )
    func localizedDescriptionSpanish() {
        let error = APIError(code: .transport, underlying: URLError(.notConnectedToInternet))
        let description = error.errorDescription(locale: Locale(identifier: "es"))
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
