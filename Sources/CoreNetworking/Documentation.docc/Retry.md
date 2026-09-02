# Retry

`RetryPolicy` y `RequestRetrier`: cuántas veces, cuánto esperar, y quién decide.

## Overview

@Snippet(path: "CoreNetworking/Snippets/retry-policy")

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
