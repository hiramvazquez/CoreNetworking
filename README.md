# CoreNetworking

Capa de red standalone sobre `URLSession`: async/await, errores tipados, retry seguro con
backoff, SSL pinning de clave pública. Sin dependencias externas.

## Requisitos

Swift 6.2+ (swift-tools 6.2) · iOS 17+ / macOS 14+.

## Instalación

```swift
// Package.swift
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
```

Para desarrollo local: `.package(path: "../CoreNetworking")`.

## Empieza aquí

La documentación completa vive en DocC (Xcode: **Product ▸ Build Documentation**, o
`CoreNetworking/Sources/CoreNetworking/Documentation.docc/`): landing, guía de 20 minutos,
un artículo por pieza (requests, errores, retry, pinning, interceptores, autenticación,
transporte), arquitectura, recetas y testing.

Seis pasos mínimos:

```swift
import CoreNetworking

// 1. Configuración
let configuration = NetworkingConfiguration(baseURL: URL(string: "https://api.miapp.com")!)

// 2. Un endpoint, un tipo
struct GetGames: BaseRequest {
    struct Response: Decodable, Sendable { let games: [String] }
    let path = "/games"
    let method = HTTPMethod.get
}

// 3. El servicio
let service = APIService(configuration: configuration)

// 4. Ejecutar — el tipo de retorno lo declara el propio request
let games = try await service.execute(GetGames()).games

// 5. Errores: un único APIError, clasificado con category
catch {
    switch error.category {
    case .offline: showOfflineBanner()
    case .unauthorized: relaunchLogin()
    default: show(error.localizedDescription)
    }
}

// 6. Testear sin red
import CoreNetworkingTestSupport
let mock = MockAPIService()
mock.stub(GetGames.self, returning: GetGames.Response(games: ["chess"]))
```

## Más

- [`AGENTS.md`](AGENTS.md) — cómo se adopta desde un `Service` de la arquitectura
  View → ViewModel → Logic → Services/Stores.
- [`Examples/APIClientApp`](Examples/APIClientApp) — un consumidor mínimo, sin
  AppFoundation.
- [`CHANGELOG.md`](CHANGELOG.md) — cambios por versión.

## Licencia

MIT — ver [LICENSE](../LICENSE) en la raíz del repositorio.
