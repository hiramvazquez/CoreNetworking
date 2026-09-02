import Foundation
import os

/// Production `HTTPTransport`: one `URLSession` owned by this transport,
/// created WITHOUT a session-level delegate.
///
/// CN-04 moves pinning (and progress) from a single delegate shared by every
/// task on the session to `TaskDelegate`, a fresh instance per call: each
/// transfer remembers for ITSELF whether it cancelled its own challenge
/// because pinning rejected the certificate, so `URLError(.cancelled)` from a
/// pinning failure can never be confused with the caller cancelling the
/// `Task` (CN-01) — no shared state, no session-wide delegate to get that
/// wrong.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let pinning: SSLPinningConfiguration?

    /// Creates a transport with its own `URLSession`.
    ///
    /// - Parameters:
    ///   - configuration: Session configuration. Defaults to `.default`; set
    ///     `protocolClasses` on it to inject a mock `URLProtocol` for
    ///     integration tests (`MockURLProtocol`).
    ///   - pinning: SSL pinning configuration (default: none — system TLS
    ///     validation only).
    public init(
        configuration: URLSessionConfiguration = .default,
        pinning: SSLPinningConfiguration? = nil
    ) {
        self.pinning = pinning
        // `delegate: nil` a nivel de sesión: cada llamada (`send`/`download`)
        // pasa su propio `TaskDelegate` a `session.data(for:delegate:)` /
        // `session.upload(for:from:delegate:)` / `session.download(for:delegate:)`.
        self.session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
    }

    deinit {
        // La sesión ya no tiene un delegate propio que retener (ese era el
        // motivo original de este `deinit`), pero sigue reteniendo su cola
        // interna y cualquier tarea en curso hasta invalidarse: sin esto, una
        // `URLSessionTransport` descartada deja la sesión (y sus tareas) con
        // vida indefinidamente en vez de liberarse con el transporte.
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: URLRequest, progress: TransferProgress?) async throws -> (Data, HTTPURLResponse) {
        let taskDelegate = TaskDelegate(pinning: pinning, progress: progress)
        do {
            let (data, response): (Data, URLResponse)
            if let body = request.httpBody {
                // `session.upload(for:from:delegate:)`, no `httpBody` a pelo:
                // es la API pensada para cuerpos de request con progreso
                // (`didSendBodyData` es fiable con ella; con `data(for:)` +
                // `httpBody` depende de detalles internos no documentados).
                var uploadRequest = request
                uploadRequest.httpBody = nil
                (data, response) = try await session.upload(for: uploadRequest, from: body, delegate: taskDelegate)
            } else {
                (data, response) = try await session.data(for: request, delegate: taskDelegate)
            }
            // La entrega puede terminar sin haber reportado 1.0 (p. ej. sin
            // Content-Length, la única señal de "terminó" es que la llamada
            // volvió).
            progress?.onDownload?(1.0)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (data, httpResponse)
        } catch {
            throw Self.remapPinningCancellation(
                error,
                pinningFailed: taskDelegate.pinningFailed,
                host: request.url?.host
            )
        }
    }

    public func download(
        _ request: URLRequest,
        to destination: URL,
        progress: TransferProgress?
    ) async throws -> HTTPURLResponse {
        let taskDelegate = TaskDelegate(pinning: pinning, progress: progress, destination: destination)
        do {
            let (temporaryLocation, response) = try await session.download(for: request, delegate: taskDelegate)
            if let fileMoveError = taskDelegate.fileMoveError {
                throw fileMoveError
            }
            // Verificado empíricamente: `session.download(for:delegate:)` (la
            // API async de conveniencia) NUNCA invoca
            // `URLSessionDownloadDelegate.didFinishDownloadingTo` en el SDK
            // que este paquete usa — el temporal SIGUE VIVO cuando `await`
            // reanuda aquí, así que el movimiento ocurre en este punto, no en
            // el delegate. `taskDelegate.didMoveFile` cubre el caso contrario
            // (una plataforma que sí entregue el callback primero): si ya
            // movió el fichero, no se intenta mover un temporal que ya no
            // existe.
            if !taskDelegate.didMoveFile {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: temporaryLocation, to: destination)
            }
            progress?.onDownload?(1.0)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return httpResponse
        } catch {
            throw Self.remapPinningCancellation(
                error,
                pinningFailed: taskDelegate.pinningFailed,
                host: request.url?.host
            )
        }
    }

    // MARK: - Pinning ↔ cancellation mapping

    /// Whether `error` is the `URLError(.cancelled)` Foundation produces when
    /// `TaskDelegate` cancelled a server-trust challenge because pinning
    /// rejected it — and if so, replaces it with `PinningFailure`. Any other
    /// error (including a genuine `URLError(.cancelled)` from the caller
    /// cancelling the `Task`) passes through unchanged.
    ///
    /// Pulled out as an internal, pure function — rather than inlined in the
    /// `catch` above — so `PinningPipelineTests` can exercise the exact
    /// mapping `send`/`download` use without a real TLS handshake (which
    /// `URLProtocol`-based mocks cannot simulate: they bypass the transport
    /// layer where server-trust challenges happen).
    static func remapPinningCancellation(_ error: any Error, pinningFailed: Bool, host: String?) -> any Error {
        guard pinningFailed, let urlError = error as? URLError, urlError.code == .cancelled else {
            return error
        }
        return PinningFailure(host: host ?? "")
    }
}
