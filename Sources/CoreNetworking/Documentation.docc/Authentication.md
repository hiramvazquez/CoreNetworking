# Autenticación y refresh de token

`TokenRefresher`, `BearerTokenInterceptor` y `TokenRefreshRetrier`: N requests con 401 a la
vez disparan exactamente un refresh.

## Overview

```swift
public actor TokenRefresher: TokenRefreshing {
    public init(refresh: @escaping @Sendable () async throws -> Void)
}

public struct BearerTokenInterceptor: RequestInterceptor {
    public init(tokenProvider: @escaping @Sendable () async -> String?)
}

public struct TokenRefreshRetrier: RequestRetrier {
    public init(refresher: any TokenRefreshing)
}
```

<!-- snippet: auth-token-refresh -->
```swift
import CoreNetworking
import Foundation

actor TokenStore {
    private(set) var token: String?
    func save(_ token: String) { self.token = token }
    func current() -> String? { token }
}

let tokenStore = TokenStore()

let refresher = TokenRefresher {
    // let newToken = try await authClient.refresh()
    await tokenStore.save("nuevo-token")
}

let configuration = NetworkingConfiguration(baseURL: URL(string: "https://api.miapp.com")!)
let service = APIService(
    configuration: configuration,
    interceptors: [BearerTokenInterceptor { await tokenStore.current() }],
    retriers: [TokenRefreshRetrier(refresher: refresher)]
)
```

`BearerTokenInterceptor` añade `Authorization: Bearer <token>` leyendo el token FRESCO en
cada `willSend` — incluido el que dispara `TokenRefreshRetrier` tras un refresh.
`TokenRefreshRetrier.retry` solo actúa en el PRIMER intento (`context.attempt == 1`) de un
401: refresca y responde `.retry` si funciona, `.doNotRetry` si el refresh falla (el 401
original llega al consumidor sin requests extra) — nunca reintenta un 401 en un intento
posterior, para no entrar en bucle si el token nuevo tampoco vale.

`TokenRefresher` es un `actor` porque N requests que reciben 401 a la vez deben disparar
EXACTAMENTE un refresh: si ya hay uno en vuelo, los demás esperan su resultado — crítico
cuando el refresh token del backend es de un solo uso.

Para el logout global cuando el refresh falla, ver <doc:Recipes>.

## Precedencia de headers

Un request pasa por dos fases antes de llegar al transporte, y cada una puede pisar lo que
puso la anterior — esto no estaba documentado en ningún sitio antes de esta versión, y es
justo lo que confunde cuando un header no sale con el valor que esperabas:

1. **`buildURLRequest`** construye el `URLRequest` base, en este orden (cada paso pisa la
   misma clave si la repite):
   1. `Accept: application/json` siempre; `Content-Type: application/json` solo si el
      request declara `body`.
   2. `NetworkingConfiguration.defaultHeaders`.
   3. `BaseRequest.headers` — lo más específico del request gana sobre la configuración
      global.
   4. **Si `request.authenticationPolicy == .none`**: se retiran, del `URLRequest` ya
      fusionado, los headers `Authorization`, `Proxy-Authorization`, `Cookie` y
      `X-Api-Key` — pero SOLO los que vinieron del paso 2 (`defaultHeaders`). Uno que el
      propio paso 3 (`BaseRequest.headers`) haya puesto sobrevive intacto — ver "Vía
      ambiental vs. vía explícita" debajo. Este paso ocurre ANTES de que corra ningún
      interceptor.
2. **Los `interceptors`**, en orden de la lista pasada a `APIService.init`, cada uno con su
   `willSend` — DESPUÉS de que el paso 1 termine, sobre el `URLRequest` ya completo. Un
   interceptor que llama `setValue(_:forHTTPHeaderField:)` pisa CUALQUIER cosa puesta en el
   paso 1 — POR DEFECTO. `BearerTokenInterceptor` es más cuidadoso: antes de tocar
   `Authorization`, distingue de dónde salió el valor que ya hay, usando `RequestContext
   .explicitHeaderFields` (ver debajo). Pisa el que llegó SOLO por `defaultHeaders` (paso
   2 — un valor estático, no una decisión de este endpoint) pero nunca el que
   `BaseRequest.headers` (paso 3) declaró explícitamente.

Hasta esta versión no existía esa distinción: `BearerTokenInterceptor` sobrescribía
`Authorization` sin condición con el token que tuviera a mano, diera igual de dónde
viniera lo que ya hubiera — el endpoint de login mandaba el token viejo, el de refresh
mandaba el token caducado que intentaba renovar, y un endpoint contra un dominio de
terceros recibía la credencial interna de la app. La sección siguiente cubre cómo se opta
por que NINGUNA credencial llegue; la distinción ambiental/explícita de este paso 2 es la
que decide, en el caso normal (`.automatic`), CUÁL de las credenciales que ya hay en la
petición sobrevive.

## Política de autenticación por request

