import Foundation

/// Protocol for network service capable of executing API requests.
///
/// Provides type-safe async/await networking with automatic retries,
/// interceptors, SSL pinning and typed error handling: every method throws
/// `APIError` (typed throws), so callers can switch exhaustively without
/// casting.
public protocol APIServiceProtocol: Sendable {
    /// Executes `request` and returns its decoded `Response`.
    ///
    /// The response type is not inferred at the call site: it is
    /// `Request.Response`, declared by the request itself. A request that
    /// doesn't declare one gets `Empty` back (see `Empty`, `BaseRequest`).
    ///
    /// - Parameter request: The request to execute.
    /// - Returns: `request`'s declared `Response`, decoded.
    /// - Throws: `APIError` if the request fails or the response cannot be decoded.
    func execute<Request: BaseRequest>(
        _ request: Request
    ) async throws(APIError) -> Request.Response

    /// Executes `request` and decodes the response as `Type`, overriding
    /// `Request.Response`. For the odd call site that needs a different (or
    /// partial) view of the payload than the request declares.
    ///
    /// - Parameters:
    ///   - request: The request to execute.
    ///   - type: The type to decode instead of `Request.Response`.
    /// - Returns: `type`, decoded.
    /// - Throws: `APIError` if the request fails or the response cannot be decoded.
    func execute<Request: BaseRequest, Value: Decodable & Sendable>(
        _ request: Request,
        as type: Value.Type
    ) async throws(APIError) -> Value

    /// Uploads data with progress tracking.
    ///
    /// Cancelling the surrounding `Task` cancels the transfer.
    ///
    /// - Parameters:
    ///   - request: The upload request configuration
    ///   - data: Data to upload as the request body
    ///   - progress: Closure called with upload progress (0.0 to 1.0)
    /// - Returns: Decoded response of type `Response`
    /// - Throws: `APIError` if the upload fails or the response cannot be decoded
    func upload<Request: BaseRequest, Response: Decodable>(
        request: Request,
        data: Data,
        progress: (@Sendable (Double) -> Void)?
    ) async throws(APIError) -> Response

    /// Fetches `request`'s response body entirely in memory, with progress
    /// tracking as it arrives.
    ///
    /// Cancelling the surrounding `Task` cancels the transfer. For anything
    /// large enough that holding it in memory matters, use
    /// `download(_:to:progress:)` instead.
    ///
    /// - Parameters:
    ///   - request: The request to execute.
    ///   - progress: Closure called with download progress (0.0 to 1.0).
    ///     Fractional values are only reported when the server sends
    ///     Content-Length; 1.0 is always reported when the body finished.
    /// - Returns: The response body.
    /// - Throws: `APIError` if the transfer fails.
    func data<Request: BaseRequest>(
        for request: Request,
        progress: (@Sendable (Double) -> Void)?
    ) async throws(APIError) -> Data

    /// Streams `request`'s response body straight to `destination` on disk —
    /// no matter its size, it is never held in memory as `Data`.
    ///
    /// Cancelling the surrounding `Task` cancels the transfer; no file is
    /// left at `destination` if the download does not complete. Any existing
    /// file at `destination` is replaced on success.
    ///
    /// - Parameters:
    ///   - request: The request to execute.
    ///   - destination: Where to write the downloaded file.
    ///   - progress: Closure called with download progress (0.0 to 1.0).
    ///     Fractional values are only reported when the server sends
    ///     Content-Length; 1.0 is always reported when the body finished.
    /// - Throws: `APIError` if the download fails.
    func download<Request: BaseRequest>(
        _ request: Request,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws(APIError)
}
