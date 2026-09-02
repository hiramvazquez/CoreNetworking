import Foundation
import os

/// Production `HTTPTransport`: one `URLSession` owned by this transport,
/// created with a dedicated delegate object for SSL pinning (never `self`).
///
/// The session's delegate is `PinningSessionDelegate` (`SessionDelegates.swift`),
/// at the SESSION level: every task on this transport shares the same pinning
/// decision. CN-04 replaces it with a delegate per task; until then this is
/// where the session — and its `deinit` — lives, not in `APIService`.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

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
        // Una sola sesión, creada aquí, con un objeto delegate propio (no self).
        // La sesión retiene a su delegate hasta que se invalida (ver deinit).
        self.session = URLSession(
            configuration: configuration,
            delegate: PinningSessionDelegate(pinning: pinning),
            delegateQueue: nil
        )
    }

    deinit {
        // La URLSession retiene fuerte a su delegate; sin esto, sesión y
        // delegate se fugan al soltar el transporte.
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: URLRequest, progress: TransferProgress?) async throws -> (Data, HTTPURLResponse) {
        // API nativa: la cancelación del Task cancela la transferencia.
        let taskDelegate = progress.map { TransferProgressDelegate(progress: $0) }
        let (data, response) = try await session.data(for: request, delegate: taskDelegate)
        // La entrega puede terminar sin haber reportado 1.0 (p. ej. sin
        // Content-Length, la única señal de "terminó" es que la llamada volvió).
        progress?.onDownload?(1.0)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }
}

/// Per-task delegate that reports upload/download progress for one
/// `URLSessionTransport.send` call.
///
/// It deliberately implements ONLY the progress callbacks, so authentication
/// challenges keep falling through to the session-level pinning delegate.
private final class TransferProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    private let progress: TransferProgress
    private let receivedBytes = OSAllocatedUnfairLock<Int64>(initialState: 0)

    init(progress: TransferProgress) {
        self.progress = progress
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0, let onUpload = progress.onUpload else { return }
        onUpload(min(1.0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let onDownload = progress.onDownload else { return }
        let expectedLength = dataTask.response?.expectedContentLength ?? -1
        guard expectedLength > 0 else { return }
        let total = receivedBytes.withLock { state -> Int64 in
            state += Int64(data.count)
            return state
        }
        onDownload(min(1.0, Double(total) / Double(expectedLength)))
    }
}
