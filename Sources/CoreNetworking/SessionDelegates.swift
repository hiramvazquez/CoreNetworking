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

        // 3 estados: notApplicable → validación TLS por defecto del sistema;
        // validated → credencial; failed → cancelar. Nunca useCredential a ciegas.
        let result = pinning.validate(serverTrust: serverTrust, host: challenge.protectionSpace.host)
        let credential = result == .validated ? URLCredential(trust: serverTrust) : nil
        completionHandler(result.disposition, credential)
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
