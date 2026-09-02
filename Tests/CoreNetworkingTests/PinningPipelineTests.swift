import CoreNetworkingTestSupport
import Foundation
import Testing

@testable import CoreNetworking

/// El mapeo de extremo a extremo que arregla CN-01: un fallo de pinning tiene
/// que llegar a la app como `APIError(code: .untrustedServer)`, nunca como
/// `.cancelled`.
///
/// ## Por qué esta suite NO abre una conexión TLS real
///
/// El bug de CN-01 vive en la frontera entre `URLSession` y su delegate: al
/// cancelar un challenge de server-trust, Foundation entrega
/// `URLError(.cancelled)` — el MISMO error que produce cancelar el `Task`.
/// Reproducir eso de verdad exigiría un servidor HTTPS con un certificado que
/// el pinning rechace, algo que ni `URLProtocol` ni `MockURLProtocol` pueden
/// simular: un `URLProtocol` a medida sustituye el transporte DESPUÉS de la
/// fase de TLS, así que nunca dispara `urlSession(_:task:didReceive
/// challenge:completionHandler:)`.
///
/// En su lugar, esta suite verifica las dos piezas que juntas forman el
/// mapeo completo, cada una exactamente como la usa el código de producción:
/// 1. `URLSessionTransport.remapPinningCancellation` — la función pura que
///    `send`/`download` invocan de verdad en su `catch`, verificada aquí
///    directamente (sin reimplementarla).
/// 2. `APIService.data(for:)`/`execute`/`download(to:)` — el mapeo
///    `PinningFailure → .untrustedServer` en el pipeline, verificado
///    haciendo que `InMemoryTransport` lance EXACTAMENTE lo que
///    `URLSessionTransport` lanzaría (`PinningFailure`, vía
///    `InMemoryTransport.Outcome.pinningFailure(host:)`).
///
/// Combinado con `PinningDelegateTests` (el delegate por tarea marca
/// `pinningFailed` en la rama `.failed` del challenge, con el fixture de
/// certificado real), las tres piezas cubren la cadena completa:
/// challenge → `TaskDelegate.pinningFailed` → `URLSessionTransport` →
/// `APIService` → `APIError`.
@Suite("Pinning de extremo a extremo: CN-01, la cancelación que no es cancelación")
struct PinningPipelineTests {
    // MARK: - 1. `URLSessionTransport.remapPinningCancellation` (función pura)

    @Test("URLError(.cancelled) CON pinningFailed → PinningFailure")
    func cancelledWithPinningFailedBecomesPinningFailure() {
        let result = URLSessionTransport.remapPinningCancellation(
            URLError(.cancelled),
            pinningFailed: true,
            host: "pinning.test"
        )
        let pinningFailure = result as? PinningFailure
        #expect(pinningFailure?.host == "pinning.test")
    }

    @Test("URLError(.cancelled) SIN pinningFailed → sigue siendo .cancelled")
    func cancelledWithoutPinningFailedStaysCancelled() {
        let result = URLSessionTransport.remapPinningCancellation(
            URLError(.cancelled),
            pinningFailed: false,
            host: "pinning.test"
        )
        #expect((result as? URLError)?.code == .cancelled)
    }

    @Test("otro URLError con pinningFailed == true no se toca (solo .cancelled se reinterpreta)")
    func otherURLErrorsAreUntouchedEvenWithPinningFailed() {
        let result = URLSessionTransport.remapPinningCancellation(
            URLError(.timedOut),
            pinningFailed: true,
            host: "pinning.test"
        )
        #expect((result as? URLError)?.code == .timedOut)
    }

    @Test("un error que no es URLError pasa intacto")
    func nonURLErrorsAreUntouched() {
        struct Otro: Error {}
        let result = URLSessionTransport.remapPinningCancellation(Otro(), pinningFailed: true, host: "x")
        #expect(result is Otro)
    }

    // MARK: - 2. `APIService` — mapeo `PinningFailure` → `.untrustedServer`

    private struct Payload: Decodable, Sendable { let ok: Bool }

    private struct GetRequest: BaseRequest {
        typealias Response = Payload
        let path = "/resource"
        let method: HTTPMethod = .get
    }

    private func makeService(transport: InMemoryTransport) -> APIService {
        let configuration = NetworkingConfiguration(baseURL: URL(string: "https://unit.test")!)
        return APIService(configuration: configuration, transport: transport, retryPolicy: .noRetry)
    }

    @Test("execute: PinningFailure del transporte → code == .untrustedServer, category == .untrustedServer")
    func executeMapsPinningFailureToUntrustedServer() async throws {
        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(
                url: URL(string: "https://unit.test/resource")!,
                response: .pinningFailure(host: "unit.test")
            )
        )
        let service = makeService(transport: transport)

        do {
            let _: Payload = try await service.execute(GetRequest())
            Issue.record("debía fallar")
        } catch {
            #expect(error.code == .untrustedServer, "esperaba .untrustedServer, llegó \(error)")
            #expect(error.category == .untrustedServer)
            #expect(error.isCancellation == false, "un fallo de pinning NUNCA es una cancelación")
        }
    }

    @Test("execute: un URLError(.cancelled) normal (sin pinning) → code == .cancelled")
    func executeMapsPlainCancellationToCancelled() async throws {
        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(
                url: URL(string: "https://unit.test/resource")!,
                response: .failure(URLError(.cancelled))
            )
        )
        let service = makeService(transport: transport)

        do {
            let _: Payload = try await service.execute(GetRequest())
            Issue.record("debía fallar")
        } catch {
            #expect(error.code == .cancelled, "esperaba .cancelled, llegó \(error)")
            #expect(error.category == .cancelled)
            #expect(error.isCancellation == true)
        }
    }

    @Test("data(for:): PinningFailure del transporte → .untrustedServer")
    func dataForMapsPinningFailureToUntrustedServer() async throws {
        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(
                url: URL(string: "https://unit.test/resource")!,
                response: .pinningFailure(host: "unit.test")
            )
        )
        let service = makeService(transport: transport)

        do {
            _ = try await service.data(for: GetRequest(), progress: nil)
            Issue.record("debía fallar")
        } catch {
            #expect(error.code == .untrustedServer)
            #expect(error.category == .untrustedServer)
        }
    }

    @Test("download(to:): PinningFailure del transporte → .untrustedServer, sin fichero en destination")
    func downloadToDiskMapsPinningFailureToUntrustedServer() async throws {
        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(
                url: URL(string: "https://unit.test/resource")!,
                response: .pinningFailure(host: "unit.test")
            )
        )
        let service = makeService(transport: transport)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn04-pinning-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            try await service.download(GetRequest(), to: destination, progress: nil)
            Issue.record("debía fallar")
        } catch {
            #expect(error.code == .untrustedServer)
            #expect(error.category == .untrustedServer)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("download(to:): un URLError(.cancelled) normal (sin pinning) → .cancelled")
    func downloadToDiskMapsPlainCancellationToCancelled() async throws {
        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(
                url: URL(string: "https://unit.test/resource")!,
                response: .failure(URLError(.cancelled))
            )
        )
        let service = makeService(transport: transport)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn04-cancel-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            try await service.download(GetRequest(), to: destination, progress: nil)
            Issue.record("debía fallar")
        } catch {
            #expect(error.code == .cancelled)
            #expect(error.category == .cancelled)
        }
    }
}
