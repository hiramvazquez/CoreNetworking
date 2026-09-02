# Changelog — CoreNetworking

Todos los cambios notables de este paquete se documentan en este fichero. El formato sigue
[Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y el versionado,
[SemVer](https://semver.org/lang/es/).

## [Unreleased]

### Documentación

- Los 13 `@Snippet(path:)` de `Documentation.docc/` (no se resolvían en el primer
  `xcodebuild docbuild` sobre DerivedData limpio) se sustituyen por bloques de código en
  línea marcados `<!-- snippet: <name> -->`, verificados contra `Snippets/` por
  `Scripts/check-doc-snippets.sh` en CI (job `docs`, antes de `docbuild`).

## [1.0.0] - 2026-09-02

Primera versión estable.

### Roturas de API

- `APIError` pasa de ser un `enum` cerrado a un `struct` extensible con `Code` (conjunto
  abierto), `RequestSummary`, `ResponseSummary` y `underlying`. Añadir un `Code` nuevo ya
  no rompe a los consumidores. `TransportError` y `APIMessageError` desaparecen —
  `APIError.category` cubre la clasificación de alto nivel, y `decodeBody<T>(_:using:)`
  permite decodificar cualquier sobre de error del servidor con el tipo y el `JSONDecoder`
  del consumidor.
- `APIError` deja de ser `Equatable` (un `==` que ignorase `underlying` mentiría).
  `CoreNetworkingTestSupport` añade `APIError.stub(code:...)` para tests.
- `RetryPolicy.shouldRetry` pasa a `@Sendable (APIError, Int) -> Bool`; `RetryPolicy` deja
  de ser `Equatable` (el predicado es un closure).
- `RequestInterceptor.didFail(_:error:)` tipa `error: APIError` en vez de `Error`
  (sustituido más tarde por la firma con `RequestContext`, ver más abajo).
- `SSLPinningConfiguration`: `pinnedHosts: Set<String>?` → `hosts: Hosts` (`.all`/`.only`);
  `validateCertificateChain: Bool` → `chainValidation: ChainValidation`
  (`.system`/`.unsafeSkipForDevelopment`); el constructor exige ≥ 2 pines.
- `APIService.init` ya no crea su propia `URLSession`: el designado recibe
  `transport: any HTTPTransport` (el `convenience init(configuration:...)` de siempre se
  conserva).
- `RetryPolicy.initialDelay`/`.maxDelay` pasan de `TimeInterval` a `Duration`.
- `CoreNetworkingTestSupport.MockAPIService.result: Any?` desaparece —
  `stub(_:returning:)`/`stub(_:throwing:)` por tipo de request.
- `BaseRequest` se rediseña alrededor de `associatedtype Body: Encodable & Sendable =
  Never` / `associatedtype Response: Decodable & Sendable = Empty`; `parameters` se
  renombra a `body`; `timeoutInterval: TimeInterval` pasa a `timeout: Duration`;
  `headers`/`queryItems` dejan de ser opcionales.
- `HTTPMethod` cambia sus casos a minúscula (`.get`, `.post`, …) — `HTTPMethod.GET` ya no
  compila.
- `APIServiceProtocol.execute`: `execute<Request, Response: Decodable>(request:) ->
  Response` pasa a `execute<R: BaseRequest>(_:) -> R.Response`, con la sobrecarga
  `execute<R, Value>(_:as:)` añadida.
- `NetworkingConfiguration.environment` desaparece.
- `BaseResponse.swift` (`BaseResponse`, `EmptyResponse`), `RequestParameters`,
  `EmptyParameters`, `RequestValidationError`,
  `validated()`/`isValid`/`debugValidated()`/`requestDescription` se eliminan.
- `SessionDelegates.swift` (`PinningSessionDelegate`, `UploadProgressDelegate`)
  desaparece — el pinning decide por tarea con `TaskDelegate`.
- `APIServiceProtocol.download(request:progress:) -> Data` se sustituye por
  `data(for:progress:) -> Data` (en memoria) y `download(_:to:progress:)` (a disco).
- `RequestInterceptor` se reescribe alrededor de `RequestContext`: `willSend(_:context:)`
  pasa a `async throws(APIError)`; `didReceive` recibe `HTTPURLResponse` (no
  `URLResponse`) y `context`; `didFail` pasa a `didFail(_ error: APIError, context:)` (ya
  no recibe `request:` por separado).
- `APIService.init` (designado y `convenience`) gana `retriers: [any RequestRetrier] = []`.
- **`APIServiceProtocol.upload`** pasa a la misma forma que `execute`:
  `upload(_:data:progress:) -> Request.Response` (el tipo de respuesta ya no se anota en
  el call site, se infiere del propio request) más la sobrecarga
  `upload(_:data:as:progress:) -> Value`, igual que `execute(_:as:)`. Se elimina
  `upload(request:data:progress:) -> Response`. Migrar
  `service.upload(request: req, data: d)` a `service.upload(req, data: d)`.
- **`APIError.Category`** gana `.unreachable`
  (`networkConnectionLost`/`cannotConnectToHost`/`dnsLookupFailed`/`cannotFindHost`,
  antes indistinguibles de `.unknown`): un `switch` exhaustivo sobre `Category` en la app
  deja de compilar hasta añadir el caso — el propio doc del tipo pide comparar contra los
  casos conocidos y caer a `default`, nunca `switch` exhaustivo, precisamente por esto.
- `MockAPIService` (`CoreNetworkingTestSupport`) lanza `APIError(code: .unstubbed)` — no
  `.invalidResponse` — cuando un request no tiene stub registrado o el stub no coincide
  con el tipo pedido; `underlying` nombra el request y el tipo esperado. Un test que
  comparaba contra `.invalidResponse` para este caso debe comparar contra `.unstubbed`.

### Changed

- **`download(_:to:)`** pasa por el mismo `performWithRetry` que `execute`/`upload`/`data`
  — interceptores, `retriers` y `retryPolicy` incluidos — en vez de una copia paralela del
  pipeline de un único intento. Cada intento reescribe `destination` atómicamente, así que
  reintentar es válido: una descarga a medias reintenta desde cero, nunca reanuda. El
  mapeo de errores no cambia de comportamiento observable.
- `NetworkingConfiguration.protocolClasses` queda `@available(*, deprecated, message:
  "Configura protocolClasses en sessionConfiguration")` — sigue funcionando (se fusiona en
  la `URLSessionConfiguration` real), pero `sessionConfiguration` es ahora la única forma
  soportada de instalar un `URLProtocol` de mock.

### Added

- `HTTPTransport` (`Transport/HTTPTransport.swift`): el protocolo `send(_:progress:) async
  throws -> (Data, HTTPURLResponse)` que reemplaza al registro estático de `URLProtocol`
  como punto de inyección bajo `APIService`. `URLSessionTransport` es la implementación de
  producción: posee la `URLSession` y su `deinit`.
- `InMemoryTransport` (`CoreNetworkingTestSupport`): `HTTPTransport` en memoria, sin
  `URLSession` ni registro global — un `actor` por test. Soporta secuencias de respuestas
  (500 → 500 → 200).
- `ManualClock` (`CoreNetworkingTestSupport`): `Clock<Duration>` que solo avanza cuando el
  test llama a `advance(by:)`; `waitUntilSleeping()` suspende hasta que el pipeline
  registra el siguiente `sleep`.
- `MockURLProtocol` / `MockAPIHelper.setupMockSequence(...)`: soporte de secuencias también
  en el mock de integración.
- `Empty`: el `Decodable` que `BaseRequest.Response` usa por defecto y que `execute`
  produce para 204/205/body vacío.
- `NetworkingConfiguration.makeEncoder: @Sendable () -> JSONEncoder`.
- `NetworkingConfiguration.sessionConfiguration: @Sendable () -> URLSessionConfiguration`,
  con `defaultSessionConfiguration()` (`waitsForConnectivity`, cookies desactivadas, TLS
  1.2 mínimo) como valor por defecto.
- `PinningFailure` (`Transport/TaskDelegate.swift`), `public`: la señal interna que
  distingue "pinning rechazó el certificado" de "el llamador canceló".
  `CoreNetworkingTestSupport.InMemoryTransport.Outcome.pinningFailure(host:)` la expone en
  tests sin necesitar un handshake TLS real.
- `RequestRetrier` (`Retry/RequestRetrier.swift`): `func retry(_ error: APIError, context:
  RequestContext) async -> RetryDecision` (`.doNotRetry` / `.retry` /
  `.retryAfter(Duration)`), consultado ANTES que `RetryPolicy` en cada intento fallido.
- `Auth/TokenRefresher.swift`: `TokenRefreshing` (protocolo) y `actor TokenRefresher` —
  deduplica refreshes concurrentes. `BearerTokenInterceptor(tokenProvider:)` añade
  `Authorization: Bearer <token>` leyendo el token fresco en cada `willSend`.
  `TokenRefreshRetrier(refresher:)` refresca y reintenta un 401 solo en el primer intento.
- `CoreNetworkingTestSupport`: `RecordingInterceptor`, un `RequestInterceptor` público que
  graba `willSend`/`didReceive`/`didFail` en orden.
- `APIError.errorDescription` (`LocalizedError`): frase neutra y localizable
  (inglés/español, string catalog del paquete) por `category`, nunca un código pelado.
- `EndpointService` (`Sources/CoreNetworking/EndpointService.swift`): `public protocol
  EndpointService: Sendable { var api: any APIServiceProtocol { get } }` con `public
  extension EndpointService { func call<R: BaseRequest>(_ request: R) async
  throws(APIError) -> R.Response }`. Plantilla cómoda para un `Service` de un solo request
  — no un requisito: un `Service` que necesite más de un patrón de llamada sigue llamando
  `api.execute` directamente.
- `AGENTS.md` en la raíz del paquete: un Service por request, mapeo de errores con
  `category`/`decodeBody`, cómo testear con `MockAPIService`/`InMemoryTransport`.
- `Empty` conforma `Equatable`.
- `APIError.Code.unstubbed` (`CoreNetworkingTestSupport`): el código que lanza
  `MockAPIService` sin stub.
- `errorDescription` (EN/ES, `Localizable.xcstrings`) para `.unreachable`: "Could not
  connect to the server." / "No se pudo conectar con el servidor.".

### Fixed

- Ningún `catch` del pipeline pierde ya el error original: un `NSError` arbitrario del
  transporte llega como `code == .unexpected` con `underlying` intacto; un fallo de
  decodificación conserva el body de la respuesta para diagnóstico.
- 401 y 403 ya no colapsan en la misma categoría (`.unauthorized` vs. `.forbidden`).
- `isRetryable` ya no reintenta `notConnectedToInternet` y sí reintenta `dnsLookupFailed` /
  `cannotFindHost`, que son transitorios.
- `execute` ya soporta respuestas vacías: `Response == Empty` decodifica a `Empty()` sin
  mirar el body (204, HEAD, DELETE); un `Response` declarado que no sea `Empty` con body
  vacío lanza `.decoding` con `response.body.isEmpty` en vez de que `JSONDecoder` falle con
  un mensaje opaco.
- `Content-Type: application/json` ya solo se envía cuando el request declara `body`
  (antes viajaba también en GET sin cuerpo); `Accept: application/json` se envía siempre,
  sobrescribible por `headers`.
- El body del request se codifica con `NetworkingConfiguration.makeEncoder` en vez de un
  `JSONEncoder()` recién instanciado.
- `buildURLRequest` usa `URL.appending(path:)` en vez de `appendingPathComponent`.

### Docs

- `RequestSummary.init(URLRequest)` documenta que un método fuera del `HTTPMethod`
  cerrado (p. ej. WebDAV) se guarda como `.get` igual que `httpMethod == nil` —
  limitación conocida, no un bug; `HTTPMethod` sigue cerrado a propósito (sin `case
  custom(String)`).
- Tabla ASN.1 de SPKI: añadido RSA-3072 (antes solo RSA-2048/4096 y EC P-256/P-384).
