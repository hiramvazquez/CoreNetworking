import Foundation

// MARK: - Pinning Session Delegate

/// Dedicated `URLSessionDelegate` that owns TLS pinning decisions.
///
/// The service's `URLSession` is created once with this delegate (never with
/// the service itself). Holding only immutable state, it stays valid for the
/// whole session lifetime.
final class PinningSessionDelegate: NSObject, URLSessionDelegate {
    private let pinning: SSLPinningConfiguration?

    init(pinning: SSLPinningConfiguration?) {
        self.pinning = pinning
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Solo tratamos server-trust; cualquier otro challenge va al sistema.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              let pinning else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Nota C1: semántica provisional de 2 estados (paridad con el código
        // anterior). El paso de pinning la sustituye por el modelo de 3 estados
        // notApplicable/validated/failed.
        if pinning.validate(serverTrust: serverTrust, forHost: challenge.protectionSpace.host) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - Upload Progress Delegate

/// Per-task delegate that reports upload progress.
///
/// It deliberately implements ONLY `didSendBodyData`, so authentication
/// challenges keep falling through to the session-level pinning delegate.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(1.0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
