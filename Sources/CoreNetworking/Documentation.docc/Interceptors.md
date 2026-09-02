# Interceptores

`RequestInterceptor` y `RequestContext`: observan y pueden abortar cada intento, con la
misma identidad de request fluyendo por las tres llamadas.

## Overview

```swift
public struct RequestContext: Sendable {
    public let id: UUID
    public let request: URLRequest
    public let attempt: Int          // 1-based: el primer intento es 1
    public let startedAt: ContinuousClock.Instant
}

public protocol RequestInterceptor: Sendable {
    func willSend(_ request: URLRequest, context: RequestContext) async throws(APIError) -> URLRequest
    func didReceive(_ response: HTTPURLResponse, data: Data, context: RequestContext) async
    func didFail(_ error: APIError, context: RequestContext) async
}
```

Se invocan en orden por intento: `willSend` (todos) → transporte → `didReceive` →
validación de status → en error: `didFail`. El MISMO `RequestContext` (mismo `id`) fluye a
través de las tres llamadas de un intento; un reintento crea uno nuevo (`attempt`
incrementado, `id` distinto) — así se correlacionan logs sin confundir requests
concurrentes a la misma URL.

<!-- snippet: interceptors-logging -->
```swift
import CoreNetworking
import Foundation

struct RequestIDInterceptor: RequestInterceptor {
    func willSend(_ request: URLRequest, context: RequestContext) async throws(APIError) -> URLRequest {
        var request = request
        request.setValue(context.id.uuidString, forHTTPHeaderField: "X-Request-ID")
        return request
    }

    func didReceive(_ response: HTTPURLResponse, data: Data, context: RequestContext) async {
        // métrica: duración = ContinuousClock.now - context.startedAt
    }

    func didFail(_ error: APIError, context: RequestContext) async {
        // métrica de fallo, correlacionada por context.id
    }
}

let configuration = NetworkingConfiguration(baseURL: URL(string: "https://api.miapp.com")!)
let service = APIService(
    configuration: configuration,
    interceptors: [RequestIDInterceptor(), LoggingInterceptor()]
)
```

`willSend` puede **abortar** el request lanzando: el transporte nunca llega a verlo,
`APIService` envuelve lo lanzado en `APIError(code: .interceptor, underlying:)`, llama a
`didFail` exactamente una vez, y ese error pasa por `retriers`/`RetryPolicy` como cualquier
otro fallo. `didReceive` recibe siempre `HTTPURLResponse` (no `URLResponse`, sin castear).

``LoggingInterceptor`` (incluido) loguea vía `os.Logger`, correlacionado por `context.id`.
Los headers sensibles (Authorization, Cookie, api keys, tokens) se redactan SIEMPRE — sin
opción para des-redactar. Bodies solo en `DEBUG` y con opt-in.

## Topics

- ``RequestInterceptor``
- ``RequestContext``
- ``LoggingInterceptor``

## Ver también

- <doc:Authentication> — el interceptor más usado: bearer token + refresh.
- <doc:Retry> — `RequestRetrier`, la otra mitad del pipeline de fallo.
