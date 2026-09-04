import CoreNetworkingTestSupport
import Foundation
import Testing

@testable import CoreNetworking

@Suite("Logging: redacción de headers sensibles")
struct LoggingRedactionTests {
    @Test("Authorization/Cookie/Set-Cookie/api keys se redactan SIEMPRE, case-insensitive")
    func sensitiveHeadersAreRedacted() {
        let headers = [
            "Authorization": "Bearer secret-token",
            "authorization": "Bearer secret-token",
            "Cookie": "session=abc",
            "Set-Cookie": "session=abc",
            "X-API-Key": "sk-123",
            "Api-Key": "sk-123",
            "X-Auth-Token": "tok",
            "Proxy-Authorization": "Basic xyz",
            "My-Client-Secret": "shh"
        ]

        let redacted = HeaderRedactor.redact(headers)

        for (key, _) in headers {
            #expect(redacted[key] == "<redacted>", "el header \(key) debía redactarse")
        }
    }

    @Test("headers no sensibles pasan intactos")
    func benignHeadersPassThrough() {
        let headers = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Keep-Alive": "timeout=5",
            "X-App-Version": "1.0"
        ]
        #expect(HeaderRedactor.redact(headers) == headers)
    }

    @Test("no existe configuración para des-redactar")
    func redactionIsNotConfigurable() {
        // La firma es estática y sin flags: si esto compila, no hay opt-out.
        let _: ([String: String]) -> [String: String] = HeaderRedactor.redact
    }

    // MARK: - Nombre sensible que NO es "Authorization" (cobertura de la lista completa)

    @Test("nombre sensible 'Authentication' se redacta (no solo 'Authorization')")
    func authenticationHeaderIsRedacted() {
        let headers = ["Authentication": "Digest realm=api, nonce=xyz"]
        #expect(HeaderRedactor.redact(headers)["Authentication"] == "<redacted>")
    }

    // MARK: - Marcadores parciales (coincidencia por `contains`, no por nombre exacto)

    @Test(
        "marcadores parciales (token, secret, apikey, api-key, password) redactan pese a un nombre de header distinto"
    )
    func partialMarkersRedact() {
        let headers = [
            "X-Custom-Token": "abc",  // contiene "token"
            "clientSecret": "abc",  // contiene "secret"
            "MyApiKeyHeader": "abc",  // contiene "apikey"
            "backend-api-key-v2": "abc",  // contiene "api-key"
            "User-Password": "abc",  // contiene "password"
            "refresh_token_value": "abc"  // contiene "token", guiones bajos incluidos
        ]
        let redacted = HeaderRedactor.redact(headers)
        for (key, _) in headers {
            #expect(redacted[key] == "<redacted>", "el header \(key) debía redactarse por marcador parcial")
        }
    }

    @Test("los marcadores parciales matchean con cualquier capitalización")
    func partialMarkersRedactRegardlessOfCase() {
        let headers = [
            "X-TOKEN-ID": "abc",
            "Client-SECRET": "abc",
            "APIKEY-legacy": "abc",
            "Api-Key-Rotation": "abc",
            "PASSWORD-reset": "abc"
        ]
        let redacted = HeaderRedactor.redact(headers)
        for (key, _) in headers {
            #expect(redacted[key] == "<redacted>", "el header \(key) debía redactarse (case-insensitive)")
        }
    }

    @Test("los nombres sensibles exactos matchean con capitalización arbitraria, no solo Title-Case")
    func mixedCaseSensitiveNamesRedact() {
        let headers = [
            "aUtHoRiZaTiOn": "Bearer x",
            "CoOkIe": "session=1",
            "sEt-CoOkIe": "session=1",
            "X-aPi-KeY": "sk-1",
            "PROXY-AUTHORIZATION": "Basic xyz"
        ]
        let redacted = HeaderRedactor.redact(headers)
        for (key, _) in headers {
            #expect(redacted[key] == "<redacted>", "el header \(key) debía redactarse")
        }
    }

    @Test("un header inocuo, sin nombre sensible ni marcador parcial, NO se redacta")
    func benignHeaderWithoutMarkerIsNotRedacted() {
        let headers = ["X-Request-Id": "abc-123", "Accept-Language": "es-ES", "X-Correlation": "42"]
        #expect(HeaderRedactor.redact(headers) == headers, "sobre-redactar headers inocuos no está en el contrato")
    }
}

