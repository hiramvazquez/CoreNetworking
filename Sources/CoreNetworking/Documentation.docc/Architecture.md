# Arquitectura

En View → ViewModel → Logic → Services/Stores, este paquete lo toca un único `Service`.

## Overview

Un **Service** declara `protocol XxxServicing: Sendable` + una implementación (`struct`
normalmente) que es la ÚNICA pieza de la app que referencia `APIServiceProtocol` y
`BaseRequest`. Si necesita más de una llamada, sigue siendo el único sitio que lo hace —
la Logic que lo usa nunca ve `APIServiceProtocol`. Conformar ``EndpointService`` da
`call(_:)` gratis (ver <doc:Requests>).

```swift
struct LoginRequest: BaseRequest {
    struct Response: Decodable, Sendable { let token: String }
    let path = "/login"
    let method = HTTPMethod.post
    let body: Body?
    struct Body: Encodable, Sendable { let email: String; let password: String }
}

struct LoginService: LoginServicing, EndpointService {
    let api: any APIServiceProtocol
    func login(email: String, password: String) async throws(APIError) -> Session {
        let response = try await call(LoginRequest(body: .init(email: email, password: password)))
        return Session(token: response.token)
    }
}
```

### Mapeo de errores

Todo lo que puede fallar es un `APIError` (typed throws) — el Service lo propaga tal cual,
nunca lo interpreta. Es la **Logic** que llama al Service quien clasifica con `category` y
lo traduce a su propio `XxxError: DomainError` (paquete AppFoundation) — el
`ErrorPresenting` de la app nunca ve un `APIError`, solo `DomainError`s. Para leer el
cuerpo de un error de servidor con tu propio envelope, `error.decodeBody(MiEnvelope.self)`
desde la Logic — este paquete nunca interpreta el body, solo lo conserva.

### Cómo testear un Service

- **Caso feliz / error puntual**: `MockAPIService` — construye el Service con el MISMO
  `init(api:)` que usa producción, pasando el mock en vez de un `APIService` real.
- **Pipeline real** (retries, interceptores, refresh de token, 401 → refresh → 200):
  `InMemoryTransport` + `ManualClock`. Ver <doc:Testing>.

Referencia completa: `AppFoundation/Examples/LoginApp` (el Service de referencia, con sus
tres niveles de test) y `AppFoundation/AGENTS.md` (capas View/ViewModel/Logic).

## Ver también

- <doc:Requests>
- <doc:Testing>
