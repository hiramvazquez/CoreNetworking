import Foundation

/// Production API service.
///
/// - No `URLSession` of its own: every request goes through an injected
///   `HTTPTransport` (`URLSessionTransport` by default via the convenience
///   `init`, `InMemoryTransport` in unit tests). The transport — not this
///   type — owns the session and its lifetime.
/// - Upload/download go through the same transport and pipeline as `execute`
///   (interceptors + retry + error mapping); cancelling the task cancels the
///   transfer.
/// - Retry sleeps through an injected `Clock<Duration>` (`ContinuousClock` by
///   default, `ManualClock` in tests) — no real wall-clock waits in tests.
/// - Every public method throws `APIError` (typed throws).
///
/// ## Example
/// ```swift
/// let service = APIService(
///     configuration: NetworkingConfiguration(baseURL: apiBaseURL),
///     retryPolicy: .conservative,
///     interceptors: [LoggingInterceptor()]
/// )
/// let games: [Game] = try await service.execute(request: GetGamesRequest())
/// ```
public final class APIService: APIServiceProtocol {
    private let configuration: NetworkingConfiguration
    private let transport: any HTTPTransport
    private let retryPolicy: RetryPolicy
    private let interceptors: [any RequestInterceptor]
    private let clock: any Clock<Duration>

    /// Creates an API service with an explicit transport.
    ///
    /// This is the designated init: `transport` has no default because the
    /// choice belongs to the consumer — production code picks
    /// `URLSessionTransport` (or use the `sslPinning:` convenience `init`
    /// below), tests pick `InMemoryTransport`.
    ///
    /// - Parameters:
    ///   - configuration: Immutable networking configuration (base URL,
    ///     default headers, decoder factory). Required — there is no global
    ///     fallback.
    ///   - transport: What actually sends the request. No default.
    ///   - retryPolicy: Retry configuration.
    ///   - interceptors: Request/Response interceptors (invoked in order).
    ///   - clock: Clock used to sleep between retries (default:
    ///     `ContinuousClock()`). Inject a `ManualClock` in tests to advance
    ///     backoff without waiting on the wall clock.
    public init(
        configuration: NetworkingConfiguration,
        transport: any HTTPTransport,
        retryPolicy: RetryPolicy = RetryPolicy(),
        interceptors: [any RequestInterceptor] = [],
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.interceptors = interceptors
        self.clock = clock
    }

    /// Convenience: builds a `URLSessionTransport` from `configuration` and
    /// `sslPinning` — same call shape as before `HTTPTransport` existed.
    ///
    /// - Parameter sslPinning: SSL pinning configuration (default: none —
    ///   system TLS validation only).
    public convenience init(
        configuration: NetworkingConfiguration,
        retryPolicy: RetryPolicy = RetryPolicy(),
        interceptors: [any RequestInterceptor] = [],
        sslPinning: SSLPinningConfiguration? = nil
    ) {
        let sessionConfiguration = URLSessionConfiguration.default
        if let protocolClasses = configuration.protocolClasses {
            sessionConfiguration.protocolClasses = protocolClasses
        }
        self.init(
            configuration: configuration,
            transport: URLSessionTransport(configuration: sessionConfiguration, pinning: sslPinning),
            retryPolicy: retryPolicy,
            interceptors: interceptors
        )
    }

    // MARK: - Execute

    public func execute<Request: BaseRequest, Response: Decodable>(
        request: Request
    ) async throws(APIError) -> Response {
        let (data, response, summary) = try await performWithRetry(request) { [transport] urlRequest in
            try await transport.send(urlRequest, progress: nil)
        }
        return try Self.decode(Response.self, from: data, request: summary, response: response, using: configuration.makeDecoder)
    }

    // MARK: - Upload

