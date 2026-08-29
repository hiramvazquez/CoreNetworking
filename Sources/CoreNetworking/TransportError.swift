import Foundation

/// Errores de transporte en un vocabulario que cualquier dominio consumidor
/// puede propagar sin conocer HTTP.
///
/// **Sin payloads `String` a propósito** (OQ-18, iOSAppBaseline PRD 0001): un
/// consumidor que envuelva este caso en su propio error de dominio puede darlo
/// por hecho — ninguna salida de `TransportError` filtra el mensaje crudo de
/// un servidor. Por eso `APIError.custom`, que sí arrastra ese mensaje
/// (`APIMessageError.message`), se traduce aquí solo por su `statusCode`: el
/// mensaje se descarta a propósito, no se olvida.
public enum TransportError: Error, Equatable, Sendable, CaseIterable {
    case offline
    case unauthorized
    case rateLimited
    case server
    case connectionInterrupted
    case unknown

    /// Traduce un `APIError` de transporte puro.
    ///
    /// **Sin `default:` a propósito**: un caso nuevo de `APIError` debe forzar
    /// una decisión aquí, no caer en `.unknown` en silencio.
    ///
    /// `.cancelled` y `.decodingError` mapean a `.unknown`: su significado real
    /// depende de contexto que este init no tiene (si la cancelación la pidió
    /// el propio llamador, o qué forma esperaba el dominio consumidor). Esa
    /// decisión es del ADAPTER que consume este paquete, no de transporte
    /// puro — constrúyela ahí si tu dominio la necesita distinta de `.unknown`.
    public init(from error: APIError) {
        switch error {
        case .networkError(let urlError):
            self = urlError.code == .notConnectedToInternet ? .offline : .unknown

        case .httpStatus(let codigo, _), .custom(_, let codigo, _):
            self = Self.mapearEstado(codigo)

        case .certificateValidationFailed:
            self = .connectionInterrupted

        case .invalidURL, .invalidResponse, .encodingError, .unknown,
             .decodingError, .cancelled:
            self = .unknown
        }
    }

    private static func mapearEstado(_ codigo: Int) -> TransportError {
        switch codigo {
        case 401, 403: .unauthorized
        case 429: .rateLimited
        case 500...599: .server
        default: .unknown
        }
    }
}