``RequestAuthenticationPolicy`` es la ÚNICA excepción a "los interceptores ganan siempre" —
y, con `.none`, también a "el paso 4 de `buildURLRequest` corta la vía ambiental de
headers". `BearerTokenInterceptor` la consulta explícitamente para decidir si debe tocar
`Authorization`, y cualquier interceptor propio (API key, multi-tenant) puede hacer lo
mismo leyendo `RequestContext.authenticationPolicy` — no hace falta que sea el de Bearer.

- `.automatic` (default): comportamiento preexistente — un interceptor de autenticación
  PUEDE fijar su credencial y PISA cualquier `Authorization` AMBIENTAL que ya hubiera
  (`defaultHeaders` incluido — ver por qué debajo), pero nunca uno que el propio request
  haya declarado EXPLÍCITAMENTE en `headers`. Este es el caso normal: un `BaseRequest` que
  no declara nada se comporta exactamente igual que antes de que esta propiedad existiera.
- `.none`: ninguna credencial AMBIENTAL llega a este request, haya o no una disponible.

### Vía ambiental vs. vía explícita

La misma distinción gobierna las dos reglas de arriba (qué pisa el paso 2, y qué corta
`.none`):

- **Ambiental** = todo lo que se aplica a CUALQUIER request sin que este lo haya pedido:
  `NetworkingConfiguration.defaultHeaders` (una API key o un bearer fijo, puesto UNA vez al
  construir la configuración — patrón normal, y un diccionario ESTÁTICO que
  estructuralmente no puede llevar un token vivo) y lo que un interceptor de autenticación
  adjuntaría por su cuenta.
- **Explícita** = un `Authorization` (o header equivalente) que el propio `BaseRequest`
  declare en `headers` — lo escribió quien definió ESE endpoint, a propósito, normalmente
  la credencial de un partner o de un tenant distinto: el caso que justamente hace falta
  poder mandar a un host de terceros.

Bajo `.automatic`, `BearerTokenInterceptor` PISA lo ambiental y RESPETA lo explícito: si
`Authorization` solo llegó por `defaultHeaders`, el interceptor lo sustituye por la
credencial viva sin miramientos — es exactamente su trabajo, suplir lo que un valor
estático no puede (un equipo que deja un placeholder en `defaultHeaders` y añade un
`BearerTokenInterceptor` real obtiene el token vivo, no el placeholder). Si en cambio lo
declaró `BaseRequest.headers`, sobrevive intacto — bajo `.automatic` nunca se pisa, y bajo
`.none` nunca se retira (ver debajo).

`.none` corta la vía ambiental para un conjunto pequeño y exacto de nombres de header:
`Authorization`, `Proxy-Authorization`, `Cookie` y `X-Api-Key`
(`APIService.ambientCredentialHeaderNames`) — deliberadamente sin las coincidencias por
subcadena que usa `HeaderRedactor` (`token`, `secret`...) para logs: sobre-redactar un log
es gratis, pero retirar un header de un request que de verdad sale a la red es un cambio de
comportamiento real, así que aquí manda la lista más estrecha y predecible posible. La vía
explícita nunca se toca, ni bajo `.automatic` (no se pisa) ni bajo `.none` (no se retira).

El mecanismo que hace posible distinguir las dos vías es `RequestContext
.explicitHeaderFields`: el conjunto (en minúsculas) de los nombres de header que
`BaseRequest.headers` declaró para ESTE intento, calculado en `buildURLRequest` y
propagado al `RequestContext` de cada interceptor — no solo al de `BearerTokenInterceptor`,
cualquier interceptor de autenticación propio puede consultarlo para aplicar la misma
regla.

```swift
struct LoginRequest: BaseRequest {
    struct Body: Encodable, Sendable { let email: String; let password: String }
    struct Response: Decodable, Sendable { let token: String }

    let path = "/auth/login"
    let method = HTTPMethod.post
    let body: Body?
    // Sin esto, un login relanzado tras un logout mandaría el token de la
    // sesión anterior — tanto si viene de defaultHeaders (una API key fija,
    // por ejemplo) como si lo añadiera BearerTokenInterceptor.
    let authenticationPolicy = RequestAuthenticationPolicy.none
}
```

Para una credencial propia contra un host de terceros (otro esquema, otro tenant, la API
key de ese partner) basta con declararla en `headers` junto con `.none` — `.none` limpia la
credencial AMBIENTAL de `defaultHeaders` (la interna de la app) sin tocar la que este
request puso a propósito:

```swift
struct ThirdPartyRequest: BaseRequest {
    let path = "/webhook"
    let method = HTTPMethod.post
    var headers: [String: String] { ["Authorization": "ApiKey \(partnerKey)"] }
    let partnerKey: String
    // Sin esto, la API key interna en defaultHeaders (si la hay) igual
    // llegaría junto a esta — `.none` es lo que la retira.
    let authenticationPolicy = RequestAuthenticationPolicy.none
}
```

## Topics

- ``RequestAuthenticationPolicy``
- ``TokenRefreshing``
- ``TokenRefresher``
- ``BearerTokenInterceptor``
- ``TokenRefreshRetrier``