    public func upload<Request: BaseRequest, Response: Decodable>(
        request: Request,
        data uploadData: Data,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws(APIError) -> Response {
        let (data, response, summary) = try await performWithRetry(request) { [transport] urlRequest in
            // El body va en `httpBody`, no en un parámetro de upload aparte
            // (CN-04 lo cambia por `upload(for:from:)` con delegate). El
            // progreso, si lo hay, es el único lado (upload) de `TransferProgress`.
            var urlRequest = urlRequest
            urlRequest.httpBody = uploadData
            let transferProgress = progress.map { TransferProgress(onUpload: $0) }
            return try await transport.send(urlRequest, progress: transferProgress)
        }
        return try Self.decode(Response.self, from: data, request: summary, response: response, using: configuration.makeDecoder)
    }

    // MARK: - Download

    public func download<Request: BaseRequest>(
        request: Request,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws(APIError) -> Data {
        // Sigue en memoria (no a disco) hasta CN-04: el transporte devuelve
        // `Data` completa, con progreso reportado por el lado `onDownload` de
        // `TransferProgress` mientras llega.
        let (data, _, _) = try await performWithRetry(request) { [transport] urlRequest in
            let transferProgress = progress.map { TransferProgress(onDownload: $0) }
            return try await transport.send(urlRequest, progress: transferProgress)
        }
        return data
    }

    // MARK: - Shared Pipeline

    /// Runs one request through the shared pipeline with retry.
    ///
    /// Pipeline per attempt: build URLRequest → interceptors `willSend` →
    /// transport → interceptors `didReceive` → status validation.
    ///
    /// Retry rules:
    /// - `retryPolicy.maxAttempts` counts TOTAL requests (3 ⇒ 3 requests).
    /// - Only idempotent methods retry by default; POST/PATCH need the
    ///   request's `allowsNonIdempotentRetry` opt-in.
    /// - A server `Retry-After` takes precedence over the jittered backoff.
    private func performWithRetry<Request: BaseRequest>(
        _ request: Request,
        transport: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws(APIError) -> (data: Data, response: HTTPURLResponse, request: APIError.RequestSummary) {
        let methodAllowsRetry = request.method.isIdempotent || request.allowsNonIdempotentRetry
        var attemptsMade = 0
        while true {
            do {
                return try await performOnce(request, transport: transport)
            } catch {
                attemptsMade += 1
                let shouldRetry = attemptsMade < retryPolicy.maxAttempts &&
                                  methodAllowsRetry &&
                                  retryPolicy.shouldRetry(error, attemptsMade)
                guard shouldRetry else { throw error }

                let delay = error.retryAfter ?? retryPolicy.jitteredDelay(for: attemptsMade - 1)
                NetLog.retry.debug(
                    "retry \(attemptsMade, privacy: .public)/\(self.retryPolicy.maxAttempts - 1, privacy: .public) en \(String(describing: delay), privacy: .public) — \(String(describing: error), privacy: .public)"
                )
                do {
                    try await clock.sleep(for: delay)
                } catch let cancellation {
                    throw APIError(code: .cancelled, request: error.request, underlying: cancellation)
                }
            }
        }
    }

    /// Executes a single attempt through the pipeline.
    private func performOnce<Request: BaseRequest>(
        _ request: Request,
        transport: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws(APIError) -> (data: Data, response: HTTPURLResponse, request: APIError.RequestSummary) {
        var urlRequest = try buildURLRequest(from: request)

        for interceptor in interceptors {
            urlRequest = await interceptor.willSend(urlRequest)
        }

        let summary = APIError.RequestSummary(urlRequest)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(urlRequest)
        } catch let urlError as URLError {
            // `.cancelled` es la cancelación del llamador. El pinning que
            // rechaza un certificado también llega como `.cancelled` desde
            // Foundation: distinguirlo (→ `.untrustedServer`) exige el delegate
            // por tarea de CN-04; el código ya existe para que nada lo confunda.
            let code: APIError.Code = urlError.code == .cancelled ? .cancelled : .transport
            let apiError = APIError(code: code, request: summary, underlying: urlError)
            await notifyInterceptorsOfFailure(urlRequest, error: apiError)
            throw apiError
        } catch let cancellation as CancellationError {
            let apiError = APIError(code: .cancelled, request: summary, underlying: cancellation)
            await notifyInterceptorsOfFailure(urlRequest, error: apiError)
            throw apiError
        } catch {
            // Un APIError del transporte se respeta; cualquier otro error viaja
            // ENTERO en `underlying`. Nunca se pierde.
            let apiError = (error as? APIError) ?? APIError(code: .unexpected, request: summary, underlying: error)
            await notifyInterceptorsOfFailure(urlRequest, error: apiError)
            throw apiError
        }

        for interceptor in interceptors {
            await interceptor.didReceive(response, data: data)
        }

        // didFail se notifica en TODOS los caminos de error del pipeline:
        // transporte (arriba), respuesta inválida y status non-2xx.
        guard let httpResponse = response as? HTTPURLResponse else {
            let apiError = APIError(code: .invalidResponse, request: summary)
            await notifyInterceptorsOfFailure(urlRequest, error: apiError)
            throw apiError
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            // Status, headers y body tal cual: el sobre de error lo decodifica
            // el consumidor con `decodeBody`, no este paquete.
            let apiError = APIError(
                code: .httpStatus,
                request: summary,
                response: APIError.ResponseSummary(response: httpResponse, body: data)
            )
            await notifyInterceptorsOfFailure(urlRequest, error: apiError)
            throw apiError
        }

        return (data, httpResponse, summary)
    }

    /// Decodes the response body. Any failure — a `DecodingError` or anything
    /// else the decoder throws — becomes `.decoding`; the body stays attached
    /// via `response` so the consumer can inspect what actually came back.
    private static func decode<Response: Decodable>(
        _ type: Response.Type,
        from data: Data,
        request: APIError.RequestSummary,
        response: HTTPURLResponse,
        using makeDecoder: @Sendable () -> JSONDecoder
    ) throws(APIError) -> Response {
        do {
            return try makeDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError(
                code: .decoding,
                request: request,
                response: APIError.ResponseSummary(response: response, body: data),
                underlying: error
            )
        }
    }

    // MARK: - Helper Methods

    /// Builds a URLRequest from a BaseRequest with all features applied.
    private func buildURLRequest<Request: BaseRequest>(
        from request: Request
    ) throws(APIError) -> URLRequest {
        guard var urlComponents = URLComponents(
            url: configuration.baseURL.appendingPathComponent(request.path),
            resolvingAgainstBaseURL: true
        ) else {
            throw APIError(code: .invalidURL, request: APIError.RequestSummary(method: request.method, url: nil))
        }

        if let queryItems = request.queryItems, !queryItems.isEmpty {
            urlComponents.queryItems = queryItems
        }

        guard let url = urlComponents.url else {
            throw APIError(code: .invalidURL, request: APIError.RequestSummary(method: request.method, url: nil))
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = request.timeoutInterval

        // Merge headers: default headers first, request headers overwrite.
        for (key, value) in configuration.defaultHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        if let parameters = request.parameters {
            do {
                urlRequest.httpBody = try JSONEncoder().encode(parameters)
            } catch {
                // El error original (EncodingError u otro) nunca se pierde.
                throw APIError(
                    code: .encoding,
                    request: APIError.RequestSummary(method: request.method, url: url),
                    underlying: error
                )
            }
        }

        return urlRequest
    }

    /// Notifies all interceptors of a request failure.
    private func notifyInterceptorsOfFailure(_ request: URLRequest, error: APIError) async {
        for interceptor in interceptors {
            await interceptor.didFail(request, error: error)
        }
    }
}
