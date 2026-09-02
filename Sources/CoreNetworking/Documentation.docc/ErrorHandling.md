# Errores

`APIError`: un único tipo (struct, no enum) que conserva todo — request, respuesta y el
error de debajo — y se clasifica con `category` para decidir sin castear.

## Overview

@Snippet(path: "CoreNetworking/Snippets/errors-decode-body")

- **`code`** (``APIError/Code``): qué pasó, conjunto abierto — `.invalidURL`,
  `.invalidResponse`, `.transport`, `.cancelled`, `.untrustedServer`, `.httpStatus`,
  `.encoding`, `.decoding`, `.interceptor`, `.unexpected`. Un `Code` nuevo no rompe a los
  consumidores: compáralo contra los estáticos que conoces y cae a `default`, nunca un
  `switch` exhaustivo.
- **`category`**: clasificación cerrada y de alto nivel para presentación/política —
  `.offline`, `.timeout`, `.unreachable`, `.unauthorized`, `.forbidden`, `.notFound`,
  `.rateLimited`, `.client`, `.server`, `.untrustedServer`, `.cancelled`, `.decoding`,
  `.unknown`. `.unreachable` (`networkConnectionLost`, `cannotConnectToHost`,
  `dnsLookupFailed`, `cannotFindHost`) es distinto de `.offline`
  (`notConnectedToInternet`): hay red, pero el servidor concreto no responde.
- **`decodeBody<T>(_:using:)`**: la app decodifica SU propio sobre de error con SU propio
  `JSONDecoder`. El paquete nunca interpreta el body del servidor, solo lo conserva en
  `response.body`.
- **`isCancellation`**: `true` solo para `code == .cancelled` — nunca se confunde con
  `.untrustedServer` (pinning). Ver <doc:Pinning>.
- **`isRetryable`** / **`retryAfter`**: ver <doc:Retry>.
- `errorDescription` (`LocalizedError`): frase neutra y localizable por `category` — un
  fallback técnico; el copy real de cara al usuario sigue siendo responsabilidad de la app.

### Política de evolución

`APIError` no es `Equatable` a propósito — un `==` que ignorase `underlying` (un `any
Error`) mentiría. Compara `code`, `statusCode` o `category`. Para stubear en tests:

```swift
import CoreNetworkingTestSupport

let error = APIError.stub(code: .httpStatus, statusCode: 422, body: bodyData)
```

## Topics

- ``APIError``
- ``APIError/Code``
- ``APIError/Category``
- ``APIError/RequestSummary``
- ``APIError/ResponseSummary``
