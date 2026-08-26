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
  probar cancelación. `MockURLProtocol.removeAll()` limpia entre tests.
- `MockAPIService` es un stub de `APIServiceProtocol` para tests de
  consumidores (configura `result` o `error`).
- Nada de esto viaja en el binario de producción: es un producto aparte.

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
