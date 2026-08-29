import Testing
import Foundation
@testable import CoreNetworking

/// `TransportError` traduce `APIError` al vocabulario transversal que un
/// dominio consumidor puede propagar sin conocer HTTP. Sin payloads `String`
/// a propósito (OQ-18, iOSAppBaseline PRD 0001): un consumidor apoya en esto
/// su garantía de que ningún error propagado contiene la credencial ni el
/// mensaje crudo del servidor.
@Suite("TransportError — init(from: APIError)")
struct TransportErrorTests {

    // MARK: - HTTP status → caso

    @Test("401 y 403 → unauthorized")
    func noAutorizado() {
        #expect(TransportError(from: .httpStatus(401, retryAfter: nil)) == .unauthorized)
        #expect(TransportError(from: .httpStatus(403, retryAfter: nil)) == .unauthorized)
    }

    @Test("429 → rateLimited")
    func demasiadasPeticiones() {
        #expect(TransportError(from: .httpStatus(429, retryAfter: nil)) == .rateLimited)
    }

    @Test("500...599 → server")
    func errorDelServidor() {
        #expect(TransportError(from: .httpStatus(500, retryAfter: nil)) == .server)
        #expect(TransportError(from: .httpStatus(599, retryAfter: nil)) == .server)
    }

    @Test("un código sin caso especial → unknown")
    func codigoSinMapeoEspecial() {
        #expect(TransportError(from: .httpStatus(402, retryAfter: nil)) == .unknown)
    }

    @Test(".custom sigue el mismo mapeo por código que .httpStatus")
    func customSigueElCodigo() {
        let mensaje = APIMessageError(message: "server-said-this")
        #expect(TransportError(from: .custom(mensaje, statusCode: 500, retryAfter: nil)) == .server)
    }

    // MARK: - Red

    @Test("sin conexión → offline")
    func sinConexion() {
        #expect(TransportError(from: .networkError(URLError(.notConnectedToInternet))) == .offline)
    }

    @Test("otro fallo de red → unknown")
    func otroFalloDeRed() {
        #expect(TransportError(from: .networkError(URLError(.timedOut))) == .unknown)
    }

    // MARK: - Pinning

    @Test("certificado inválido → connectionInterrupted")
    func certificadoInvalido() {
        #expect(TransportError(from: .certificateValidationFailed) == .connectionInterrupted)
    }

    // MARK: - Sin caso especial: unknown

    @Test("invalidURL, invalidResponse, encodingError, unknown → unknown")
    func sinCasoEspecial() {
        let contexto = EncodingError.Context(codingPath: [], debugDescription: "x")
        #expect(TransportError(from: .invalidURL) == .unknown)
        #expect(TransportError(from: .invalidResponse) == .unknown)
        #expect(TransportError(from: .encodingError(.invalidValue(0, contexto))) == .unknown)
        #expect(TransportError(from: .unknown) == .unknown)
    }

    /// `.cancelled` y `.decodingError` también caen en `.unknown` aquí:
    /// distinguir una cancelación propia de una ajena, o decidir qué implica
    /// un fallo de decodificación para un dominio concreto, es juicio del
    /// ADAPTER que consume este paquete — no de transporte puro. Este init no
    /// intenta adivinarlo (iOSAppBaseline lo intercepta antes de llegar aquí).
    @Test("cancelled y decodingError → unknown (el adapter decide su significado real)")
    func sinJuicioDeAdapter() {
        let contexto = DecodingError.Context(codingPath: [], debugDescription: "x")
        #expect(TransportError(from: .cancelled) == .unknown)
        #expect(TransportError(from: .decodingError(.dataCorrupted(contexto))) == .unknown)
    }

    // MARK: - CaseIterable

    @Test("los seis casos transversales, ninguno perdido")
    func casosIterables() {
        #expect(Set(TransportError.allCases) == [
            .offline, .unauthorized, .rateLimited, .server, .connectionInterrupted, .unknown,
        ])
    }

    // MARK: - S1: sin payloads String

    /// La garantía que sostiene S1 en el consumidor (iOSAppBaseline, PRD
    /// 0001): ningún caso de `TransportError` lleva un `String` asociado, así
    /// que un mensaje de servidor que llegue por `.custom` no puede
    /// sobrevivir a esta conversión. Centinela: si algún día un caso ganara
    /// un payload `String`, esta conversión seguiría "funcionando" — pero el
    /// texto interpolado del resultado ya no sería solo el nombre del caso, y
    /// este test lo cazaría.
    @Test("un mensaje de servidor no sobrevive a la conversión")
    func elMensajeDelServidorNoViaja() {
        let centinela = "sentinel-secret-4f3a9c"
        let mensaje = APIMessageError(message: centinela)

        let resultado = TransportError(from: .custom(mensaje, statusCode: 500, retryAfter: nil))

        #expect(!String(describing: resultado).contains(centinela))
    }
}
