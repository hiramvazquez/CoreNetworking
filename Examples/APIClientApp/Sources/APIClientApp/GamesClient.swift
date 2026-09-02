import CoreNetworking
import Foundation

/// El único tipo que toca `APIServiceProtocol`/`BaseRequest` en este ejemplo. Devuelve
/// modelos de dominio (`Game`), nunca el DTO decodificado, y traduce `APIError` a
/// `GamesError` antes de devolverlo — el resto de la app nunca ve `APIError`.
public struct GamesClient: Sendable {
    private let api: any APIServiceProtocol

    public init(api: any APIServiceProtocol) {
        self.api = api
    }

    public func fetchGames() async throws(GamesError) -> [Game] {
        do {
            let response = try await api.execute(GetGames())
            return response.games.map(Game.init(dto:))
        } catch {
            throw GamesError(error)
        }
    }

    public func createGame(title: String) async throws(GamesError) -> Game {
        do {
            let response = try await api.execute(CreateGame(title: title))
            return Game(id: response.id, title: response.title)
        } catch {
            throw GamesError(error)
        }
    }
}

/// Construye el `APIService` de producción: retry seguro por defecto, sin pinning (un
/// consumidor real lo añade con `sslPinning:`, ver la documentación de CoreNetworking,
/// artículo «Pinning»).
public func makeGamesClient(baseURL: URL) -> GamesClient {
    let configuration = NetworkingConfiguration(baseURL: baseURL)
    let service = APIService(configuration: configuration)
    return GamesClient(api: service)
}
