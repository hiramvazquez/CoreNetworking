import Foundation

/// The single error type of CoreNetworking. Every public API throws it
/// (typed throws), and every failure — transport, HTTP status, decoding, an
/// interceptor aborting, or something nobody anticipated — is an `APIError`.
///
/// It is a **struct**, not an enum, so it can grow without breaking anyone:
/// a new `Code` is an additive change and consumers classify with `code`,
/// `category` or `statusCode` instead of an exhaustive `switch`.
///
/// It keeps **everything**: what was asked (`request`), everything the server
/// said (`response`: status, headers and the raw body) and the error underneath
/// (`underlying`: `URLError`, `DecodingError`, `EncodingError`, the error an
/// interceptor threw, or the arbitrary `NSError` a `URLProtocol` produced).
/// Nothing is discarded on the way up.
///
/// ## Example
/// ```swift
/// do {
///     let games: [Game] = try await service.execute(request: GetGamesRequest())
/// } catch {
///     // typed throws: `error` ya es APIError
///     switch error.category {
///     case .offline: showOfflineBanner()
///     case .unauthorized: relaunchLogin()
///     case .untrustedServer: showInsecureConnection()
///     default:
///         if let problem = try? error.decodeBody(ServerProblem.self) {
///             show(problem.detail)
///         } else {
///             show(error.localizedDescription)
///         }
///     }
/// }
/// ```
public struct APIError: Error, Sendable {

    // MARK: - Code

