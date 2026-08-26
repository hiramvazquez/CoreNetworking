//
//  BaseRequest.swift
//  HiramNetworking
//
//  Created by Hiram on 2025-02-17.
//

import Foundation

/// HTTP methods supported by the API
public enum HTTPMethod: String, Sendable {
    case GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS
}

/// Protocol for request parameters that can be encoded to JSON
public protocol RequestParameters: Encodable, Sendable {}

/// Empty parameters for requests that don't need a body
public struct EmptyParameters: RequestParameters {
    public init() {}
}

/// Base protocol for all API requests
///
/// Implement this protocol to define type-safe API requests:
///
/// ## Example - Simple GET Request
/// ```swift
/// struct GetGamesRequest: BaseRequest {
///     typealias Parameters = EmptyParameters
///     let path = "/api/games"
///     let method: HTTPMethod = .GET
/// }
/// ```
///
/// ## Example - POST Request with Body
/// ```swift
/// struct CreateGameRequest: BaseRequest {
///     struct Body: RequestParameters {
///         let title: String
///         let genre: String
///     }
///
///     let path = "/api/games"
///     let method: HTTPMethod = .POST
///     let parameters: Body?
///
///     init(title: String, genre: String) {
///         self.parameters = Body(title: title, genre: genre)
///     }
/// }
/// ```
///
/// ## Example - GET Request with Query Parameters
/// ```swift
/// struct SearchGamesRequest: BaseRequest {
///     typealias Parameters = EmptyParameters
///     let path = "/api/games"
///     let method: HTTPMethod = .GET
///
///     let platform: String?
///     let genre: String?
///
///     var queryItems: [URLQueryItem]? {
///         var items: [URLQueryItem] = []
///         if let platform {
///             items.append(URLQueryItem(name: "platform", value: platform))
///         }
///         if let genre {
///             items.append(URLQueryItem(name: "genre", value: genre))
///         }
///         return items.isEmpty ? nil : items
///     }
/// }
/// ```
public protocol BaseRequest: Sendable {
    /// Associated type for request body parameters
    associatedtype Parameters: RequestParameters
    
    /// API endpoint path (relative to base URL)
    ///
    /// Examples: "/api/games", "/users/123", "/auth/login"
    /// **Must start with "/"**
    var path: String { get }
    
    /// HTTP method for the request
    var method: HTTPMethod { get }
    
    /// HTTP headers specific to this request
    ///
    /// These will be merged with default headers from `NetworkingConfiguration`.
    /// Request headers take precedence over defaults.
    var headers: [String: String] { get }
    
    /// Request body parameters (for POST, PUT, PATCH)
    ///
    /// Use `EmptyParameters` for requests without a body (GET, DELETE).
    var parameters: Parameters? { get }
    
    /// Query parameters (for GET requests with URL parameters)
    ///
    /// These are automatically URL-encoded and appended to the path.
    ///
    /// ## Example
    /// ```swift
    /// var queryItems: [URLQueryItem]? {
    ///     [
    ///         URLQueryItem(name: "page", value: "1"),
    ///         URLQueryItem(name: "limit", value: "20")
    ///     ]
    /// }
    /// // Results in: /api/games?page=1&limit=20
    /// ```
    var queryItems: [URLQueryItem]? { get }
    
    /// Request timeout interval in seconds
    ///
    /// Override to customize timeout for slow endpoints.
    /// Default is 30 seconds.
    var timeoutInterval: TimeInterval { get }
}

// MARK: - Default Implementations

public extension BaseRequest {
    /// Default Content-Type header for JSON requests
    var headers: [String: String] {
        ["Content-Type": "application/json"]
    }
    
    /// Default: no body parameters
    var parameters: Parameters? {
        nil
    }
    
    /// Default: no query parameters
    var queryItems: [URLQueryItem]? {
        nil
    }
    
    /// Default timeout: 30 seconds
    var timeoutInterval: TimeInterval {
        30.0
    }
}

// MARK: - Request Validation

/// Errors that can occur during request validation
public enum RequestValidationError: Error, Sendable, CustomStringConvertible {
    case pathMustStartWithSlash(String)
    case pathContainsInvalidCharacters(String)
    case emptyPath
    case invalidQueryParameter(name: String, reason: String)
    
    public var description: String {
        switch self {
        case .pathMustStartWithSlash(let path):
            return "Path must start with '/': '\(path)'"
        case .pathContainsInvalidCharacters(let path):
            return "Path contains invalid characters: '\(path)'"
        case .emptyPath:
            return "Path cannot be empty"
        case .invalidQueryParameter(let name, let reason):
            return "Invalid query parameter '\(name)': \(reason)"
        }
    }
}

public extension BaseRequest {
    /// Validates the request and returns it if valid.
    ///
    /// Call this before executing a request to ensure it's well-formed.
    ///
    /// ## Example
    /// ```swift
    /// let request = try MyRequest().validated()
    /// let response = try await service.execute(request: request)
    /// ```
    ///
    /// - Throws: `RequestValidationError` if validation fails.
    /// - Returns: Self if validation passes.
    func validated() throws -> Self {
        // Validate path
        guard !path.isEmpty else {
            throw RequestValidationError.emptyPath
        }
        
        guard path.hasPrefix("/") else {
            throw RequestValidationError.pathMustStartWithSlash(path)
        }
        
        // Check for obviously invalid characters
        let invalidCharacters = CharacterSet(charactersIn: " \t\n\r")
        if path.unicodeScalars.contains(where: { invalidCharacters.contains($0) }) {
            throw RequestValidationError.pathContainsInvalidCharacters(path)
        }
        
        // Validate query parameters
        if let queryItems = queryItems {
            for item in queryItems {
                if item.name.isEmpty {
                    throw RequestValidationError.invalidQueryParameter(
                        name: "(empty)",
                        reason: "Query parameter name cannot be empty"
                    )
                }
            }
        }
        
        return self
    }
    
    /// Returns whether the request is valid without throwing.
    ///
    /// - Returns: `true` if the request passes validation.
    var isValid: Bool {
        (try? validated()) != nil
    }
    
    /// Validates the request in DEBUG builds only.
    ///
    /// Use this during development to catch issues early without
    /// impacting production performance.
    ///
    /// - Returns: Self (always succeeds in release builds).
    func debugValidated() -> Self {
        #if DEBUG
        do {
            return try validated()
        } catch {
            assertionFailure("Request validation failed: \(error)")
            return self
        }
        #else
        return self
        #endif
    }
}

// MARK: - Request Description

public extension BaseRequest {
    /// Human-readable description of the request for logging.
    var requestDescription: String {
        var desc = "\(method.rawValue) \(path)"
        
        if let queryItems = queryItems, !queryItems.isEmpty {
            let params = queryItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
            desc += "?\(params)"
        }
        
        return desc
    }
}
