import Foundation

/// The single point of test injection below `APIService`: "send an HTTP
/// request, get back a response".
///
/// `URLSessionTransport` is the production implementation (real
/// `URLSession`). `CoreNetworkingTestSupport` ships `InMemoryTransport` for
/// unit tests — no global registry, paralelizable, sequences of responses
/// (500 → 200) — and keeps `MockURLProtocol` around for the handful of tests
/// that need to go through the real URL loading system.
public protocol HTTPTransport: Sendable {
    /// Sends `request` and returns its body and HTTP response.
    ///
    /// - Parameter progress: Optional upload/download progress callbacks.
    ///   `nil` when the caller does not care.
    /// - Throws: Whatever the underlying transport produces — a `URLError`,
    ///   a `CancellationError`, `PinningFailure`, or any other `Error`. This
    ///   protocol makes no promises about the error type: `APIService` is
    ///   what maps it to `APIError`.
    func send(_ request: URLRequest, progress: TransferProgress?) async throws -> (Data, HTTPURLResponse)

    /// Sends `request` and streams its body straight to `destination`
    /// instead of holding it in memory, no matter how large the response is.
    ///
    /// - Parameters:
    ///   - destination: Where to move the downloaded file. Any existing file
    ///     at this URL is replaced. The implementation is responsible for
    ///     leaving no orphaned temporary file behind, on success OR failure.
    ///   - progress: Optional download progress callback. `onUpload` is
    ///     ignored (a download has no request body to report).
    /// - Throws: Same contract as `send`.
    func download(
        _ request: URLRequest,
        to destination: URL,
        progress: TransferProgress?
    ) async throws -> HTTPURLResponse
}

/// Upload/download progress callbacks for one `HTTPTransport.send` call.
///
/// Both callbacks report a fraction in `0...1`; a transport that cannot
/// determine total size (no `Content-Length`) may skip intermediate values
/// but should still report `1.0` once the transfer finishes.
public struct TransferProgress: Sendable {
    public let onUpload: (@Sendable (Double) -> Void)?
    public let onDownload: (@Sendable (Double) -> Void)?

    public init(
        onUpload: (@Sendable (Double) -> Void)? = nil,
        onDownload: (@Sendable (Double) -> Void)? = nil
    ) {
        self.onUpload = onUpload
        self.onDownload = onDownload
    }
}
