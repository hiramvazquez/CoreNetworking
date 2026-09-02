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

    /// Downloads data with progress tracking.
    ///
    /// Cancelling the surrounding `Task` cancels the transfer.
    ///
    /// - Parameters:
    ///   - request: The download request configuration
    ///   - progress: Closure called with download progress (0.0 to 1.0).
    ///     Fractional values are only reported when the server sends
    ///     Content-Length; 1.0 is always reported when the body finished.
    /// - Returns: Downloaded data
    /// - Throws: `APIError` if the download fails
    func download<Request: BaseRequest>(
        request: Request,
        progress: (@Sendable (Double) -> Void)?
    ) async throws(APIError) -> Data
}
