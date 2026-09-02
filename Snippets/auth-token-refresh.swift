// Bearer token con refresh-on-401: TokenRefresher deduplica N refreshes
// concurrentes en uno solo; BearerTokenInterceptor lee el token fresco en
// cada intento, incluido el que dispara el refresh.
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
