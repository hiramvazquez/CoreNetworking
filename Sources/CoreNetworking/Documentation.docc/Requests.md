# Requests

`BaseRequest`, `HTTPMethod`, `Empty`, `APIServiceProtocol`, `APIService` y
`EndpointService`: un endpoint es un tipo completo.

## Overview

### `BaseRequest`

Pide (`path`, `method`, `body`, `queryItems`) y declara lo que espera de vuelta
(`Response`). Sin `Response` propio, `execute` devuelve ``Empty`` — no hace falta ningún
`typealias` de relleno para un GET sin body ni respuesta que decodificar.

@Snippet(path: "CoreNetworking/Snippets/requests-body-and-delete")

Opciones por request, todas con default: `headers` (pisan a los de la configuración y al
`Accept`/`Content-Type` del paquete), `queryItems` (`[]`), `timeout` (`Duration`, 30 s) y
`allowsNonIdempotentRetry` (`false` — opt-in para reintentar POST/PATCH). `Content-Type:
application/json` solo se envía cuando el request declara `body`; `Accept:
application/json` siempre, salvo que `headers` lo sobrescriba.

### `APIService` / `APIServiceProtocol`

`APIService` no crea ninguna `URLSession` por sí mismo: el `init(configuration:...)` de
conveniencia construye un `URLSessionTransport` por debajo, usando la fábrica
`sessionConfiguration` de `configuration`. El `init(configuration:transport:...)` designado
es el punto de inyección real — ver <doc:Transport>.

@Snippet(path: "CoreNetworking/Snippets/quickstart-service")

Para el caso puntual en que hace falta decodificar algo distinto de lo que el request
declara, existe la sobrecarga `execute(_:as:)`.

### `EndpointService`: la plantilla de un Service

```swift
public protocol EndpointService: Sendable { var api: any APIServiceProtocol { get } }
public extension EndpointService {
    func call<R: BaseRequest>(_ request: R) async throws(APIError) -> R.Response {
        try await api.execute(request)
    }
}
```

Plantilla cómoda para un `Service` de la arquitectura de <doc:Architecture>, no un
requisito: un `Service` que necesite más de un patrón de llamada sigue llamando
`api.execute` directamente.

```swift
struct LoginService: LoginServicing, EndpointService {
    let api: any APIServiceProtocol
    func login(email: String, password: String) async throws(APIError) -> Session {
        let response = try await call(LoginRequest(body: .init(email: email, password: password)))
        return Session(token: response.token)
    }
}
```

### Decoder, encoder y sesión

Cada backend tiene su convención de claves y de fechas; el `JSONDecoder`/`JSONEncoder` los
pones tú, como **fábricas** (`makeDecoder`/`makeEncoder`), no una instancia compartida — no
porque no sean `Sendable` (lo son), sino porque son clases MUTABLES: reconfigurarlas desde
dos peticiones concurrentes sería una carrera de datos real. `sessionConfiguration` sigue
el mismo patrón para la `URLSessionConfiguration` (`waitsForConnectivity`, cookies
desactivadas, TLS 1.2 mínimo por defecto).

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

## Topics

### Núcleo

- ``BaseRequest``
- ``HTTPMethod``
- ``Empty``
- ``APIServiceProtocol``
- ``APIService``
- ``EndpointService``
- ``NetworkingConfiguration``
