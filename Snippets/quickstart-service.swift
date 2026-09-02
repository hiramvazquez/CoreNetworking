// Configuración mínima + un request tipado + ejecutarlo. El tipo de retorno lo
// declara el propio request — no hay nada que anotar en el call site.
import CoreNetworking
import Foundation

struct GetGames: BaseRequest {
    struct Response: Decodable, Sendable { let games: [String] }
    let path = "/games"
    let method = HTTPMethod.get
}

let configuration = NetworkingConfiguration(
    baseURL: URL(string: "https://api.miapp.com")!,
    defaultHeaders: ["X-App-Version": "1.0"]
)
let service = APIService(configuration: configuration)

func fetchGames() async {
    do {
        let games = try await service.execute(GetGames()).games
        print(games)
    } catch {
        switch error.category {
        case .offline: print("sin conexión")
        case .unauthorized: print("relanzar login")
        default: print(error.localizedDescription)
        }
    }
}

await fetchGames()
