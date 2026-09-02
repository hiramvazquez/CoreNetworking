# CoreNetworking

Capa de red standalone sobre `URLSession` con async/await, Swift 6 estricto y
errores tipados. Sin dependencias externas.

- **Typed throws**: toda la API pública lanza `throws(APIError)`.
- **Config inyectada**: sin singletons ni fallbacks — `NetworkingConfiguration`
  entra por el init.
- **Retry seguro**: solo métodos idempotentes por defecto, backoff exponencial
  con jitter, `Retry-After` respetado.
- **SSL pinning** de clave pública (SPKI SHA-256, formato TrustKit) con
  decisión de 3 estados.
- **Mocks fuera de producción**: producto separado `CoreNetworkingTestSupport`.

## Requisitos

iOS 17+ · macOS 14+ · Swift 6.2+ (swift-tools 6.2, language mode 6, strict concurrency)

## Instalación

```swift
// Package.swift
dependencies: [
    .package(path: "../CoreNetworking")
],
targets: [
    .target(name: "MiApp", dependencies: ["CoreNetworking"]),
    .testTarget(
        name: "MiAppTests",
        dependencies: [
            "MiApp",
            .product(name: "CoreNetworkingTestSupport", package: "CoreNetworking")
        ]
    )
]
```

## Uso básico

### 1. Configuración y servicio

```swift
import CoreNetworking

let configuration = NetworkingConfiguration(
    baseURL: URL(string: "https://api.miapp.com")!,
    defaultHeaders: ["X-App-Version": "1.0"],
    environment: "production"
)

let service = APIService(configuration: configuration)
```

`APIService` no crea ninguna `URLSession`: el `init` de arriba es azúcar que
construye un `URLSessionTransport` por debajo. Si necesitas configurar la
sesión (timeouts, `waitsForConnectivity`, caché…) o pinning, pasa el
transporte tú mismo — es el punto de inyección real:

```swift
let transport = URLSessionTransport(
    configuration: {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = true
        return c
    }(),
    pinning: pinning   // opcional, ver SSL Pinning
)
let service = APIService(configuration: configuration, transport: transport)
```

