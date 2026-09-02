# Retry

`RetryPolicy` y `RequestRetrier`: cuántas veces, cuánto esperar, y quién decide.

## Overview

<!-- snippet: retry-policy -->
```swift
import CoreNetworking
import Foundation

let configuration = NetworkingConfiguration(baseURL: URL(string: "https://api.miapp.com")!)

let policy = RetryPolicy(
    maxAttempts: 3,
    initialDelay: .milliseconds(500),
    shouldRetry: { error, _ in
        // No reintentar nunca un error propio del interceptor.
        error.isRetryable && error.code != .interceptor
    }
)

let service = APIService(configuration: configuration, retryPolicy: policy)
```

- `maxAttempts` cuenta requests TOTALES (3 ⇒ como mucho 3 requests); `.noRetry` = 1.
- Solo métodos idempotentes reintentan por defecto; POST/PATCH requieren
  `allowsNonIdempotentRetry = true` en el request.
- Retryable por defecto (``APIError/isRetryable``): errores transitorios de transporte
  (`timedOut`, `networkConnectionLost`, `cannotConnectToHost`, `dnsLookupFailed`,
  `cannotFindHost` — **no** `notConnectedToInternet`) y HTTP 5xx / 408 / 429.
- Backoff exponencial con equal jitter, en `Duration`. Un `Retry-After` del servidor
  (segundos u HTTP-date) manda sobre el backoff calculado.
- El sleep entre reintentos pasa por un `any Clock<Duration>` inyectado
  (`APIService.init(clock:)`, `ContinuousClock()` por defecto) — nunca `Task.sleep`
  directo. Ver <doc:Testing> para `ManualClock`.

## Reintento por interceptor: `RequestRetrier`

```swift
public enum RetryDecision: Sendable, Equatable {
    case doNotRetry
    case retry
    case retryAfter(Duration)   // manda sobre RetryPolicy Y sobre Retry-After
}

public protocol RequestRetrier: Sendable {
    func retry(_ error: APIError, context: RequestContext) async -> RetryDecision
}
```

`APIService.init(retriers:)` recibe una lista, consultada ANTES que `RetryPolicy` en cada
intento fallido: el primero que NO devuelva `.doNotRetry` decide; si todos devuelven
`.doNotRetry` (o la lista está vacía), decide `RetryPolicy`. `RetryPolicy.maxAttempts`
acota ambos caminos. Una decisión `.retry`/`.retryAfter` hace que el MISMO request vuelva a
pasar por `willSend` — el caso de uso principal es <doc:Authentication>.

## Topics

- ``RetryPolicy``
- ``RequestRetrier``
- ``RetryDecision``