/// Verifica el contrato de privacidad de `LoggingInterceptor` — el doc comment
/// del tipo ("Privacy rules (not configurable)") es exactamente donde un
/// fallo es una fuga de credenciales en un sysdiagnose.
///
/// ## Por qué no se intercepta `os.Logger` directamente
///
/// Se comprobó empíricamente (fuera de este target, con un binario suelto)
/// que `OSLogStore(scope: .currentProcessIdentifier)` SÍ puede leer entradas
/// propias, pero SOLO las de nivel `.error`/`.fault` — las de `.debug`, que es
/// el nivel que usan `willSend`/`didReceive` (justo donde viven headers y
/// body), no se persisten en el log store por defecto y `getEntries` no las
/// devuelve nunca, con independencia del tiempo de espera. Construir algo
/// sobre `OSLogStore` aquí daría cobertura desigual (solo `didFail`) y frágil
/// (depende de timing y de que el proceso de test tenga log store accesible,
/// que no está garantizado en todos los entornos de CI).
///
/// En su lugar, `RequestInterceptor.swift` extrae la parte que decide QUÉ se
/// logaría a tres funciones puras `internal` (`headersLogPayload`,
/// `bodyLogPayload`, `failureLogFields`) — cada método público de
/// `LoggingInterceptor` es ahora un one-liner que llama a la función y pasa
/// el resultado a `Logger` sin tocarlo, así que verificar la función pura es
/// verificar el dato real que saldría logueado. Es el mismo patrón que
/// `ScreenPresentationLogic` en AppFoundation, y por el mismo motivo: hacer
/// verificable un contrato que un framework del sistema no deja observar.
@Suite("LoggingInterceptor: contrato de privacidad (funciones puras testables)")
struct LoggingInterceptorContractTests {
    // MARK: - headersLogPayload — el wiring real de `willSend` con `includeHeaders`

