import CoreNetworking

/// El error de dominio de este cliente: lo único que un consumidor de `GamesClient` ve —
/// nunca `APIError`. Sin AppFoundation, no hay `DomainError`/`AppErrorConvertible`: el
/// mapeo es manual, pero el principio (un `Service` — aquí, `GamesClient` — traduce el
/// error de transporte antes de devolverlo) es el mismo que documenta
/// `AppFoundation/AGENTS.md`.
public enum GamesError: Error, Sendable, Equatable {
    case offline
    case notFound
    case server
    case other

    init(_ error: APIError) {
        switch error.category {
        case .offline, .unreachable: self = .offline
        case .notFound: self = .notFound
        case .server: self = .server
        default: self = .other
        }
    }
}
