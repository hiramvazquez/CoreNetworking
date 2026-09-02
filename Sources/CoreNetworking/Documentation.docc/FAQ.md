# Preguntas frecuentes

## El scheme se llama `CoreNetworking-Package`, no `CoreNetworking`

Con dos productos SPM (`CoreNetworking` y `CoreNetworkingTestSupport`), SPM no genera un
scheme `CoreNetworking` con acción de test — el agregado es **`CoreNetworking-Package`**:

```bash
xcodebuild test -scheme CoreNetworking-Package -destination "platform=iOS Simulator,name=iPhone 17"
```

Un script que use `-scheme CoreNetworking` falla con *"not currently configured for the
test action"* — y falla de forma que parece un problema de la suite, no del scheme.

## ¿Qué pasa con `Retry-After`?

Un `Retry-After` del servidor (segundos, o una HTTP-date como en `RequestSummary`) manda
sobre el backoff calculado por `RetryPolicy` — pero no sobre `RetryDecision.retryAfter` de
un `RequestRetrier`, que tiene la prioridad más alta de las tres. Ver <doc:Retry>.

## ¿Por qué no existe `TransportError`?

`APIError` es un único `struct` extensible con `category` para la clasificación de alto
nivel. Un segundo tipo de error público para la misma capa duplicaba esa clasificación y
además colapsaba 401 y 403 en el mismo caso — algo que una app real necesita distinguir
(relanzar login no es lo mismo que "no tienes permiso"). Ver <doc:ErrorHandling>.

## `NetworkingConfiguration.protocolClasses` está deprecado — ¿qué uso en su lugar?

`sessionConfiguration` (una fábrica de `URLSessionConfiguration`) es la única forma
soportada de instalar un `URLProtocol` de mock hoy — ver <doc:Testing>, sección
`MockURLProtocol`. `protocolClasses` sigue funcionando (se fusiona en la sesión real) pero
son dos caminos para lo mismo, y solo uno está soportado activamente.