    @Test("con includeHeaders, un Authorization nunca sale con su valor real")
    func headersLogPayloadRedactsAuthorization() throws {
        var request = URLRequest(url: try #require(URL(string: "https://x.test")))
        request.setValue("Bearer super-secret-token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = try #require(LoggingInterceptor.headersLogPayload(from: request, includeHeaders: true))
        #expect(payload["Authorization"] == "<redacted>")
        #expect(payload["Content-Type"] == "application/json", "un header inocuo debe seguir siendo legible")
        #expect(!payload.values.contains("Bearer super-secret-token"), "el valor real NUNCA debe sobrevivir")
    }

    @Test("includeHeaders == false → nil, aunque el request lleve headers sensibles")
    func headersLogPayloadOptOut() throws {
        var request = URLRequest(url: try #require(URL(string: "https://x.test")))
        request.setValue("Bearer super-secret-token", forHTTPHeaderField: "Authorization")
        #expect(LoggingInterceptor.headersLogPayload(from: request, includeHeaders: false) == nil)
    }

    @Test("sin headers en el request → nil, no un diccionario vacío")
    func headersLogPayloadNoHeaders() throws {
        let request = URLRequest(url: try #require(URL(string: "https://x.test")))
        #expect(LoggingInterceptor.headersLogPayload(from: request, includeHeaders: true) == nil)
    }

    // MARK: - bodyLogPayload — opt-in; el gate de `#if DEBUG` se documenta aparte

    @Test("includeBody == false → nil, aunque el body sea perfectamente decodificable")
    func bodyLogPayloadOptOut() {
        let sensitiveBody = Data(#"{"password":"hunter2"}"#.utf8)
        #expect(LoggingInterceptor.bodyLogPayload(sensitiveBody, includeBody: false) == nil)
    }

    @Test("includeBody == true devuelve el texto tal cual")
    func bodyLogPayloadOptIn() {
        let body = Data(#"{"a":1}"#.utf8)
        #expect(LoggingInterceptor.bodyLogPayload(body, includeBody: true) == #"{"a":1}"#)
    }

    @Test("body nil, o binario no-UTF8, → nil incluso con includeBody == true")
    func bodyLogPayloadNilOrBinary() {
        #expect(LoggingInterceptor.bodyLogPayload(nil, includeBody: true) == nil)
        let binary = Data([0xFF, 0xFE, 0x00, 0xD8])
        #expect(LoggingInterceptor.bodyLogPayload(binary, includeBody: true) == nil)
    }

    // El límite conocido: esta suite se compila y corre en DEBUG (`swift
    // test` siempre construye en configuración debug salvo `-c release`,
    // y los tests necesitan `@testable import` que solo se resuelve en
    // debug). El `#if DEBUG` que envuelve la ÚNICA llamada a
    // `bodyLogPayload` en `willSend`/`didReceive` no se puede, por tanto,
    // poner en rojo/verde desde un `@Test` de este target. Verificado a
    // mano en su lugar, con `swift build -c release` y luego:
    //   strings .build/arm64-apple-macosx/release/CoreNetworking.build/RequestInterceptor.swift.o | grep 'body:'
    // — cero resultados (frente a "body: %{private}s" en el `.o` de debug) y
    //   nm .../release/.../RequestInterceptor.swift.o | grep bodyLogPayload
    // — sin símbolo alguno: confirma que en release el bloque `#if DEBUG`
    // entero desaparece del objeto compilado, no solo que `includeBody`
    // decide en runtime.

    // MARK: - failureLogFields — nunca `underlying`, nunca el body del servidor

    @Test("el texto de underlying NUNCA aparece en los campos que didFail logaría")
    func failureLogFieldsNeverExposesUnderlying() {
        struct ServerLeak: Error, CustomStringConvertible {
            var description: String { "user john.doe@example.com not found in database" }
        }
        let error = APIError.stub(
            code: .httpStatus,
            statusCode: 404,
            body: Data("user john.doe@example.com not found".utf8),
            underlying: ServerLeak()
        )
        let fields = LoggingInterceptor.failureLogFields(error, elapsedMilliseconds: 42)

        #expect(fields.code == "httpStatus")
        #expect(fields.status == "404")
        #expect(fields.elapsedMS == 42)
        #expect(!fields.code.contains("john.doe"))
        #expect(!fields.status.contains("john.doe"))
    }

    @Test("failureLogFields no puede recibir underlying ni el body: no están en su firma")
    func failureLogFieldsSignatureExcludesUnderlyingAndBody() {
        // Garantía estructural, no de comportamiento: si esto compila, la
        // función sigue sin aceptar `underlying`/`response` como parámetro,
        // así que es IMPOSIBLE que termine emitiéndolos.
        let _: (APIError, Int) -> (code: String, status: String, elapsedMS: Int) = LoggingInterceptor.failureLogFields
    }

    @Test("sin statusCode (fallo de transporte) → status \"-\", nunca crashea")
    func failureLogFieldsNoStatusCode() {
        let error = APIError.stub(code: .transport, underlying: URLError(.timedOut))
        let fields = LoggingInterceptor.failureLogFields(error, elapsedMilliseconds: 5)
        #expect(fields.status == "-")
        #expect(fields.code == "transport")
        #expect(fields.elapsedMS == 5)
    }

    // MARK: - elapsedMilliseconds — determinista, sin `sleep`

    @Test("elapsedMilliseconds mide la duración exacta entre start y now")
    func elapsedMillisecondsIsExact() {
        let start = ContinuousClock.now
        let later = start.advanced(by: .milliseconds(250))
        #expect(LoggingInterceptor.elapsedMilliseconds(since: start, now: later) == 250)
    }

    @Test("elapsedMilliseconds redondea al entero más cercano")
    func elapsedMillisecondsRounds() {
        let start = ContinuousClock.now
        let later = start.advanced(by: .microseconds(1600))  // 1.6ms -> redondea a 2
        #expect(LoggingInterceptor.elapsedMilliseconds(since: start, now: later) == 2)
    }

    @Test("elapsedMilliseconds sin avance de reloj → 0")
    func elapsedMillisecondsZero() {
        let start = ContinuousClock.now
        #expect(LoggingInterceptor.elapsedMilliseconds(since: start, now: start) == 0)
    }

    // MARK: - Ciclo willSend→didReceive/didFail a través del pipeline REAL
    //
    // Estos dos tests no pueden observar qué se logueó (ver el comentario del
    // suite), pero ejercitan el código de PRODUCCIÓN real de
    // `LoggingInterceptor` (no las funciones puras) con `includeHeaders` e
    // `includeBody` en `true`, en éxito y en fallo — la parte que las
    // funciones puras no cubren por sí solas: que `willSend`/`didReceive`/
    // `didFail` realmente llaman a esas funciones y no revientan con datos
    // reales del pipeline. `RecordingInterceptor`, en paralelo en la misma
    // lista de interceptores, confirma que ambos ven el mismo `context.id`
    // por intento — el mismo contrato que `InterceptorTests.
    // contextIdentityAcrossRetries` prueba de forma genérica.

    private struct EchoRequest: BaseRequest {
        typealias Response = Echo
        let path = "/thing"
        let method: HTTPMethod = .get
    }

    private struct Echo: Decodable, Sendable { let ok: Bool }

    @Test("LoggingInterceptor en éxito: willSend→didReceive con el mismo context.id, sin crash")
    func loggingInterceptorSurvivesSuccessPath() async throws {
        let baseURL = URL(string: "https://logging-pipeline-ok.test")!
        let recorder = RecordingInterceptor()
        let logging = LoggingInterceptor(includeHeaders: true, includeBody: true)
        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(
                url: baseURL.appendingPathComponent("/thing"),
                response: .response(status: 200, body: Data(#"{"ok":true}"#.utf8))
            )
        )
        let configuration = NetworkingConfiguration(baseURL: baseURL)
        let service = APIService(
            configuration: configuration,
            transport: transport,
            retryPolicy: .noRetry,
            interceptors: [logging, recorder]
        )

        let echo: Echo = try await service.execute(EchoRequest())
        #expect(echo.ok)

        let events = await recorder.events
        #expect(events.count == 2, "willSend + didReceive, en el mismo intento que vio LoggingInterceptor")
        guard case .willSend(_, let willSendContext) = events[0],
            case .didReceive(_, _, let didReceiveContext) = events[1]
        else {
            Issue.record("orden de eventos inesperado: \(events)")
            return
        }
        #expect(willSendContext.id == didReceiveContext.id, "un mismo intento comparte context.id")
    }

    @Test(
        "LoggingInterceptor en fallo HTTP con body sensible: willSend→didReceive→didFail comparten context.id, sin crash"
    )
    func loggingInterceptorSurvivesFailurePath() async throws {
        let baseURL = URL(string: "https://logging-pipeline-fail.test")!
        let recorder = RecordingInterceptor()
        let logging = LoggingInterceptor(includeHeaders: true, includeBody: true)
        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(
                url: baseURL.appendingPathComponent("/thing"),
                response: .response(status: 500, body: Data("user jane@corp.example blocked".utf8))
            )
        )
        let configuration = NetworkingConfiguration(baseURL: baseURL)
        let service = APIService(
            configuration: configuration,
            transport: transport,
            retryPolicy: .noRetry,
            interceptors: [logging, recorder]
        )

        await #expect(throws: APIError.self) {
            let _: Echo = try await service.execute(EchoRequest())
        }

        let events = await recorder.events
        // Un 500 SÍ es una respuesta válida: willSend, didReceive (llegó la
        // respuesta) y didFail (status no-2xx) — el mismo orden que prueba
        // `InterceptorTests.didFailOnHTTPError` de forma genérica.
        #expect(events.count == 3, "willSend + didReceive + didFail")
        guard case .willSend(_, let willSendContext) = events.first, case .didFail(_, let didFailContext) = events.last
        else {
            Issue.record("orden de eventos inesperado: \(events)")
            return
        }
        #expect(willSendContext.id == didFailContext.id, "un mismo intento comparte context.id, también en fallo")
    }
}
