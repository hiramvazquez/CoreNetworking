import Foundation
import os

/// Transport-level signal: the per-task delegate cancelled a server-trust
/// challenge because pinning rejected the certificate.
///
/// Foundation turns that cancellation into `URLError(.cancelled)` — the same
/// error a caller gets from cancelling the `Task` — so `URLSessionTransport`
/// catches it, checks `TaskDelegate.pinningFailed`, and throws THIS instead:
/// `APIService` maps it to `APIError(code: .untrustedServer)` without ever
/// confusing a rejected certificate with a cancelled request.
///
/// `public` so `CoreNetworkingTestSupport.InMemoryTransport` — a different
/// module, without `@testable` access — can simulate the exact failure a
/// real pinning rejection produces.
public struct PinningFailure: Error, Sendable {
    /// The host whose certificate pinning rejected.
    public let host: String

    public init(host: String) {
        self.host = host
    }
}

/// A delegate scoped to ONE `URLSessionTask`, created fresh per
/// `URLSessionTransport.send`/`download` call.
///
/// Implements only the callbacks it needs:
/// - `didReceive challenge:` — the pinning decision, at TASK level instead of
///   session level. Because it is per-task, it can remember whether **this**
///   task's challenge was the one pinning rejected, without any shared state
///   between concurrent transfers.
/// - `didSendBodyData:` / `didReceive data:` — upload and in-memory download
///   progress, both reported through `send`.
/// - `didWriteData:` / `didFinishDownloadingTo:` — the
///   `URLSessionDownloadDelegate` side of download-to-disk progress and
///   completion. Kept for the completion-handler-based download APIs and any
///   platform where they DO fire; `URLSessionTransport.download` does not
///   depend on them (see its doc comment: verified empirically that
///   `session.download(for:delegate:)`, the async convenience method, never
///   invokes either on the SDK this package targets — the temp file is moved
///   in `URLSessionTransport.download` itself, right after `await` returns).
///
/// `@unchecked Sendable` JUSTIFICADO: todo el estado mutable (`pinningFailed`,
/// los bytes recibidos, si ya se movió el fichero) vive bajo
/// `OSAllocatedUnfairLock`; `URLSession` invoca estos callbacks desde su
/// propia cola serial, nunca concurrentemente entre sí para la misma tarea.
final class TaskDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private struct State {
        var pinningFailed = false
        var bytesReceived: Int64 = 0
        var didMoveFile = false
        var fileMoveError: (any Error)?
    }

    private let pinning: SSLPinningConfiguration?
    private let progress: TransferProgress?
    /// Where to move the file `didFinishDownloadingTo` hands us, IF that
    /// callback fires (see the type doc comment). `nil` for `send` (in-memory
    /// transfers never write to disk).
    private let destination: URL?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(pinning: SSLPinningConfiguration?, progress: TransferProgress? = nil, destination: URL? = nil) {
        self.pinning = pinning
        self.progress = progress
        self.destination = destination
        super.init()
    }

    /// `true` once this task's server-trust challenge was cancelled because
    /// pinning rejected it. `URLSessionTransport` reads this AFTER the
    /// `session.data(for:)`/`download(for:)` call throws `URLError(.cancelled)`
    /// to decide whether to re-throw it as `PinningFailure`.
    var pinningFailed: Bool { state.withLock { $0.pinningFailed } }

    /// `true` once `didFinishDownloadingTo` has already moved the file to
    /// `destination` — `URLSessionTransport.download` checks this before
    /// trying to move it again itself, in case some platform DOES deliver the
    /// callback.
    var didMoveFile: Bool { state.withLock { $0.didMoveFile } }

    /// Set when moving the finished download into `destination` fails
    /// (`didFinishDownloadingTo` cannot throw). `URLSessionTransport.download`
    /// checks it after `await`ing and re-throws it as the operation's error.
    var fileMoveError: (any Error)? { state.withLock { $0.fileMoveError } }

    // MARK: - Pinning (server-trust challenge, at TASK level)

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Solo tratamos server-trust; cualquier otro challenge (Basic, NTLM,
        // certificado cliente) va al sistema.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust,
            let pinning
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 3 estados: notApplicable → validación TLS por defecto del sistema;
        // validated → credencial; failed → cancelar Y recordar que fuimos
        // NOSOTROS quienes cancelamos: sin recordarlo, `URLError(.cancelled)`
        // es indistinguible de que el llamador canceló el `Task`.
        let result = pinning.validate(serverTrust: serverTrust, host: challenge.protectionSpace.host)
        if result == .failed {
            state.withLock { $0.pinningFailed = true }
            // Solo el host (privado). JAMÁS se loguean pins ni claves.
            NetLog.pinning.error("pinning falló para \(challenge.protectionSpace.host, privacy: .private(mask: .hash))")
        }
        let credential = result == .validated ? URLCredential(trust: serverTrust) : nil
        completionHandler(result.disposition, credential)
    }

    // MARK: - Upload progress

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0, let onUpload = progress?.onUpload else { return }
        onUpload(min(1.0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }

    // MARK: - In-memory download progress (`send`, `URLSessionDataDelegate`)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let onDownload = progress?.onDownload else { return }
        let expectedLength = dataTask.response?.expectedContentLength ?? -1
        guard expectedLength > 0 else { return }
        let total = state.withLock { s -> Int64 in
            s.bytesReceived += Int64(data.count)
            return s.bytesReceived
        }
        onDownload(min(1.0, Double(total) / Double(expectedLength)))
    }

    // MARK: - Download-to-disk progress (`download`, `URLSessionDownloadDelegate`)

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0, let onDownload = progress?.onDownload else { return }
        onDownload(min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let destination else { return }
        // Si esto llega a dispararse (no lo hace con `download(for:delegate:)`
        // en el SDK verificado, ver el doc del tipo), el temporal se borra en
        // cuanto el callback vuelve: hay que moverlo AHORA, síncronamente.
        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
            state.withLock { $0.didMoveFile = true }
        } catch {
            state.withLock { $0.fileMoveError = error }
        }
    }
}
