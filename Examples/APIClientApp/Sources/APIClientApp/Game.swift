/// Modelo de dominio: lo que el resto de la app ve, nunca el DTO decodificado.
public struct Game: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    init(dto: GameDTO) {
        self.id = dto.id
        self.title = dto.title
    }
}
