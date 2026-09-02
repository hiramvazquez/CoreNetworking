# APIClientApp

Consumidor mínimo de CoreNetworking, sin AppFoundation: la prueba de que el paquete se
adopta solo.

## Ficheros

```
Sources/APIClientApp/
├── GamesRequests.swift    GetGames/CreateGame: BaseRequest, y el DTO (GameDTO) que no sale de aquí
├── Game.swift              El modelo de dominio — lo que el resto de la app ve
├── GamesError.swift        El error de dominio de este cliente — nunca APIError fuera de GamesClient
└── GamesClient.swift       El único tipo que toca APIServiceProtocol/BaseRequest
```

`Tests/APIClientAppTests/GamesClientTests.swift`: caso feliz y de error contra
`MockAPIService`, y un test contra el pipeline real (`InMemoryTransport` + `ManualClock`)
que verifica el reintento tras un 500.

## Por qué existe

`AppFoundation/Examples/LoginApp` demuestra CoreNetworking dentro de la arquitectura
View → ViewModel → Logic → Services/Stores. Este ejemplo demuestra lo mismo sin esa
arquitectura encima — el patrón (un `Service`/cliente traduce DTOs a modelos de dominio y
`APIError` a un error propio) es el mismo, pero aquí no hay `Logic`, `ViewModel` ni
`DomainError`: solo CoreNetworking.

Ver la documentación de CoreNetworking (`Sources/CoreNetworking/Documentation.docc/`) para
la referencia completa por pieza.
