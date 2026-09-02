import CoreNetworking

/// Un endpoint, un tipo — la regla de `BaseRequest` (ver la documentación de
/// CoreNetworking, artículo «Requests»).
public struct GetGames: BaseRequest {
    public struct Response: Decodable, Sendable {
        public let games: [GameDTO]
    }

    public let path = "/games"
    public let method = HTTPMethod.get

    public init() {}
}

public struct CreateGame: BaseRequest {
    public struct Body: Encodable, Sendable {
        public let title: String
    }

    public struct Response: Decodable, Sendable {
        public let id: String
        public let title: String
    }

    public let path = "/games"
    public let method = HTTPMethod.post
    public let body: Body?

    public init(title: String) {
        self.body = Body(title: title)
    }
}

/// El DTO, tal como lo manda el servidor — nunca sale de este fichero sin pasar por
/// `Game.init(dto:)`.
public struct GameDTO: Decodable, Sendable {
    public let id: String
    public let title: String
}
