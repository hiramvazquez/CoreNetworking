# CoreNetworking

Paquete que centraliza la lógica de red usando `URLSession` y soporta `async/await`.
Provee un `APIService` configurable, soporte para mocks y un manejador de errores personalizable.

**⚠️ Nota importante**: Este paquete **NO** tiene dependencias externas. La configuración de dependency injection debe hacerse desde tu aplicación.

## Características

- ✅ **Zero Dependencies**: Completamente standalone
- ✅ **Async/Await**: API moderna basada en Swift Concurrency
- ✅ **Type-Safe**: Requests y responses fuertemente tipados
- ✅ **Testeable**: MockAPIService incluido para testing
- ✅ **Configurable**: Headers, environments, error handling personalizable

## Instalación

```swift
// Package.swift
dependencies: [
    .package(path: "../CoreNetworking")
]
```

## Uso Básico

### 1. Configurar Dependency Injection en tu App

**El paquete NO incluye módulo de DI**. Debes registrar el servicio en tu aplicación:

```swift
// En tu AppDelegate o punto de entrada
import HiramCore  // o tu sistema de DI
import CoreNetworking

// Crea un módulo en tu app
struct NetworkingModule: DependencyModule {
    func register() {
        Dependency.register(
            APIService(),
            lifecycle: .singleton,
            as: APIServiceProtocol.self
        )
    }
}

// Registra el módulo
DependenciesAssembler.shared.register([
    NetworkingModule(),
    // ... otros módulos
])
```

### 2. Definir Requests y Responses

```swift
import CoreNetworking

// Define tu request
struct GameListRequest: BaseRequest {
    typealias Parameters = EmptyParameters

    let path = "/games"
    let method: HTTPMethod = .GET
    let headers: [String: String]? = nil
}

// Define tu response
struct Game: BaseResponse, Codable {
    let id: Int
    let title: String
    let description: String
}
```

### 3. Usar el API Service

```swift
import CoreNetworking
import HiramCore

class GameViewModel: ObservableObject {
    @Inject var apiService: APIServiceProtocol

    @Published var games: [Game] = []

    func loadGames() async {
        let request = GameListRequest()

        do {
            let games: [Game] = try await apiService.execute(request: request)
            self.games = games
        } catch let error as APIError {
            print("API Error: \(error)")
        } catch {
            print("Unknown error: \(error)")
        }
    }
}
```

## API Reference

### BaseRequest

Protocol que define un request HTTP:

```swift
protocol BaseRequest {
    associatedtype Parameters: Encodable

    var path: String { get }
    var method: HTTPMethod { get }
    var parameters: Parameters { get }
    var headers: [String: String]? { get }
}
```

**HTTPMethod options**: `.GET`, `.POST`, `.PUT`, `.DELETE`, `.PATCH`

### BaseResponse

Protocol para responses (debe conformar `Decodable`):

```swift
protocol BaseResponse: Decodable {}
```

### APIServiceProtocol

```swift
protocol APIServiceProtocol {
    func execute<R: BaseRequest, E: BaseResponse>(
        request: R
    ) async throws -> E where R: Sendable, E: Sendable
}
```

### APIError

Errores manejados por el servicio:

```swift
enum APIError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case statusCode(Int)
    case decodingError
    case unknown
}
```

## Testing

### Usar MockAPIService

```swift
import XCTest
import CoreNetworking
@testable import MiApp

class GameViewModelTests: XCTestCase {
    func testLoadGames() async {
        // Configurar mock
        let mock = MockAPIService()
        let mockGames = [
            Game(id: 1, title: "Test Game", description: "Test")
        ]
        mock.result = mockGames

        // Inyectar mock
        Dependency.register(mock, lifecycle: .singleton, as: APIServiceProtocol.self)

        // Test
        let viewModel = GameViewModel()
        await viewModel.loadGames()

        XCTAssertEqual(viewModel.games.count, 1)
        XCTAssertEqual(viewModel.games.first?.title, "Test Game")
    }

    func testLoadGamesError() async {
        // Forzar error
        let mock = MockAPIService()
        mock.error = .invalidResponse

        Dependency.register(mock, lifecycle: .singleton, as: APIServiceProtocol.self)

        // Verificar manejo de error
        // ...
    }
}
```

