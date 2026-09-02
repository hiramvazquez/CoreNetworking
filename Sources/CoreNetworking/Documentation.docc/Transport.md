# Transporte

`HTTPTransport`, `URLSessionTransport` y `TransferProgress`: el punto de inyección bajo
`APIService`, y upload/download compartiendo el mismo pipeline que `execute`.

## Overview

`HTTPTransport` es el protocolo (`send(_:progress:) async throws -> (Data,
HTTPURLResponse)`, más `upload`/`download`) que sustituye a un registro estático de
`URLProtocol` como punto de inyección. `URLSessionTransport` es la implementación de
producción: posee la `URLSession` y su `deinit`, sin delegate propio a nivel de sesión —
cada llamada construye su propio `TaskDelegate` (ver <doc:Pinning>). En tests, el
transporte es lo que cambias para no tocar la red — `InMemoryTransport`
(`CoreNetworkingTestSupport`), ver <doc:Testing>.

```swift
let transport = URLSessionTransport(
    configuration: {
        let c = NetworkingConfiguration.defaultSessionConfiguration()
        c.timeoutIntervalForResource = 120
        return c
    }(),
    pinning: pinning   // opcional
)
let service = APIService(configuration: configuration, transport: transport)
```

### Upload / download comparten pipeline con `execute`

Las tres usan las APIs async nativas de `URLSession` (`upload(for:from:)`, `data(for:)`,
`download(for:)`): cancelar el `Task` cancela la transferencia. Pasan por interceptores,
retry y mapeo de errores igual que `execute` — `download(_:to:)` también: cada intento
reescribe `destination` atómicamente, así que reintentar es válido (una descarga a medias
reintenta desde cero, nunca reanuda).

@Snippet(path: "CoreNetworking/Snippets/transport-upload-download")

El progreso solo emite fracciones intermedias si el servidor manda `Content-Length`
(siempre emite `1.0` al terminar). `download(_:to:)` deja el fichero en `to:` — sustituye
uno existente — y no queda ningún temporal huérfano si la descarga falla o se cancela a
medias.

## Topics

- ``HTTPTransport``
- ``URLSessionTransport``
- ``TransferProgress``
- ``PinningFailure``
