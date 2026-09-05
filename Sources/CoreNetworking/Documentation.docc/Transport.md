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

### Suelo de seguridad de la sesión: `enforceSecurityFloor`

`init(sessionConfiguration:)` acepta cualquier fábrica de `URLSessionConfiguration` — nada
obliga a partir de `defaultSessionConfiguration()`. Si solo hace falta tocar una cosa (el
ejemplo de arriba, `timeoutIntervalForResource`), es tentador escribir
`{ URLSessionConfiguration.default }` y perder en silencio el TLS 1.2 mínimo y quedarse con
el timeout de recurso de 7 días de Foundation (ver más abajo).

`NetworkingConfiguration.enforceSecurityFloor(on:defaultResourceTimeout:)` es el suelo que no
depende de acordarse de partir del default: `defaultSessionConfiguration()` ya lo aplica, y
cualquier fábrica propia puede aplicarlo también sobre lo que construya:

```swift
sessionConfiguration: {
    let c = URLSessionConfiguration.default
    c.httpMaximumConnectionsPerHost = 8   // lo único que quería tocar este consumidor
    return NetworkingConfiguration.enforceSecurityFloor(on: c)
}
```

Dos reglas, cada una justificada por separado:

- **TLS mínimo 1.2 — solo sube, nunca baja.** Si la configuración de partida pide TLS 1.3, se
  respeta: es más seguro. Si pide TLS 1.0/1.1, o no dice nada (el default de Foundation es
  TLS 1.0), se sube a 1.2.
- **`timeoutIntervalForResource` — se rellena solo si sigue en el sentinel de "nadie lo
  tocó"** (el default de Foundation, 604 800 s = 7 días). Cualquier valor explícito, incluido
  el `120` del ejemplo de arriba, se respeta tal cual.

Deliberadamente NO toca `httpShouldSetCookies`/`httpCookieAcceptPolicy` ni
`waitsForConnectivity`: son preferencias legítimas del consumidor, no un mínimo de seguridad.
Desactivar cookies es la postura correcta para una API JSON (por eso `defaultSessionConfiguration()`
lo hace), pero hay backends que autentican con cookies de sesión — forzarlo ahí rompería la
app en vez de protegerla. `waitsForConnectivity` es UX (esperar a que vuelva la red en vez de
fallar al instante), no seguridad: ninguno de los dos pertenece a este suelo.

### Por qué `timeoutIntervalForResource` importa: el default de Foundation son 7 días

`BaseRequest.timeout` (30 s por defecto) fija `URLRequest.timeoutInterval`, que mide
INACTIVIDAD entre paquetes, no la duración total de la petición. El límite total lo pone
`timeoutIntervalForResource`, que Foundation deja en 604 800 s (7 días) hasta que alguien lo
toca — y eso combina mal con `waitsForConnectivity = true` (el default de este paquete): un
servidor que manda un byte cada 20 s mantiene la conexión viva DÍAS sin disparar nunca el
timeout de inactividad de 30 s.

`enforceSecurityFloor` (y por tanto `defaultSessionConfiguration()`) lo rellena a 60 s si
nadie lo tocó: el doble del timeout de inactividad por request, margen suficiente para una
respuesta lenta pero que sigue progresando, y muy por debajo de una fuga de recursos de días.
No es el valor correcto para todo: `URLSessionConfiguration.timeoutIntervalForResource` es un
ajuste de SESIÓN, no de request individual, así que hoy `execute` y `download`/`upload`
comparten el mismo valor dentro de la misma `URLSession`. Una descarga o subida grande es
legítimamente más larga que 60 s — súbelo explícitamente, como en el ejemplo de arriba
(`120`, o lo que necesite tu backend).

### Upload / download comparten pipeline con `execute`

Las tres usan las APIs async nativas de `URLSession` (`upload(for:from:)`, `data(for:)`,
`download(for:)`): cancelar el `Task` cancela la transferencia. Pasan por interceptores,
retry y mapeo de errores igual que `execute` — `download(_:to:)` también: cada intento
reescribe `destination` atómicamente, así que reintentar es válido (una descarga a medias
reintenta desde cero, nunca reanuda).