## Configuración Avanzada

### Custom Headers

```swift
struct AuthenticatedRequest: BaseRequest {
    typealias Parameters = EmptyParameters

    let path = "/profile"
    let method: HTTPMethod = .GET

    var headers: [String: String]? {
        return [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
    }

    private let token: String

    init(token: String) {
        self.token = token
    }
}
```

### Request con Parámetros POST

```swift
struct CreateGameRequest: BaseRequest {
    struct Parameters: Encodable {
        let title: String
        let description: String
        let genre: String
    }

    let path = "/games"
    let method: HTTPMethod = .POST
    let parameters: Parameters

    init(title: String, description: String, genre: String) {
        self.parameters = Parameters(
            title: title,
            description: description,
            genre: genre
        )
    }
}
```

### Environments

```swift
// Configura el environment (desarrollo, staging, producción)
APIEnvironment.current = .development

// O configura una URL base personalizada
NetworkingConfig.shared.baseURL = "https://api.custom.com"
```

## Arquitectura

El paquete sigue una arquitectura limpia:

```
CoreNetworking/
├── APIService.swift          # Implementación principal
├── APIServiceProtocol.swift  # Protocol para DI
├── BaseRequest.swift         # Protocol para requests
├── BaseResponse.swift        # Protocol para responses
├── APIError.swift            # Error types
├── APIEnvironment.swift      # Environment configuration
├── NetworkingConfig.swift    # Global config
└── Mocks/
    ├── MockAPIService.swift  # Mock para testing
    ├── MockAPIHelper.swift   # Helper utilities
    └── MockURLProtocol.swift # URL protocol mock
```

## Filosofía del Paquete

### ¿Por qué NO incluye DI?

Para mantener el paquete:
- **Independiente**: No fuerza un sistema de DI específico
- **Reutilizable**: Puede usarse con cualquier framework de DI (Swinject, Factory, HiramCore, etc.)
- **Testeable**: Fácil de testear sin dependencias externas
- **Flexible**: El consumidor decide cómo registrar las dependencias

### Ventajas de esta Arquitectura

1. **Zero Dependencies**: El paquete no depende de ningún otro paquete
2. **Plug & Play**: Funciona con cualquier sistema de DI
3. **Menor Acoplamiento**: No hay dependencias circulares
4. **Más Testeable**: Puedes testear el paquete aisladamente
5. **Mejor Mantenibilidad**: Cambios en DI no afectan networking

## Migración desde Versión Anterior

Si usabas la versión anterior con `NetworkingModule` incluido:

### Antes (con dependencia de HiramDI)
```swift
import CoreNetworking

// El módulo venía con el paquete
DependenciesAssembler.shared.register([
    NetworkingModule()  // ❌ Ya no existe aquí
])
```

### Después (sin dependencias)
```swift
import HiramCore
import CoreNetworking

// Crea el módulo en tu app
struct NetworkingModule: DependencyModule {
    func register() {
        Dependency.register(
            APIService(),
            lifecycle: .singleton,
            as: APIServiceProtocol.self
        )
    }
}

// Registra desde tu app
DependenciesAssembler.shared.register([
    NetworkingModule()  // ✅ Ahora vive en tu app
])
```

## Requisitos

- iOS 16.0+
- Swift 5.9+
- Xcode 15.0+

## Contribuciones

Las contribuciones son bienvenidas. Por favor:
1. Asegúrate de que el paquete siga sin dependencias externas
2. Añade tests para nuevas funcionalidades
3. Mantén la API simple y type-safe

## License

MIT License


## Using with AppFoundation

If your project also uses `AppFoundation`, register `APIService` in the DI container and inject it in ViewModels.
