# Recetas

Descarga con progreso, rotación de pin y logout global — de principio a fin.

## Descarga con progreso

`download(_:to:progress:)` escribe directo a disco, comparte pipeline con `execute`
(interceptores, retry, mapeo de errores) y limpia `destination` en cualquier camino de
error:

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

## Rotación de pin

Con un pin de respaldo ya desplegado (RFC 7469 §2.5, ver <doc:Pinning>), rotar la clave del
servidor es seguro:

1. **Antes de rotar**: confirma que la app ya tiene desplegado el pin de respaldo —
   `SSLPinningConfiguration(publicKeyHashes: [actual, respaldo], ...)` — en la versión
   mínima soportada. Sin esto, rotar deja esa versión sin poder conectar.
2. **Rota la clave del servidor** hacia la que corresponde al pin de respaldo.
3. **Publica una nueva versión de la app** con `publicKeyHashes: [respaldo, nuevoRespaldo]`
   — el pin que era "actual" desaparece; el que era "respaldo" pasa a ser el actual; se
   añade un nuevo pin de respaldo para la próxima rotación.
4. **Nunca despliegues con un solo pin.** El `precondition` de
   ``SSLPinningConfiguration`` ya lo impide en tiempo de construcción — es la señal de que
   un paso de esta lista se saltó.

## Logout global al 401

Cuando `TokenRefreshRetrier` falla (el refresh en sí devuelve un error), invalida la
sesión local y notifica a la app — sin requests extra, porque `TokenRefreshRetrier` nunca
reintenta un 401 más allá del primer intento (ver <doc:Authentication>):

<!-- snippet: recipe-logout-401 -->
```swift
import CoreNetworking
import Foundation

protocol SessionExpiring: Sendable {
    func sessionDidExpire() async
}

actor SessionStore {
    private(set) var token: String?
    private let onExpire: any SessionExpiring

    init(onExpire: any SessionExpiring) {
        self.onExpire = onExpire
    }

    func current() -> String? { token }
    func save(_ token: String) { self.token = token }

    func invalidate() async {
        token = nil
        await onExpire.sessionDidExpire()
    }
}

func makeAuthenticatedService(
    baseURL: URL,
    sessionStore: SessionStore,
    authClient: @escaping @Sendable () async throws -> String
) -> APIService {
    let refresher = TokenRefresher {
        do {
            let newToken = try await authClient()
            await sessionStore.save(newToken)
        } catch {
            await sessionStore.invalidate()
            throw error
        }
    }

    return APIService(
        configuration: NetworkingConfiguration(baseURL: baseURL),
        interceptors: [BearerTokenInterceptor { await sessionStore.current() }],
        retriers: [TokenRefreshRetrier(refresher: refresher)]
    )
}
```

La app observa `SessionExpiring` (un protocolo propio, no de este paquete — el mismo
patrón que un `*Storing`) desde su vista raíz y navega a login cuando la sesión expira; ver
la receta equivalente en la documentación de AppFoundation y
`AppFoundation/Examples/LoginApp` para el ejemplo end-to-end completo, incluida la vista.

## Tests de un Service

Ver <doc:Testing> para `MockAPIService` (caso feliz/error puntual) e `InMemoryTransport` +
`ManualClock` (pipeline real: retries, interceptores, refresh de token).
