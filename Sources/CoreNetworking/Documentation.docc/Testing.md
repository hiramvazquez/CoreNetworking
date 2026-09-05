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

## Red real (opt-in): `LiveNetworkTests`

Los 226 tests de arriba corren contra `InMemoryTransport`/`MockURLProtocol` — dominios
falsos, sin socket real detrás. Eso es perfecto para el pipeline, pero ciego a todo lo que
vive POR DEBAJO de la costura del transporte: un handshake TLS real (el pinning nunca ha
visto un `didReceive challenge:` de verdad — `MockURLProtocol` sustituye el transporte
DESPUÉS de la fase de TLS), `Content-Encoding: gzip` real, una redirección servida por un
servidor real, un `Retry-After` que no escribimos nosotros, o un timeout contra una
respuesta genuinamente lenta.

`Tests/CoreNetworkingTests/LiveNetworkTests.swift` cierra ese hueco contra dos backends
públicos — `dummyjson.com` (el backend de referencia de AppStarter: payload real, 404 real,
y el host contra el que se mide el pinning en un handshake TLS en vivo) y `httpbin.org`
(comportamientos de transporte: redirecciones, gzip, un cuerpo en varios frames, `Retry-After`
real, 429 real, timeout real).

**Por qué está apagada por defecto.** Un backend de terceros que se cae, cambia de
comportamiento o limita por rate convertiría un suite determinista de ~0,1 s en uno
inestable — y la reacción humana a un CI inestable es dejar de mirarlo. La suite entera
lleva `@Suite(.enabled(if:))` leyendo la variable de entorno
`CORENETWORKING_LIVE_NETWORK_TESTS`: sin ella, ni siquiera se ejecuta (Swift Testing la
reporta como "skipped", no como fallo) — `swift test` a secas nunca toca la red.

**Cómo lanzarla a mano:**

```bash
CORENETWORKING_LIVE_NETWORK_TESTS=1 swift test --filter LiveNetworkTests
```

En CI corre sola, por su propio `schedule` (diario) y por `workflow_dispatch` — nunca en
push/PR. Ver el job `red-real` en `.github/workflows/ci.yml` y el doc comment del propio
fichero de test para el porqué completo, incluido por qué NO hay un servidor HTTPS local
con certificado autofirmado (la vía pública para un `SecIdentity` de servidor pasa por el
llavero, y eso puede colgar un runner headless esperando un diálogo que nadie puede
responder).

**Qué NO debe entrar aquí.** Nada que un mock ya pueda producir: la precedencia de
interceptores, el backoff de retry, la lógica pura de la configuración de pinning, el
filtrado de headers sensibles en redirecciones (`RedirectSecurityTests` ya lo prueba con
sockets loopback reales — eso YA es "real": mismo `URLSession`/CFNetwork, la única
diferencia con un host de Internet es la resolución DNS). Eso va en un test determinista,
con un mock. Si un test nuevo en `LiveNetworkTests` empieza a parecerse a uno del pipeline,
sobra ahí — muévelo.