    /// What went wrong, as an open set.
    ///
    /// Adding a new code is NOT a breaking change: consumers compare against
    /// the static members they know and fall through for the rest. Never
    /// `switch` exhaustively over codes — use `default:`.
    public struct Code: Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        /// The URL could not be built from the base URL + path (+ query).
        public static let invalidURL = Code("invalidURL")
        /// The response is not an `HTTPURLResponse`.
        public static let invalidResponse = Code("invalidResponse")
        /// The transport failed before a response arrived. `underlying` is
        /// the `URLError` (see `urlError`).
        public static let transport = Code("transport")
        /// The caller cancelled (Swift structured cancellation or
        /// `URLError.cancelled`). See `isCancellation`.
        public static let cancelled = Code("cancelled")
        /// TLS pinning rejected the server's certificate. Never confused with
        /// `cancelled`.
        public static let untrustedServer = Code("untrustedServer")
        /// The server answered with a non-2xx status. `response` is always
        /// present: status, headers and body, untouched.
        public static let httpStatus = Code("httpStatus")
        /// The request body could not be encoded. `underlying` is the
        /// `EncodingError`.
        public static let encoding = Code("encoding")
        /// The response body could not be decoded into the expected type
        /// (or `decodeBody` was asked for a body that is not there).
        /// `underlying` is the `DecodingError`; `response` keeps the body.
        public static let decoding = Code("decoding")
        /// An interceptor aborted the request. `underlying` is what it threw.
        public static let interceptor = Code("interceptor")
        /// An error nobody anticipated. `underlying` is ALWAYS present: the
        /// original error is never lost.
        public static let unexpected = Code("unexpected")
    }

    // MARK: - Summaries

    /// What was asked: method and URL. No headers (they may carry credentials).
    public struct RequestSummary: Sendable, Hashable {
        public let method: HTTPMethod
        public let url: URL?

        public init(method: HTTPMethod, url: URL?) {
            self.method = method
            self.url = url
        }

        init(_ urlRequest: URLRequest) {
            self.method = urlRequest.httpMethod.flatMap(HTTPMethod.init(rawValue:)) ?? .get
            self.url = urlRequest.url
        }
    }

    /// Everything the server said: status, headers and the raw body.
    public struct ResponseSummary: Sendable {
        public let statusCode: Int
        /// Header names normalized to lowercase. Use `header(_:)` to look one
        /// up case-insensitively.
        public let headers: [String: String]
        /// The raw body, exactly as received. Decode it with `decodeBody`.
        public let body: Data

        public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
            self.statusCode = statusCode
            self.headers = headers.reduce(into: [:]) { result, header in
                result[header.key.lowercased()] = header.value
            }
            self.body = body
        }

        public init(response: HTTPURLResponse, body: Data) {
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
                guard let name = field.key as? String else { return }
                result[name.lowercased()] = String(describing: field.value)
            }
            self.init(statusCode: response.statusCode, headers: headers, body: body)
        }

        /// Case-insensitive header lookup.
        public func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }
    }

    // MARK: - Stored

    public let code: Code
    public let request: RequestSummary?
    public let response: ResponseSummary?
    public let underlying: (any Error)?

    public init(
        code: Code,
        request: RequestSummary? = nil,
        response: ResponseSummary? = nil,
        underlying: (any Error)? = nil
    ) {
        self.code = code
        self.request = request
        self.response = response
        self.underlying = underlying
    }

    // MARK: - Derived

    /// HTTP status code, when the server answered.
    public var statusCode: Int? { response?.statusCode }

    /// Server-requested wait (`Retry-After`: delay-seconds or HTTP-date, RFC 9110).
    public var retryAfter: Duration? {
        Self.parseRetryAfter(response?.header("Retry-After"))
    }

    /// The `URLError` underneath, for `.transport` and `.cancelled`.
    public var urlError: URLError? { underlying as? URLError }

    /// `true` when the caller cancelled. Never `true` for a pinning failure
    /// (that is `.untrustedServer`).
    public var isCancellation: Bool { code == .cancelled }

    /// Whether retrying the same request may succeed.
    ///
    /// - `.transport`: only transient failures — `timedOut`,
    ///   `networkConnectionLost`, `cannotConnectToHost`, `dnsLookupFailed`,
    ///   `cannotFindHost`. **Not** `notConnectedToInternet`: without a network
    ///   there is nothing to retry in half a second (use `waitsForConnectivity`).
    /// - `.httpStatus`: 5xx, 408 and 429.
    /// - Everything else: `false`.
    public var isRetryable: Bool {
        switch code {
        case .transport:
            guard let urlError else { return false }
            return Self.transientTransportCodes.contains(urlError.code)
        case .httpStatus:
            guard let statusCode else { return false }
            return (500...599).contains(statusCode) || statusCode == 408 || statusCode == 429
        default:
            return false
        }
    }

    private static let transientTransportCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost
    ]

    // MARK: - Category

    /// Coarse classification for presentation and policy, derived from `code`,
    /// `urlError` and `statusCode`. A new `Code` lands in `.unknown` until it
    /// gets a row here, so adding codes never breaks consumers.
    ///
    /// | `code`            | detail                                                     | `category`         |
    /// |-------------------|------------------------------------------------------------|--------------------|
    /// | `.transport`      | `notConnectedToInternet`, `dataNotAllowed`, `internationalRoamingOff` | `.offline` |
    /// | `.transport`      | `timedOut`                                                 | `.timeout`         |
    /// | `.transport`      | any other `URLError` (`networkConnectionLost`, `cannotConnectToHost`, `dnsLookupFailed`, `cannotFindHost`, …) | `.unknown` |
    /// | `.httpStatus`     | 401                                                        | `.unauthorized`    |
    /// | `.httpStatus`     | 403                                                        | `.forbidden`       |
    /// | `.httpStatus`     | 404                                                        | `.notFound`        |
    /// | `.httpStatus`     | 429                                                        | `.rateLimited`     |
    /// | `.httpStatus`     | other 400…499                                              | `.client`          |
    /// | `.httpStatus`     | 500…599                                                    | `.server`          |
    /// | `.httpStatus`     | anything else                                              | `.unknown`         |
    /// | `.untrustedServer`| —                                                          | `.untrustedServer` |
    /// | `.cancelled`      | —                                                          | `.cancelled`       |
    /// | `.decoding`       | —                                                          | `.decoding`        |
    /// | anything else     | —                                                          | `.unknown`         |
    public var category: Category {
        switch code {
        case .transport:
            switch urlError?.code {
            case .notConnectedToInternet?, .dataNotAllowed?, .internationalRoamingOff?:
                return .offline
            case .timedOut?:
                return .timeout
            default:
                return .unknown
            }
        case .httpStatus:
            switch statusCode {
            case 401?: return .unauthorized
            case 403?: return .forbidden
            case 404?: return .notFound
            case 429?: return .rateLimited
            case (400...499)?: return .client
            case (500...599)?: return .server
            default: return .unknown
            }
        case .untrustedServer:
            return .untrustedServer
        case .cancelled:
            return .cancelled
        case .decoding:
            return .decoding
        default:
            return .unknown
        }
    }

    /// Coarse, closed classification of an `APIError` (see `category`).
    public enum Category: Sendable, Hashable, CaseIterable {
        case offline, timeout, unauthorized, forbidden, notFound, rateLimited, client, server,
             untrustedServer, cancelled, decoding, unknown
    }

    // MARK: - Body decoding

    /// Decodes the server's error body with the consumer's own type and decoder.
    ///
    /// Any backend envelope works — `{"message"}`, RFC 9457 problem+json,
    /// per-field validation errors — because the package never interprets the
    /// body; it only keeps it.
    ///
    /// - Throws: `APIError(code: .decoding)` when there is no body (no
    ///   `response`), or wrapping the `DecodingError` (in `underlying`) when the
    ///   body does not match `type`. `request` and `response` are carried over.
    public func decodeBody<T: Decodable>(
        _ type: T.Type,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws(APIError) -> T {
        guard let response else {
            throw APIError(code: .decoding, request: request, response: nil, underlying: nil)
        }
        do {
            return try decoder.decode(type, from: response.body)
        } catch {
            throw APIError(code: .decoding, request: request, response: response, underlying: error)
        }
    }

    // MARK: - Retry-After

    /// Parses a `Retry-After` header value: delay-seconds or HTTP-date (RFC 9110).
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> Duration? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        if let seconds = TimeInterval(trimmed) {
            return .seconds(max(0, seconds))
        }

        guard let date = parseHTTPDate(trimmed) else { return nil }
        return .seconds(max(0, date.timeIntervalSince(now)))
    }

    private static func parseHTTPDate(_ value: String) -> Date? {
        // `Date.HTTPFormatStyle` (`Date(_:strategy: .http)`) existe desde iOS 18/
        // macOS 15 en la API, pero su conformidad a `ParseStrategy` no está
        // disponible hasta iOS 26/macOS 26 (verificado contra el SDK 26.5): el
        // `#available` refleja eso, no la disponibilidad nominal del tipo.
        if #available(iOS 26, macOS 26, *) {
            return try? Date(value, strategy: .http)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

// MARK: - Duration → TimeInterval

extension Duration {
    /// Seconds as `TimeInterval`, para el cálculo de backoff de
    /// `RetryPolicy` (`TimeInterval`-based; ver CN-03/`Clock` para migrarlo).
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

// MARK: - Technical Description

extension APIError: CustomStringConvertible {
    /// Technical, non-localized, log-safe description: `code`, method, status
    /// and a summary of `underlying` (type, domain and code — never its
    /// message). Deliberately omits the URL, the body and any server text so
    /// it can be logged with `.public` privacy.
    public var description: String {
        var parts = ["code: \(code)"]
        if let request {
            parts.append("method: \(request.method.rawValue)")
        }
        if let statusCode {
            parts.append("status: \(statusCode)")
        }
        if let underlying {
            parts.append("underlying: \(Self.summarize(underlying))")
        }
        return "APIError(\(parts.joined(separator: ", ")))"
    }

    private static func summarize(_ error: any Error) -> String {
        switch error {
        case let urlError as URLError:
            return "URLError(\(urlError.code.rawValue))"
        case let decodingError as DecodingError:
            return "DecodingError.\(caseName(of: decodingError))"
        case let encodingError as EncodingError:
            return "EncodingError.\(caseName(of: encodingError))"
        case is CancellationError:
            return "CancellationError"
        default:
            let nsError = error as NSError
            return "\(nsError.domain)(\(nsError.code))"
        }
    }

    private static func caseName(of error: any Error) -> String {
        let mirror = Mirror(reflecting: error)
        return mirror.children.first?.label ?? String(describing: type(of: error))
    }
}

// MARK: - LocalizedError

extension APIError: LocalizedError {
    /// Neutral, human sentence per `category` (EN + ES, from the package's
    /// string catalog). Never a bare code like "error 9". Apps that want their
    /// own copy map on `category` and ignore this.
    public var errorDescription: String? {
        errorDescription(locale: .current)
    }

    func errorDescription(locale: Locale) -> String {
        let bundle = Bundle.module
        switch category {
        case .offline:
            return String(localized: "error.offline", defaultValue: "No internet connection.", bundle: bundle, locale: locale)
        case .timeout:
            return String(localized: "error.timeout", defaultValue: "The server did not respond in time.", bundle: bundle, locale: locale)
        case .unauthorized:
            return String(localized: "error.unauthorized", defaultValue: "Your session has expired. Please sign in again.", bundle: bundle, locale: locale)
        case .forbidden:
            return String(localized: "error.forbidden", defaultValue: "You do not have permission to do this.", bundle: bundle, locale: locale)
        case .notFound:
            return String(localized: "error.notFound", defaultValue: "The requested resource was not found.", bundle: bundle, locale: locale)
        case .rateLimited:
            return String(localized: "error.rateLimited", defaultValue: "Too many requests. Please try again later.", bundle: bundle, locale: locale)
        case .client:
            return String(localized: "error.client", defaultValue: "The request could not be processed (\(statusCode ?? 0)).", bundle: bundle, locale: locale)
        case .server:
            return String(localized: "error.server", defaultValue: "Server error (\(statusCode ?? 0)).", bundle: bundle, locale: locale)
        case .untrustedServer:
            return String(localized: "error.untrustedServer", defaultValue: "The server's identity could not be verified.", bundle: bundle, locale: locale)
        case .cancelled:
            return String(localized: "error.cancelled", defaultValue: "The operation was cancelled.", bundle: bundle, locale: locale)
        case .decoding:
            return String(localized: "error.decoding", defaultValue: "The server's response could not be read.", bundle: bundle, locale: locale)
        case .unknown:
            return String(localized: "error.unknown", defaultValue: "Something went wrong. Please try again.", bundle: bundle, locale: locale)
        }
    }
}
