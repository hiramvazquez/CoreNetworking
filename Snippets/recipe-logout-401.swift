// Logout global: cuando el refresh del token falla, se invalida la sesión local
// y se notifica a la app — sin requests extra (el 401 original llega tal cual).
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
