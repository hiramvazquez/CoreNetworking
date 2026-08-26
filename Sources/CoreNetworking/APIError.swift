import Foundation

/// Represents custom error messages from the server
public struct APIMessageError: Decodable, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// Comprehensive error type for networking operations
///
/// This enum provides detailed error information while preserving
/// the underlying error context for debugging purposes.
///
/// ## Example
/// ```swift
/// do {
///     let response = try await apiService.execute(request: request)
/// } catch let error as APIError {
///     switch error {
///     case .networkError(let urlError):
///         print("Network issue: \(urlError.localizedDescription)")
///     case .decodingError(let decodingError):
///         print("JSON parsing failed: \(decodingError)")
///     case .httpStatus(let code):
///         print("Server returned: \(code)")
///     default:
///         print("Error: \(error.message)")
///     }
/// }
/// ```
public enum APIError: Error, Equatable, Sendable {
    /// Unknown or unhandled error
    case unknown

    /// The URL construction failed (invalid path or base URL)
    case invalidURL

    /// The response is not a valid HTTPURLResponse
    case invalidResponse

    /// HTTP status code error (4xx, 5xx)
    case httpStatus(Int)

    /// Custom server error with message
    case custom(APIMessageError)

    /// Network-level error (timeout, no connection, etc.)
    case networkError(URLError)

    /// JSON decoding failed
    case decodingError(DecodingError)

    /// JSON encoding failed (request body)
    case encodingError(EncodingError)

    /// SSL Certificate validation failed
    case certificateValidationFailed

    /// Request was cancelled
    case cancelled

    // MARK: - Error Mapping

    /// Maps server response data to appropriate error type
    ///
    /// Attempts to decode custom error message from server,
    /// falls back to HTTP status code if decoding fails.
    ///
    /// - Parameters:
    ///   - data: Response data from server (may contain JSON error)
    ///   - response: HTTP response with status code
    /// - Returns: Appropriate APIError case
    static func map(data: Data?, response: HTTPURLResponse) -> APIError {
        // Try to decode custom error message
        if let data = data,
           let custom = try? JSONDecoder().decode(APIMessageError.self, from: data) {
            return .custom(custom)
        }

        // Fall back to HTTP status code
        return .httpStatus(response.statusCode)
    }

    /// Maps URLError to APIError
    ///
    /// Preserves the original URLError for detailed debugging
    /// while providing a consistent error interface.
    ///
    /// - Parameter urlError: The underlying URLError
    /// - Returns: APIError.networkError wrapping the URLError
    static func map(_ urlError: URLError) -> APIError {
        if urlError.code == .cancelled {
            return .cancelled
        }
        return .networkError(urlError)
    }

    // MARK: - Error Properties

    /// The underlying error for debugging purposes
    ///
    /// Use this to access the original error details:
    /// ```swift
    /// if case .networkError(let urlError) = error {
    ///     print("Error code: \(urlError.code.rawValue)")
    ///     print("Failed URL: \(urlError.failureURLString ?? "unknown")")
    /// }
    /// ```
    public var underlyingError: Error? {
        switch self {
        case .networkError(let error):
            return error
        case .decodingError(let error):
            return error
        case .encodingError(let error):
            return error
        default:
            return nil
        }
    }

    /// Whether this error is retryable
    ///
    /// Returns true for transient network errors that might
    /// succeed on retry (timeout, connection lost, etc.)
    public var isRetryable: Bool {
        switch self {
        case .networkError(let urlError):
            return urlError.code == .timedOut ||
                   urlError.code == .networkConnectionLost ||
                   urlError.code == .notConnectedToInternet ||
                   urlError.code == .cannotConnectToHost
        case .httpStatus(let code):
            // Retry 5xx server errors and 408 Request Timeout
            return code >= 500 || code == 408
        default:
            return false
        }
    }

    /// HTTP status code if available
    public var statusCode: Int? {
        if case .httpStatus(let code) = self {
            return code
        }
        return nil
    }
}

// MARK: - Technical Description

extension APIError: CustomStringConvertible {
    /// Technical, non-localized description for logs and debugging.
    ///
    /// Deliberately NOT user-facing copy: mapping errors to user-presentable,
    /// localized messages is the consumer app's responsibility (decision del
    /// owner - la capa de presentacion vive fuera de este paquete).
    public var description: String {
        switch self {
        case .unknown:
            return "APIError.unknown"
        case .invalidURL:
            return "APIError.invalidURL"
        case .invalidResponse:
            return "APIError.invalidResponse"
        case .httpStatus(let code):
            return "APIError.httpStatus(\(code))"
        case .custom(let custom):
            return "APIError.custom(message: \(custom.message))"
        case .networkError(let urlError):
            return "APIError.networkError(code: \(urlError.code.rawValue))"
        case .decodingError(let decodingError):
            return "APIError.decodingError(\(decodingError))"
        case .encodingError(let encodingError):
            return "APIError.encodingError(\(encodingError))"
        case .certificateValidationFailed:
            return "APIError.certificateValidationFailed"
        case .cancelled:
            return "APIError.cancelled"
        }
    }
}

extension APIError {
    public static func == (lhs: APIError, rhs: APIError) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, .unknown):
            return true
        case (.invalidURL, .invalidURL):
            return true
        case (.invalidResponse, .invalidResponse):
            return true
        case let (.httpStatus(l), .httpStatus(r)):
            return l == r
        case let (.custom(l), .custom(r)):
            return l == r
        case let (.networkError(l), .networkError(r)):
            return l.code == r.code && l.failureURLString == r.failureURLString
        case (.decodingError, .decodingError):
            // DecodingError is not Equatable; treat as unequal unless you want to compare descriptions
            return false
        case (.encodingError, .encodingError):
            // EncodingError is not Equatable; treat as unequal unless you want to compare descriptions
            return false
        case (.certificateValidationFailed, .certificateValidationFailed):
            return true
        case (.cancelled, .cancelled):
            return true
        default:
            return false
        }
    }
}
