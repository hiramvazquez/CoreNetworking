# Testing

`InMemoryTransport` (camino principal), `ManualClock` (retry sin esperar de verdad),
`MockURLProtocol` (integración) y `MockAPIService` (consumidores del paquete).

## `InMemoryTransport`

Sin `URLSession`, sin `URLProtocol`, sin registro estático global: cada instancia es nueva
y la posee el test, así que no hay contaminación entre tests corriendo en paralelo ni
disciplina de "un host por test" que recordar. Soporta SECUENCIAS de respuestas (500 → 500
→ 200), lo que `MockURLProtocol` no puede hacer.

## `ManualClock`: retry sin esperar de verdad

`APIService` duerme entre reintentos a través de un `any Clock<Duration>` inyectado.
`ManualClock` es ese reloj en tests: nadie espera tiempo real, y `advance(by:)` dispara los
`sleep` pendientes a mano. `waitUntilSleeping()` no sondea ni duerme — se resuelve en el
instante en que el pipeline registra el siguiente `sleep`.

<!-- snippet: testing-inmemory-transport -->
```swift
import CoreNetworking
import CoreNetworkingTestSupport
import Foundation

struct GetGames: BaseRequest {
    struct Response: Decodable, Sendable { let games: [String] }
    let path = "/games"
    let method = HTTPMethod.get
}

func retryEventuallySucceeds() async throws {
    let transport = InMemoryTransport()
    await transport.register(
        InMemoryTransport.Exchange(
            url: URL(string: "https://unit.test/games")!,
            responses: [
                .response(status: 500),
                .response(status: 500),
                .response(status: 200, body: Data(#"{"games":["chess"]}"#.utf8))
            ]
        )
    )

    let clock = ManualClock()
    let service = APIService(
        configuration: NetworkingConfiguration(baseURL: URL(string: "https://unit.test")!),
        transport: transport,
        retryPolicy: RetryPolicy(maxAttempts: 3, initialDelay: .milliseconds(500)),
        clock: clock
    )

    let task = Task { () async throws(APIError) -> GetGames.Response in
        try await service.execute(GetGames())
    }

    // Dos reintentos antes del 200: dos backoffs que disparar a mano.
    await clock.waitUntilSleeping()
    clock.advance(by: .seconds(10))
    await clock.waitUntilSleeping()
    clock.advance(by: .seconds(10))

    let games = try await task.value
    let attempts = await transport.recorded.count
    assert(games.games == ["chess"])
    assert(attempts == 3)
}

try await retryEventuallySucceeds()
```

## `MockURLProtocol` (integración)

Para el puñado de tests que necesitan atravesar el URL loading system de verdad — merge de
headers, cookies, redirecciones, el delegate de pinning. Registro síncrono, matching por
método+URL, `responses` consumidas en orden. **Aísla por URL, no con `removeAll()`**: el
registro es estático y compartido, y Swift Testing paraleliza las suites por defecto — un
`removeAll()` en tu test borra los mocks de las suites que corren a la vez. Usa un host
distinto por test (`https://mi-caso.test`).

## `MockAPIService`

Stub de `APIServiceProtocol` para tests de CONSUMIDORES del paquete (un `Service` propio,
no `APIService` en sí). Los stubs se registran por TIPO de request:

```swift
let mock = MockAPIService()
mock.stub(GetGamesRequest.self, returning: [Game(id: 1)])
mock.stub(DeleteGameRequest.self, throwing: .stub(code: .httpStatus, statusCode: 404))
```

Un request sin stub registrado — o registrado con un tipo que no coincide — lanza
`APIError(code: .unstubbed)`, no `.invalidResponse`: nada de la respuesta era inválida,
faltaba el stub. `.unstubbed` vive en `CoreNetworkingTestSupport`, no en `CoreNetworking` —
``APIError/Code`` es un conjunto abierto pensado justo para esto.

> **Ojo al scheme si tienes CI.** Con dos productos, SPM no genera un scheme
> `CoreNetworking` con acción de test: el agregado es **`CoreNetworking-Package`**. Ver
> <doc:FAQ>.

Nada de `CoreNetworkingTestSupport` viaja en el binario de producción: es un producto
aparte.
