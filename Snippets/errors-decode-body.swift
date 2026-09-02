// La app decodifica SU propio sobre de error con SU propio JSONDecoder — el
// paquete nunca interpreta el body del servidor, solo lo conserva.
import CoreNetworking

struct GetGames: BaseRequest {
    struct Response: Decodable, Sendable { let games: [String] }
    let path = "/games"
    let method = HTTPMethod.get
}

struct MyServerProblem: Decodable, Sendable {
    let detail: String
}

func fetchGames(service: any APIServiceProtocol) async -> String {
    do {
        let games = try await service.execute(GetGames())
        return "\(games.games.count) juegos"
    } catch {
        switch error.category {
        case .offline: return "sin conexión"
        case .unauthorized: return "sesión expirada"
        case .untrustedServer: return "conexión insegura"
        default:
            if let problem = try? error.decodeBody(MyServerProblem.self) {
                return problem.detail
            }
            return error.localizedDescription
        }
    }
}
