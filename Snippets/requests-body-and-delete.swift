// Un endpoint es un tipo completo: sin Response propio, execute devuelve Empty —
// no hace falta ningún typealias de relleno para un DELETE sin cuerpo.
import CoreNetworking

struct CreateGame: BaseRequest {
    struct Body: Encodable, Sendable { let title: String }
    struct Response: Decodable, Sendable { let id: String }

    let path = "/games"
    let method = HTTPMethod.post
    let body: Body?

    init(title: String) { self.body = Body(title: title) }
}

struct DeleteGame: BaseRequest {
    let path: String
    let method = HTTPMethod.delete
    init(id: String) { self.path = "/games/\(id)" }
}

func createAndDelete(service: any APIServiceProtocol) async throws(APIError) {
    let created = try await service.execute(CreateGame(title: "Chess"))
    _ = try await service.execute(DeleteGame(id: created.id))
}