En tests, el transporte es lo que cambias para no tocar la red — ver
[Testing](#testing).

### El decoder es tuyo

Cada backend tiene su convención de claves y de fechas, así que el `JSONDecoder`
lo pones tú. Sin esto había que repetir `CodingKeys` en cada DTO —o decodificar
las fechas a `String` y convertirlas a mano—, que es trabajo que una línea
resuelve:

```swift
let configuration = NetworkingConfiguration(
    baseURL: URL(string: "https://api.miapp.com")!,
    makeDecoder: {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }
)
```

Es una **fábrica** y no un `JSONDecoder` a propósito: `JSONDecoder` es una clase
mutable y no `Sendable`, así que compartir una instancia entre peticiones
concurrentes sería una carrera de datos que el compilador no puede ver. Se crea
uno por decode, que es lo que ya se hacía.

Si no pasas nada, el comportamiento es el de siempre: `JSONDecoder()` sin
configurar, o sea claves literales y fechas como número.

`NetworkingConfiguration` es un struct inmutable `Sendable`. Una `baseURL` sin
scheme/host es un error de programación y falla en construcción (precondición),
no en el primer request.

### 2. Requests tipados

```swift
struct GetGamesRequest: BaseRequest {
    typealias Parameters = EmptyParameters
    let path = "/games"
    let method: HTTPMethod = .GET
}

struct CreateGameRequest: BaseRequest {
    struct Body: RequestParameters {
        let title: String
    }
    let path = "/games"
    let method: HTTPMethod = .POST
    let parameters: Body?
}
```

Opciones por request (con defaults): `headers` (pisan a los de la config),
`queryItems`, `timeoutInterval` (30 s) y `allowsNonIdempotentRetry` (false —
opt-in para reintentar POST/PATCH).

### 3. Ejecutar

```swift
do {
    let games: [Game] = try await service.execute(request: GetGamesRequest())
} catch {
    // typed throws: `error` ya es APIError
    switch error.category {
    case .offline: showOfflineBanner()
    case .unauthorized: relaunchLogin()
    default: show(error.localizedDescription)
    }
}
```

Ver la sección [Errores](#errores) para el detalle de `code`, `category` y
`decodeBody`.

### Upload / Download

```swift
let response: UploadResponse = try await service.upload(
    request: UploadRequest(),
    data: fileData,
    progress: { fraction in print(fraction) }
)

let data = try await service.download(request: DownloadRequest(), progress: nil)
```

Usan las APIs async nativas de `URLSession`: cancelar el `Task` cancela la
transferencia. Ambos pasan por el mismo pipeline que `execute` (interceptores,
retry, mapeo de errores). El progreso de download solo emite fracciones si el
servidor manda `Content-Length` (siempre emite 1.0 al terminar).

## Errores

Un único tipo, `APIError` (struct, no enum): conserva **todo** — lo que se
pidió (`request`), todo lo que dijo el servidor (`response`: status, headers
y body sin tocar) y el error de debajo (`underlying`: `URLError`,
`DecodingError`, `EncodingError`, o lo que sea que un `URLProtocol`
produjera). Nada se descarta camino arriba. `TransportError` no existe: era
un segundo `Error` público para la misma capa que además colapsaba 401 y 403
en el mismo caso.

```swift
do {
    let games: [Game] = try await service.execute(request: GetGamesRequest())
} catch {
    switch error.category {
    case .offline:          showOfflineBanner()
    case .unauthorized:     relaunchLogin()
    case .untrustedServer:  showInsecureConnection()
    default:
        if let problem = try? error.decodeBody(MyServerProblem.self) {
            show(problem.detail)
        } else {
            show(error.localizedDescription)
        }
    }
}
```

- **`code`** (`APIError.Code`): qué pasó, como conjunto abierto —
  `.invalidURL`, `.invalidResponse`, `.transport`, `.cancelled`,
  `.untrustedServer`, `.httpStatus`, `.encoding`, `.decoding`,
  `.interceptor`, `.unexpected`. Un `Code` nuevo **no** rompe a los
  consumidores: no hagas `switch` exhaustivo sobre `code`, compáralo contra
  los estáticos que conoces y cae a `default`.
- **`category`**: clasificación cerrada y de más alto nivel para
  presentación/política — `.offline`, `.timeout`, `.unauthorized`,
  `.forbidden`, `.notFound`, `.rateLimited`, `.client`, `.server`,
  `.untrustedServer`, `.cancelled`, `.decoding`, `.unknown`. 401 y 403 son
  categorías distintas (`.unauthorized` vs. `.forbidden`): la UI las trata
  distinto (relanzar login no es lo mismo que "no tienes permiso").
- **`decodeBody<T>(_:using:)`**: la app decodifica **su propio** sobre de
  error con **su propio** `JSONDecoder` — `{"message"}`, RFC 9457
  `problem+json`, errores de validación por campo, lo que sea. El paquete
  nunca interpreta el body del servidor, solo lo conserva en `response.body`.
- **`isCancellation`**: `true` solo para `code == .cancelled` (cancelación
  del llamador). Nunca se confunde con `.untrustedServer` (pinning).
- **`isRetryable`** / **`retryAfter`**: ver [Retry](#retry).
- **`statusCode`**, **`urlError`**: atajos sobre `response`/`underlying`.
- `errorDescription` (`LocalizedError`) es una frase neutra y localizable
  (inglés/español vía el string catalog del paquete) por `category` — nunca
  un código pelado tipo "error 9". Es un fallback técnico; el copy real de
  cara al usuario sigue siendo responsabilidad de la app.

**Política de evolución**: `APIError` no es `Equatable` a propósito — un
`==` que ignorase `underlying` (un `any Error`) mentiría. Compara `code`,
`statusCode` o `category`. Para stubear en tests, usa
`CoreNetworkingTestSupport`:

```swift
import CoreNetworkingTestSupport

let error = APIError.stub(code: .httpStatus, statusCode: 422, body: bodyData)
#expect(error.code == .httpStatus)
```

## Retry

```swift
let service = APIService(
    configuration: configuration,
    retryPolicy: RetryPolicy(maxAttempts: 3, initialDelay: .milliseconds(500))
)
```

- `maxAttempts` = requests TOTALES (3 ⇒ como mucho 3 requests). `.noRetry` = 1.
- Solo métodos idempotentes reintentan por defecto; POST/PATCH requieren
  `allowsNonIdempotentRetry = true` en el request.
- Retryable por defecto (`APIError.isRetryable`): errores transitorios de
  transporte (`timedOut`, `networkConnectionLost`, `cannotConnectToHost`,
  `dnsLookupFailed`, `cannotFindHost` — **no** `notConnectedToInternet`: sin
  red no hay nada que reintentar en medio segundo) y HTTP 5xx / 408 / 429.
- Backoff exponencial con equal jitter, en `Duration` (no `TimeInterval`):
  `initialDelay: Duration = .milliseconds(500)`, `maxDelay: Duration = .seconds(16)`.
  Un `Retry-After` del servidor (segundos u HTTP-date, también `Duration`)
  manda sobre el backoff.
- El criterio es un predicado inyectable y tipado:
  ```swift
  public let shouldRetry: @Sendable (APIError, Int) -> Bool
  ```
  Recibe el `APIError` (así puede mirar `code`, `statusCode`, `urlError` o el
  body del servidor sin castear) y el número de intentos ya hechos. Por
  defecto es `APIError.isRetryable`; pásalo para, por ejemplo, no reintentar
  nunca un método propio:
  ```swift
  RetryPolicy(shouldRetry: { error, _ in error.isRetryable && error.code != .interceptor })
  ```
  `RetryPolicy` no es `Equatable` a propósito: `shouldRetry` es un closure.
- El sleep entre reintentos pasa por un `any Clock<Duration>` inyectado en
  `APIService.init(clock:)` — `ContinuousClock()` por defecto, nunca
  `Task.sleep` directo. En tests, inyecta `ManualClock`
  (`CoreNetworkingTestSupport`) y controla el paso del tiempo a mano: cero
  esperas reales, cero flakiness por carga de CI. Ver [Testing](#testing).

## SSL Pinning

Pin = SHA-256 del SPKI (SubjectPublicKeyInfo) en base64 — el mismo formato que
usan TrustKit, HPKP y `NSPinnedDomains`:

```bash
openssl s_client -connect api.miapp.com:443 < /dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary | base64
```

RFC 7469 §2.5 exige un **pin de respaldo**: una clave que ya tienes (o has
generado) pero que el servidor todavía no sirve. Sin él, rotar la clave del
servidor deja cada copia instalada de la app sin poder conectar hasta que
salga una actualización. Genera el respaldo desde una clave/CSR futuros con el
mismo comando, apuntando al `.pem` en lugar de al host:

```bash
# clave/CSR de respaldo, aún no desplegados en el servidor
openssl pkey -in respaldo.pem -pubout -outform DER \
  | openssl dgst -sha256 -binary | base64
```

### Pinning declarativo (recomendado): `NSPinnedDomains`

Para pines estáticos, Apple ofrece pinning declarativo desde iOS 14 —
`NSAppTransportSecurity` → `NSPinnedDomains` — sin escribir código, sin
delegate propio, cubierto por **toda** `URLSession` del proceso (no solo la de
este paquete) y sin poder sufrir un bug de cableado como el de
`PinningSessionDelegate`. Va en el `Info.plist` de la app:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSPinnedDomains</key>
    <dict>
        <key>api.miapp.com</key>
        <dict>
            <key>NSIncludesSubdomains</key>
            <true/>
            <key>NSPinnedLeafIdentities</key>
            <array>
                <dict>
                    <key>SPKI-SHA256-BASE64</key>
                    <string>r/mIkG3eEpVdm+u/ko/cwxzOMo1bk4TyHIlByibiA5E=</string>
                </dict>
                <dict>
                    <key>SPKI-SHA256-BASE64</key>
                    <string>Vjs8r4z+80wjNcr1YKepWQboSIRi63WsWXhIMN+eWys=</string>
                </dict>
            </array>
            <key>NSPinnedCAIdentities</key>
            <array/>
        </dict>
    </dict>
</dict>
```

`NSPinnedLeafIdentities` pinea la clave hoja (lo que hace este paquete);
`NSPinnedCAIdentities` pinea una CA intermedia/raíz — usa uno u otro según tu
cadena, con al menos dos entradas (clave actual + respaldo) igual que arriba.
Basta con esto cuando los pines son estáticos y no necesitas pinear
`WKWebView` con la misma política (`NSPinnedDomains` **no** cubre WebKit).

Usa el pinning programático de abajo cuando necesites pines que se obtienen o
rotan en remoto, o un conjunto de hosts que se decide en tiempo de ejecución
— casos que un plist estático no puede expresar.

### Pinning programático (opt-in)

```swift
let pinning = SSLPinningConfiguration(
    publicKeyHashes: [
        "r/mIkG3eEpVdm+u/ko/cwxzOMo1bk4TyHIlByibiA5E=",   // clave actual
        "Vjs8r4z+80wjNcr1YKepWQboSIRi63WsWXhIMN+eWys="    // pin de respaldo (RFC 7469)
    ],
    hosts: .only(["api.miapp.com"])   // o .all para pinear toda la sesión
)
let service = APIService(configuration: configuration, sslPinning: pinning)
```

Decisión de 3 estados: host sin pin → validación TLS por defecto del sistema;
pin válido → continúa; pin inválido o cadena rota → conexión cancelada.
`.disabled` equivale a "sin pinning" (el sistema valida normal; nunca acepta a
ciegas).

El constructor exige (con `precondition`, pines son constantes de compilación)
al menos 2 pines válidos — usa `SSLPinningConfiguration.validatePins(_:)`
primero si los pines vienen de una fuente remota o no confiable, para
convertir un payload malformado en un error manejado en vez de un crash.

`chainValidation: .unsafeSkipForDevelopment` salta `SecTrustEvaluateWithError`
para poder probar contra certificados autofirmados; solo tiene efecto en
builds `DEBUG` — en Release degrada a `.system` con un `assertionFailure`, así
que nunca llega a producción por accidente.

Soportado en la tabla ASN.1 de SPKI: RSA-2048/3072/4096, EC P-256/P-384.

## Interceptores

```swift
public protocol RequestInterceptor: Sendable {
    func willSend(_ request: URLRequest) async -> URLRequest
    func didReceive(_ response: URLResponse, data: Data) async
    func didFail(_ request: URLRequest, error: APIError) async
}
```

Se invocan en orden. `didFail` recibe siempre el `APIError` ya mapeado (no
`Error`), así que puede leer `code`, `statusCode` o `response` sin castear.
Se notifica en TODOS los caminos de error del pipeline (transporte, respuesta
inválida, non-2xx). Los errores de decodificación ocurren después del
pipeline y no pasan por interceptores.

`LoggingInterceptor` (incluido) loguea vía `os.Logger`; los headers sensibles
(Authorization, Cookie, api keys, tokens…) se redactan SIEMPRE — no hay opción
para des-redactar. Bodies solo en DEBUG y con opt-in.

## Testing

### `InMemoryTransport` (camino principal)

Sin `URLSession`, sin `URLProtocol`, sin registro estático global: cada
`InMemoryTransport` es una instancia nueva que posee el test, así que no hay
contaminación entre tests corriendo en paralelo ni disciplina de "un host por
test" que recordar. Es un `actor` (el estado se comparte de verdad entre el
test y el pipeline), y soporta SECUENCIAS de respuestas — 500 → 500 → 200 —
para probar "reintento que acaba bien", algo que `MockURLProtocol` no puede
hacer.

```swift
import CoreNetworking
import CoreNetworkingTestSupport

let transport = InMemoryTransport()
await transport.register(InMemoryTransport.Exchange(
    url: URL(string: "https://unit.test/games")!,
    responses: [
        .response(status: 500),
        .response(status: 500),
        .response(status: 200, body: gamesJSON)
    ]
))

let service = APIService(
    configuration: NetworkingConfiguration(baseURL: URL(string: "https://unit.test")!),
    transport: transport,
    retryPolicy: RetryPolicy(maxAttempts: 3, initialDelay: .milliseconds(1)),
    clock: ManualClock()   // sin dormir de verdad — ver más abajo
)

let games: [Game] = try await service.execute(request: GetGamesRequest())
await transport.recorded.count   // 3
```

- `Exchange.responses` se consume en orden; el último elemento se repite (un
  único elemento se comporta como un mock reutilizable de siempre).
- `transport.recorded`: cada `URLRequest` que pasó por el transporte, con
  `httpBody` legible directamente (nunca un stream — no hay `URLSession` de
  por medio).
- `Outcome.failure(_ error: any Error)` simula un fallo de transporte (p. ej.
  `URLError(.timedOut)`) sin necesidad de un `URLProtocol`.

### `ManualClock`: retry sin esperar de verdad

`APIService.performWithRetry` duerme a través de un `any Clock<Duration>`
inyectado (`ContinuousClock()` por defecto). `ManualClock` (misma librería)
es ese reloj en tests: nadie espera tiempo real, y `advance(by:)` dispara los
`sleep` pendientes a mano.

```swift
let clock = ManualClock()
let task = Task { () async throws(APIError) -> Payload in
    try await service.execute(request: GetGamesRequest())
}
await clock.waitUntilSleeping()   // el pipeline llegó al backoff — sin sondear, sin dormir
clock.advance(by: .seconds(10))   // dispara el siguiente intento
let result = try await task.value
```

`waitUntilSleeping()` no sondea ni duerme: es una `withCheckedContinuation`
que se resuelve en el instante en que el pipeline registra el `sleep`. Es la
pieza que hace posible que `RetryBehaviorTests` no mida tiempo de pared ni
tenga un solo `Task.sleep` real, y que `swift test --parallel` sea
determinista bajo cualquier carga de CI.

### `MockURLProtocol` (integración)

Para el puñado de tests que necesitan atravesar el URL loading system de
verdad — merge de headers, cookies, redirecciones, el delegate de pinning —
`MockURLProtocol` sigue disponible, ahora también con secuencias:

```swift
MockURLProtocol.register(MockNetworkExchange(
    url: URL(string: "https://unit.test/games")!,
    responses: [MockResponse(statusCode: 500), MockResponse(statusCode: 200, data: gamesJSON)]
))

let configuration = NetworkingConfiguration(
    baseURL: URL(string: "https://unit.test")!,
    protocolClasses: [MockURLProtocol.self]
)
let service = APIService(configuration: configuration)
```

- Registro síncrono, matching por método+URL, `responses` consumidas en
  orden (la última se repite), `recordedRequests` para asertar
  conteos/headers, `latency` opcional para probar cancelación.
- **Aísla por URL, no con `removeAll()`.** El registro es estático y compartido,
  y Swift Testing paraleliza las suites por defecto: un `removeAll()` en tu test
  borra los mocks de las suites que corren a la vez y las deja en rojo por algo
  que no tiene nada que ver con lo que probaban. Pasó de verdad —cinco tests de
  cancelación ajenos— y el fallo costaba entender. Usa **un host distinto por
  test** (`https://mi-caso.test`), que es lo que de verdad aísla porque el
  matching es por URL exacta. `removeAll()` sigue existiendo para el caso en que
  controlas toda la ejecución, p. ej. bajo `@Suite(.serialized)`.

### `MockAPIService`

Stub de `APIServiceProtocol` para tests de CONSUMIDORES del paquete (no de
`APIService` en sí). Los stubs se registran por TIPO de request, no por orden
de llamada — un `stub` para `GetGamesRequest` nunca se confunde con uno para
`DeleteGameRequest`, ni con un `Response` del tipo equivocado:

```swift
let mock = MockAPIService()
mock.stub(GetGamesRequest.self, returning: [Game(id: 1)])
mock.stub(DeleteGameRequest.self, throwing: .stub(code: .httpStatus, statusCode: 404))
```

Nada de esto viaja en el binario de producción: es un producto aparte.

> **Ojo al scheme si tienes CI.** Al existir dos productos, SPM ya no genera un scheme
> `CoreNetworking` con acción de test: el agregado es **`CoreNetworking-Package`**.
>
> ```bash
> xcodebuild test -scheme CoreNetworking-Package -destination "platform=iOS Simulator,name=iPhone 17"
> ```
>
> Un script que siga usando `-scheme CoreNetworking` falla con *"not currently configured
> for the test action"* — y falla de forma que parece un problema de la suite, no del scheme.

## Arquitectura

```
Sources/CoreNetworking/
├── APIServiceProtocol.swift        # Contrato público (typed throws)
├── APIService.swift                # Pipeline: build → interceptores → transporte → status
├── SessionDelegates.swift          # PinningSessionDelegate + UploadProgressDelegate
├── SSLPinningConfiguration.swift   # 3 estados + SPKIHasher
├── RetryPolicy.swift               # Backoff + jitter
├── APIError.swift                  # Error tipado + mapeo + Retry-After
├── BaseRequest.swift / BaseResponse.swift
├── RequestInterceptor.swift        # Protocolo + LoggingInterceptor
├── Logging.swift                   # os.Logger + redacción
└── Configuration/NetworkingConfiguration.swift

Sources/CoreNetworkingTestSupport/  # MockURLProtocol, MockAPIHelper, MockAPIService
```
