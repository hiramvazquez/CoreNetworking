# Requests

`BaseRequest`, `HTTPMethod`, `Empty`, `APIServiceProtocol`, `APIService` y
`EndpointService`: un endpoint es un tipo completo.

## Overview

### `BaseRequest`

Pide (`path`, `method`, `body`, `queryItems`) y declara lo que espera de vuelta
(`Response`). Sin `Response` propio, `execute` devuelve ``Empty`` — no hace falta ningún
`typealias` de relleno para un GET sin body ni respuesta que decodificar.

<!-- snippet: requests-body-and-delete -->
```swift
import CoreNetworking

struct CreateGame: BaseRequest {
    struct Body: Encodable, Sendable { let title: String }
    struct Response: Decodable, Sendable { let id: String }

    let path = "/games"
    let method = HTTPMethod.post
    let body: Body?

    init(title: String) { self.body = Body(title: title) }
}

struct DeleteGame: BaseRequest {
    let path: String
    let method = HTTPMethod.delete
    init(id: String) { self.path = "/games/\(id)" }
}

func createAndDelete(service: any APIServiceProtocol) async throws(APIError) {
    let created = try await service.execute(CreateGame(title: "Chess"))
    _ = try await service.execute(DeleteGame(id: created.id))
}
```

Opciones por request, todas con default: `headers` (pisan a los de la configuración y al
`Accept`/`Content-Type` del paquete), `queryItems` (`[]`), `timeout` (`Duration`, 30 s),
`allowsNonIdempotentRetry` (`false` — opt-in para reintentar POST/PATCH) y
`authenticationPolicy` (``RequestAuthenticationPolicy/automatic`` — un endpoint público, el
propio refresh, o un host de terceros declaran `.none`; ver <doc:Authentication> para la
tabla completa de precedencia de headers). `Content-Type: application/json` solo se envía
cuando el request declara `body`; `Accept: application/json` siempre, salvo que `headers`
lo sobrescriba.

### `APIService` / `APIServiceProtocol`

`APIService` no crea ninguna `URLSession` por sí mismo: el `init(configuration:...)` de
conveniencia construye un `URLSessionTransport` por debajo, usando la fábrica
`sessionConfiguration` de `configuration`. El `init(configuration:transport:...)` designado
es el punto de inyección real — ver <doc:Transport>.

<!-- snippet: quickstart-service -->
```swift
import CoreNetworking
import Foundation

struct GetGames: BaseRequest {
    struct Response: Decodable, Sendable { let games: [String] }
    let path = "/games"
    let method = HTTPMethod.get
}

let configuration = NetworkingConfiguration(
    baseURL: URL(string: "https://api.miapp.com")!,
    defaultHeaders: ["X-App-Version": "1.0"]
)
let service = APIService(configuration: configuration)

func fetchGames() async {
    do {
        let games = try await service.execute(GetGames()).games
        print(games)
    } catch {
        switch error.category {
        case .offline: print("sin conexión")
        case .unauthorized: print("relanzar login")
        default: print(error.localizedDescription)
        }
    }
}

await fetchGames()
```

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
