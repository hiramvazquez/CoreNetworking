import Foundation

/// Protocol for network service capable of executing API requests.
///
/// Provides type-safe async/await networking with automatic retries,
/// interceptors, SSL pinning and typed error handling: every method throws
/// `APIError` (typed throws), so callers can switch exhaustively without
/// casting.
public protocol APIServiceProtocol: Sendable {
    /// Executes a network request and returns the decoded response.
    ///
    /// - Parameter request: The request to execute
    /// - Returns: Decoded response of type `Response`
    /// - Throws: `APIError` if the request fails or the response cannot be decoded
    func execute<Request: BaseRequest, Response: Decodable>(
        request: Request
    ) async throws(APIError) -> Response

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
