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

@Snippet(path: "CoreNetworking/Snippets/auth-token-refresh")

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

## Topics

- ``TokenRefreshing``
- ``TokenRefresher``
- ``BearerTokenInterceptor``
- ``TokenRefreshRetrier``
