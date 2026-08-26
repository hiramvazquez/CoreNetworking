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
/// } catch {
///     // typed throws: `error` ya es APIError
///     switch error {
///     case .networkError(let urlError):
///         handleTransport(urlError)
///     case .httpStatus(let code, _), .custom(_, let code, _):
///         handleHTTP(code)
///     default:
///         handleOther(error)
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

    /// HTTP status code error (4xx, 5xx). `retryAfter` carries the parsed
    /// `Retry-After` header (seconds) when the server sent one.
    case httpStatus(Int, retryAfter: TimeInterval?)

    /// Custom server error with message. Preserves the HTTP status code so
    /// retryability and handling decisions stay status-driven.
    case custom(APIMessageError, statusCode: Int, retryAfter: TimeInterval?)

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
    /// Attempts to decode custom error message from server (preserving the
    /// status code), falls back to plain HTTP status. Parses `Retry-After`
    /// (delay-seconds or HTTP-date) when present.
    static func map(data: Data?, response: HTTPURLResponse) -> APIError {
        let retryAfter = parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"))

        if let data,
           let custom = try? JSONDecoder().decode(APIMessageError.self, from: data) {
            return .custom(custom, statusCode: response.statusCode, retryAfter: retryAfter)
        }

        return .httpStatus(response.statusCode, retryAfter: retryAfter)
    }

    /// Maps URLError to APIError, preserving the original error.
    static func map(_ urlError: URLError) -> APIError {
        if urlError.code == .cancelled {
            return .cancelled
        }
        return .networkError(urlError)
    }

    /// Parses a `Retry-After` header value: delay-seconds or HTTP-date (RFC 9110).
    static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        if let seconds = TimeInterval(trimmed) {
            return max(0, seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    // MARK: - Error Properties

    /// The underlying error for debugging purposes
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

    /// Whether this error is retryable.
    ///
    /// Transient transport errors and HTTP 5xx / 408 / 429 — for `.custom`
    /// the decision is driven by its preserved status code, not the message.
    public var isRetryable: Bool {
        switch self {
        case .networkError(let urlError):
            return urlError.code == .timedOut ||
                   urlError.code == .networkConnectionLost ||
                   urlError.code == .notConnectedToInternet ||
                   urlError.code == .cannotConnectToHost
        case .httpStatus(let code, _), .custom(_, let code, _):
            return code >= 500 || code == 408 || code == 429
        default:
            return false
        }
    }

    /// HTTP status code if available (also for `.custom`).
    public var statusCode: Int? {
        switch self {
        case .httpStatus(let code, _), .custom(_, let code, _):
            return code
        default:
            return nil
        }
    }

    /// Server-requested retry delay in seconds (`Retry-After`), if any.
    public var retryAfterDelay: TimeInterval? {
        switch self {
        case .httpStatus(_, let retryAfter), .custom(_, _, let retryAfter):
            return retryAfter
        default:
            return nil
        }
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
        case .httpStatus(let code, let retryAfter):
            return "APIError.httpStatus(\(code)\(retryAfter.map { ", retryAfter: \($0)s" } ?? ""))"
        case .custom(let custom, let statusCode, _):
            return "APIError.custom(status: \(statusCode), message: \(custom.message))"
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

// MARK: - Equatable

extension APIError {
    /// Equality compares CASE and STATUS (plus the server message for
    /// `.custom` and the error code for `.networkError`).
    ///
    /// `retryAfter` is deliberately ignored: it is volatile transport metadata
    /// and two failures with the same cause must compare equal regardless of
    /// what the server suggested as a wait.
    public static func == (lhs: APIError, rhs: APIError) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, .unknown):
            return true
        case (.invalidURL, .invalidURL):
            return true
        case (.invalidResponse, .invalidResponse):
            return true
        case let (.httpStatus(l, _), .httpStatus(r, _)):
            return l == r
        case let (.custom(lm, ls, _), .custom(rm, rs, _)):
            return lm == rm && ls == rs
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
