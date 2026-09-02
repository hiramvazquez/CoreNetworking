# Empezando

De cero a un request tipado ejecutándose contra un servidor real, en seis pasos.

## Overview

### 1. Instalar el paquete

```swift
// Package.swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MiApp",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MiApp", targets: ["MiApp"])],
    dependencies: [
        .package(url: "https://github.com/hiram0816/spm-pro.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "MiApp",
            dependencies: [.product(name: "CoreNetworking", package: "spm-pro")]
        ),
        .testTarget(
            name: "MiAppTests",
            dependencies: [
                "MiApp",
                .product(name: "CoreNetworkingTestSupport", package: "spm-pro")
            ]
        )
    ]
)
```

**Resultado esperado**: `swift build` resuelve el paquete y compila.

### 2. Configurar

`Sources/MiApp/Configuration.swift` — una declaración de nivel superior compila sola en un
target de biblioteca; una llamada/`await` suelto no (ver el paso 4):

```swift
import CoreNetworking
import Foundation

let configuration = NetworkingConfiguration(
    baseURL: URL(string: "https://api.miapp.com")!,
    defaultHeaders: ["X-App-Version": "1.0"]
)
```

**Resultado esperado**: compila; una `baseURL` sin scheme/host falla en construcción
(`precondition`), no en el primer request.

### 3. Declarar un request tipado

`Sources/MiApp/GetGames.swift`:

```swift
import CoreNetworking

struct GetGames: BaseRequest {
    struct Response: Decodable, Sendable { let games: [String] }
    let path = "/games"
    let method = HTTPMethod.get
}
```

**Resultado esperado**: compila. `Response` fija el tipo de retorno de `execute`; sin uno
propio, `execute` devuelve `Empty`.

### 4. Crear el servicio y ejecutar

El snippet de abajo repite `GetGames` y `configuration` de los pasos 2-3 para poder
compilar solo, como todo snippet de esta documentación — en tu proyecto ya los tienes, así
que copia solo `let service = APIService(configuration: configuration)` y la función
`fetchGames()` en un fichero nuevo, `Sources/MiApp/GamesClient.swift`; la llamada final
(`await fetchGames()`) no es una declaración, así que va al paso 6 (un test), no suelta en
el fichero de biblioteca.

@Snippet(path: "CoreNetworking/Snippets/quickstart-service")

**Resultado esperado**: contra un backend real que sirva `/games`, `fetchGames()` imprime
la lista; sin red, `error.category == .offline`.

### 5. Requests con cuerpo y sin respuesta

`Sources/MiApp/CreateAndDeleteGame.swift`:

@Snippet(path: "CoreNetworking/Snippets/requests-body-and-delete")

**Resultado esperado**: `createAndDelete` compila y encadena POST → DELETE; `DeleteGame`
no declara `Response`, así que `execute` produce `Empty` sin decodificar nada.

### 6. Testear sin red

`Tests/MiAppTests/GamesClientTests.swift`:

```swift
import Testing
import CoreNetworking
import CoreNetworkingTestSupport

@testable import MiApp

@Test func fetchesGames() async throws {
    let mock = MockAPIService()
    mock.stub(GetGames.self, returning: GetGames.Response(games: ["chess"]))

    let games = try await mock.execute(GetGames())

    #expect(games.games == ["chess"])
}
```

**Resultado esperado**: `swift test` compila y corre 1 test, en verde — sin tocar la red.
Ver <doc:Testing> para el pipeline completo (`InMemoryTransport`, `ManualClock`).

## De aquí en adelante

- Reintentos, pinning SSL, interceptores y refresh de token: <doc:Retry>, <doc:Pinning>,
  <doc:Interceptors>, <doc:Authentication>.
- Cómo se adopta desde un `Service` de la arquitectura View → ViewModel → Logic →
  Services/Stores: <doc:Architecture>.