<!-- snippet: transport-upload-download -->
```swift
import CoreNetworking
import Foundation

struct UploadAvatar: BaseRequest {
    struct Response: Decodable, Sendable { let url: String }
    let path = "/avatar"
    let method = HTTPMethod.post
}

struct DownloadReport: BaseRequest {
    let path = "/reports/latest.pdf"
    let method = HTTPMethod.get
}

func uploadAndDownload(service: any APIServiceProtocol, avatarData: Data, destination: URL) async throws(APIError) {
    let uploaded = try await service.upload(UploadAvatar(), data: avatarData) { fraction in
        print("subida: \(fraction)")
    }
    print(uploaded.url)

    try await service.download(DownloadReport(), to: destination) { fraction in
        print("descarga: \(fraction)")
    }
}
```

El progreso solo emite fracciones intermedias si el servidor manda `Content-Length`
(siempre emite `1.0` al terminar). `download(_:to:)` deja el fichero en `to:` — sustituye
uno existente — y no queda ningún temporal huérfano si la descarga falla o se cancela a
medias.

### Redirecciones (3xx): qué viaja con la credencial

`URLSession` sigue las redirecciones automáticamente y en silencio — un 3xx no es un error,
así que ningún `catch` de este paquete (retry, interceptores, mapeo de errores) llega a
verlo pasar. Sin nada más, eso deja una pregunta sin responder: si el backend redirige a
otro dominio (o alguien consigue que lo haga), ¿el `Authorization` viaja con la petición?

Medido empíricamente (`RedirectSecurityTests`, sockets loopback reales — un `URLProtocol`
de mock JAMÁS invoca `willPerformHTTPRedirection`, comprobado aparte) en el toolchain de
referencia de este paquete: Foundation retira `Authorization`/`Proxy-Authorization` de
**toda** redirección, incluida una de mismo origen — comportamiento no documentado,
específico de CFNetwork, que no puede darse por hecho en otra versión de Darwin ni en
`swift-corelibs-foundation` (Linux). Y no toca ningún otro header: `Cookie`, `X-Api-Key`,
`X-Auth-Token` o una `Authentication` a medida cruzan a **cualquier** destino sin filtrar,
origen distinto incluido. Esa es la fuga real.

`TaskDelegate` implementa `willPerformHTTPRedirection` para responder con una política
explícita en vez de depender de ese comportamiento implícito — ``RedirectPolicy``,
configurable en `URLSessionTransport.init(redirectPolicy:)`:

- **`.followSanitizingCrossOrigin`** (default, seguro): sigue la redirección; si el destino
  cambia de origen (scheme, host o puerto), retira cualquier header con pinta de credencial
  (``RedirectPolicy/sensitiveHeaderNames``) — lo haya retirado ya Foundation o no. Si el
  destino es el MISMO origen, restaura los que Foundation haya podido retirar por su cuenta
  (`Authorization` incluido) — sin esto, una redirección legítima dentro del propio dominio
  perdería la sesión en silencio.
- **`.never`**: no sigue ninguna redirección; la respuesta 3xx (status, headers, cuerpo)
  llega al llamador como si fuera la respuesta final. Para un endpoint que nunca debería
  redirigir.
- **`.followPreservingAllHeaders`**: sigue toda redirección sin retirar nada, cruce o no de
  origen — opt-out explícito para una flota de hosts internos que comparten credencial. No
  es el default: hay que nombrarlo.

```swift
let transport = URLSessionTransport(
    pinning: pinning,
    redirectPolicy: .never   // o .followSanitizingCrossOrigin (default) / .followPreservingAllHeaders
)
```

El pinning sigue aplicándose después de una redirección a otro host sin nada adicional: es
un challenge por TAREA (`didReceive challenge:`), y el mismo `TaskDelegate` de la tarea
sigue siendo su delegate tras la redirección — el segundo host recibe su propio challenge,
evaluado contra la misma ``SSLPinningConfiguration``, sin arrastrar la decisión del primero.
Verificado en `RedirectSecurityTests`.

## Topics

- ``HTTPTransport``
- ``URLSessionTransport``
- ``TransferProgress``
- ``PinningFailure``
- ``RedirectPolicy``
