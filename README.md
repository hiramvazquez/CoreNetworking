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
    switch error {
    case .networkError(let urlError): ...
    case .httpStatus(let code, _), .custom(_, let code, _): ...
    default: ...
    }
}
```

`APIError` expone `statusCode`, `isRetryable`, `retryAfterDelay`,
`underlyingError` y una `description` técnica. El copy de cara al usuario es
responsabilidad de la app consumidora.

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

## Retry

```swift
let service = APIService(
    configuration: configuration,
    retryPolicy: RetryPolicy(maxAttempts: 3, initialDelay: 0.5)
)
```

- `maxAttempts` = requests TOTALES (3 ⇒ como mucho 3 requests). `.noRetry` = 1.
- Solo métodos idempotentes reintentan por defecto; POST/PATCH requieren
  `allowsNonIdempotentRetry = true` en el request.
- Retryable: errores transitorios de transporte y HTTP 5xx / 408 / 429.
- Backoff exponencial con equal jitter; un `Retry-After` del servidor
  (segundos u HTTP-date) manda sobre el backoff.

## SSL Pinning

```swift
let pinning = SSLPinningConfiguration(
    publicKeyHashes: ["r/mIkG3eEpVdm+u/ko/cwxzOMo1bk4TyHIlByibiA5E="],
    pinnedHosts: ["api.miapp.com"]
)
let service = APIService(configuration: configuration, sslPinning: pinning)
```

Decisión de 3 estados: host sin pin → validación TLS por defecto del sistema;
pin válido → continúa; pin inválido o cadena rota → conexión cancelada.
`.disabled` equivale a "sin pinning" (el sistema valida normal; nunca acepta a
ciegas). Pin = SHA-256 del SPKI en base64 (mismo formato que TrustKit):

```bash
openssl s_client -connect api.miapp.com:443 < /dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary | base64
```

Soportado: RSA-2048/4096, EC P-256/P-384.

## Interceptores

```swift
public protocol RequestInterceptor: Sendable {
    func willSend(_ request: URLRequest) async -> URLRequest
    func didReceive(_ response: URLResponse, data: Data) async
    func didFail(_ request: URLRequest, error: Error) async
}
```

Se invocan en orden. `didFail` se notifica en TODOS los caminos de error del
pipeline (transporte, respuesta inválida, non-2xx). Los errores de
decodificación ocurren después del pipeline y no pasan por interceptores.

`LoggingInterceptor` (incluido) loguea vía `os.Logger`; los headers sensibles
(Authorization, Cookie, api keys, tokens…) se redactan SIEMPRE — no hay opción
para des-redactar. Bodies solo en DEBUG y con opt-in.

## Testing

```swift
import CoreNetworking
import CoreNetworkingTestSupport

// Mock determinista a nivel URLProtocol:
MockURLProtocol.register(MockNetworkExchange(
    url: URL(string: "https://unit.test/games")!,
    response: MockResponse(statusCode: 200, data: gamesJSON)
))

let configuration = NetworkingConfiguration(
    baseURL: URL(string: "https://unit.test")!,
    protocolClasses: [MockURLProtocol.self]
)
let service = APIService(configuration: configuration)
```

- Registro síncrono, matching por método+URL, respuestas reutilizables,
  `recordedRequests` para asertar conteos/headers, `latency` opcional para
  probar cancelación.
- **Aísla por URL, no con `removeAll()`.** El registro es estático y compartido,
  y Swift Testing paraleliza las suites por defecto: un `removeAll()` en tu test
  borra los mocks de las suites que corren a la vez y las deja en rojo por algo
  que no tiene nada que ver con lo que probaban. Pasó de verdad —cinco tests de
  cancelación ajenos— y el fallo costaba entender. Usa **un host distinto por
  test** (`https://mi-caso.test`), que es lo que de verdad aísla porque el
  matching es por URL exacta. `removeAll()` sigue existiendo para el caso en que
  controlas toda la ejecución, p. ej. bajo `@Suite(.serialized)`.
- `MockAPIService` es un stub de `APIServiceProtocol` para tests de
  consumidores (configura `result` o `error`).
- Nada de esto viaja en el binario de producción: es un producto aparte.

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
